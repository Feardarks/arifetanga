import AudioDSP
import AudioToolbox
import AVFoundation
import Foundation
import QuartzCore

/// AS-12 / AS-15 raporu: AU'nun kabul ettiği biçim, gecikmesi ve yükü. Ana thread okur.
struct SoundIsolationReport: Equatable {
    /// Kabul edilen biçimler, ör. "48k×1, 48k×2, 16k×1".
    var accepted = ""
    /// Kullanılan biçim, ör. "48 kHz mono" ya da "16 kHz mono (48k ↔ 16k yeniden örnekleme)".
    var format = ""
    var highQuality = false
    /// `kAudioUnitProperty_Latency` (ms).
    var declaredLatencyMs = 0.0
    /// Sentetik konuşmayla ölçülen zincir gecikmesi (ms) ve korelasyonu.
    var calibratedLatencyMs: Double?
    var calibrationCorrelation: Float?
    /// Hizalamada kullanılan gecikme (ms).
    var usedLatencyMs = 0.0
    /// Oynatma sırasında gerçek içerikte ölçülen gecikme (ms) ve korelasyonu (yalnızca rapor).
    var measuredLatencyMs: Double?
    var measuredCorrelation: Float?
    /// Bu thread'in CPU süresi / işlenen ses süresi (%, tek çekirdek) ve duvar saati oranı.
    /// Duvar ≫ CPU ise iş başka bir birimde (ANE/GPU) ya da başka thread'lerde yapılıyordur.
    var cpuPercent: Double?
    var wallPercent: Double?
    /// 10,67 ms (512 kare @ 48 kHz) başına en kötü işleme süresi, son 10 s (ms).
    var worstBlockMs: Double?
    var renderErrors = 0
    var lastError: String?

    /// Hesap birimi tahmini: duvar süresi CPU süresinin çok üstündeyse iş başka birimde yapılıyordur.
    var computeHint: String {
        guard let cpu = cpuPercent, let wall = wallPercent, wall > 0.05 else { return "?" }
        return wall > cpu * 1.6 ? "CPU dışı (ANE/GPU?)" : "CPU"
    }
}

enum SoundIsolationError: LocalizedError {
    case unavailable(String)
    case format(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): "AUSoundIsolation açılamadı: \(message)"
        case .format(let tried): "AUSoundIsolation biçim kabul etmedi (\(tried))"
        }
    }
}

/// AUSoundIsolation'ı oynatma zincirinde çalıştırır (02-cozum §5.4, AS-12): `M = (L+R)/2` → AU (Voice ya da
/// HighQualityVoice, %100 ıslak) → ayrılmış konuşma. AU akışın hızını kabul etmezse 48k ↔ AU hızı çevrimi kendi
/// rasyonel yeniden örnekleyicimizle yapılır (gecikmesi tam bilinir). AU, `AUAudioUnit` render bloğuyla doğrudan
/// çağrılır; AVAudioEngine gerekmez. Yalnızca demux thread'inden kullanılır; rapor her thread'den okunabilir.
final class SoundIsolationUnit: VoiceIsolator, @unchecked Sendable {
    let sampleRate: Double
    let highQuality: Bool
    private(set) var latency: Int
    /// Art arda render hatası: arka planda ANE/GPU erişimi kesilmiş olabilir; DialogCore F1'e geçer.
    private(set) var failed = false

    private let unit: AUAudioUnit
    private let render: AURenderBlock
    private let auRate: Double
    private let auChannels: Int
    private let toAU: Resampler?
    private let fromAU: Resampler?
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private var pull: AURenderPullInputBlock!
    private var sampleTime = 0.0
    private var fifo: [Float] = []
    private let fifoPad: Int
    private var debt = 0
    private var consecutiveErrors = 0

    private let lock = NSLock()
    private var reportValue: SoundIsolationReport

    // Yük ölçümü
    private var cpuSeconds = 0.0
    private var wallSeconds = 0.0
    private var mediaSeconds = 0.0
    private var blockWorst: [Double] = []
    private var blockWorstCurrent = 0.0
    private var blockWorstFrames = 0

