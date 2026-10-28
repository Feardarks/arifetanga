import AudioDSP
import AVFoundation
import CoreMedia
import Foundation
import MediaFormat

/// M9 ayarları (ana thread yazar, demux thread'i uygular).
struct DialogSettings: Equatable {
    enum Engine: String, CaseIterable {
        /// Ön planda AUSoundIsolation, arka planda F1 (02-cozum §5.4).
        case automatic = "Otomatik"
        /// Arka planda da AUSoundIsolation (AS-15: arka planda çalışıyor mu?). Hata verirse F1.
        case soundIsolation = "AU"
        /// Her zaman F1 (DSP merkez çıkarma).
        case dsp = "DSP (F1)"
    }

    var tier = 0
    var engine: Engine = .automatic
    var solo = false
    var highQuality = false

    var active: Bool { tier > 0 || solo }

    var label: String {
        guard active else { return "kapalı" }
        let level = solo ? "solo (yalnızca ayrılmış ses)" : "K\(tier) +\(Int(DialogCore.gainDB(tier: tier))) dB"
        return "\(level) · \(engine.rawValue)" + (highQuality ? " · HQ" : "")
    }

    /// CSV parametre özeti.
    var csv: String {
        "diyalog_kademe=\(tier); diyalog_motor=\(engine.rawValue); diyalog_solo=\(solo); diyalog_hq=\(highQuality)"
    }
}

/// M10 ayarları (02-cozum §5.5).
struct BoostSettings: Equatable {
    /// Kaydırıcı, %100–150.
    var percent = 100.0
    var mode: LimiterMode = .smart
    /// Uzman "Agresif": yönetici L_max −7 LUFS (daha fazla sıkıştırma kabul edilir).
    var aggressive = false
    /// Uzman "Atmos'u koru": Atmos içerikte boost %100'e kilitlenir, Atmos sıkıştırılmış kalır.
    var keepAtmos = false
    /// Hoparlör rotasında 150 Hz, 2. derece yüksek geçiren (boost > %100 iken).
    var speakerHighPass = true

    var gainDB: Double { BoostConfig.gainDB(percent: percent) }
    var active: Bool { gainDB > 0 }

    var label: String {
        "%\(Int(percent.rounded())) (+\(TR.num(gainDB, 1)) dB) · \(mode.rawValue)" + (aggressive ? " · Agresif" : "")
    }

    var csv: String {
        "boost_yuzde=\(Int(percent.rounded())); boost_db=\(TR.num(gainDB, 2)); limiter=\(mode.rawValue); agresif=\(aggressive); "
            + "atmos_koru=\(keepAtmos); hpf=\(speakerHighPass)"
    }
}

/// Çıkış rotasının sınıfı: limiter tavanı, hoparlör HPF'si ve rota başına boost hafızası buna göre (§5.5).
enum AudioRouteClass: String, CaseIterable {
    case speaker = "hoparlör"
    case headphones = "kulaklık"
    case bluetooth = "Bluetooth"
    case airPlay = "AirPlay"
    case usb = "USB DAC"
    case other = "diğer"

    static var current: AudioRouteClass {
        guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType else { return .other }
        switch port {
        case .builtInSpeaker: return .speaker
        case .headphones, .lineOut: return .headphones
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return .bluetooth
        case .airPlay: return .airPlay
        case .usbAudio: return .usb
        default: return .other
        }
    }

    /// Bluetooth AAC kodlayıcısının aşımı için −1,5 dBTP; diğerleri −1,0.
    var ceilingDBTP: Double { self == .bluetooth ? -1.5 : -1.0 }
}

/// Ses evresinin tüm ayarları.
struct AudioStageSettings: Equatable {
    var dialog = DialogSettings()
    var boost = BoostSettings()
    var route: AudioRouteClass = .other

    /// Kapalıyken ses birebir geçer (Atmos sıkıştırılmış kalır).
    var active: Bool { dialog.active || boost.active }
}

