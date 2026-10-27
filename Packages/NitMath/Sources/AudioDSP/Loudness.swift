import Foundation

/// İkinci dereceden süzgeç (Direct Form II transposed, Double durum).
public struct Biquad: Sendable {
    public var b: (Double, Double, Double)
    public var a: (Double, Double)
    private var z1 = 0.0
    private var z2 = 0.0

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        b = (b0, b1, b2)
        a = (a1, a2)
    }

    public mutating func process(_ x: Double) -> Double {
        let y = b.0 * x + z1
        z1 = b.1 * x - a.0 * y + z2
        z2 = b.2 * x - a.1 * y
        return y
    }

    public mutating func reset() {
        z1 = 0
        z2 = 0
    }
}

/// ITU-R BS.1770 K-ağırlıklandırması: yüksek raf + RLB yüksek geçiren, her örnekleme hızı için
/// (libebur128'in katsayı formülleri; 48 kHz'te standarttaki katsayıları verir).
public enum KWeighting {
    public static func filters(sampleRate fs: Double) -> (Biquad, Biquad) {
        var f0 = 1681.974450955533
        let g = 3.999843853973347
        var q = 0.7071752369554196
        var k = tan(Double.pi * f0 / fs)
        let vh = pow(10, g / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                           a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(Double.pi * f0 / fs)
        a0 = 1 + k / q + k * k
        let highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        return (shelf, highPass)
    }
}

/// Kısa süreli (kayan pencere) K-ağırlıklı loudness ölçer; 100 ms bloklar, varsayılan 3 s pencere (EBU R128 "S").
/// Kanal ağırlıkları BS.1770: ön ve merkez 1, surround 1,41; LFE 0.
public struct LoudnessMeter: Sendable {
    public let sampleRate: Double
    public let weights: [Double]
    private var filters: [(Biquad, Biquad)]
    private var blockEnergy = 0.0
    private var blockFill = 0
    private let blockLength: Int
    private var blocks: [Double]
    private var blockIndex = 0
    private var blocksFilled = 0

    public init(sampleRate: Double, weights: [Double], window: Double = 3.0) {
        self.sampleRate = sampleRate
        self.weights = weights
        filters = weights.map { _ in KWeighting.filters(sampleRate: sampleRate) }
        blockLength = max(Int(sampleRate * 0.1), 1)
        blocks = [Double](repeating: 0, count: max(Int((window / 0.1).rounded()), 1))
    }

    /// Karışık (interleaved) örnekleri ölçer.
    public mutating func add(interleaved samples: UnsafeBufferPointer<Float>, frames: Int) {
        let channels = weights.count
        for f in 0..<frames {
            var energy = 0.0
            for c in 0..<channels where weights[c] > 0 {
                var x = Double(samples[f * channels + c])
                x = filters[c].0.process(x)
                x = filters[c].1.process(x)
                energy += weights[c] * x * x
            }
            blockEnergy += energy
            blockFill += 1
            if blockFill == blockLength {
                blocks[blockIndex] = blockEnergy / Double(blockLength)
                blockIndex = (blockIndex + 1) % blocks.count
                blocksFilled = min(blocksFilled + 1, blocks.count)
                blockEnergy = 0
                blockFill = 0
            }
        }
    }

    /// LUFS; henüz blok yoksa ya da sessizse `nil`.
    public var loudness: Double? {
        guard blocksFilled > 0 else { return nil }
        let mean = blocks.prefix(blocksFilled).reduce(0, +) / Double(blocksFilled)
        guard mean > 1e-12 else { return nil }
        return -0.691 + 10 * log10(mean)
    }

    public mutating func reset() {
        for i in filters.indices {
            filters[i].0.reset()
            filters[i].1.reset()
        }
        blockEnergy = 0
        blockFill = 0
        blocks = [Double](repeating: 0, count: blocks.count)
        blockIndex = 0
        blocksFilled = 0
    }
}
