import Foundation

/// Konuşmayı ayıran motor (AUSoundIsolation ya da F1). Aynı sayıda örnek döndürür; `latency` örnek gecikmelidir.
public protocol VoiceIsolator: AnyObject {
    var latency: Int { get }
    func isolate(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) -> [Float]
    func reset()
}

extension CenterExtractor: VoiceIsolator {
    public func isolate(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) -> [Float] {
        process(left: left, right: right)
    }
}

/// Karışık örnekteki kanalın rolü (BS.1770 ağırlığı ve diyalog yerleşimi için).
public enum ChannelRole: Sendable {
    case left, right, center, lfe, surround, other
}

/// Müzikli sahnelerde diyalog yükseltmesinin gevşetilmesi (02-cozum §5.4, Sound Analysis).
public enum MusicRelaxation {
    /// `r = clamp(1 − 0,8 · max(p_müzik, p_şarkı) · (1 − p_konuşma), 0,2, 1)`
    public static func target(music: Double, singing: Double, speech: Double) -> Double {
        min(max(1 - 0.8 * max(music, singing) * (1 - speech), 0.2), 1)
    }
}

/// M9 diyalog netleştirme çekirdeği (02-cozum §5.4): ayrılmış sesin geri karıştırılması.
///
/// Stereo: `v = izole(L, R)`; `L' = c·(L + a·v)`, `R' = c·(R + a·v)`. Mono: kanalın kendisi izole edilir.
/// Çok kanallı: kademe 1–2'de merkez `C·(1 + a)`, kademe 3'te `C + a·izole(C)`. `a = (10^(G/20) − 1)·r`,
/// G = +3/+6/+9 dB. `c`: K-ağırlıklı 3 s loudness eşleme, [−6, 0] dB, τ = 2 s.
/// Kuru yol ve iki motor ortak `latency`'ye hizalanır; çıktı örneği `j`, girdi örneği `j − latency`'dir.
public final class DialogCore {
    public enum Engine: Int, Sendable {
        case primary = 0
        case fallback = 1
    }

    public let sampleRate: Double
    public let roles: [ChannelRole]
    public let latency: Int
    public var tier = 0
    /// Yalnızca ayrılmış ses (dinleme testi); loudness eşleme uygulanmaz.
    public var solo = false
    /// Müzik gevşetmesi hedefi (0,2–1); gevşeme 0,5 s, dönüş 1 s ile yumuşatılır.
    public var relaxationTarget = 1.0
    public private(set) var relaxation = 1.0
    /// Loudness eşleme kazancı (dB, ≤ 0).
    public private(set) var compensationDB = 0.0
    public private(set) var activeEngine: Engine

    private let channels: Int
    private let leftIndex: Int?
    private let rightIndex: Int?
    private let centerIndex: Int?
    private let multichannel: Bool
    private var engines: [VoiceIsolator?]
    private var engineFIFOs: [[Float]]
    private var engineRunning: [Bool]
    private var engineFed: [Int]
    private var weights: [Double]
    private var targetEngine: Engine
    private var dryFIFO: [Float]
    private var dryMeter: LoudnessMeter
    private var wetMeter: LoudnessMeter
    private let crossfadeFrames: Int
    private let warmFrames: Int
    private var neededVoice = true
    /// Sıfırlamadan sonra hızlı oturma süresi (kare): yeniden işlemede ısınma çıktısı atılır, `c` ve `r` hemen
    /// yerine otursun diye bu sürede zaman sabitleri kısadır.
    private var settleFrames = 0