/// Ses evresinin anlık durumu (HUD, CSV).
struct AudioStageStatus: Equatable {
    var settings = AudioStageSettings()
    // M9
    /// Etkin motor: "AUSoundIsolation", "F1 (DSP)" …
    var engine = "kapalı"
    var engineNote: String?
    var relaxation = 1.0
    var compensationDB = 0.0
    var isolation: SoundIsolationReport?
    var isolationState: String?
    var music: MusicDetector.Probabilities?
    var musicMsPerDecision: Double?
    var musicError: String?
    // M10
    /// Yöneticinin şu anki kazancı (işleme anında; çalan ses için göstergeler `AudioMeterRecord`'dan gelir).
    var boostManagerDB: Double?
    var ceilingDBTP = -1.0
    var highPassActive = false
    // Ortak
    /// Sıkıştırılmış Dolby PCM'e çözülüyorsa çözülen düzen ("5.1").
    var decodedLayout: String?
    var decodeError: String?
    /// Evrenin toplam gecikmesi (M9 + M10; PTS'leri etkilemez).
    var latencyMs = 0.0
    /// Evrenin toplam yükü (Dolby çözme + M9 + M10), demux thread'inde, tek çekirdeğin yüzdesi.
    var stageCPUPercent: Double?
    var reprocessCount = 0
    var lastReprocessMs: Double?
}

/// M10 göstergesinin bir kaydı (256 kare ≈ 5 ms): PTS'li olduğundan arayüz o an duyulan sesle hizalı okur.
struct AudioMeterRecord: Equatable {
    var pts: Double
    var duration: Double
    var gainReductionDB: Double
    var appliedGainDB: Double
    var clipped: [Int]
    var peakDBFS: Double
    var truePeakOvers: Int
}

/// Ses evresi (S4 M9 + S5 M10). Ham ses örneklerini (demux sonrası) alır, çıkış örneklerini üretir:
/// - Kapalıyken birebir geçirir (Atmos sıkıştırılmış kalır).
/// - Açıkken PCM'e çevirir (Dolby: Apple çözücüsü; 5.1/7.1 yatak), M9 (`DialogCore`) ve M10 (`BoostChain`)
///   ile işler. Çıkış örnekleri ham örneklerin zaman ızgarasına hizalıdır (aynı PTS ve süre): böylece yeniden
///   işleme ve aç/kapa geçişleri ham örnek sınırında dikişsiz yapılır ve A/V kayması olmaz.
/// Yalnızca demux thread'inden kullanılır; durum, göstergeler ve AU hazır bildirimi başka thread'lerden okunur/gelir.
final class AudioStage: @unchecked Sendable {
    private struct GridEntry {
        let pts: CMTime
        let start: Int
        let frames: Int
    }

    private struct PCM {
        var samples: [Float]
        var frames: Int
        var pts: CMTime
        var rate: Double
        var roles: [ChannelRole]
        var format: CMAudioFormatDescription
    }

    private enum Extracted {
        case pcm(PCM)
        /// Çözücü henüz çıktı vermedi (ısınma).
        case pending
        case failed(String)
    }

    /// AU hazır olunca ya da açılamayınca (başka thread'den): oyuncu yeniden işleme ister.
    var onIsolationChange: (() -> Void)?

    private(set) var settings = AudioStageSettings()
    private(set) var background = false

    private let lock = NSLock()
    private var statusValue = AudioStageStatus()
    private var meters: [AudioMeterRecord] = []
    private var readyIsolation: SoundIsolationUnit?
    private var isolationError: String?
    private var requestedKey: String?

    private var isolation: SoundIsolationUnit?
    private var detector: MusicDetector?
    private var detectorError: String?
    private let decoder = DolbyDecoder()
    private var decodeFailure: String?

    private var built = false
    private var core: DialogCore?
    private var boost: BoostChain?
    private var latency = 0
    private var roles: [ChannelRole] = []
    private var channels = 0
    private var rate = 0.0
    private var lfeChannels: Set<Int> = []
    private var outFormat: CMAudioFormatDescription?

