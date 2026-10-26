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
    var chromeVisible = true
    var panelName = "yok"
    var loop = true

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
        surface.apply(.single(params.mode))
        surface.onLayout = { [weak self] in
            self?.needsRender = true
            self?.referencePatchDirty = true
        }
        player.preventsDisplaySleepDuringVideoPlayback = true
        filter = HeadroomFilter(tauUp: params.tauUpMs / 1000, deadband: params.deadbandPercent / 100)
        peakLock = PeakLock(config: params.peakLockConfig, enabled: params.peakLock)
        telemetry.setParams(params.csvSummary)
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
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func resetKnee() {
        peakLock.resetKnee()
        event("b_k sıfırlandı")
    }

    // MARK: Testler

    /// Tonalite testinde gerçek SDR video gerekir: soldaki Referans yolu Apple'ın SDR video işleyişidir.
    var canRunToneTest: Bool {
        if case .file = source, let currentFormat { return !currentFormat.transfer.isHDR }
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
        surface.apply(.single(params.mode))
        updatePeakLockEnabled()
        needsRender = true
        event("Test bitti")
    }

    private func updatePeakLockEnabled() {
        // Tonalite testinde iki yarı aynı SDR beyazında karşılaştırılır; parlaklık sabit kalmalı.
        peakLock.enabled = params.peakLock && params.mode == .nit && labMode != .tonality
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
            surface.apply(.single(params.mode))
        }
        telemetry.setParams(params.csvSummary)
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
            if let target = result.brightness, target > brightness, params.mode == .nit {
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

        // Yeni video karesi.
        var newFramePTS: Double?
        if case .file = source, let output {
            let itemTime = output.itemTime(forHostTime: link.targetTimestamp)
            if output.hasNewPixelBuffer(forItemTime: itemTime) {
                var displayTime = CMTime.invalid
                if let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime) {
                    let pts = displayTime.isValid ? displayTime.seconds : itemTime.seconds
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
                        snapshot.formatLabel = "\(CVPixelBufferGetWidth(pb))×\(CVPixelBufferGetHeight(pb)) · \(format.label)"
                        snapshot.isHDR = format.transfer.isHDR
                        event("Biçim: \(snapshot.formatLabel)")
                    }
                    needsRender = true
                }
            }
            if player.timeControlStatus == .playing { ticksSinceFrame += 1 }
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
                if params.mode == .nit {
                    var pattern: PatternSpec?
                    if case .pattern(let p) = source { pattern = p }
                    // Histogram yalnızca yeni HDR karelerinde; L_ref kipinden bağımsız (teşhis için de gerekir).
                    let wantsHistogram = pattern == nil && (currentFormat?.transfer.isHDR ?? false)
                    snapshot.outputMax = renderer.render(layer: surface.metalLayer, pixelBuffer: currentBuffer, format: currentFormat,
                                                         pattern: pattern, settings: renderSettings(pattern: pattern), headroom: hEff,
                                                         presentAt: presentAt, histogramPTS: wantsHistogram ? newFramePTS : nil)
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
                snapshot.outputMax = renderer.render(layer: surface.metalLayer, pixelBuffer: currentBuffer, format: currentFormat,
                                                     pattern: nil, settings: renderSettings(pattern: nil), headroom: 1,
                                                     presentAt: presentAt)
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
        snapshot.hEff = params.mode == .nit ? hEff : hCur
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
            snapshot.currentTime = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
            let duration = player.currentItem?.duration.seconds ?? 0
            snapshot.duration = duration.isFinite ? duration : 0
            snapshot.playing = player.timeControlStatus == .playing
            snapshot.recordingSeconds = telemetry.elapsed
            fillSceneWhiteSnapshot()
            onSnapshot?(snapshot)
        }
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
            return (state.referenceWhite, state.sceneCount > 0 ? "histogram P90" : "çapa (histogram bekleniyor)")
        }
    }

    private func renderSettings(pattern: PatternSpec?) -> RenderSettings {
        var settings = params.renderSettings
        settings.referenceWhiteNits = resolvedReferenceWhite(pattern: pattern).nits
        return settings
    }

    private func updateSceneWhite(bins: [UInt32], pts: Double) {
        let before = sceneWhite.state.referenceWhite
        sceneWhite.update(histogram: bins, time: pts, maxCLL: maxCLL)
        let state = sceneWhite.state
        if state.cut {
            event("Sahne kesimi · d \(TR.num(state.cutDistance, 3)) · kare beyazı \(state.frameWhite.map { TR.num($0, 0) } ?? "—") nit")
        }
        // Statik karede L_ref değişirse yeniden çiz (yalnızca sahne kipinde etkili).
        if params.referenceWhiteMode == .scene, abs(state.referenceWhite - before) / before >= 0.005 {
            needsRender = true
        }
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
            anchor: snapshot.anchor, chromeVisible: chromeVisible, panel: panelName, event: event)
    }
}