    public init(sampleRate: Double, roles: [ChannelRole], primary: VoiceIsolator?, fallback: VoiceIsolator?,
                start: Engine = .primary) {
        self.sampleRate = sampleRate
        self.roles = roles
        channels = roles.count
        leftIndex = roles.firstIndex(of: .left)
        rightIndex = roles.firstIndex(of: .right)
        centerIndex = roles.firstIndex(of: .center)
        multichannel = channels > 2 && centerIndex != nil
        engines = [primary, fallback]
        latency = max(primary?.latency ?? 0, fallback?.latency ?? 0)
        let first: Engine = (start == .primary && primary != nil) || fallback == nil ? .primary : .fallback
        activeEngine = first
        targetEngine = first
        weights = first == .primary ? [1, 0] : [0, 1]
        engineRunning = [first == .primary, first == .fallback]
        engineFed = [0, 0]
        engineFIFOs = [[], []]
        dryFIFO = [Float](repeating: 0, count: latency * roles.count)
        let meterWeights = roles.map { role -> Double in
            switch role {
            case .lfe: return 0
            case .surround: return 1.41
            default: return 1
            }
        }
        dryMeter = LoudnessMeter(sampleRate: sampleRate, weights: meterWeights)
        wetMeter = LoudnessMeter(sampleRate: sampleRate, weights: meterWeights)
        crossfadeFrames = Int(0.2 * sampleRate)
        warmFrames = Int(0.3 * sampleRate)
        for e in 0..<2 where engineRunning[e] { startEngine(e) }
    }

    /// Kademe 1–3 için dB.
    public static func gainDB(tier: Int) -> Double { [0, 3, 6, 9][min(max(tier, 0), 3)] }

    /// Motor değişimi (ör. arka plan → F1). Boşta duran motor önce ısınır, sonra 200 ms çapraz geçiş yapılır.
    public func select(_ engine: Engine) {
        guard engines[engine.rawValue] != nil else { return }
        targetEngine = engine
        if !engineRunning[engine.rawValue] { startEngine(engine.rawValue) }
    }

    /// Karışık örnekleri işler; aynı sayıda örnek (`latency` gecikmeli) döndürür.
    public func process(_ input: UnsafeBufferPointer<Float>, frames: Int) -> [Float] {
        let n = frames
        let blockSeconds = Double(n) / sampleRate

        // Kuru yol gecikmesi.
        dryFIFO.append(contentsOf: input.prefix(n * channels))
        let dry = Array(dryFIFO.prefix(n * channels))
        dryFIFO.removeFirst(n * channels)

        // İzolasyon kaynağı: stereo L/R, mono kanal, çok kanallıda merkez (kademe 3 ya da solo).
        // Ses gerekmeyen blokta motorlar beslenmez; yeniden gerektiğinde sıfırdan ısınırlar.
        let needsVoice = solo || !multichannel || tier >= 3
        if needsVoice, !neededVoice {
            for e in 0..<2 where engineRunning[e] { startEngine(e) }
        }
        neededVoice = needsVoice
        var voice = [Float](repeating: 0, count: n)
        if needsVoice {
            var sourceL = [Float](repeating: 0, count: n)
            var sourceR = [Float](repeating: 0, count: n)
            let li = multichannel ? centerIndex! : (leftIndex ?? 0)
            let ri = multichannel ? centerIndex! : (rightIndex ?? leftIndex ?? 0)
            for f in 0..<n {
                sourceL[f] = input[f * channels + li]
                sourceR[f] = input[f * channels + ri]
            }
            voice = isolate(left: sourceL, right: sourceR, frames: n)
        }

        // Kazançlar.
        let settling = settleFrames > 0
        settleFrames = max(settleFrames - n, 0)
        relaxation = Self.smooth(relaxation, toward: relaxationTarget, dt: blockSeconds,
                                 tau: settling ? 0.1 : relaxationTarget < relaxation ? 0.5 : 1.0)
        let g = pow(10, Self.gainDB(tier: tier) / 20)
        let a = Float((g - 1) * relaxation)

        var out = [Float](repeating: 0, count: n * channels)
        if solo {
            let targets = multichannel ? [centerIndex!] : [leftIndex, rightIndex].compactMap { $0 } + (channels == 1 ? [0] : [])
            for f in 0..<n {
                for c in targets { out[f * channels + c] = voice[f] }
            }
            return out
        }

        for f in 0..<n {
            for c in 0..<channels {
                let x = dry[f * channels + c]
                if multichannel {
                    if c == centerIndex {
                        out[f * channels + c] = tier >= 3 ? x + a * voice[f] : x * (1 + a)
                    } else {
                        out[f * channels + c] = x
                    }
                } else {
                    out[f * channels + c] = x + a * voice[f]
                }
            }
        }

        // Loudness eşleme: kuru ve (c öncesi) ıslak sinyalin 3 s K-ağırlıklı loudness'ı.
        dry.withUnsafeBufferPointer { dryMeter.add(interleaved: $0, frames: n) }
        out.withUnsafeBufferPointer { wetMeter.add(interleaved: $0, frames: n) }
        var target = 0.0
        if tier > 0, let ld = dryMeter.loudness, let lw = wetMeter.loudness {
            target = min(max(ld - lw, -6), 0)
        }
        let start = compensationDB
        compensationDB = Self.smooth(compensationDB, toward: target, dt: blockSeconds, tau: settling ? 0.15 : 2.0)
        // Blok içinde doğrusal rampa (fermuar sesi olmasın).
        let g0 = Float(pow(10, start / 20))
        let g1 = Float(pow(10, compensationDB / 20))
        for f in 0..<n {
            let gain = g0 + (g1 - g0) * Float(f + 1) / Float(n)
            for c in 0..<channels { out[f * channels + c] *= gain }
        }
        return out
    }