    private var input: [Float] = []
    private var inputFrames = 0
    private var totalFrames = 0
    private var producedFrames = 0
    private var output: [Float] = []
    private var outputBase = 0
    private var discard = 0
    private var grid: [GridEntry] = []
    /// Bu zamandan önceki çıkış atılır (sarma hedefi ya da yeniden işlemenin başladığı ham örnek sınırı).
    private var startAt: CMTime?
    private var settleSeconds = 0.0
    private var feedDetector = true
    private var cpuSeconds = 0.0
    private var mediaSeconds = 0.0
    private var reprocessCount = 0
    private var lastReprocessMs: Double?

    private static let block = 1024
    private static let maxMeters = 8192

    var status: AudioStageStatus {
        lock.lock()
        defer { lock.unlock() }
        return statusValue
    }

    /// Ayarları uygular. İşleme zinciri bir sonraki örnekte yeniden kurulur; çağıran `reset` ile zaman çizelgesini sıfırlar.
    func apply(_ newSettings: AudioStageSettings) {
        settings = newSettings
        built = false
        core = nil
        boost = nil
        decodeFailure = nil
        publish()
    }

    /// Arka plan: AU yerine F1 (çapraz geçişle; yeniden işleme gerekmez).
    func setBackground(_ value: Bool) {
        background = value
        if let core { core.select(preferredEngine(hasIsolation: isolation != nil && settings.dialog.engine != .dsp)) }
        publish()
    }

    /// Zaman çizelgesini sıfırlar.
    /// - Parameters:
    ///   - startAt: Bundan önceki çıkış atılır (ısınma).
    ///   - settleSeconds: M9'un `c`/`r`'si ve M10 yöneticisinin hızlı oturduğu süre.
    ///   - seek: Sarma: son müzik kararı ve tüm göstergeler unutulur. Yeniden işlemede müzik kararı korunur,
    ///     göstergelerden yalnızca `startAt` sonrası (yeniden üretilecek kısım) atılır.
    func reset(startAt: CMTime?, settleSeconds: Double, seek: Bool) {
        self.startAt = startAt
        self.settleSeconds = settleSeconds
        input.removeAll(keepingCapacity: true)
        inputFrames = 0
        totalFrames = 0
        producedFrames = 0
        output.removeAll(keepingCapacity: true)
        outputBase = 0
        grid.removeAll()
        decoder.reset()
        core?.reset(settleSeconds: settleSeconds)
        boost?.reset(settleSeconds: settleSeconds)
        discard = latency
        if seek { detector?.reset() }
        lock.lock()
        if seek || startAt == nil {
            meters.removeAll()
        } else if let startAt {
            let from = startAt.seconds - 0.001
            meters.removeAll { $0.pts >= from }
        }
        lock.unlock()
    }

    /// Yeniden işleme kaydı (HUD): süre, ms.
    func noteReprocess(milliseconds: Double) {
        reprocessCount += 1
        lastReprocessMs = milliseconds
        publish()
    }

    /// M10 göstergeleri: PTS'i `time`'a kadar olan (o an duyulmuş) kayıtlar sırayla çıkarılır.
    func takeMeters(until time: Double) -> [AudioMeterRecord] {
        lock.lock()
        defer { lock.unlock() }
        let count = meters.firstIndex { $0.pts > time } ?? meters.count
        let taken = Array(meters.prefix(count))
        meters.removeFirst(count)
        return taken
    }

