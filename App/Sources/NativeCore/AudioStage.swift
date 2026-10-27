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

/// Diyalog evresinin anlık durumu (HUD, CSV).
struct DialogStatus: Equatable {
    var settings = DialogSettings()
    /// Etkin motor: "AUSoundIsolation", "F1 (DSP)" …
    var engine = "kapalı"
    var engineNote: String?
    /// Sıkıştırılmış Dolby diyalog için çözülüyorsa çözülen düzen ("5.1").
    var decodedLayout: String?
    var decodeError: String?
    var latencyMs = 0.0
    var relaxation = 1.0
    var compensationDB = 0.0
    /// Evrenin toplam yükü (Dolby çözme + F1/AU + karıştırma), demux thread'inde, tek çekirdeğin yüzdesi.
    var stageCPUPercent: Double?
    var reprocessCount = 0
    var lastReprocessMs: Double?
    var isolation: SoundIsolationReport?
    var isolationState: String?
    var music: MusicDetector.Probabilities?
    var musicMsPerDecision: Double?
    var musicError: String?
}

/// M9 diyalog evresi (02-cozum §5.4, S4). Ham ses örneklerini (demux sonrası) alır, çıkış örneklerini üretir:
/// - Kapalıyken birebir geçirir (Atmos sıkıştırılmış kalır).
/// - Açıkken PCM'e çevirir (Dolby: Apple çözücüsü; 5.1/7.1 yatak), `DialogCore` ile işler. Çıkış örnekleri ham
///   örneklerin zaman ızgarasına hizalıdır (aynı PTS ve süre): böylece yeniden işleme ve aç/kapa geçişleri ham
///   örnek sınırında dikişsiz yapılır ve A/V kayması olmaz.
/// Yalnızca demux thread'inden kullanılır; durum ve AU hazır bildirimi başka thread'lerden okunur/gelir.
final class DialogStage: @unchecked Sendable {
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

    private(set) var settings = DialogSettings()
    private(set) var background = false

    private let lock = NSLock()
    private var statusValue = DialogStatus()
    private var readyIsolation: SoundIsolationUnit?
    private var isolationError: String?
    private var requestedKey: String?

    private var isolation: SoundIsolationUnit?
    private var detector: MusicDetector?
    private var detectorError: String?
    private let decoder = DolbyDecoder()
    private var decodeFailure: String?

    private var core: DialogCore?
    private var roles: [ChannelRole] = []
    private var channels = 0
    private var rate = 0.0
    private var lfeChannels: Set<Int> = []
    private var outFormat: CMAudioFormatDescription?

    private var input: [Float] = []
    private var inputFrames = 0
    private var totalFrames = 0
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

    var status: DialogStatus {
        lock.lock()
        defer { lock.unlock() }
        return statusValue
    }

    /// Ayarları uygular. Çekirdek bir sonraki örnekte yeniden kurulur; çağıran `reset` ile zaman çizelgesini sıfırlar.
    func apply(_ newSettings: DialogSettings) {
        settings = newSettings
        core = nil
        decodeFailure = nil
        publish()
    }

    /// Arka plan: AU yerine F1 (çapraz geçişle; yeniden işleme gerekmez).
    func setBackground(_ value: Bool) {
        background = value
        if let core { core.select(preferredEngine(hasIsolation: isolation != nil && settings.engine != .dsp)) }
        publish()
    }

    /// Zaman çizelgesini sıfırlar.
    /// - Parameters:
    ///   - startAt: Bundan önceki çıkış atılır (ısınma).
    ///   - settleSeconds: `c` ve `r`'nin hızlı oturduğu süre.
    ///   - forgetMusic: Sarmada son müzik kararı unutulur; yeniden işlemede korunur.
    func reset(startAt: CMTime?, settleSeconds: Double, forgetMusic: Bool) {
        self.startAt = startAt
        self.settleSeconds = settleSeconds
        input.removeAll(keepingCapacity: true)
        inputFrames = 0
        totalFrames = 0
        output.removeAll(keepingCapacity: true)
        outputBase = 0
        grid.removeAll()
        decoder.reset()
        if let core {
            core.reset(settleSeconds: settleSeconds)
            discard = core.latency
        }
        if forgetMusic { detector?.reset() }
    }

    /// Yeniden işleme kaydı (HUD): süre, ms.
    func noteReprocess(milliseconds: Double) {
        reprocessCount += 1
        lastReprocessMs = milliseconds
        publish()
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
        ensureCore(pcm)
        input.append(contentsOf: pcm.samples)
        inputFrames += pcm.frames
        grid.append(GridEntry(pts: pcm.pts, start: totalFrames, frames: pcm.frames))
        totalFrames += pcm.frames
        mediaSeconds += Double(pcm.frames) / pcm.rate
        feedDetector = !warm
        if inputFrames >= Self.block { runCore() }
        return emitReady()
    }

