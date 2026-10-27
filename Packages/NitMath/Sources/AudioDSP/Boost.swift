import Foundation

/// M10 limiter kipi (02-cozum §5.5).
public enum LimiterMode: String, CaseIterable, Sendable {
    /// Boost yöneticisi + yumuşak dirsekli kompresör + gerçek tepe limiter (varsayılan).
    case smart = "Akıllı"
    /// Boost doğrudan, yalnızca gerçek tepe limiter.
    case limiterOnly = "Yalnızca limiter"
    /// Boost doğrudan, sonda deterministik sert kırpma (±1,0); kırpılan örnekler sayılır.
    case off = "Kapalı"
    /// Laboratuvar (AS-37 g): kırpma yok; 1,0'ı aşan float renderer'a gider, yalnızca sayılır.
    case rawFloat = "Ham float"
}

/// M10 ayarları.
public struct BoostConfig: Equatable, Sendable {
    /// Kaydırıcı, %100–150.
    public var percent: Double
    public var mode: LimiterMode
    /// Limiter tavanı (dBTP): −1,0; Bluetooth AAC rotasında −1,5.
    public var ceilingDBTP: Double
    /// Yöneticinin hedef üst loudness'ı (LUFS, kısa süreli): −10; "Agresif" −7.
    public var maxLoudness: Double
    /// Hoparlör rotasında 150 Hz, 2. derece yüksek geçiren (boost > %100 iken).
    public var speakerHighPass: Bool

    public init(percent: Double = 100, mode: LimiterMode = .smart, ceilingDBTP: Double = -1, maxLoudness: Double = -10,
                speakerHighPass: Bool = false) {
        self.percent = percent
        self.mode = mode
        self.ceilingDBTP = ceilingDBTP
        self.maxLoudness = maxLoudness
        self.speakerHighPass = speakerHighPass
    }

    /// Algısal eşleme: `G(p) = 6 · log2(p/100) / log2(1,5)` dB; kod düzeyinde [0, 6] dB'ye kenetli.
    public static func gainDB(percent: Double) -> Double {
        let p = min(max(percent.isFinite ? percent : 100, 100), 150)
        // 1e-9 dB'ye yuvarlanır: %150 tam 6 dB olsun (kayan nokta artığı kazancı oynatmasın).
        let g = (6 * log2(p / 100) / log2(1.5) * 1e9).rounded() / 1e9
        return min(max(g, 0), 6)
    }

    public var targetGainDB: Double { Self.gainDB(percent: percent) }
}

/// Bir alt blokun (256 kare) göstergeleri. Arayüz bunları PTS ile oynatma noktasına hizalayarak okur.
public struct BoostBlockStats: Equatable, Sendable {
    /// Çağrının çıkışında alt blokun ilk karesi.
    public var offset: Int
    public var frames: Int
    /// Kompresör + limiter kazanç azaltması, alt bloktaki en büyük değer (dB, ≥ 0).
    public var gainReductionDB: Double
    /// Uygulanan boost (yönetici sonrası, dB).
    public var appliedGainDB: Double
    /// Kanal başına kırpılan (Kapalı) ya da 1,0'ı aşan (Ham float) örnek sayısı.
    public var clipped: [Int]
    /// Kırpma öncesi en büyük örnek (dBFS).
    public var peakDBFS: Double
    /// Çıkışta gerçek tepesi tavanı (limiter kiplerinde) ya da 0 dBTP'yi (Kapalı/Ham) aşan örnek aralığı sayısı.
    public var truePeakOvers: Int
}

/// M10 boost zinciri (02-cozum §5.5). Karışık float örnek alır, aynı sayıda örnek `latency` gecikmeyle verir.
/// Gecikme kipten bağımsızdır (anahtar değişince zamanlama sıçramaz):
/// yöneticinin ileriye bakışı + limiter ön bakışı (2 ms) + gerçek tepe dedektörünün gecikmesi.
public final class BoostChain {
    public let sampleRate: Double
    public let channels: Int
    public let latency: Int
    public let config: BoostConfig
    /// Yöneticinin şu anki kazancı (dB). Akıllı dışındaki kiplerde hedef kazançtır.
    public private(set) var managerGainDB: Double
    /// Son `process` çağrısının alt blok göstergeleri.
    public private(set) var stats: [BoostBlockStats] = []
    public static let statsInterval = 256