    /// Ham örneği işler; çalınacak örnekleri döndürür (birikiyorsa boş).
    /// - Parameter warm: Yeniden işlemede geçmişten beslenen örnek (müzik dedektörüne tekrar verilmez).
    func process(_ raw: CMSampleBuffer, warm: Bool = false) -> [CMSampleBuffer] {
        let pts = CMSampleBufferGetPresentationTimeStamp(raw)
        guard settings.active, decodeFailure == nil else { return passthrough(raw, pts: pts) }

        let cpuStart = Self.threadCPUTime()
        defer { cpuSeconds += Self.threadCPUTime() - cpuStart }
        let pcm: PCM
        switch extract(raw) {
        case .pcm(let value): pcm = value
        case .pending: return []
        case .failed(let message):
            // Çözülemeyen Dolby ham geçer (Atmos sürer); ayar değişene ya da sarılana kadar.
            decodeFailure = message
            publish()
            return passthrough(raw, pts: pts)
        }
        build(for: pcm)
        input.append(contentsOf: pcm.samples)
        inputFrames += pcm.frames
        grid.append(GridEntry(pts: pcm.pts, start: totalFrames, frames: pcm.frames))
        totalFrames += pcm.frames
        mediaSeconds += Double(pcm.frames) / pcm.rate
        feedDetector = !warm
        if inputFrames >= Self.block { run() }
        return emitReady()
    }

    /// Dosya sonu: zincirde kalan (gecikme kadar) ses sıfırla itilerek çıkarılır.
    func drain() -> [CMSampleBuffer] {
        guard settings.active, built, !grid.isEmpty else { return [] }
        let frames = latency + Self.block
        input.append(contentsOf: [Float](repeating: 0, count: frames * channels))
        inputFrames += frames
        feedDetector = false
        run()
        let out = emitReady()
        output.removeAll(keepingCapacity: true)
        grid.removeAll()
        return out
    }

    // MARK: Özel

    private func passthrough(_ raw: CMSampleBuffer, pts: CMTime) -> [CMSampleBuffer] {
        if let startAt, pts.isValid, pts < startAt - CMTime(value: 1, timescale: 1000) { return [] }
        return [raw]
    }