    // Gerçek içerikte gecikme doğrulaması (yalnızca rapor).
    private var probeInput: [Float] = []
    private var probeOutput: [Float] = []
    private var framesUntilProbe: Int
    private var probing = false
    private let probeQueue = DispatchQueue(label: "arif.isolation.lag", qos: .utility)

    static let maxFrames: AUAudioFrameCount = 4096

    var report: SoundIsolationReport {
        lock.lock()
        defer { lock.unlock() }
        return reportValue
    }

    /// AU'yu açar, biçimi yoklar, gecikmeyi sentetik konuşmayla ölçer. Arka planda çalışır; sonuç ana
    /// thread'de değil, `completion`'ın çağrıldığı thread'de gelir.
    static func make(sampleRate: Double, highQuality: Bool,
                     completion: @escaping @Sendable (Result<SoundIsolationUnit, Error>) -> Void) {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        AUAudioUnit.instantiate(with: description, options: []) { unit, error in
            guard let unit else {
                completion(.failure(SoundIsolationError.unavailable(error?.localizedDescription ?? "bileşen yok")))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                completion(Result { try SoundIsolationUnit(unit: unit, sampleRate: sampleRate, highQuality: highQuality) })
            }
        }
    }

    private init(unit: AUAudioUnit, sampleRate: Double, highQuality: Bool) throws {
        self.unit = unit
        self.sampleRate = sampleRate
        self.highQuality = highQuality
        var report = SoundIsolationReport()
        report.highQuality = highQuality

        // AS-12: hangi hız/kanal kabul ediliyor? Önce akışın hızı, sonra yaygın hızlar; önce mono.
        let rates = [sampleRate, 48000, 44100, 32000, 24000, 16000].reduce(into: [Double]()) { if !$0.contains($1) { $0.append($1) } }
        var accepted: [(rate: Double, channels: Int)] = []
        for rate in rates {
            for channels in [1, 2] {
                guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)),
                      Self.setFormat(format, on: unit) else { continue }
                accepted.append((rate, channels))
            }
        }
        report.accepted = accepted.map { "\(Self.kHz($0.rate))×\($0.channels)" }.joined(separator: ", ")
        // Akışın hızı kabul ediliyorsa çevrim yok; yoksa en yüksek kabul edilen hız (yeniden örnekleme).
        let atStreamRate = accepted.filter { $0.rate == sampleRate }
        guard let chosen = atStreamRate.min(by: { $0.channels < $1.channels })
                ?? accepted.max(by: { ($0.rate, -$0.channels) < ($1.rate, -$1.channels) }) else {
            throw SoundIsolationError.format(rates.map { Self.kHz($0) }.joined(separator: "/") + " × mono/stereo")
        }
        auRate = chosen.rate
        auChannels = chosen.channels
        guard let format = AVAudioFormat(standardFormatWithSampleRate: auRate, channels: AVAudioChannelCount(auChannels)),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.maxFrames),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.maxFrames) else {
            throw SoundIsolationError.format("tampon")
        }
        guard Self.setFormat(format, on: unit) else { throw SoundIsolationError.format(report.accepted) }
        self.input = input
        self.output = output
        if auRate != sampleRate {
            toAU = Resampler(inputRate: Int(sampleRate), outputRate: Int(auRate))
            fromAU = Resampler(inputRate: Int(auRate), outputRate: Int(sampleRate))
            report.format = "\(Self.kHz(auRate)) \(auChannels == 1 ? "mono" : "stereo") (\(Self.kHz(sampleRate)) ↔ \(Self.kHz(auRate)) yeniden örnekleme)"
        } else {
            toAU = nil
            fromAU = nil
            report.format = "\(Self.kHz(auRate)) \(auChannels == 1 ? "mono" : "stereo")"
        }
        fifoPad = toAU == nil ? 0 : 32

        // Parametreler: yalnızca ayrılmış ses (%100 ıslak); karışımı DialogCore yapar.
        let tree = unit.parameterTree
        tree?.parameter(withID: kAUSoundIsolationParam_WetDryMixPercent, scope: kAudioUnitScope_Global, element: 0)?.value = 100
        let type = highQuality ? kAUSoundIsolationSoundType_HighQualityVoice : kAUSoundIsolationSoundType_Voice
        if let parameter = tree?.parameter(withID: kAUSoundIsolationParam_SoundToIsolate, scope: kAudioUnitScope_Global, element: 0) {
            parameter.value = AUValue(type)
            if Int(parameter.value) != type { report.lastError = "SoundToIsolate kabul edilmedi (\(parameter.value))" }
        } else if highQuality {
            report.lastError = "SoundToIsolate parametresi yok"
        }

        unit.maximumFramesToRender = Self.maxFrames
        do {
            try unit.allocateRenderResources()
        } catch {
            throw SoundIsolationError.unavailable("kaynak ayrılamadı: \(error.localizedDescription)")
        }
        render = unit.renderBlock
        report.declaredLatencyMs = unit.latency * 1000

        // Zincirin kendi gecikmesi: yeniden örnekleme + FIFO payı + AU'nun bildirdiği.
        let rateAU = chosen.rate
        let resampling = (toAU.map { $0.latency * sampleRate / rateAU } ?? 0) + (fromAU?.latency ?? 0)
        latency = Int((Double(fifoPad) + resampling + unit.latency * sampleRate).rounded())
        framesUntilProbe = Int(sampleRate * 8)
        reportValue = report

        let inputList = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        pull = { _, _, frameCount, _, data in
            let destination = UnsafeMutableAudioBufferListPointer(data)
            let bytes = Int(frameCount) * MemoryLayout<Float>.size
            for i in 0..<min(destination.count, inputList.count) {
                guard let source = inputList[i].mData else { return kAudioUnitErr_NoConnection }
                if let target = destination[i].mData {
                    target.copyMemory(from: source, byteCount: bytes)
                } else {
                    destination[i].mData = source
                }
                destination[i].mDataByteSize = UInt32(bytes)
            }
            return noErr
        }
        resetChain()
        calibrate()
    }

    deinit {
        unit.deallocateRenderResources()
    }

    func reset() {
        resetChain()
        probeInput.removeAll(keepingCapacity: true)
        probeOutput.removeAll(keepingCapacity: true)
        framesUntilProbe = Int(sampleRate * 8)
    }

    func isolate(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) -> [Float] {
        let n = min(left.count, right.count)
        guard n > 0 else { return [] }
        let cpuStart = Self.threadCPUTime()
        let wallStart = CACurrentMediaTime()

        var mono = [Float](repeating: 0, count: n)
        for i in 0..<n { mono[i] = 0.5 * (left[i] + right[i]) }
        let atAURate = toAU.map { r in mono.withUnsafeBufferPointer { r.process($0) } } ?? mono
        var voice = [Float](repeating: 0, count: atAURate.count)
        var offset = 0
        while offset < atAURate.count {
            let count = min(Int(Self.maxFrames), atAURate.count - offset)
            atAURate.withUnsafeBufferPointer { src in
                voice.withUnsafeMutableBufferPointer { dst in
                    renderChunk(UnsafeBufferPointer(rebasing: src[offset..<(offset + count)]),
                                into: UnsafeMutableBufferPointer(rebasing: dst[offset..<(offset + count)]))
                }
            }
            offset += count
        }
        let back = fromAU.map { r in voice.withUnsafeBufferPointer { r.process($0) } } ?? voice
        // Yeniden örnekleme çıktısı çağrı başına birkaç örnek oynayabilir: FIFO payı bunu karşılar; yine de
        // eksik kalırsa sıfır verilir ve borç sonradan düşülür, hizalama kaymaz.
        fifo.append(contentsOf: back)
        if debt > 0 {
            let drop = min(debt, fifo.count)
            fifo.removeFirst(drop)
            debt -= drop
        }
        let available = min(n, fifo.count)
        var out = Array(fifo.prefix(available))
        fifo.removeFirst(available)
        if available < n {
            out += [Float](repeating: 0, count: n - available)
            debt += n - available
        }

        let wall = CACurrentMediaTime() - wallStart
        account(cpu: Self.threadCPUTime() - cpuStart, wall: wall, frames: n)
        probe(input: mono, output: out)
        return out
    }

    // MARK: Render

    private func renderChunk(_ source: UnsafeBufferPointer<Float>, into destination: UnsafeMutableBufferPointer<Float>) {
        let n = source.count
        guard let inputChannels = input.floatChannelData, let outputChannels = output.floatChannelData else { return }
        for c in 0..<auChannels {
            inputChannels[c].update(from: source.baseAddress!, count: n)
        }
        input.frameLength = AVAudioFrameCount(n)
        let list = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        for c in 0..<list.count {
            list[c].mData = UnsafeMutableRawPointer(outputChannels[c])
            list[c].mDataByteSize = UInt32(n * MemoryLayout<Float>.size)
        }
        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = sampleTime
        timestamp.mFlags = .sampleTimeValid
        let status = render(&flags, &timestamp, AUAudioFrameCount(n), 0, output.mutableAudioBufferList, pull)
        sampleTime += Double(n)
        guard status == noErr else {
            consecutiveErrors += 1
            if consecutiveErrors >= 3 { failed = true }
            lock.lock()
            reportValue.renderErrors += 1
            reportValue.lastError = "render \(status)"
            lock.unlock()
            for i in 0..<n { destination[i] = 0 }
            return
        }
        consecutiveErrors = 0
        // AU kendi tamponunu vermiş olabilir: ABL'deki işaretçiden okunur.
        for i in 0..<n { destination[i] = 0 }
        let weight = 1 / Float(auChannels)
        for c in 0..<min(list.count, auChannels) {
            guard let data = list[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<n { destination[i] += weight * data[i] }
        }
    }

    private func resetChain() {
        unit.reset()
        toAU?.reset()
        fromAU?.reset()
        sampleTime = 0
        fifo = [Float](repeating: 0, count: fifoPad)
        debt = 0
        consecutiveErrors = 0
        failed = false
    }

    // MARK: Gecikme

    /// Sentetik konuşma (formantlı darbe dizisi) zincirden geçirilir; çapraz korelasyonla gecikme ölçülür.
    /// Korelasyon yeterliyse (≥ 0,3) hizalamada bu kullanılır; değilse AU'nun bildirdiği.
    private func calibrate() {
        let seconds = 3.0
        let speech = Self.syntheticSpeech(sampleRate: sampleRate, seconds: seconds)
        var out: [Float] = []
        let block = 1024
        var offset = 0
        while offset < speech.count {
            let n = min(block, speech.count - offset)
            let chunk = Array(speech[offset..<(offset + n)])
            out += chunk.withUnsafeBufferPointer { isolate(left: $0, right: $0) }
            offset += n
        }
        let start = Int(sampleRate)
        let result = LagEstimator.estimate(reference: Array(speech[start...]), signal: Array(out[start...]),
                                           maxLag: Int(sampleRate * 0.5))
        lock.lock()
        if let result {
            reportValue.calibratedLatencyMs = Double(result.lag) / sampleRate * 1000
            reportValue.calibrationCorrelation = result.correlation
            if result.correlation >= 0.3 { latency = result.lag }
        }
        reportValue.usedLatencyMs = Double(latency) / sampleRate * 1000
        // Kalibrasyon yükü rapora girmez.
        cpuSeconds = 0
        wallSeconds = 0
        mediaSeconds = 0
        blockWorst.removeAll()
        blockWorstCurrent = 0
        blockWorstFrames = 0
        reportValue.renderErrors = 0
        lock.unlock()
        resetChain()
    }

    /// Her ~8 s'de 2 s'lik girdi/çıktı yakalanır ve gecikme arka planda ölçülür (korelasyon ≥ 0,3 ise rapora).
    private func probe(input: [Float], output: [Float]) {
        if probeInput.isEmpty {
            framesUntilProbe -= input.count
            lock.lock()
            let busy = probing
            lock.unlock()
            guard framesUntilProbe <= 0, !busy else { return }
        }
        probeInput += input
        probeOutput += output
        guard probeInput.count >= Int(sampleRate * 2) else { return }
        let reference = probeInput
        let signal = probeOutput
        let rate = sampleRate
        probeInput.removeAll(keepingCapacity: true)
        probeOutput.removeAll(keepingCapacity: true)
        framesUntilProbe = Int(sampleRate * 8)
        lock.lock()
        probing = true
        lock.unlock()
        probeQueue.async { [weak self] in
            let result = LagEstimator.estimate(reference: reference, signal: signal, maxLag: Int(rate * 0.5))
            guard let self else { return }
            self.lock.lock()
            if let result, result.correlation >= 0.3 {
                self.reportValue.measuredLatencyMs = Double(result.lag) / rate * 1000
                self.reportValue.measuredCorrelation = result.correlation
            }
            self.probing = false
            self.lock.unlock()
        }
    }

    private func account(cpu: Double, wall: Double, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        cpuSeconds += cpu
        wallSeconds += wall
        mediaSeconds += Double(frames) / sampleRate
        // 512 karelik (48 kHz'te 10,67 ms) blok başına süre; çağrılar farklı boyda olduğundan orantılanır.
        let perBlock = wall / Double(frames) * 512 * 1000
        blockWorstCurrent = max(blockWorstCurrent, perBlock)
        blockWorstFrames += frames
        if blockWorstFrames >= Int(sampleRate) {
            blockWorst.append(blockWorstCurrent)
            if blockWorst.count > 10 { blockWorst.removeFirst() }
            blockWorstCurrent = 0
            blockWorstFrames = 0
        }
        if mediaSeconds > 0.5 {
            reportValue.cpuPercent = cpuSeconds / mediaSeconds * 100
            reportValue.wallPercent = wallSeconds / mediaSeconds * 100
            reportValue.worstBlockMs = blockWorst.max()
        }
    }

    // MARK: Yardımcılar

    /// Giriş ve çıkış aynı biçime ayarlanır. Bazı efektler giriş/çıkış kanal ya da hız uyuşmazlığını reddettiğinden
    /// iki sıra da denenir.
    private static func setFormat(_ format: AVAudioFormat, on unit: AUAudioUnit) -> Bool {
        if (try? unit.inputBusses[0].setFormat(format)) != nil, (try? unit.outputBusses[0].setFormat(format)) != nil { return true }
        if (try? unit.outputBusses[0].setFormat(format)) != nil, (try? unit.inputBusses[0].setFormat(format)) != nil { return true }
        return false
    }

    /// Formantlı darbe dizisi: 4 Hz hece zarfı, değişen temel frekans, beş ünlü (a e i o u).
    static func syntheticSpeech(sampleRate fs: Double, seconds: Double) -> [Float] {
        let count = Int(fs * seconds)
        let vowels: [(Double, Double, Double)] = [(730, 1090, 2440), (530, 1840, 2480), (270, 2290, 3010),
                                                  (570, 840, 2410), (300, 870, 2240)]
        let bandwidths = [80.0, 90.0, 120.0]
        var state = [(0.0, 0.0), (0.0, 0.0), (0.0, 0.0)]
        var phase = 0.0
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / fs
            let syllable = Int(t / 0.25)
            let vowel = vowels[syllable % vowels.count]
            let f0 = 120 + 30 * sin(2 * Double.pi * 0.7 * t) + 10 * Double(syllable % 3)
            phase += f0 / fs
            var x = 0.0
            if phase >= 1 {
                phase -= 1
                x = 1
            }
            let local = t.truncatingRemainder(dividingBy: 0.25) / 0.25
            let envelope = local < 0.8 ? sin(Double.pi * local / 0.8) : 0
            var y = x
            for (k, f) in [vowel.0, vowel.1, vowel.2].enumerated() {
                let r = exp(-Double.pi * bandwidths[k] / fs)
                let a1 = 2 * r * cos(2 * Double.pi * f / fs)
                let a2 = -r * r
                let v = (1 - r) * y + a1 * state[k].0 + a2 * state[k].1
                state[k].1 = state[k].0
                state[k].0 = v
                y = v
            }
            out[i] = Float(y * envelope)
        }
        let peak = out.reduce(Float(0)) { max($0, abs($1)) }
        if peak > 0 { for i in out.indices { out[i] *= 0.3 / peak } }
        return out
    }

    private static func kHz(_ rate: Double) -> String {
        rate.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(rate / 1000))k" : "\(TR.num(rate / 1000, 1))k"
    }

    private static func threadCPUTime() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }
}