    private let targetGain: Double
    private let managerDelay: Int
    private let lookahead: Int
    private let limiterDelay: Int
    private let ceiling: Float
    private let limiterTarget: Float
    private let useLimiter: Bool
    private let useCompressor: Bool
    private let useHighPass: Bool

    private var meter: LoudnessMeter
    private var managerLine: [Float]
    private var managerPos = 0
    private var highPass: [Biquad]
    private var compPower: [Double]
    private var compGainDB = 0.0
    private let rmsCoef: Double
    private let compAttack: Double
    private let compRelease: Double

    private var detectors: [TruePeakDetector]
    private var outputDetectors: [TruePeakDetector]
    private var limiterLine: [Float]
    private var limiterPos = 0
    /// Kayan pencere minimumu (L + 1 örnek) için tekdüze kuyruk: (örnek sırası, gerekli kazanç).
    private var minQueue: [(index: Int, value: Float)] = []
    private var minHead = 0
    private var envelopeRing: [Float]
    private var envelopePos = 0
    private let window: [Float]
    private var fastEnvelope: Float = 1
    private var slowEnvelope: Float = 1
    private let fastRelease: Float
    private let slowAttack: Float
    private let slowRelease: Float
    private var sampleIndex = 0
    private var settleFrames = 0

    /// - Parameters:
    ///   - weights: BS.1770 kanal ağırlıkları (ön ve merkez 1, surround 1,41, LFE 0); yöneticinin loudness'ı için.
    ///   - managerLookahead: Yöneticinin ileriye bakışı (s).
    public init(sampleRate: Double, weights: [Double], config: BoostConfig, managerLookahead: Double = 1.0) {
        self.sampleRate = sampleRate
        let channels = weights.count
        self.channels = channels
        self.config = config
        let target = config.targetGainDB
        targetGain = target
        managerDelay = max(Int(managerLookahead * sampleRate), 0)
        let lookahead = max(Int((0.002 * sampleRate).rounded()), 1)
        self.lookahead = lookahead
        limiterDelay = lookahead + TruePeak.delay
        latency = managerDelay + lookahead + TruePeak.delay
        ceiling = Float(pow(10, config.ceilingDBTP / 20))
        // Kazanç ara değerler arasında değiştiğinden küçük bir pay bırakılır (−0,1 dB).
        limiterTarget = Float(pow(10, (config.ceilingDBTP - 0.1) / 20))
        useLimiter = config.mode == .smart || config.mode == .limiterOnly
        useCompressor = config.mode == .smart && target > 0
        useHighPass = config.speakerHighPass && target > 0
        managerGainDB = config.mode == .smart ? 0 : target

        meter = LoudnessMeter(sampleRate: sampleRate, weights: weights)
        managerLine = [Float](repeating: 0, count: max(managerDelay, 1) * channels)
        highPass = (0..<channels).map { _ in Self.highPass(sampleRate: sampleRate, frequency: 150) }
        compPower = [Double](repeating: 0, count: channels)
        rmsCoef = 1 - exp(-1 / (0.010 * sampleRate))
        compAttack = 1 - exp(-1 / (0.005 * sampleRate))
        compRelease = 1 - exp(-1 / (0.120 * sampleRate))

        detectors = [TruePeakDetector](repeating: TruePeakDetector(), count: channels)
        outputDetectors = [TruePeakDetector](repeating: TruePeakDetector(), count: channels)
        limiterLine = [Float](repeating: 0, count: (lookahead + TruePeak.delay) * channels)
        envelopeRing = [Float](repeating: 1, count: lookahead)
        // Hann biçimli atak rampası: L katsayı, toplamı 1.
        let raw = (0..<lookahead).map { Float(0.5 - 0.5 * cos(2 * Double.pi * (Double($0) + 0.5) / Double(lookahead))) }
        let sum = raw.reduce(0, +)
        window = raw.map { $0 / sum }
        fastRelease = Float(1 - exp(-1 / (0.060 * sampleRate)))
        slowAttack = Float(1 - exp(-1 / (0.150 * sampleRate)))
        slowRelease = Float(1 - exp(-1 / (0.400 * sampleRate)))
    }