    private func extract(_ raw: CMSampleBuffer) -> Extracted {
        guard let format = CMSampleBufferGetFormatDescription(raw),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
            return .failed("biçim yok")
        }
        if asbd.mFormatID == kAudioFormatLinearPCM {
            // Kayıpsız kaynak tamsayı gelebilir (S6); işlenen çıktı aynı düzende float32'dir.
            guard let pcm = NativeAudioPipeline.floatSamples(of: raw),
                  let output = NativeAudioPipeline.floatFormat(matching: format) else { return .failed("PCM biçimi beklenmedik") }
            return .pcm(PCM(samples: pcm.samples, frames: pcm.frames, pts: CMSampleBufferGetPresentationTimeStamp(raw),
                            rate: asbd.mSampleRate, roles: Self.roles(of: format, channels: pcm.channels), format: output))
        }
        // Sıkıştırılmış (AC-3 / E-AC-3, JOC dahil): Apple çözücüsüyle yatak kanallarına.
        switch decoder.decode(raw) {
        case .success(let decoded):
            guard let decoded else { return .pending }
            return .pcm(PCM(samples: decoded.samples, frames: decoded.frames, pts: decoded.pts, rate: decoded.rate,
                            roles: decoded.positions.map { Self.role($0) }, format: decoded.format))
        case .failure(let error):
            return .failed(error.localizedDescription)
        }
    }

    /// Zincir yalnızca `apply`/`reset` sonrasında ya da biçim değişince kurulur; akış ortasında motor eklemek
    /// ızgarayı kaydırırdı (hazır olan AU bir sonraki yeniden işlemede devreye girer).
    private func build(for pcm: PCM) {
        if built, rate == pcm.rate, roles == pcm.roles { return }
        let dialog = settings.dialog
        var core: DialogCore?
        if dialog.active {
            if dialog.engine != .dsp { requestIsolation(rate: pcm.rate) }
            adoptIsolation(rate: pcm.rate)
            let useIsolation = dialog.engine != .dsp && isolation != nil
            var primary: VoiceIsolator?
            if useIsolation, let isolation { primary = isolation }
            let made = DialogCore(sampleRate: pcm.rate, roles: pcm.roles, primary: primary,
                                  fallback: CenterExtractor(sampleRate: pcm.rate), start: preferredEngine(hasIsolation: useIsolation))
            made.tier = dialog.tier
            made.solo = dialog.solo
            made.reset(settleSeconds: settleSeconds)
            core = made
            if detector == nil || detector?.sampleRate != pcm.rate {
                do {
                    detector = try MusicDetector(sampleRate: pcm.rate)
                    detectorError = nil
                } catch {
                    detector = nil
                    detectorError = error.localizedDescription
                }
            }
        }
        // M10 her zaman zincirin sonunda: %100'de bile M9 çıkışının tepelerini limiter korur.
        let weights = pcm.roles.map { role -> Double in
            switch role {
            case .lfe: return 0
            case .surround: return 1.41
            default: return 1
            }
        }
        let boostSettings = settings.boost
        let config = BoostConfig(percent: boostSettings.percent, mode: boostSettings.mode, ceilingDBTP: settings.route.ceilingDBTP,
                                 maxLoudness: boostSettings.aggressive ? -7 : -10,
                                 speakerHighPass: boostSettings.speakerHighPass && settings.route == .speaker)
        let boost = BoostChain(sampleRate: pcm.rate, weights: weights, config: config)
        boost.reset(settleSeconds: settleSeconds)

        // Eski zincirde bekleyen ses atılır (yalnızca biçim değişiminde dolu olur; en çok gecikme kadar).
        input.removeAll(keepingCapacity: true)
        inputFrames = 0
        output.removeAll(keepingCapacity: true)
        grid.removeAll()
        outputBase = totalFrames
        producedFrames = totalFrames
        self.core = core
        self.boost = boost
        built = true
        latency = (core?.latency ?? 0) + boost.latency
        discard = latency
        channels = pcm.roles.count
        rate = pcm.rate
        roles = pcm.roles
        lfeChannels = Set(pcm.roles.indices.filter { pcm.roles[$0] == .lfe })
        outFormat = pcm.format
        publish()
    }

    private func preferredEngine(hasIsolation: Bool) -> DialogCore.Engine {
        guard hasIsolation else { return .fallback }
        if isolation?.failed == true { return .fallback }
        return background && settings.dialog.engine == .automatic ? .fallback : .primary
    }

    private func run() {
        guard built, inputFrames > 0 else { return }
        let n = inputFrames
        var data = input
        if let core {
            if core.activeEngine == .primary, isolation?.failed == true { core.select(.fallback) }
            if let detector {
                if feedDetector {
                    var mono = [Float](repeating: 0, count: n)
                    let used = (0..<channels).filter { !lfeChannels.contains($0) }
                    let weight = 1 / Float(max(used.count, 1))
                    for f in 0..<n {
                        var sum: Float = 0
                        for c in used { sum += input[f * channels + c] }
                        mono[f] = sum * weight
                    }
                    mono.withUnsafeBufferPointer { detector.feed($0) }
                }
                core.relaxationTarget = detector.relaxationTarget
            }
            data = data.withUnsafeBufferPointer { core.process($0, frames: n) }
        }
        if let boost {
            data = data.withUnsafeBufferPointer { boost.process($0, frames: n) }
            record(boost.stats)
        }
        producedFrames += n
        input.removeAll(keepingCapacity: true)
        inputFrames = 0
        var produced = data[...]
        if discard > 0 {
            let d = min(discard, n)
            produced = produced.dropFirst(d * channels)
            discard -= d
        }
        output.append(contentsOf: produced)
        publish()
    }

    /// M10 göstergelerini, karşılık geldikleri ham örneğin PTS'iyle kaydeder (ısınma ve dolgu atılır).
    private func record(_ stats: [BoostBlockStats]) {
        var records: [AudioMeterRecord] = []
        for stat in stats {
            let index = producedFrames + stat.offset - latency
            guard index >= 0, let entry = grid.first(where: { index >= $0.start && index < $0.start + $0.frames }) else { continue }
            let pts = entry.pts.seconds + Double(index - entry.start) / rate
            if let startAt, pts < startAt.seconds - 0.001 { continue }
            records.append(AudioMeterRecord(pts: pts, duration: Double(stat.frames) / rate, gainReductionDB: stat.gainReductionDB,
                                            appliedGainDB: stat.appliedGainDB, clipped: stat.clipped, peakDBFS: stat.peakDBFS,
                                            truePeakOvers: stat.truePeakOvers))
        }
        guard !records.isEmpty else { return }
        lock.lock()
        meters += records
        if meters.count > Self.maxMeters { meters.removeFirst(meters.count - Self.maxMeters) }
        lock.unlock()
    }

    private func emitReady() -> [CMSampleBuffer] {
        guard channels > 0 else { return [] }
        var result: [CMSampleBuffer] = []
        while let entry = grid.first {
            let available = outputBase + output.count / channels
            guard available >= entry.start + entry.frames else { break }
            let offset = max(entry.start - outputBase, 0) * channels
            let count = entry.frames * channels
            let keep = startAt.map { entry.pts >= $0 - CMTime(value: 1, timescale: 1000) } ?? true
            if keep, let format = outFormat {
                let samples = Array(output[offset..<(offset + count)])
                if let sample = NativeAudioPipeline.pcmSampleBuffer(samples, frames: entry.frames, format: format, pts: entry.pts) {
                    result.append(sample)
                }
            }
            output.removeFirst(offset + count)
            outputBase = entry.start + entry.frames
            grid.removeFirst()
        }
        return result
    }

    // MARK: AUSoundIsolation

    private func requestIsolation(rate: Double) {
        let key = "\(rate)|\(settings.dialog.highQuality)"
        lock.lock()
        guard requestedKey != key else {
            lock.unlock()
            return
        }
        requestedKey = key
        readyIsolation = nil
        isolationError = nil
        lock.unlock()
        isolation = nil
        SoundIsolationUnit.make(sampleRate: rate, highQuality: settings.dialog.highQuality) { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            guard self.requestedKey == key else {
                self.lock.unlock()
                return
            }
            switch result {
            case .success(let unit): self.readyIsolation = unit
            case .failure(let error): self.isolationError = error.localizedDescription
            }
            self.lock.unlock()
            self.onIsolationChange?()
        }
    }

    private func adoptIsolation(rate: Double) {
        lock.lock()
        let ready = readyIsolation
        lock.unlock()
        let highQuality = settings.dialog.highQuality
        if let ready, ready.sampleRate == rate, ready.highQuality == highQuality {
            isolation = ready
        } else if isolation.map({ $0.sampleRate != rate || $0.highQuality != highQuality }) == true {
            isolation = nil
        }
    }

    // MARK: Durum

    private func publish() {
        var s = AudioStageStatus()
        s.settings = settings
        let dialog = settings.dialog
        if dialog.active, let core {
            let usingIsolation = core.activeEngine == .primary && dialog.engine != .dsp && isolation != nil
            s.engine = usingIsolation ? "AUSoundIsolation" + (dialog.highQuality ? " (HQ)" : "") : "F1 (DSP)"
            var notes: [String] = []
            if background { notes.append("arka plan") }
            if isolation?.failed == true { notes.append("AU hata verdi → F1") }
            s.engineNote = notes.isEmpty ? nil : notes.joined(separator: " · ")
            s.relaxation = core.relaxation
            s.compensationDB = core.compensationDB
        } else if dialog.active {
            s.engine = decodeFailure == nil ? "hazırlanıyor" : "geçiş (çözülemedi)"
        }
        if let boost {
            s.boostManagerDB = boost.managerGainDB
            s.ceilingDBTP = boost.config.ceilingDBTP
            s.highPassActive = boost.config.speakerHighPass && boost.config.targetGainDB > 0
        }
        if built, rate > 0 { s.latencyMs = Double(latency) / rate * 1000 }
        s.decodedLayout = decoder.layoutName
        s.decodeError = decodeFailure
        if mediaSeconds > 0.5 { s.stageCPUPercent = cpuSeconds / mediaSeconds * 100 }
        s.reprocessCount = reprocessCount
        s.lastReprocessMs = lastReprocessMs
        s.isolation = isolation?.report
        lock.lock()
        if dialog.engine != .dsp, dialog.active, isolation == nil {
            s.isolationState = isolationError ?? "AU hazırlanıyor (kalibrasyon); şimdilik F1"
        }
        lock.unlock()
        if dialog.active {
            if let detector {
                s.music = detector.probabilities
                s.musicMsPerDecision = detector.load.msPerDecision
                s.musicError = detector.lastError
            } else {
                s.musicError = detectorError
            }
        }
        lock.lock()
        statusValue = s
        lock.unlock()
    }

    // MARK: Yardımcılar

    static func role(_ position: SpeakerPosition) -> ChannelRole {
        switch position {
        case .left, .leftTotal: .left
        case .right, .rightTotal: .right
        case .center: .center
        case .lfe, .lfe2: .lfe
        case .surroundLeft, .surroundRight, .rearSurroundLeft, .rearSurroundRight, .centerSurround,
             .surroundDirectLeft, .surroundDirectRight:
            .surround
        default: .other
        }
    }

    /// Kanal rolleri biçimin kanal tanımlarından (yoksa kanal sayısına göre varsayılan düzenden).
    static func roles(of format: CMAudioFormatDescription, channels: Int) -> [ChannelRole] {
        var size = 0
        if let layout = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &size),
           layout.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions,
           Int(layout.pointee.mNumberChannelDescriptions) == channels {
            let offset = MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions) ?? 12
            let descriptions = (UnsafeRawPointer(layout) + offset).bindMemory(to: AudioChannelDescription.self, capacity: channels)
            return (0..<channels).map { role(label: descriptions[$0].mChannelLabel) }
        }
        if channels == 1 { return [.center] }
        return SpeakerLayout.defaultPositions(channelCount: channels).map { role($0) }
    }

    private static func role(label: AudioChannelLabel) -> ChannelRole {
        switch label {
        case kAudioChannelLabel_Left, kAudioChannelLabel_LeftTotal: .left
        case kAudioChannelLabel_Right, kAudioChannelLabel_RightTotal: .right
        case kAudioChannelLabel_Center, kAudioChannelLabel_Mono: .center
        case kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2: .lfe
        case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround, kAudioChannelLabel_RearSurroundLeft,
             kAudioChannelLabel_RearSurroundRight, kAudioChannelLabel_CenterSurround, kAudioChannelLabel_LeftSurroundDirect,
             kAudioChannelLabel_RightSurroundDirect:
            .surround
        default: .other
        }
    }

    private static func threadCPUTime() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }
}

