import Foundation

/// ITU-R BS.1770-4 Ek 2 gerçek tepe (true-peak) ölçümü: 4× aşırı örnekleme, faz başına 12 katsayılı çok fazlı FIR.
public enum TruePeak {
    /// `phases[p][j]`: 4× ara değerin p. fazı için x(n − j) katsayısı.
    public static let phases: [[Float]] = [
        [0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000, -0.0594482421875, 0.1373291015625,
         0.9721679687500, -0.1022949218750, 0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500],
        [-0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250, -0.1665039062500, 0.4650878906250,
         0.7797851562500, -0.2003173828125, 0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375],
        [-0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000, -0.2003173828125, 0.7797851562500,
         0.4650878906250, -0.1665039062500, 0.0891113281250, -0.0517578125000, 0.0292968750000, -0.0291748046875],
        [-0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750, -0.1022949218750, 0.9721679687500,
         0.1373291015625, -0.0594482421875, 0.0332031250000, -0.0196533203125, 0.0109863281250, 0.0017089843750],
    ]

    /// Dedektörün gecikmesi: n. örnekte verilen tepe, [n − 6, n − 5] aralığına aittir.
    public static let delay = 6

    public static func dB(_ linear: Float) -> Double {
        20 * log10(max(Double(linear), 1e-12))
    }
}

/// Tek kanallı, akış hâlinde gerçek tepe dedektörü.
public struct TruePeakDetector: Sendable {
    // Son 12 örnek iki kez yazılır; böylece kronolojik pencere her zaman bitişiktir: buffer[pos ..< pos + 12].
    private var buffer = [Float](repeating: 0, count: 24)
    private var pos = 0

    public init() {}

    /// Yeni örneği ekler; `TruePeak.delay` örnek gerideki aralığın gerçek tepe değerini (mutlak) döndürür.
    /// - Parameter threshold: Verilirse ve pencere bu eşiği aşamayacak kadar küçükse ara değerler hesaplanmaz
    ///   (faz başına |h| toplamı ≤ 2,03); dönen değer o zaman yalnızca eşiğin altında olduğu garanti olan örnek tepesidir.
    public mutating func push(_ x: Float, threshold: Float? = nil) -> Float {
        buffer[pos] = x
        buffer[pos + 12] = x
        pos = pos == 11 ? 0 : pos + 1
        // x(n − j) = buffer[pos + 11 − j]
        var peak = max(abs(buffer[pos + 5]), abs(buffer[pos + 6]))
        if let threshold {
            var window: Float = 0
            for i in pos..<(pos + 12) { window = max(window, abs(buffer[i])) }
            if window * 2.03 <= threshold { return peak }
        }
        for phase in TruePeak.phases {
            var y: Float = 0
            for j in 0..<12 { y += phase[j] * buffer[pos + 11 - j] }
            peak = max(peak, abs(y))
        }
        return peak
    }

    public mutating func reset() {
        for i in buffer.indices { buffer[i] = 0 }
        pos = 0
    }
}

/// Çok kanallı gerçek tepe ölçer (akış boyunca en büyük değer).
public struct TruePeakMeter: Sendable {
    private var detectors: [TruePeakDetector]
    public private(set) var maximum: Float = 0

    public init(channels: Int) {
        detectors = [TruePeakDetector](repeating: TruePeakDetector(), count: channels)
    }

    public mutating func add(interleaved samples: UnsafeBufferPointer<Float>, frames: Int) {
        let channels = detectors.count
        for f in 0..<frames {
            for c in 0..<channels {
                maximum = max(maximum, detectors[c].push(samples[f * channels + c]))
            }
        }
    }

    /// Ölçülen en büyük gerçek tepe (dBTP); sondaki gecikme kadar örnek için 6 sıfır daha verilmelidir.
    public var dBTP: Double { TruePeak.dB(maximum) }
}
