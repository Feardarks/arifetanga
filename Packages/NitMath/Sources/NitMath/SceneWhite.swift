import Foundation

/// Sahne bazlı referans beyaz (`L_ref`) tahmincisi (02-cozum §3.5.1).
///
/// Girdi: kaynak karenin 256 kutulu PQ(maxRGB) histogramı (Metal'de 1/4 çözünürlükte üretilir).
/// Çıkış: `L_ref` (nit). Eğri yalnızca girdiyi ölçekler: `x = L / L_ref`; P-2 her `L_ref` için korunur.
/// İki giriş yolu vardır: HDR10/HLG için histogram, DV için RPU L1 (S2.3). L2/L8 trim düzeltmesi sonra gelir.
public struct SceneWhiteEstimator: Sendable {
    public struct Config: Equatable, Sendable {
        /// Diffuse beyaz yüzdeliği (yalnızca ≥ `minNits` pikseller üzerinden).
        public var percentile = 0.90
        public var minNits = 1.0
        /// Film çapasından en fazla sapma (stop).
        public var deviationStops = 0.5
        public var lMin = 80.0
        public var lMax = 300.0
        /// Tek karelik flaşları silen medyan penceresi (kare).
        public var prefilterFrames = 9
        /// Kesimden sonra yeni sahne değerini belirleyen kare sayısı.
        public var cutFrames = 3
        public var cutTau = 0.25
        /// `L_ref` düşerken (görüntü parlar).
        public var fallTau = 4.0
        public var fallRateStopsPerSecond = 0.25
        /// `L_ref` yükselirken (görüntü kararır); pompalamaya karşı ana koruma.
        public var riseTau = 8.0
        public var riseRateStopsPerSecond = 0.1
        /// Sahne başındaki değere göre sınırlar (stop).
        public var maxRiseInScene = 0.2
        public var maxFallInScene = 0.5
        public var deadbandStops = 0.1
        /// Kesim: `d > cutThreshold` ve `d > cutRelative × medyan(son cutHistory s)`.
        public var cutThreshold = 0.08
        public var cutRelative = 4.0
        public var cutHistory = 2.0
        public var minCutGap = 0.5
        public var anchorRateStopsPerMinute = 0.1
        /// DV L1: algısal ortalamanın ≈ 2 stop üstü (AS-38'de kalibre edilir).
        public var doviK = 4.0

        public init() {}
    }

    /// Telemetri ve HUD için anlık durum.
    public struct State: Equatable, Sendable {
        /// Bu karenin P90 tahmini (nit); `nil` ise karede ≥ 1 nit piksel yok.
        public var frameWhite: Double?
        /// Zamansal süzgeçten geçmiş sahne beyazı Ŵ (nit).
        public var smoothedWhite: Double
        /// Film çapası A (nit).
        public var anchor: Double
        /// Sonuç `L_ref` (nit).
        public var referenceWhite: Double
        /// Son karenin kesim metriği.
        public var cutDistance: Double
        /// Bu karede kesim oldu mu?
        public var cut: Bool
        public var sceneCount: Int
    }

    public var config: Config
    public private(set) var state: State

    private var initialized = false
    private var pendingCut = false
    private var previousL1White: Double?
    private var lastTime: Double?
    private var previousCDF: [Double]?
    private var cutHistory: [(time: Double, d: Double)] = []
    private var lastCutTime = -Double.infinity
    private var ring: [Double] = []
    private var collecting = 0
    private var fastTransition = false
    private var sceneStartLog = 0.0
    private var whiteLog = 0.0
    private var anchorLog = 0.0
    private var anchorWeights = [Double](repeating: 0, count: SceneWhiteEstimator.anchorBinCount)
    private var anchorTotalWeight = 0.0

    private static let anchorBinMinLog = 4.0
    private static let anchorBinWidth = 0.05
    private static let anchorBinCount = 140
    /// Çapa, en az bu kadar sahne süresi birikmeden ilk değerinde kalır (s).
    private static let anchorWarmup = 10.0

    public init(config: Config = Config(), initialAnchor: Double = NitTone.defaultReferenceWhiteNits) {
        self.config = config
        let startLog = log2(max(initialAnchor, 1))
        anchorLog = startLog
        whiteLog = startLog
        state = State(frameWhite: nil, smoothedWhite: initialAnchor, anchor: initialAnchor,
                      referenceWhite: min(max(initialAnchor, config.lMin), config.lMax),
                      cutDistance: 0, cut: false, sceneCount: 0)
    }

    /// Başlangıç çapası: `clamp(MaxFALL, 100, 203)`; MaxFALL yoksa 203 nit.
    public static func initialAnchor(maxFALL: Double?) -> Double {
        guard let maxFALL, maxFALL > 0 else { return NitTone.defaultReferenceWhiteNits }
        return min(max(maxFALL, 100), NitTone.defaultReferenceWhiteNits)
    }

