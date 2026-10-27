import AudioDSP
import AVFoundation
import NitMath
import QuartzCore
import UIKit

/// S0 Nit Laboratuvarı motoru.
///
/// S0 sadeleştirmesi: kod çözme, ses ve senkron `AVPlayer`'a bırakılır. Nit yolu kareleri
/// `AVPlayerItemVideoOutput`'tan alır; Referans yolu aynı oynatıcının `AVPlayerLayer`'ıdır.
/// Böylece iki yol aynı saatte kalır ve geçiş yalnızca katman görünürlüğüdür (K6).
/// MKV/FFmpeg ile kendi demux ve VideoToolbox hattımız S2'de gelir (02-cozum §10.2).
/// Laboratuvarın çalışma kipi: normal oynatma ya da testlerden biri.
enum LabMode: Equatable {
    case normal
    case equality(EqualityTrial)
    case tonality
}

/// Eşitlik testinin (S0-C) tek denemesi.
struct EqualityTrial: Equatable {
    var windowFraction: Double
    var levelNits: Double
    var nitOnLeft: Bool
    var blank = false
}

@MainActor
final class LabEngine: NSObject {
    let surface = VideoSurfaceView()
    let telemetry = Telemetry()

    var onSnapshot: ((LabSnapshot) -> Void)?
    var onStatusChange: ((HeadroomStatus) -> Void)?
    /// Rota değişince o rotanın hatırlanan boost değeri (kulaklığa geçince %100: güvenlik).
    var onBoostRecall: ((Double, AudioRouteClass) -> Void)?
    var chromeVisible = true
    var panelName = "yok"
    var loop = true {
        didSet { native?.loop = loop }
    }

    var params = NitParams() {
        didSet { paramsChanged(from: oldValue) }
    }

    private(set) var source: LabSource = .none
    private(set) var rendererAvailable: Bool
    private(set) var labMode: LabMode = .normal

    private let renderer: NitRenderer?
    private let player = AVPlayer()
    private var output: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private var endObserver: NSObjectProtocol?
    private var accessedURL: URL?
    private var sourceLabel = "yok"

    private var filter = HeadroomFilter()
    private var peakLock = PeakLock()
    private var snapshot = LabSnapshot()

    private var currentBuffer: CVPixelBuffer?
    private var currentFormat: FrameFormat?
    private var hdrHint = false
    private var frameDuration = 1.0 / 24
    private var lastDisplayPTS: Double?
    private var ticksSinceFrame = 0
    private var cadenceRing: [Int] = []
    private var jitterRing: [Double] = []
    private var lastTimestamp: CFTimeInterval?
    private var lastRenderedHeadroom = 0.0
    private var needsRender = true
    private var lastPeakEval = 0.0
    private var lastRowTime = 0.0
    private var lastSnapshotTime = 0.0
    private var lastObservedBrightness: Double?
    private var appSetBrightness: Double?
    private var initialBrightness: Double?
    private var switchStart: CFTimeInterval?
    private var lastParamEvent: CFTimeInterval = 0
    private var referencePatchDirty = true

    // Sahne bazlı referans beyaz (S0b, 02-cozum §3.5.1).
    private var sceneWhite = SceneWhiteEstimator()
    private var maxCLL: Double?
    private var anchorKey: String?
    private var lastAnchorSave: CFTimeInterval = 0
    private static let anchorPrefix = "nitLab.anchor."

    // Kendi hattımız (S2.2): MKV/M2TS ve istenirse MP4/MOV.
    private var native: NativePlayer?
    /// S3: tek saat. Ses renderer'ı ve Referans katmanı synchronizer'a bir kez eklenir, dosyalar arasında paylaşılır.
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private var loggedAudioLabel: String?
    private var loggedDialogEngine: String?
    private var loggedIsolationReport = false
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// M10 (S5): çıkış rotası ve oynatma saatine hizalı göstergeler.
    private var route = AudioRouteClass.current
    private var boostMeters = BoostMeters()
    private var lastBoostEvent: CFTimeInterval = 0
    /// DV P5'in şekillendirme verisi okunamazsa Nit yerine Referans gösterilir (yanlış renk yerine).
    private var nativeForcedReference = false
    private static let nativeExtensions: Set<String> = ["mkv", "webm", "m2ts", "mts", "ts"]

    // Dolby Vision RPU (S2.3): L1 sahne beyazı ve Referans'ta P7 → P8.1.
    private var dovi: DoviRpuProcessor?
    private var l1Validity = DolbyVisionL1Validity()
    /// Sahne beyazı şu an DV L1'den mi besleniyor? Değilse histogramdan.
    private var sceneWhiteFromL1 = false
    private var loggedElType: String?
    private var loggedRpuErrors = 0
    private var loggedReshapeFailures = 0
    /// DV P5 (S2.4): gösterilen karenin IPTPQc2 kod çözüm parametreleri; ilk parametreler gelene kadar kare çizilmez.
    private var currentDovi: DoviShaderParams?
    private var p5WaitingSince: CFTimeInterval?

    /// Kullanıcının seçtiği mod; P5 gibi durumlarda fiilen Referans gösterilir.
    private var effectiveMode: RenderMode { nativeForcedReference ? .reference : params.mode }