/// AC-3 / E-AC-3 (JOC dahil) → float32 karışık PCM, Apple'ın çözücüsüyle (`AVAudioConverter`). JOC'de nesneler
/// değil yatak (5.1/7.1) çıkar; diyalog açıkken Atmos uzamsallaştırması bu yüzden kapanır (02-cozum §5.4).
/// Çıkış zaman damgası: ilk paketin PTS'i + çıkan kare sayısı (çözücü gecikmesi kendiliğinden hizalanır);
/// 50 ms'den büyük süreksizlikte yeniden çapalanır.
final class DolbyDecoder {
    struct Decoded {
        var samples: [Float]
        var frames: Int
        var pts: CMTime
        var rate: Double
        var positions: [SpeakerPosition]
        var format: CMAudioFormatDescription
    }

    enum DecodeError: LocalizedError {
        case converter(String)

        var errorDescription: String? {
            switch self {
            case .converter(let message): "Dolby çözülemedi: \(message)"
            }
        }
    }

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var sourceFormat: CMFormatDescription?
    private var outBuffer: AVAudioPCMBuffer?
    private var pcmFormat: CMAudioFormatDescription?
    private var positions: [SpeakerPosition] = []
    private var anchor: CMTime?
    private var inputFrames = 0
    private var outputFrames = 0
    private(set) var layoutName: String?