    /// Durumu sıfırlar (sarma ya da yeniden işleme); bir sonraki çıktı yine `latency` gecikmelidir.
    /// - Parameter settleSeconds: Isınma süresi; bu sürede `c` ve `r` hızlı oturur (çıktısı atılacak bölüm).
    public func reset(settleSeconds: Double = 0) {
        dryFIFO = [Float](repeating: 0, count: latency * channels)
        dryMeter.reset()
        wetMeter.reset()
        compensationDB = 0
        relaxation = relaxationTarget
        settleFrames = Int(settleSeconds * sampleRate)
        for e in 0..<2 where engineRunning[e] { startEngine(e) }
    }

    // MARK: Özel

    private func startEngine(_ e: Int) {
        guard let engine = engines[e] else { return }
        engine.reset()
        engineRunning[e] = true
        engineFed[e] = 0
        engineFIFOs[e] = [Float](repeating: 0, count: latency - engine.latency)
    }

    private func isolate(left: [Float], right: [Float], frames n: Int) -> [Float] {
        var outputs: [[Float]] = [[], []]
        for e in 0..<2 where engineRunning[e] {
            guard let engine = engines[e] else { continue }
            let v = left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in engine.isolate(left: l, right: r) } }
            engineFIFOs[e].append(contentsOf: v)
            outputs[e] = Array(engineFIFOs[e].prefix(n))
            engineFIFOs[e].removeFirst(min(n, engineFIFOs[e].count))
            engineFed[e] += n
        }
        // Çapraz geçiş: hedef motor ısındıysa ağırlık 200 ms'de ona kayar.
        var voice = [Float](repeating: 0, count: n)
        let target = targetEngine.rawValue
        guard let targetIsolator = engines[target] else { return voice }
        let ready = engineFed[target] >= targetIsolator.latency + warmFrames || weights[target] > 0
        let step = 1.0 / Double(max(crossfadeFrames, 1))
        for f in 0..<n {
            if ready, weights[target] < 1 {
                weights[target] = min(weights[target] + step, 1)
                weights[1 - target] = 1 - weights[target]
            }
            var v: Float = 0
            for e in 0..<2 where weights[e] > 0 && f < outputs[e].count { v += Float(weights[e]) * outputs[e][f] }
            voice[f] = v
        }
        if weights[target] >= 1 {
            activeEngine = targetEngine
            engineRunning[1 - target] = false
        }
        return voice
    }

    private static func smooth(_ value: Double, toward target: Double, dt: Double, tau: Double) -> Double {
        value + (target - value) * (1 - exp(-dt / tau))
    }
}