    /// Yumuşak dirsekli kompresörün statik eğrisi: seviye (dBFS) → kazanç (dB, ≤ 0).
    public static func compressorGainDB(level: Double, threshold: Double = -8, ratio: Double = 2, knee: Double = 6) -> Double {
        let over = level - threshold
        if 2 * over <= -knee { return 0 }
        if 2 * over < knee { return (1 / ratio - 1) * (over + knee / 2) * (over + knee / 2) / (2 * knee) }
        return (1 / ratio - 1) * over
    }

    /// Sıfırlar; `settleSeconds` boyunca yönetici hızlı oturur (yeniden işleme ısınması, çıktısı atılır).
    public func reset(settleSeconds: Double = 0) {
        meter.reset()
        for i in managerLine.indices { managerLine[i] = 0 }
        managerPos = 0
        for i in highPass.indices { highPass[i].reset() }
        for i in compPower.indices { compPower[i] = 0 }
        compGainDB = 0
        for c in 0..<channels {
            detectors[c].reset()
            outputDetectors[c].reset()
        }
        for i in limiterLine.indices { limiterLine[i] = 0 }
        limiterPos = 0
        minQueue.removeAll(keepingCapacity: true)
        minHead = 0
        for i in envelopeRing.indices { envelopeRing[i] = 1 }
        envelopePos = 0
        fastEnvelope = 1
        slowEnvelope = 1
        sampleIndex = 0
        managerGainDB = config.mode == .smart ? 0 : targetGain
        settleFrames = Int(settleSeconds * sampleRate)
    }