    func reset() {
        converter?.reset()
        anchor = nil
        inputFrames = 0
        outputFrames = 0
    }

    /// `nil`: çözücü henüz çıktı vermedi.
    func decode(_ sample: CMSampleBuffer) -> Result<Decoded?, Error> {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return .failure(DecodeError.converter("biçim yok")) }
        if sourceFormat == nil || !CMFormatDescriptionEqual(format, otherFormatDescription: sourceFormat) {
            if let error = configure(format) { return .failure(error) }
        }
        guard let converter, let inputFormat, let outBuffer, let pcmFormat else {
            return .failure(DecodeError.converter("çözücü yok"))
        }
        let rate = inputFormat.sampleRate
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        var packetFrames = 1536
        let duration = CMSampleBufferGetDuration(sample)
        if duration.isValid, duration.seconds > 0 { packetFrames = Int((duration.seconds * rate).rounded()) }
        if let anchor, pts.isValid {
            let expected = anchor + CMTime(value: CMTimeValue(inputFrames), timescale: CMTimeScale(rate))
            if abs((pts - expected).seconds) > 0.05 { reset() }
        }
        if anchor == nil {
            anchor = pts.isValid ? pts : .zero
        }
        inputFrames += packetFrames

        guard let block = CMSampleBufferGetDataBuffer(sample) else { return .success(nil) }
        let length = CMBlockBufferGetDataLength(block)
        let compressed = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: max(length, 1))
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: compressed.data) == kCMBlockBufferNoErr else {
            return .success(nil)
        }
        compressed.byteLength = UInt32(length)
        compressed.packetCount = 1
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                              mDataByteSize: UInt32(length))
        var samples: [Float] = []
        var supplied = false
        let channels = Int(outBuffer.format.channelCount)
        while true {
            outBuffer.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return compressed
            }
            if status == .error {
                return .failure(DecodeError.converter(error?.localizedDescription ?? "dönüştürme hatası"))
            }
            let frames = Int(outBuffer.frameLength)
            if frames > 0, let data = outBuffer.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: data, count: frames * channels))
            }
            if status != .haveData { break }
        }
        let frames = samples.count / max(channels, 1)
        guard frames > 0, let anchor else { return .success(nil) }
        let outPTS = anchor + CMTime(value: CMTimeValue(outputFrames), timescale: CMTimeScale(rate))
        outputFrames += frames
        return .success(Decoded(samples: samples, frames: frames, pts: outPTS, rate: rate, positions: positions, format: pcmFormat))
    }

    private func configure(_ format: CMFormatDescription) -> Error? {
        let input = AVAudioFormat(cmAudioFormatDescription: format)
        let sourceChannels = Int(input.channelCount)
        let tag: AudioChannelLayoutTag
        switch sourceChannels {
        case 1:
            tag = kAudioChannelLayoutTag_Mono
            positions = [.center]
        case 2:
            tag = kAudioChannelLayoutTag_Stereo
            positions = [.left, .right]
        case 7...:
            tag = kAudioChannelLayoutTag_MPEG_7_1_C
            positions = [.left, .right, .center, .lfe, .surroundLeft, .surroundRight, .rearSurroundLeft, .rearSurroundRight]
        default:
            tag = kAudioChannelLayoutTag_MPEG_5_1_A
            positions = [.left, .right, .center, .lfe, .surroundLeft, .surroundRight]
        }
        guard let layout = AVAudioChannelLayout(layoutTag: tag) else { return DecodeError.converter("kanal düzeni") }
        let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate, interleaved: true,
                                   channelLayout: layout)
        guard let converter = AVAudioConverter(from: input, to: output),
              let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 8192),
              let pcm = NativeAudioPipeline.pcmFormat(rate: Int(input.sampleRate), positions: positions) else {
            return DecodeError.converter("\(sourceChannels) kanal \(Int(input.sampleRate)) Hz için dönüştürücü kurulamadı")
        }
        self.converter = converter
        inputFormat = input
        outBuffer = buffer
        pcmFormat = pcm
        sourceFormat = format
        layoutName = SpeakerLayout.name(positions)
        anchor = nil
        inputFrames = 0
        outputFrames = 0
        return nil
    }
}