    override init() {
        renderer = NitRenderer()
        rendererAvailable = renderer != nil
        super.init()
        if let renderer {
            NitRenderer.configure(surface.metalLayer, device: renderer.device)
        } else {
            snapshot.errorMessage = "Metal başlatılamadı"
        }
        surface.playerLayer.player = player
        // Çok kanallı PCM ve native Atmos sistemin uzamsallaştırıcısına gider; stereo stereo kalır (02-cozum §5.3).
        audioRenderer.allowedAudioSpatializationFormats = .multichannel
        synchronizer.addRenderer(audioRenderer)
        synchronizer.addRenderer(surface.sampleLayer)
        surface.apply(.single(effectiveMode))
        surface.onLayout = { [weak self] in
            self?.needsRender = true
            self?.referencePatchDirty = true
        }
        player.preventsDisplaySleepDuringVideoPlayback = true
        filter = HeadroomFilter(tauUp: params.tauUpMs / 1000, deadband: params.deadbandPercent / 100)
        peakLock = PeakLock(config: params.peakLockConfig, enabled: params.peakLock)
        telemetry.setParams(params.csvSummary)
        // M9 (S4, AS-15): arka planda video atılır, diyalog F1'e geçer; dönüşte geri gelir.
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.backgroundChanged(true) }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.backgroundChanged(false) }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.routeChanged() }
            },
        ]
        snapshot.route = route
    }

    /// M9 + M10 ayarları ve rota (ses evresine).
    private var stageSettings: AudioStageSettings {
        AudioStageSettings(dialog: params.dialogSettings, boost: params.boostSettings, route: route)
    }

    private static func boostKey(_ route: AudioRouteClass) -> String { "boost.route." + route.rawValue }

    /// AS-37 testleri arasında kırpma/GR sayaçlarını sıfırlar.
    func resetBoostMeters() {
        boostMeters = BoostMeters()
        event("Boost göstergeleri sıfırlandı")
    }

    /// Rota değişti: tavan (BT −1,5 dBTP) ve hoparlör HPF'si yenilenir; boost o rotanın hatırlanan değerine döner (§5.5).
    private func routeChanged() {
        let newRoute = AudioRouteClass.current
        guard newRoute != route else { return }
        let old = route
        route = newRoute
        snapshot.route = newRoute
        let stored = UserDefaults.standard.double(forKey: Self.boostKey(newRoute))
        let recalled = stored >= 100 ? stored : 100
        event("Rota: \(old.rawValue) → \(newRoute.rawValue) · tavan \(TR.num(newRoute.ceilingDBTP, 1)) dBTP · boost %\(Int(recalled.rounded())) (rota hafızası)")
        native?.setAudioStage(stageSettings)
        if abs(recalled - params.boostPercent) > 0.01 { onBoostRecall?(recalled, newRoute) }
    }

    private func backgroundChanged(_ background: Bool) {
        native?.setBackground(background)
        guard native != nil else { return }
        event(background ? "Arka plan: video duruyor, ses sürüyor" + (params.dialogSettings.active ? " · diyalog → F1" : "")
                         : "Ön plan: video yeniden dolduruluyor")
    }

    // MARK: Yaşam döngüsü

    func start() {
        guard displayLink == nil else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        event("Laboratuvar açıldı")
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        player.pause()
        native?.stop()
        saveAnchor()
        UIApplication.shared.isIdleTimerDisabled = false
        // Kullanıcı arada değiştirmediyse parlaklığı giriş değerine döndür (02-cozum §3.6).
        if let screen, let initial = initialBrightness, let set = appSetBrightness,
           abs(Double(screen.brightness) - set) < 0.01 {
            screen.brightness = CGFloat(initial)
        }
        releaseAccess()
        event("Laboratuvar kapandı")
    }

    // MARK: Kaynaklar

    func load(url: URL) {
        endTest()
        saveAnchor()
        releaseAccess()
        if url.startAccessingSecurityScopedResource() { accessedURL = url }
        resetFrameState()
        source = .file(url)
        sourceLabel = url.lastPathComponent
        snapshot.errorMessage = nil
        snapshot.formatLabel = "Yükleniyor…"
        event("Dosya: \(sourceLabel)")

        if Self.nativeExtensions.contains(url.pathExtension.lowercased()) || params.preferNativeEngine {
            loadNative(url: url)
            return
        }
        surface.nativeBackend = false
        let asset = AVURLAsset(url: url)
        Task { [weak self] in
            do {
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    self?.fail("Dosyada video izi yok")
                    return
                }
                let (fps, characteristics, descriptions) = try await track.load(.nominalFrameRate, .mediaCharacteristics,
                                                                                .formatDescriptions)
                let light = descriptions.first.flatMap(Self.contentLightLevel)
                self?.attach(asset: asset, hdr: characteristics.contains(.containsHDRVideo), fps: Double(fps),
                             title: url.lastPathComponent, maxCLL: light?.maxCLL, maxFALL: light?.maxFALL)
            } catch {
                self?.fail("Dosya açılamadı: \(error.localizedDescription)")
            }
        }
    }

    func showPattern(_ spec: PatternSpec) {
        endTest()
        player.pause()
        resetFrameState()
        source = .pattern(spec)
        sourceLabel = spec.label
        snapshot.errorMessage = nil
        snapshot.formatLabel = spec.label
        snapshot.isHDR = spec.kind.isHDR
        needsRender = true
        event("Desen: \(spec.label)")
    }

    func togglePlay() {
        guard case .file = source else { return }
        if let native {
            native.setPlaying(!native.isPlaying)
            event(native.isPlaying ? "Oynat" : "Duraklat")
            return
        }
        if player.timeControlStatus == .playing {
            player.pause()
            event("Duraklat")
        } else {
            player.play()
            event("Oynat")
        }
    }

    func seek(to seconds: Double) {
        lastDisplayPTS = nil
        sceneWhite.markCut()
        if let native {
            native.seek(to: seconds)
            return
        }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func resetKnee() {
        peakLock.resetKnee()
        event("b_k sıfırlandı")
    }

    // MARK: Testler

    /// Tonalite testinde gerçek SDR video gerekir: soldaki Referans yolu Apple'ın SDR video işleyişidir.
    var canRunToneTest: Bool {
        // Sol yarı AVPlayerLayer'dır; kendi hattımızda bu test yok.
        if native == nil, case .file = source, let currentFormat { return !currentFormat.transfer.isHDR }
        return false
    }

    /// Eşitlik testi denemesi: bir yarıda Nit SDR × H, diğerinde sistemin ton eşlediği PQ beyaz.
    func beginEqualityTrial(windowFraction: Double, levelNits: Double, nitOnLeft: Bool) {
        player.pause()
        if let renderer {
            NitRenderer.configureReference(surface.referencePatchLayer, device: renderer.device, maxNits: levelNits)
        }
        labMode = .equality(EqualityTrial(windowFraction: windowFraction, levelNits: levelNits, nitOnLeft: nitOnLeft))
        surface.apply(.equality(nitOnLeft: nitOnLeft))
        updatePeakLockEnabled()
        referencePatchDirty = true
        needsRender = true
    }

    /// Denemeler arası siyah ekran.
    func blankEquality() {
        guard case .equality(var trial) = labMode else { return }
        trial.blank = true
        labMode = .equality(trial)
        surface.apply(.blank)
    }

    func beginToneTest() {
        guard canRunToneTest else { return }
        labMode = .tonality
        surface.apply(.tonality)
        updatePeakLockEnabled()
        needsRender = true
        event("Tonalite testi başladı")
    }

    func endTest() {
        guard labMode != .normal else { return }
        labMode = .normal
        surface.apply(.single(effectiveMode))
        updatePeakLockEnabled()
        needsRender = true
        event("Test bitti")
    }

    private func updatePeakLockEnabled() {
        // Tonalite testinde iki yarı aynı SDR beyazında karşılaştırılır; parlaklık sabit kalmalı.
        peakLock.enabled = params.peakLock && effectiveMode == .nit && labMode != .tonality
    }

    func exportCSV() throws -> URL {
        try telemetry.exportCSV()
    }

    func event(_ text: String) {
        telemetry.append(row(event: text))
    }

    // MARK: Özel

    private var screen: UIScreen? { surface.window?.windowScene?.screen }

    private func attach(asset: AVURLAsset, hdr: Bool, fps: Double, title: String, maxCLL: Double?, maxFALL: Double?) {
        hdrHint = hdr
        // Film çapası: ikinci izlemede önbellekten, yoksa MaxFALL'dan (02-cozum §3.5.1).
        self.maxCLL = maxCLL
        anchorKey = Self.anchorPrefix + title
        let cached = UserDefaults.standard.double(forKey: Self.anchorPrefix + title)
        let initialAnchor = cached > 0 ? cached : SceneWhiteEstimator.initialAnchor(maxFALL: maxFALL)
        sceneWhite = SceneWhiteEstimator(config: sceneWhiteConfig, initialAnchor: initialAnchor)
        lastAnchorSave = CACurrentMediaTime()
        if hdr {
            event("Sahne beyazı: başlangıç çapası \(TR.num(initialAnchor, 0)) nit (\(cached > 0 ? "önbellek" : maxFALL != nil ? "MaxFALL" : "varsayılan"))"
                  + (maxCLL.map { " · MaxCLL \(TR.num($0, 0))" } ?? ""))
        }
        frameDuration = fps > 0 ? 1 / fps : 1.0 / 24
        let pixelFormat = hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let output = AVPlayerItemVideoOutput(outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            AVVideoAllowWideColorKey: true,
        ])
        let item = AVPlayerItem(asset: asset)
        item.add(output)
        self.output = output

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEnd() }
        }

        player.replaceCurrentItem(with: item)
        snapshot.isHDR = hdr
        snapshot.formatLabel = hdr ? "HDR · biçim bekleniyor" : "SDR · biçim bekleniyor"
        player.play()
    }

    private func handleEnd() {
        saveAnchor()
        guard loop else { return }
        lastDisplayPTS = nil
        sceneWhite.markCut()
        player.seek(to: .zero)
        player.play()
        event("Döngü başa sardı")
    }

    private func fail(_ message: String) {
        snapshot.errorMessage = message
        snapshot.formatLabel = "Hata"
        event("Hata: \(message)")
    }

    private func releaseAccess() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }

    private func resetFrameState() {
        native?.stop()
        native = nil
        dovi = nil
        currentDovi = nil
        p5WaitingSince = nil
        sceneWhiteFromL1 = false
        snapshot.rpuSummary = nil
        snapshot.reshapeSummary = nil
        snapshot.rpuMeanMicros = nil
        snapshot.histogramWhite = nil
        nativeForcedReference = false
        surface.nativeBackend = false
        surface.apply(.single(effectiveMode))
        output = nil
        currentBuffer = nil
        currentFormat = nil
        lastDisplayPTS = nil
        ticksSinceFrame = 0
        cadenceRing.removeAll()
        snapshot.droppedFrames = 0
        renderer?.gpuStats.reset()
        renderer?.flushCache()
        needsRender = true
    }

    private func paramsChanged(from old: NitParams) {
        sceneWhite.config = sceneWhiteConfig
        filter.tauUp = params.tauUpMs / 1000
        filter.deadband = params.deadbandPercent / 100
        peakLock.config = params.peakLockConfig
        updatePeakLockEnabled()
        if params.mode != old.mode, labMode == .normal {
            switchStart = CACurrentMediaTime()
            surface.apply(.single(effectiveMode))
            native?.setOutput(effectiveMode == .nit ? .nit : .reference)
        }
        telemetry.setParams(params.csvSummary)
        if params.dialogSettings != old.dialogSettings || params.boostSettings != old.boostSettings {
            native?.setAudioStage(stageSettings)
        }
        if params.dialogSettings != old.dialogSettings {
            event("Diyalog: \(params.dialogSettings.label)" + (native == nil && params.dialogSettings.active ? " (yalnızca kendi hattımızda)" : ""))
        }
        if params.boostSettings != old.boostSettings {
            UserDefaults.standard.set(params.boostPercent, forKey: Self.boostKey(route))
            // Kaydırıcı sürüklenirken olaylar en fazla 2 Hz; kip değişimi hemen yazılır.
            let now = CACurrentMediaTime()
            if params.limiterMode != old.limiterMode || now - lastBoostEvent >= 0.5 {
                lastBoostEvent = now
                event("Boost: \(params.boostSettings.label)" + (native == nil && params.boostSettings.active ? " (yalnızca kendi hattımızda)" : ""))
            }
        }
        if params.rendererVolumeTest != old.rendererVolumeTest {
            audioRenderer.volume = params.rendererVolumeTest ? 1.5 : 1
            event("AS-37 g: renderer volume ← \(params.rendererVolumeTest ? "1,5" : "1,0") · okunan \(TR.num(Double(audioRenderer.volume), 2))")
        }
        needsRender = true
        // Kaydırıcı sürüklenirken CSV'yi boğmamak için parametre olayları en fazla 2 Hz yazılır.
        let now = CACurrentMediaTime()
        if params.mode != old.mode || now - lastParamEvent >= 0.5 {
            lastParamEvent = now
            event("Parametre: \(params.csvSummary)")
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTimestamp.map { now - $0 } ?? link.duration
        if let last = lastTimestamp, link.duration > 0 {
            // Bir sonraki vsync'e göre sapma; kaçırılan vsync'ler ayrıca kadansta görünür.
            let delta = now - last
            let periods = max(1, (delta / link.duration).rounded())
            jitterRing.append(abs(delta - periods * link.duration) * 1000)
            if jitterRing.count > 120 { jitterRing.removeFirst(jitterRing.count - 120) }
        }
        lastTimestamp = now

        guard let screen else { return }
        if initialBrightness == nil { initialBrightness = Double(screen.brightness) }

        let hCur = Double(screen.currentEDRHeadroom)
        let hPot = Double(screen.potentialEDRHeadroom)
        let hEff = filter.update(current: hCur, dt: dt)
        let brightness = Double(screen.brightness)
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let thermal = ProcessInfo.processInfo.thermalState
        let captured = surface.window?.traitCollection.sceneCaptureState == .active

        // P-1: uygulama parlaklığı asla düşürmez; dışarıdan gelen düşüşler yalnızca kaydedilir.
        if let previous = lastObservedBrightness, brightness < previous - 0.005 {
            snapshot.externalDimCount += 1
            event("Parlaklık dışarıdan düştü: \(TR.num(previous)) → \(TR.num(brightness))")
        }
        lastObservedBrightness = brightness

        // Tepe Kilidi ve durum, 10 Hz.
        if now - lastPeakEval >= 0.1 {
            lastPeakEval = now
            let result = peakLock.update(PeakLock.Input(
                time: now, current: hCur, potential: hPot, brightness: brightness, lowPower: lowPower,
                thermalSerious: thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue, captured: captured))
            if let target = result.brightness, target > brightness, effectiveMode == .nit {
                screen.brightness = CGFloat(target)
                appSetBrightness = target
                lastObservedBrightness = target
                event("Tepe Kilidi: parlaklık \(TR.num(brightness)) → \(TR.num(target))")
            }
            snapshot.raising = result.raising
            snapshot.kneeBrightness = peakLock.kneeBrightness
            if result.status != snapshot.status {
                event("Durum: \(snapshot.status.rawValue) → \(result.status.rawValue)")
                snapshot.status = result.status
                onStatusChange?(result.status)
            }
        }

        // Yeni video karesi: AVPlayer çıkışından ya da kendi hattımızın kuyruğundan.
        var newFramePTS: Double?
        var arrived: (buffer: CVPixelBuffer, pts: Double)?
        if case .file = source, let native {
            if native.currentOutput == .nit,
               let taken = native.frames.take(atOrBefore: native.mediaTime(atHostTime: link.targetTimestamp)) {
                arrived = (taken.frame.buffer, taken.frame.pts)
            }
        } else if case .file = source, let output {
            let itemTime = output.itemTime(forHostTime: link.targetTimestamp)
            if output.hasNewPixelBuffer(forItemTime: itemTime) {
                var displayTime = CMTime.invalid
                if let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime) {
                    arrived = (pb, displayTime.isValid ? displayTime.seconds : itemTime.seconds)
                }
            }
        }
        if case .file = source {
            if let arrived {
                let pb = arrived.buffer
                let pts = arrived.pts
                do {
                    if let last = lastDisplayPTS {
                        let gap = pts - last
                        if gap > frameDuration * 1.5, gap < 1 {
                            snapshot.droppedFrames += Int((gap / frameDuration).rounded()) - 1
                        }
                    }
                    lastDisplayPTS = pts
                    newFramePTS = pts
                    if ticksSinceFrame > 0 {
                        cadenceRing.append(ticksSinceFrame)
                        if cadenceRing.count > 12 { cadenceRing.removeFirst(cadenceRing.count - 12) }
                    }
                    ticksSinceFrame = 0
                    currentBuffer = pb
                    if currentFormat == nil {
                        let format = FrameFormat.from(pb, hdrHint: hdrHint)
                        currentFormat = format
                        let frameLabel = "\(CVPixelBufferGetWidth(pb))×\(CVPixelBufferGetHeight(pb)) · \(format.label)"
                        // Kendi hattımızda akış etiketi (codec, DV profili) korunur.
                        if native == nil { snapshot.formatLabel = frameLabel }
                        snapshot.isHDR = format.transfer.isHDR || (native?.info.isHDR ?? false)
                        event("Biçim: \(frameLabel)")
                    }
                    needsRender = true
                }
            }
            if isPlayingNow { ticksSinceFrame += 1 }
        }

        // DV P5 (S2.4): gösterilen karenin kod çözüm parametreleri; gelmezse önceki kare parametreleri sürer.
        if let dovi, dovi.decodesReshaping, let pts = newFramePTS {
            if let params = dovi.reshape(forPTS: pts) {
                currentDovi = params
                p5WaitingSince = nil
            } else if currentDovi == nil {
                waitForP5Parameters(now: now)
            }
        }
        // Sahne beyazı, DV: gösterilen karenin RPU L1'i (geçerliyse histogram yerine; §3.5.1 öncelik 1).
        if let dovi, let pts = newFramePTS, let l1 = dovi.l1(forPTS: pts) {
            updateSceneWhite(l1: l1, pts: pts)
        }
        // Sahne beyazı: önceki karelerin histogramları (bir karelik gecikme önemsiz; §3.5.1).
        if let result = renderer?.histograms.take() {
            updateSceneWhite(bins: result.bins, pts: result.pts)
        }
        if now - lastAnchorSave > 300 {
            lastAnchorSave = now
            saveAnchor()
        }

        // Headroom değişince statik kare de yeniden çizilir: düşüşte her zaman, yükselişte ≥ %1.
        if hEff < lastRenderedHeadroom - 1e-4 || abs(hEff - lastRenderedHeadroom) / max(lastRenderedHeadroom, 1) >= 0.01 {
            needsRender = true
        }

        if needsRender, let renderer {
            let presentAt = link.targetTimestamp
            switch labMode {
            case .normal:
                if effectiveMode == .nit {
                    var pattern: PatternSpec?
                    if case .pattern(let p) = source { pattern = p }
                    // Histogram yalnızca yeni HDR karelerinde; L_ref kipinden bağımsız (teşhis için de gerekir).
                    let wantsHistogram = pattern == nil && ((currentFormat?.transfer.isHDR ?? false) || currentDovi != nil)
                    snapshot.outputMax = renderer.render(layer: surface.metalLayer, pixelBuffer: renderableBuffer, format: currentFormat,
                                                         pattern: pattern, settings: renderSettings(pattern: pattern), headroom: hEff,
                                                         presentAt: presentAt, histogramPTS: wantsHistogram ? newFramePTS : nil,
                                                         dovi: currentDovi)
                } else {
                    snapshot.outputMax = 0
                }
            case .equality(let trial):
                if !trial.blank {
                    let nitCenter = trial.nitOnLeft ? 0.25 : 0.75
                    let spec = PatternSpec(kind: .sdrWindow, windowFraction: trial.windowFraction, levelNits: trial.levelNits,
                                           centerX: nitCenter)
                    snapshot.outputMax = renderer.render(layer: surface.metalLayer, pixelBuffer: nil, format: nil, pattern: spec,
                                                         settings: renderSettings(pattern: spec), headroom: hEff, presentAt: presentAt)
                    if referencePatchDirty {
                        renderer.renderReferencePatch(layer: surface.referencePatchLayer, windowFraction: trial.windowFraction,
                                                      centerX: 1 - nitCenter, nits: trial.levelNits)
                        referencePatchDirty = false
                    }
                }
            case .tonality:
                // Sağ yarı: Nit yolu, H = 1'e zorlanmış; sol yarıdaki Apple SDR video işleyişiyle aynı beyazda.
                snapshot.outputMax = renderer.render(layer: surface.metalLayer, pixelBuffer: renderableBuffer, format: currentFormat,
                                                     pattern: nil, settings: renderSettings(pattern: nil), headroom: 1,
                                                     presentAt: presentAt, dovi: currentDovi)
            }
            lastRenderedHeadroom = hEff
            needsRender = false
        }

        if let start = switchStart {
            snapshot.lastSwitchMs = (CACurrentMediaTime() - start) * 1000
            event("Geçiş: \(params.mode.rawValue) · \(TR.num(snapshot.lastSwitchMs ?? 0, 0)) ms")
            switchStart = nil
        }

        snapshot.hCur = hCur
        snapshot.hPot = hPot
        snapshot.hSmoothed = filter.smoothed
        snapshot.hEff = effectiveMode == .nit ? hEff : hCur
        snapshot.brightness = brightness
        snapshot.thermal = thermal
        snapshot.lowPower = lowPower
        snapshot.captured = captured

        if now - lastRowTime >= 0.5 {
            lastRowTime = now
            telemetry.append(row(event: ""))
        }
        if now - lastSnapshotTime >= 0.1 {
            lastSnapshotTime = now
            let (p50, p95) = renderer?.gpuStats.percentiles() ?? (0, 0)
            snapshot.gpuP50 = p50
            snapshot.gpuP95 = p95
            snapshot.cadence = cadenceLabel()
            snapshot.vsyncJitterMs = jitterRing.max() ?? 0
            if let native {
                snapshot.currentTime = native.mediaTime
                snapshot.duration = native.info.duration
            } else {
                snapshot.currentTime = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
                let duration = player.currentItem?.duration.seconds ?? 0
                snapshot.duration = duration.isFinite ? duration : 0
            }
            snapshot.playing = isPlayingNow
            snapshot.recordingSeconds = telemetry.elapsed
            fillAudioSnapshot()
            fillAudioStageSnapshot()
            fillSceneWhiteSnapshot()
            fillRpuSnapshot()
            onSnapshot?(snapshot)
        }
    }

    // MARK: Kendi hattımız

    private var isPlayingNow: Bool {
        native?.isPlaying ?? (player.timeControlStatus == .playing)
    }

    private func loadNative(url: URL) {
        player.replaceCurrentItem(with: nil)
        let path = url.path
        let output: NativePlayer.Output = params.mode == .nit ? .nit : .reference
        let title = url.lastPathComponent
        let synchronizer = self.synchronizer
        let audioRenderer = self.audioRenderer
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let player = try NativePlayer(path: path, output: output, synchronizer: synchronizer,
                                              audioRenderer: audioRenderer)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.attachNative(player, title: title) } }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.fail(message) } }
            }
        }
    }

    private func attachNative(_ player: NativePlayer, title: String) {
        // Açılış sürerken kullanıcı başka bir kaynak seçtiyse bu oyuncu kullanılmaz.
        guard case .file(let url) = source, url.lastPathComponent == title, native == nil else {
            player.stop()
            return
        }
        native = player
        let info = player.info
        hdrHint = info.isHDR
        frameDuration = info.frameRate > 0 ? 1 / info.frameRate : 1.0 / 24
        maxCLL = info.maxCLL
        let key = Self.anchorPrefix + title
        anchorKey = key
        let cached = UserDefaults.standard.double(forKey: key)
        let initialAnchor = cached > 0 ? cached : SceneWhiteEstimator.initialAnchor(maxFALL: info.maxFALL)
        sceneWhite = SceneWhiteEstimator(config: sceneWhiteConfig, initialAnchor: initialAnchor)
        lastAnchorSave = CACurrentMediaTime()

        // DV: Nit yolunda L1 okunur; P7 Referans'ta P8.1 olarak bildirilir (EL atılır, RPU dönüştürülür).
        dovi = DoviRpuProcessor(info: info)
        l1Validity = DolbyVisionL1Validity()
        sceneWhiteFromL1 = false
        loggedElType = nil
        loggedRpuErrors = 0
        var referenceNote = ""
        if let dovi {
            player.nitPacketObserver = { @Sendable packet in dovi.observe(packet) }
            if let source = info.dovi, let config = DoviRpuProcessor.referenceConfig(for: source) {
                player.referencePacketRewriter = { @Sendable packet in dovi.rewriteForReference(packet) }
                player.setReferenceDovi(config)
                referenceNote = " · Referans'ta \(config.label)"
            }
        }

        nativeForcedReference = false
        currentDovi = nil
        p5WaitingSince = nil
        loggedReshapeFailures = 0
        surface.nativeBackend = true
        player.attach(renderer: surface.sampleLayer.sampleBufferRenderer)
        player.loop = loop
        player.onLoop = { [weak self] in MainActor.assumeIsolated { self?.nativeLooped() } }
        player.onError = { [weak self] message in MainActor.assumeIsolated { self?.fail(message) } }
        player.setOutput(effectiveMode == .nit ? .nit : .reference)
        player.setAudioStage(stageSettings)
        boostMeters = BoostMeters()
        player.setBackground(UIApplication.shared.applicationState == .background)
        loggedDialogEngine = nil
        loggedIsolationReport = false
        surface.apply(.single(effectiveMode))
        updatePeakLockEnabled()

        snapshot.isHDR = info.isHDR
        snapshot.formatLabel = info.label + referenceNote + " · kendi hattımız"
        if dovi?.decodesReshaping == true {
            event("DV P5: Nit'te IPTPQc2 kod çözümü (RPU şekillendirme + IPT → LMS → BT.2020)")
        }
        event("Kendi hattımız: \(info.label)" + (info.maxCLL.map { " · MaxCLL \(Int($0))" } ?? "")
              + " · çapa \(TR.num(initialAnchor, 0)) nit")
        loggedAudioLabel = nil
        if let audio = player.audioInfo {
            let language = audio.language.map { " · \($0)" } ?? ""
            event("Ses izi: \(audio.codecName) · \(audio.channels) kanal · \(audio.sampleRate) Hz\(language)"
                  + (audio.profile == 30 ? " · Atmos" : ""))
            if let error = player.audioOpenError { event("Ses açılamadı: \(error) (görüntü sessiz oynar)") }
        } else {
            event("Dosyada ses izi yok")
        }
        player.start()
    }

    /// Ses satırı (HUD) ve yol değişince tek seferlik olay (ör. "E-AC-3 JOC → Apple (Dolby Atmos)").
    private func fillAudioSnapshot() {
        guard let native else {
            snapshot.audioSummary = nil
            snapshot.audioCPUPercent = nil
            return
        }
        guard let status = native.audioStatus else {
            if native.audioInfo == nil {
                snapshot.audioSummary = "Ses: yok"
            } else {
                snapshot.audioSummary = "Ses: \(native.audioInfo?.codecName ?? "?") açılamadı"
            }
            snapshot.audioCPUPercent = nil
            return
        }
        snapshot.audioSummary = status.label
        snapshot.audioCPUPercent = status.decodeCPUPercent
        let key = "\(status.codec) \(status.layout) \(status.path)"
        if key != loggedAudioLabel {
            loggedAudioLabel = key
            event(status.label)
        }
    }

    /// M9 ve M10 satırları (HUD), göstergeler ve tek seferlik olaylar: motor değişimi, AS-12 raporu.
    private func fillAudioStageSnapshot() {
        guard let native, let status = native.audioStageStatus else {
            snapshot.audioStage = nil
            snapshot.boostMeters = nil
            snapshot.audioStageLines = params.dialogSettings.active || params.boostSettings.active
                ? ["Diyalog ve boost yalnızca kendi hattımızda (MKV/M2TS ya da MP4 için kendi hattımız)"] : []
            return
        }
        snapshot.audioStage = status
        boostMeters.ingest(native.takeAudioMeters(), now: native.mediaTime)
        snapshot.boostMeters = status.settings.active ? boostMeters : nil
        guard status.settings.active else {
            var lines: [String] = []
            if params.boostKeepAtmos, params.boostSettings.active, native.audioStatus?.path == .atmos {
                lines.append("Atmos korunuyor: boost %100'e kilitli (Atmos'u koru)")
            }
            snapshot.audioStageLines = lines
            return
        }
        var lines: [String] = []
        let dialog = status.settings.dialog
        if let layout = status.decodedLayout, let path = native.audioStatus?.path, path != .pcm {
            let reason = dialog.active && status.settings.boost.active ? "diyalog ve boost" : dialog.active ? "diyalog" : "boost"
            lines.append("\(path == .atmos ? "Atmos" : "Dolby") → \(layout) yatak (\(reason) için)")
        }
        if let error = status.decodeError { lines.append("Dolby çözülemedi, ses değişmeden geçiyor: \(error)") }
        if dialog.active { lines += dialogLines(status) }
        lines += boostLines(status)
        var stage = "evre gecikmesi \(TR.num(status.latencyMs, 0)) ms"
        if let cpu = status.stageCPUPercent { stage += " · yük %\(TR.num(cpu, 1))" }
        if let ms = status.lastReprocessMs { stage += " · yeniden işleme \(TR.num(ms, 0)) ms" }
        lines.append(stage)
        snapshot.audioStageLines = lines
    }

    private func dialogLines(_ status: AudioStageStatus) -> [String] {
        var lines: [String] = []
        var head = "Diyalog \(status.settings.dialog.label) → \(status.engine)"
        if let note = status.engineNote { head += " (\(note))" }
        lines.append(head + " · r \(TR.num(status.relaxation)) · c \(TR.num(status.compensationDB, 1)) dB")
        if let au = status.isolation {
            lines.append("AU \(au.format)")
            var latency = "AU gecikme: bildirilen \(TR.num(au.declaredLatencyMs, 1)) · kullanılan \(TR.num(au.usedLatencyMs, 1)) ms"
            if let measured = au.measuredLatencyMs, let rho = au.measuredCorrelation {
                latency += " · ölçülen \(TR.num(measured, 1)) (ρ \(TR.num(Double(rho))))"
            }
            lines.append(latency)
            if let cpu = au.cpuPercent, let wall = au.wallPercent {
                var load = "AU yük: CPU %\(TR.num(cpu, 1)) · duvar %\(TR.num(wall, 1)) → \(au.computeHint)"
                if let worst = au.worstBlockMs { load += " · blok ≤ \(TR.num(worst, 2)) ms" }
                if au.renderErrors > 0 { load += " · hata \(au.renderErrors)" }
                lines.append(load)
            }
            if !loggedIsolationReport {
                loggedIsolationReport = true
                var text = "AS-12: AUSoundIsolation \(au.format) · kabul: \(au.accepted) · bildirilen gecikme \(TR.num(au.declaredLatencyMs, 1)) ms"
                if let calibrated = au.calibratedLatencyMs, let rho = au.calibrationCorrelation {
                    text += " · kalibrasyon \(TR.num(calibrated, 1)) ms (ρ \(TR.num(Double(rho))))"
                }
                text += " · kullanılan \(TR.num(au.usedLatencyMs, 1)) ms"
                if let error = au.lastError { text += " · not: \(error)" }
                event(text)
            }
        } else if let state = status.isolationState {
            lines.append("AU: \(state)")
        }
        if let music = status.music {
            var text = "SA: müzik \(TR.num(music.music)) · şarkı \(TR.num(music.singing)) · konuşma \(TR.num(music.speech))"
            if let ms = status.musicMsPerDecision { text += " · \(TR.num(ms, 1)) ms/karar" }
            lines.append(text)
        } else if let error = status.musicError {
            lines.append("SA: \(error)")
        }
        let engineKey = status.engine + (status.engineNote ?? "")
        if engineKey != loggedDialogEngine {
            loggedDialogEngine = engineKey
            event("Diyalog motoru: \(status.engine)" + (status.engineNote.map { " (\($0))" } ?? ""))
        }
        return lines
    }

    /// M10: etkin kazanç dürüstçe; limiter kiplerinde GR, kapalıda kırpma LED'i ve sayaçlar (§5.5 göstergeler).
    private func boostLines(_ status: AudioStageStatus) -> [String] {
        let boost = status.settings.boost
        let m = boostMeters
        var lines: [String] = []
        var head = "Boost %\(Int(boost.percent.rounded())) → hedef +\(TR.num(boost.gainDB, 1)) dB"
        if let applied = m.appliedGainDB {
            head += " · etkin +\(TR.num(max(applied, 0), 1)) dB"
            if boost.mode == .smart, boost.active, applied < boost.gainDB - 1 { head += " (içerik zaten tavanda)" }
        }
        head += " · \(boost.mode.rawValue)" + (boost.aggressive ? " (Agresif)" : "")
        lines.append(head)
        switch boost.mode {
        case .smart, .limiterOnly:
            var text = "GR \(TR.num(m.gainReductionDB, 1)) dB · 1 s tepe \(TR.num(m.gainReductionPeakDB, 1)) dB · tavan \(TR.num(status.ceilingDBTP, 1)) dBTP"
            if let heavy = m.heavyReductionFraction { text += " · GR>3 dB %\(TR.num(heavy * 100, 1))" }
            if m.truePeakOvers > 0 { text += " · tavan aşımı \(m.truePeakOvers)" }
            lines.append(text)
        case .off, .rawFloat:
            let led = m.clipLit ? "● KIRPMA" : "○ kırpma"
            var text = "\(led) · toplam \(m.clipCount) (son 1 s \(m.clipsLastSecond))"
            if m.clipsTotal.count > 1 { text += " · " + m.clipsTotal.map(String.init).joined(separator: "/") }
            if let peak = m.maxPeakDBFS, peak > 0 { text += " · en büyük +\(TR.num(peak, 1)) dBFS" }
            text += " · TP>0: \(m.truePeakOvers)"
            if boost.mode == .rawFloat { text += " · ham float (kırpılmadı)" }
            lines.append(text)
        }
        var notes: [String] = []
        if status.highPassActive { notes.append("hoparlör HPF 150 Hz") }
        if boost.active {
            switch route {
            case .headphones, .bluetooth: notes.append("iOS kulaklık güvenliği yüksek sesi sınırlayabilir")
            case .usb: notes.append("Bit-perfect değil · Boost +\(TR.num(boost.gainDB, 1)) dB")
            default: break
            }
        }
        if params.rendererVolumeTest { notes.append("renderer volume \(TR.num(Double(audioRenderer.volume), 2)) (AS-37 g)") }
        if !notes.isEmpty { lines.append("rota \(route.rawValue): " + notes.joined(separator: " · ")) }
        return lines
    }

    /// P5 karesi kod çözüm parametreleri olmadan geldi. 2 sn içinde gelmezse Referans'a geçilir:
    /// IPTPQc2'yi HDR10 gibi göstermek yeşil/mor bir görüntü verir.
    private func waitForP5Parameters(now: CFTimeInterval) {
        guard let since = p5WaitingSince else {
            p5WaitingSince = now
            return
        }
        guard now - since > 2, !nativeForcedReference else { return }
        nativeForcedReference = true
        surface.apply(.single(effectiveMode))
        native?.setOutput(.reference)
        updatePeakLockEnabled()
        let reason = dovi?.currentStats.lastReshapeError ?? "RPU'da şekillendirme verisi yok"
        snapshot.errorMessage = "DV P5 kod çözümü kurulamadı (\(reason)); Referans gösteriliyor"
        event("DV P5: şekillendirme 2 sn içinde okunamadı → Referans (\(reason))")
    }

    /// DV P5'te parametreler hazır değilse kare çizilmez (yanlış renk yerine siyah).
    private var renderableBuffer: CVPixelBuffer? {
        if dovi?.decodesReshaping == true, currentDovi == nil { return nil }
        return currentBuffer
    }

    private func nativeLooped() {
        lastDisplayPTS = nil
        sceneWhite.markCut()
        saveAnchor()
        event("Döngü başa sardı")
    }

    // MARK: Sahne beyazı

    private var sceneWhiteConfig: SceneWhiteEstimator.Config {
        var c = SceneWhiteEstimator.Config()
        c.deviationStops = params.sceneDeviationStops
        c.cutThreshold = params.cutThreshold
        return c
    }

    /// Kullanılacak L_ref ve kaynağı. Desenlerde sahne tahmini kullanılmaz (ölçümü bozmasın).
    private func resolvedReferenceWhite(pattern: PatternSpec?) -> (nits: Double, source: String) {
        switch params.referenceWhiteMode {
        case .fixed:
            return (NitTone.defaultReferenceWhiteNits, "sabit 203")
        case .manual:
            return (params.referenceWhiteNits, "elle")
        case .scene:
            if pattern != nil { return (NitTone.defaultReferenceWhiteNits, "desen: sabit 203") }
            let state = sceneWhite.state
            if sceneWhiteFromL1 { return (state.referenceWhite, "DV L1 (k = \(TR.num(sceneWhite.config.doviK, 0)))") }
            return (state.referenceWhite, state.sceneCount > 0 ? "histogram P90" : "çapa (histogram bekleniyor)")
        }
    }

    private func renderSettings(pattern: PatternSpec?) -> RenderSettings {
        var settings = params.renderSettings
        settings.referenceWhiteNits = resolvedReferenceWhite(pattern: pattern).nits
        return settings
    }

    private func updateSceneWhite(bins: [UInt32], pts: Double) {
        // DV L1 kullanılırken histogram yalnızca karşılaştırma içindir (AS-38: `k` kalibrasyonu).
        if sceneWhiteFromL1 {
            var p90 = SceneWhiteEstimator.percentileNits(bins, percentile: sceneWhite.config.percentile,
                                                         minNits: sceneWhite.config.minNits)
            if let cll = maxCLL, cll > 0, let w = p90 { p90 = min(w, cll) }
            snapshot.histogramWhite = p90
            return
        }
        snapshot.histogramWhite = nil
        let before = sceneWhite.state.referenceWhite
        sceneWhite.update(histogram: bins, time: pts, maxCLL: maxCLL)
        let state = sceneWhite.state
        if state.cut {
            event("Sahne kesimi · d \(TR.num(state.cutDistance, 3)) · kare beyazı \(state.frameWhite.map { TR.num($0, 0) } ?? "—") nit")
        }
        sceneWhiteChanged(from: before)
    }

    /// DV yolu: `W = min(k · avg, max)`; kesim `scene_refresh_flag` ya da L1 değişimi.
    private func updateSceneWhite(l1: DoviL1, pts: Double) {
        let wasValid = l1Validity.isValid
        guard l1Validity.observe(averagePQ: l1.averagePQ, maxPQ: l1.maxPQ, time: pts) else {
            if wasValid {
                if sceneWhiteFromL1 { sceneWhite.markCut() }
                sceneWhiteFromL1 = false
                event("DV L1 geçersiz (max_pq = \(l1.maxPQ) ya da 2 dk sabit) → histogram P90")
            }
            return
        }
        if !sceneWhiteFromL1 {
            sceneWhiteFromL1 = true
            sceneWhite.markCut()
            event("Sahne beyazı kaynağı: DV L1 (k = \(TR.num(sceneWhite.config.doviK, 0)))")
        }
        let before = sceneWhite.state.referenceWhite
        sceneWhite.update(l1AveragePQ: l1.averagePQ, l1MaxPQ: l1.maxPQ, time: pts, sceneRefresh: l1.sceneRefresh,
                          maxCLL: maxCLL)
        let state = sceneWhite.state
        if state.cut {
            let average = PQ.eotf(Double(l1.averagePQ) / 4095)
            let maximum = PQ.eotf(Double(l1.maxPQ) / 4095)
            event("Sahne kesimi (DV\(l1.sceneRefresh ? " refresh" : " L1")) · avg \(TR.num(average, 1)) · max \(TR.num(maximum, 0)) · "
                  + "kare beyazı \(state.frameWhite.map { TR.num($0, 0) } ?? "—") nit")
        }
        sceneWhiteChanged(from: before)
    }

    /// Statik karede L_ref değişirse yeniden çiz (yalnızca sahne kipinde etkili).
    private func sceneWhiteChanged(from before: Double) {
        if params.referenceWhiteMode == .scene, abs(sceneWhite.state.referenceWhite - before) / before >= 0.005 {
            needsRender = true
        }
    }

    /// RPU özeti (HUD) ve tek seferlik olaylar: EL türü, ilk hata.
    private func fillRpuSnapshot() {
        guard let dovi else { return }
        let stats = dovi.currentStats
        guard stats.rpus > 0 else {
            snapshot.rpuSummary = "RPU: henüz yok"
            return
        }
        var parts = ["RPU \(stats.rpus)"]
        if let profile = stats.guessedProfile { parts.append("P\(profile)" + (stats.elType.map { " \($0)" } ?? "")) }
        if stats.conversions > 0 { parts.append("→ 8.1 ×\(stats.conversions)") }
        parts.append("ort \(TR.num(stats.meanMicros / 1000, 2)) · en kötü \(TR.num(stats.maxMicros / 1000, 2)) ms")
        if stats.errors > 0 { parts.append("hata \(stats.errors)") }
        snapshot.rpuSummary = parts.joined(separator: " · ")
        snapshot.rpuMeanMicros = stats.meanMicros
        if dovi.decodesReshaping {
            var text = "P5 Nit: " + (stats.reshapeSummary ?? "eşleme bekleniyor")
            if stats.reshapeChanges > 1 { text += " · \(stats.reshapeChanges) eşleme" }
            if stats.reshapeFailures > 0 { text += " · okunamayan \(stats.reshapeFailures)" }
            snapshot.reshapeSummary = text
            if stats.reshapeFailures > 0, loggedReshapeFailures == 0 {
                event("DV P5 şekillendirme hatası: \(stats.lastReshapeError ?? "?") (önceki eşleme sürüyor)")
            }
            loggedReshapeFailures = stats.reshapeFailures
        }

        if let el = stats.elType, el != loggedElType {
            loggedElType = el
            event("DV P7 EL türü: \(el) → Referans'ta P8.1, kip \(el == "FEL" ? "2 (eşleme etkisiz)" : "4 (eşleme korunur)")")
        }
        if stats.errors > 0, loggedRpuErrors == 0 {
            event("RPU hatası: \(stats.lastError ?? "?")")
        }
        loggedRpuErrors = stats.errors
    }

    private func fillSceneWhiteSnapshot() {
        var pattern: PatternSpec?
        if case .pattern(let p) = source { pattern = p }
        let ref = resolvedReferenceWhite(pattern: pattern)
        snapshot.referenceWhite = ref.nits
        snapshot.referenceWhiteSource = ref.source
        snapshot.sceneCount = sceneWhite.state.sceneCount
        if pattern == nil, snapshot.isHDR, sceneWhite.state.sceneCount > 0 {
            let state = sceneWhite.state
            snapshot.frameWhite = state.frameWhite
            snapshot.sceneWhite = state.smoothedWhite
            snapshot.anchor = state.anchor
            snapshot.whiteFractionOfH = params.curve(state.smoothedWhite / ref.nits)
        } else {
            snapshot.frameWhite = nil
            snapshot.sceneWhite = nil
            snapshot.anchor = nil
            snapshot.whiteFractionOfH = nil
        }
    }

    private func saveAnchor() {
        guard let anchorKey, hdrHint, sceneWhite.state.sceneCount > 0 else { return }
        UserDefaults.standard.set(sceneWhite.state.anchor, forKey: anchorKey)
    }

    /// HDR10 içerik ışık seviyesi (MaxCLL, MaxFALL); 4 bayt, büyük uçlu.
    nonisolated static func contentLightLevel(_ description: CMFormatDescription) -> (maxCLL: Double, maxFALL: Double)? {
        guard let data = CMFormatDescriptionGetExtension(description,
                                                         extensionKey: kCMFormatDescriptionExtension_ContentLightLevelInfo) as? Data,
              data.count >= 4 else { return nil }
        let b = [UInt8](data)
        let cll = Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        let fall = Double(UInt16(b[2]) << 8 | UInt16(b[3]))
        guard cll > 0 || fall > 0 else { return nil }
        return (cll, fall)
    }

    private func cadenceLabel() -> String {
        let recent = cadenceRing.suffix(8)
        guard recent.count >= 4 else { return "—" }
        let set = Set(recent)
        if set == [2, 3] { return "3:2" }
        if set.count == 1, let n = set.first { return "\(n):\(n)" }
        return recent.map { String($0) }.joined(separator: " ")
    }

    private func row(event: String) -> Telemetry.Row {
        Telemetry.Row(
            t: telemetry.elapsed, date: Date(),
            hCur: snapshot.hCur, hPot: snapshot.hPot, hS: snapshot.hSmoothed, hEff: snapshot.hEff,
            brightness: snapshot.brightness, status: snapshot.status.rawValue, mode: params.mode.rawValue,
            source: sourceLabel, thermal: snapshot.thermal.label, lowPower: snapshot.lowPower, captured: snapshot.captured,
            gpuP50: snapshot.gpuP50, gpuP95: snapshot.gpuP95, dropped: snapshot.droppedFrames, cadence: snapshot.cadence,
            jitterMs: snapshot.vsyncJitterMs, outputMax: snapshot.outputMax, playing: snapshot.playing,
            referenceWhite: snapshot.referenceWhite, frameWhite: snapshot.frameWhite, sceneWhite: snapshot.sceneWhite,
            anchor: snapshot.anchor, histogramWhite: snapshot.histogramWhite, rpuMicros: snapshot.rpuMeanMicros,
            audioCPU: snapshot.audioCPUPercent, audioStage: snapshot.audioStage, boostMeters: snapshot.boostMeters,
            route: route.rawValue, chromeVisible: chromeVisible, panel: panelName, event: event)
    }
}