    /// Bir karenin histogramını işler ve `L_ref`'i döndürür.
    /// - Parameters:
    ///   - histogram: 256 kutu; kutu `i` PQ aralığı `[i/256, (i+1)/256)`.
    ///   - time: Karenin medya zamanı (s).
    ///   - forceCut: Sarma ya da döngü başa dönüşü; her zaman kesim sayılır.
    ///   - maxCLL: Biliniyorsa sahne beyazı için tavan (nit).
    @discardableResult
    public mutating func update(histogram: [UInt32], time: Double, forceCut: Bool = false, maxCLL: Double? = nil) -> Double {
        let total = histogram.reduce(0) { $0 + Double($1) }
        guard total > 0 else { return state.referenceWhite }

        let dt = min(max(time - (lastTime ?? time), 0), 0.5)
        lastTime = time

        // 1. Kare beyazı (P90, ≥ 1 nit), MaxCLL tavanıyla.
        var frameWhite = Self.percentileNits(histogram, percentile: config.percentile, minNits: config.minNits)
        if let cll = maxCLL, cll > 0, let w = frameWhite { frameWhite = min(w, cll) }
        state.frameWhite = frameWhite

        // 2. Kesim tespiti (64 kutulu CDF farkı).
        let cdf = Self.coarseCDF(histogram, total: total)
        var cut = forceCut || pendingCut || !initialized
        pendingCut = false
        var distance = 0.0
        if let previous = previousCDF {
            distance = zip(cdf, previous).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(cdf.count)
            cutHistory.removeAll { time - $0.time > config.cutHistory || $0.time > time }
            let median = Self.median(cutHistory.map { $0.d }) ?? 0
            if distance > config.cutThreshold, distance > config.cutRelative * median,
               time - lastCutTime >= config.minCutGap {
                cut = true
            }
            cutHistory.append((time, distance))
        }
        previousCDF = cdf
        state.cutDistance = distance
        return ingest(frameWhite: frameWhite, time: time, dt: dt, cut: cut)
    }

    /// Dolby Vision L1 yolu (02-cozum §3.5.1, öncelik 1): `W_s = min(k · PQ⁻¹(avg), PQ⁻¹(max))`.
    /// L1 değerleri 12-bit PQ kodudur (0–4095). Kesim: RPU `scene_refresh_flag` ya da L1 değişimi.
    /// L1 çekim boyunca sabit olduğundan çekim içinde pompalama yapısal olarak olamaz.
    @discardableResult
    public mutating func update(l1AveragePQ: UInt16, l1MaxPQ: UInt16, time: Double, sceneRefresh: Bool,
                                forceCut: Bool = false, maxCLL: Double? = nil) -> Double {
        let dt = min(max(time - (lastTime ?? time), 0), 0.5)
        lastTime = time
        let average = PQ.eotf(Double(l1AveragePQ) / 4095)
        let maximum = PQ.eotf(Double(l1MaxPQ) / 4095)
        var raw = min(config.doviK * average, maximum)
        if let cll = maxCLL, cll > 0 { raw = min(raw, cll) }
        let white: Double? = raw >= config.minNits ? raw : nil
        state.frameWhite = white

        // L1 değişimi çekim kesimidir. Her karede oynayan kodlamalarda pompalamayı önlemek için
        // ölü bölgeden (0,1 stop) küçük değişimler kesim sayılmaz ve kesimler en az 0,5 s arayla olur.
        let rawLog = log2(max(raw, 1e-3))
        let changed = previousL1White.map { abs(rawLog - $0) >= config.deadbandStops } ?? true
        previousL1White = rawLog
        let changeCut = changed && time - lastCutTime >= config.minCutGap
        let cut = forceCut || pendingCut || !initialized || sceneRefresh || changeCut
        pendingCut = false
        previousCDF = nil
        state.cutDistance = 0
        return ingest(frameWhite: white, time: time, dt: dt, cut: cut)
    }

    /// Kesim kararından sonraki ortak yol: ön süzgeç, sahne içi sınırlar, çapa ve son sınırlar.
    private mutating func ingest(frameWhite: Double?, time: Double, dt: Double, cut: Bool) -> Double {
        state.cut = cut
        if cut {
            lastCutTime = time
            ring.removeAll()
            collecting = config.cutFrames
            state.sceneCount += 1
        }

        // Karede ≥ 1 nit piksel yoksa (siyah kare) tahmin değişmez.
        guard let white = frameWhite else {
            return finish()
        }
        let frameLog = log2(white)

        // 3. Ön süzgeç: son N karenin medyanı.
        ring.append(frameLog)
        if ring.count > config.prefilterFrames { ring.removeFirst(ring.count - config.prefilterFrames) }
        let prefiltered = Self.median(ring) ?? frameLog

        if !initialized {
            initialized = true
            whiteLog = frameLog
            sceneStartLog = frameLog
            collecting = 0
        } else if collecting > 0 {
            // 4. Kesimden sonra ilk karelerin medyanı yeni sahnenin değeridir; geçiş hızlıdır.
            collecting -= 1
            if collecting == 0 {
                sceneStartLog = prefiltered
                fastTransition = true
            }
        } else {
            // 5. Sahne içi: sınırlı hedef, yöne göre yavaş süzgeç.
            let target = min(max(prefiltered, sceneStartLog - config.maxFallInScene), sceneStartLog + config.maxRiseInScene)
            let delta = target - whiteLog
            if fastTransition {
                whiteLog += (1 - exp(-dt / config.cutTau)) * delta
                if abs(target - whiteLog) < 0.01 { fastTransition = false }
            } else if abs(delta) >= config.deadbandStops {
                let falling = delta < 0
                let tau = falling ? config.fallTau : config.riseTau
                let rate = falling ? config.fallRateStopsPerSecond : config.riseRateStopsPerSecond
                let step = (1 - exp(-dt / tau)) * delta
                whiteLog += max(min(step, rate * dt), -rate * dt)
            }
        }
        // 6. Film çapası: sahne değerlerinin süre ağırlıklı medyanı; ≤ 0,1 stop/dk.
        accumulateAnchor(log: prefiltered, weight: dt)
        return finish()
    }