    /// Karışık örnekleri işler; aynı sayıda, `latency` gecikmeli örnek döndürür.
    public func process(_ input: UnsafeBufferPointer<Float>, frames n: Int) -> [Float] {
        let C = channels
        var out = [Float](repeating: 0, count: n * C)
        stats.removeAll(keepingCapacity: true)
        guard n > 0 else { return out }

        // Yönetici: girdinin (ileriye bakışın ucundaki) 3 s loudness'ı; kazanç çağrı boyunca doğrusal rampa.
        meter.add(interleaved: input, frames: n)
        let start = managerGainDB
        if config.mode == .smart {
            var desired = targetGain
            if let loudness = meter.loudness { desired = min(targetGain, max(0, config.maxLoudness - loudness)) }
            let settling = settleFrames > 0
            let tau = desired < managerGainDB ? (settling ? 0.15 : 1.5) : (settling ? 0.3 : 4.0)
            managerGainDB += (desired - managerGainDB) * (1 - exp(-Double(n) / sampleRate / tau))
        }
        settleFrames = max(settleFrames - n, 0)
        let g0 = Float(pow(10, start / 20))
        let g1 = Float(pow(10, managerGainDB / 20))

        var frame = [Float](repeating: 0, count: C)
        var block = BoostBlockStats(offset: 0, frames: 0, gainReductionDB: 0, appliedGainDB: managerGainDB,
                                    clipped: [Int](repeating: 0, count: C), peakDBFS: -120, truePeakOvers: 0)
        var blockPeak: Float = 0
        var blockMinGain: Float = 1
        let overThreshold = useLimiter ? ceiling : 1

        for f in 0..<n {
            // 1. Yönetici gecikme hattı ve boost kazancı.
            let gain = g0 + (g1 - g0) * Float(f + 1) / Float(n)
            for c in 0..<C {
                let x = input[f * C + c]
                var d = x
                if managerDelay > 0 {
                    let i = managerPos * C + c
                    d = managerLine[i]
                    managerLine[i] = x
                }
                frame[c] = d * gain
            }
            if managerDelay > 0 { managerPos = managerPos + 1 == managerDelay ? 0 : managerPos + 1 }

            // 2. Hoparlör yüksek geçireni.
            if useHighPass {
                for c in 0..<C { frame[c] = Float(highPass[c].process(Double(frame[c]))) }
            }

            // 3. Kompresör (RMS 10 ms, bağlı kanallar).
            var compLinear: Float = 1
            if useCompressor {
                var power = 0.0
                for c in 0..<C {
                    let v = Double(frame[c])
                    compPower[c] += (v * v - compPower[c]) * rmsCoef
                    power = max(power, compPower[c])
                }
                let level = 10 * log10(power + 1e-12)
                let desired = Self.compressorGainDB(level: level)
                compGainDB += (desired - compGainDB) * (desired < compGainDB ? compAttack : compRelease)
                compLinear = Float(pow(10, compGainDB / 20))
                for c in 0..<C { frame[c] *= compLinear }
            }

            // 4. Limiter hattı (kiplerden bağımsız aynı gecikme) ve gerçek tepe.
            var limiterGain: Float = 1
            if useLimiter {
                var peak: Float = 0
                for c in 0..<C { peak = max(peak, detectors[c].push(frame[c], threshold: limiterTarget)) }
                let required = peak > limiterTarget ? limiterTarget / peak : 1
                // Kayan minimum: [k − L, k] (k = sampleIndex − 6, dedektör gecikmesi).
                let k = sampleIndex
                while minQueue.count > minHead, minQueue[minQueue.count - 1].value >= required { minQueue.removeLast() }
                minQueue.append((k, required))
                while minQueue[minHead].index < k - lookahead { minHead += 1 }
                if minHead > 256 {
                    minQueue.removeFirst(minHead)
                    minHead = 0
                }
                let m = minQueue[minHead].value
                // İki kademeli bırakma: kısa olaylar 60 ms'de, süreğen sınırlama 400 ms'de bırakılır.
                fastEnvelope = m < fastEnvelope ? m : fastEnvelope + (m - fastEnvelope) * fastRelease
                slowEnvelope += (m - slowEnvelope) * (m < slowEnvelope ? slowAttack : slowRelease)
                let envelope = min(fastEnvelope, slowEnvelope)
                envelopeRing[envelopePos] = envelope
                envelopePos = envelopePos + 1 == lookahead ? 0 : envelopePos + 1
                // Hann rampası: son L zarf değerinin ağırlıklı ortalaması (hepsi ≤ gerekli kazanç → tavan korunur).
                var smoothed: Float = 0
                for j in 0..<lookahead {
                    let index = envelopePos - 1 - j
                    smoothed += window[j] * envelopeRing[index < 0 ? index + lookahead : index]
                }
                limiterGain = min(smoothed, 1)
            }
            sampleIndex += 1

            // Gecikmiş örnek limiter kazancıyla (ya da kırpma için) çıkar.
            let base = limiterPos * C
            var overs = false
            for c in 0..<C {
                let delayed = limiterLine[base + c]
                limiterLine[base + c] = frame[c]
                var y = delayed * limiterGain
                let magnitude = abs(y)
                blockPeak = max(blockPeak, magnitude)
                switch config.mode {
                case .off:
                    if magnitude > 1 {
                        block.clipped[c] += 1
                        y = y > 0 ? 1 : -1
                    }
                case .rawFloat:
                    if magnitude > 1 { block.clipped[c] += 1 }
                default:
                    break
                }
                out[f * C + c] = y
                if outputDetectors[c].push(y, threshold: overThreshold) > overThreshold * 1.0001 { overs = true }
            }
            if overs { block.truePeakOvers += 1 }
            limiterPos = limiterPos + 1 == limiterDelay ? 0 : limiterPos + 1
            blockMinGain = min(blockMinGain, limiterGain * compLinear)

            block.frames += 1
            if block.frames == Self.statsInterval || f == n - 1 {
                block.gainReductionDB = -TruePeak.dB(blockMinGain)
                block.peakDBFS = TruePeak.dB(blockPeak)
                stats.append(block)
                block = BoostBlockStats(offset: f + 1, frames: 0, gainReductionDB: 0, appliedGainDB: managerGainDB,
                                        clipped: [Int](repeating: 0, count: C), peakDBFS: -120, truePeakOvers: 0)
                blockPeak = 0
                blockMinGain = 1
            }
        }
        return out
    }

    /// 2. derece Butterworth yüksek geçiren (RBJ).
    static func highPass(sampleRate fs: Double, frequency f0: Double) -> Biquad {
        let w = 2 * Double.pi * f0 / fs
        let alpha = sin(w) / (2 * 0.7071067811865476)
        let a0 = 1 + alpha
        let c = cos(w)
        return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0,
                      a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }
}