    /// Dosya sonu: çekirdekte kalan (gecikme kadar) ses sıfırla itilerek çıkarılır.
    func drain() -> [CMSampleBuffer] {
        guard settings.active, let core, !grid.isEmpty else { return [] }
        let frames = core.latency + Self.block
        input.append(contentsOf: [Float](repeating: 0, count: frames * channels))
        inputFrames += frames
        feedDetector = false
        runCore()
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
            guard asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32,
                  let block = CMSampleBufferGetDataBuffer(raw) else { return .failed("PCM biçimi beklenmedik") }
            let channels = Int(asbd.mChannelsPerFrame)
            let frames = CMSampleBufferGetNumSamples(raw)
            var samples = [Float](repeating: 0, count: frames * channels)
            let status = samples.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let base = bytes.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: min(bytes.count, CMBlockBufferGetDataLength(block)),
                                                  destination: base)
            }
            guard status == kCMBlockBufferNoErr else { return .failed("PCM okunamadı") }
            return .pcm(PCM(samples: samples, frames: frames, pts: CMSampleBufferGetPresentationTimeStamp(raw),
                            rate: asbd.mSampleRate, roles: Self.roles(of: format, channels: channels), format: format))
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

    /// Çekirdek yalnızca `apply`/`reset` sonrasında ya da biçim değişince kurulur; akış ortasında motor eklemek
    /// ızgarayı kaydırırdı (hazır olan AU bir sonraki yeniden işlemede devreye girer).
    private func ensureCore(_ pcm: PCM) {
        if core != nil, rate == pcm.rate, roles == pcm.roles { return }
        if settings.engine != .dsp { requestIsolation(rate: pcm.rate) }
        adoptIsolation(rate: pcm.rate)
        let useIsolation = settings.engine != .dsp && isolation != nil
        var primary: VoiceIsolator?
        if useIsolation, let isolation { primary = isolation }
        let core = DialogCore(sampleRate: pcm.rate, roles: pcm.roles, primary: primary,
                              fallback: CenterExtractor(sampleRate: pcm.rate), start: preferredEngine(hasIsolation: useIsolation))
        core.tier = settings.tier
        core.solo = settings.solo
        core.reset(settleSeconds: settleSeconds)
        // Eski çekirdekte bekleyen ses atılır (yalnızca biçim değişiminde dolu olur; en çok gecikme kadar).
        input.removeAll(keepingCapacity: true)
        inputFrames = 0
        output.removeAll(keepingCapacity: true)
        grid.removeAll()
        outputBase = totalFrames
        self.core = core
        channels = pcm.roles.count
        rate = pcm.rate
        roles = pcm.roles
        lfeChannels = Set(pcm.roles.indices.filter { pcm.roles[$0] == .lfe })
        outFormat = pcm.format
        discard = core.latency
        if detector == nil || detector?.sampleRate != pcm.rate {
            do {
                detector = try MusicDetector(sampleRate: pcm.rate)
                detectorError = nil
            } catch {
                detector = nil
                detectorError = error.localizedDescription
            }
        }
        publish()
    }

    private func preferredEngine(hasIsolation: Bool) -> DialogCore.Engine {
        guard hasIsolation else { return .fallback }
        if isolation?.failed == true { return .fallback }
        return background && settings.engine == .automatic ? .fallback : .primary
    }

    private func runCore() {
        guard let core, inputFrames > 0 else { return }
        let n = inputFrames
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
        let out = input.withUnsafeBufferPointer { core.process($0, frames: n) }
        input.removeAll(keepingCapacity: true)
        inputFrames = 0
        var produced = out[...]
        if discard > 0 {
            let d = min(discard, n)
            produced = produced.dropFirst(d * channels)
            discard -= d
        }
        output.append(contentsOf: produced)
        publish()
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
        let key = "\(rate)|\(settings.highQuality)"
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
        SoundIsolationUnit.make(sampleRate: rate, highQuality: settings.highQuality) { [weak self] result in
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
        if let ready, ready.sampleRate == rate, ready.highQuality == settings.highQuality {
            isolation = ready
        } else if isolation.map({ $0.sampleRate != rate || $0.highQuality != settings.highQuality }) == true {
            isolation = nil
        }
    }

    // MARK: Durum

    private func publish() {
        var s = DialogStatus()
        s.settings = settings
        if settings.active, let core {
            let usingIsolation = core.activeEngine == .primary && settings.engine != .dsp && isolation != nil
            s.engine = usingIsolation ? "AUSoundIsolation" + (settings.highQuality ? " (HQ)" : "") : "F1 (DSP)"
            var notes: [String] = []
            if background { notes.append("arka plan") }
            if isolation?.failed == true { notes.append("AU hata verdi → F1") }
            s.engineNote = notes.isEmpty ? nil : notes.joined(separator: " · ")
            s.latencyMs = Double(core.latency) / core.sampleRate * 1000
            s.relaxation = core.relaxation
            s.compensationDB = core.compensationDB
        } else if settings.active {
            s.engine = decodeFailure == nil ? "hazırlanıyor" : "geçiş (çözülemedi)"
        }
        s.decodedLayout = decoder.layoutName
        s.decodeError = decodeFailure
        if mediaSeconds > 0.5 { s.stageCPUPercent = cpuSeconds / mediaSeconds * 100 }
        s.reprocessCount = reprocessCount
        s.lastReprocessMs = lastReprocessMs
        s.isolation = isolation?.report
        lock.lock()
        if settings.engine != .dsp, settings.active, isolation == nil {
            s.isolationState = isolationError ?? "AU hazırlanıyor (kalibrasyon); şimdilik F1"
        }
        lock.unlock()
        if let detector {
            s.music = detector.probabilities
            s.musicMsPerDecision = detector.load.msPerDecision
            s.musicError = detector.lastError
        } else {
            s.musicError = detectorError
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