    /// Sarma, döngü ya da yeni dosya sonrası: bir sonraki kare kesim sayılır.
    public mutating func markCut() {
        pendingCut = true
    }

    // MARK: Yardımcılar (testlerde de kullanılır)

    /// Kutu `i` için PQ kodu aralığı `[i/256, (i+1)/256)`.
    public static func bin(forNits nits: Double) -> Int {
        min(255, max(0, Int(PQ.inverseEOTF(nits) * 256)))
    }

    /// `minNits` üstündeki pikseller üzerinden yüzdelik (nit); kutu içinde doğrusal enterpolasyon.
    public static func percentileNits(_ histogram: [UInt32], percentile: Double, minNits: Double) -> Double? {
        let first = bin(forNits: minNits)
        guard first < histogram.count else { return nil }
        let counts = histogram[first...].map { Double($0) }
        let total = counts.reduce(0, +)
        guard total > 0 else { return nil }
        let target = percentile * total
        var cumulative = 0.0
        for (offset, count) in counts.enumerated() where count > 0 {
            if cumulative + count >= target {
                let frac = (target - cumulative) / count
                let pq = (Double(first + offset) + frac) / 256
                return max(PQ.eotf(pq), minNits)
            }
            cumulative += count
        }
        return PQ.eotf(Double(histogram.count) / 256)
    }

    /// 256 kutudan 64 kutulu, toplam piksele normalize birikimli dağılım.
    public static func coarseCDF(_ histogram: [UInt32], total: Double) -> [Double] {
        var cdf = [Double](repeating: 0, count: 64)
        var cumulative = 0.0
        for i in 0..<64 {
            for j in 0..<4 where i * 4 + j < histogram.count {
                cumulative += Double(histogram[i * 4 + j])
            }
            cdf[i] = cumulative / total
        }
        return cdf
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    // MARK: Özel

    private mutating func accumulateAnchor(log: Double, weight: Double) {
        guard weight > 0 else { return }
        let index = Int(((log - Self.anchorBinMinLog) / Self.anchorBinWidth).rounded(.down))
        anchorWeights[min(max(index, 0), Self.anchorBinCount - 1)] += weight
        anchorTotalWeight += weight
        guard anchorTotalWeight >= Self.anchorWarmup else { return }

        var cumulative = 0.0
        var medianLog = anchorLog
        for (i, w) in anchorWeights.enumerated() {
            cumulative += w
            if cumulative >= anchorTotalWeight / 2 {
                medianLog = Self.anchorBinMinLog + (Double(i) + 0.5) * Self.anchorBinWidth
                break
            }
        }
        let maxStep = config.anchorRateStopsPerMinute * weight / 60
        anchorLog += max(min(medianLog - anchorLog, maxStep), -maxStep)
    }

    private mutating func finish() -> Double {
        let deviation = max(min(whiteLog - anchorLog, config.deviationStops), -config.deviationStops)
        let reference = min(max(pow(2, anchorLog + deviation), config.lMin), config.lMax)
        state.smoothedWhite = pow(2, whiteLog)
        state.anchor = pow(2, anchorLog)
        state.referenceWhite = reference
        return reference
    }
}

/// Dolby Vision L1'in kullanılabilirliği (02-cozum §3.5.1): dönüştürülmüş bazı RPU'larda L1 sabit ya da
/// varsayılandır. İlk 2 dakikada hiç değişmiyorsa ya da `max_pq` 4095 ise geçersizdir; histograma dönülür.
public struct DolbyVisionL1Validity: Sendable {
    public private(set) var isValid = true
    private var first: (UInt16, UInt16)?
    private var firstTime: Double?
    private var changed = false

    public init() {}

    @discardableResult
    public mutating func observe(averagePQ: UInt16, maxPQ: UInt16, time: Double) -> Bool {
        guard isValid else { return false }
        if maxPQ >= 4095 {
            isValid = false
            return false
        }
        let value = (averagePQ, maxPQ)
        if let first {
            if !changed, first != value { changed = true }
        } else {
            first = value
            firstTime = time
        }
        if !changed, let t0 = firstTime, time - t0 >= 120 { isValid = false }
        return isValid
    }
}
