import Foundation

/// Rasyonel (L/M) çok fazlı FIR yeniden örnekleyici; akış hâlinde ve gecikmesi tam bilinir (02-cozum §5.4:
/// AUSoundIsolation 48 kHz'i kabul etmezse 48k → AU hızı → 48k). Prototip süzgeç Blackman pencereli sinc'tir.
///
/// Çıkış örneği `n`, girdi zamanında `n·M/L − gecikme` anına karşılık gelir; `latency` çıkış örneği cinsindendir
/// (kesirli olabilir). Süzgeç nedenseldir: her çağrı, o ana kadarki girdinin karşılığını hemen üretir.
public final class Resampler {
    public let inputRate: Int
    public let outputRate: Int
    public let up: Int
    public let down: Int
    /// Grup gecikmesi, çıkış örneği cinsinden.
    public let latency: Double

    private let tapsPerPhase: Int
    /// `phases[p][k] = h[p + k·L]`
    private let phases: [[Float]]
    private var buffer: [Float] = []
    /// `buffer[0]`'ın girdi dizinindeki yeri.
    private var bufferBase = 0
    private var inputCount = 0
    private var outputCount = 0

    /// - Parameters:
    ///   - taps: Düşük hızdaki dalga boyuna göre süzgeç uzunluğu (büyük = dik geçiş, uzun gecikme).
    ///   - cutoff: Kesim, düşük hızın Nyquist'inin kesri.
    public init(inputRate: Int, outputRate: Int, taps: Int = 48, cutoff: Double = 0.85) {
        precondition(inputRate > 0 && outputRate > 0)
        self.inputRate = inputRate
        self.outputRate = outputRate
        let g = Self.gcd(inputRate, outputRate)
        let L = outputRate / g
        let M = inputRate / g
        up = L
        down = M
        // Toplam uzunluk L'nin katı: her fazda eşit sayıda katsayı.
        let length = ((taps * max(L, M) + L - 1) / L) * L
        let K = length / L
        tapsPerPhase = K
        let fc = 0.5 * cutoff / Double(max(L, M))
        let center = Double(length - 1) / 2
        var h = (0..<length).map { j -> Double in
            let x = Double(j) - center
            let sinc = x == 0 ? 2 * fc : sin(2 * Double.pi * fc * x) / (Double.pi * x)
            let w = 0.42 - 0.5 * cos(2 * Double.pi * Double(j) / Double(length - 1))
                + 0.08 * cos(4 * Double.pi * Double(j) / Double(length - 1))
            return sinc * w
        }
        // DC kazancı: her fazın toplamı ≈ 1 (yukarı örneklemede L kazancı).
        let sum = h.reduce(0, +)
        h = h.map { $0 * Double(L) / sum }
        phases = (0..<L).map { p in (0..<K).map { k in Float(h[p + k * L]) } }
        latency = center / Double(M)
    }

    public func reset() {
        buffer.removeAll(keepingCapacity: true)
        bufferBase = 0
        inputCount = 0
        outputCount = 0
    }

    /// Girdiyi ekler, şimdiye kadar hesaplanabilen tüm çıkışları döndürür.
    public func process(_ input: UnsafeBufferPointer<Float>) -> [Float] {
        buffer.append(contentsOf: input)
        inputCount += input.count
        var out: [Float] = []
        out.reserveCapacity(input.count * up / down + 2)
        let K = tapsPerPhase
        while true {
            let position = outputCount * down
            let newest = position / up
            guard newest < inputCount else { break }
            let phase = phases[position - newest * up]
            var acc: Float = 0
            // y[n] = Σ_k x[newest − k] · h[p + k·L]; negatif dizinler sıfırdır.
            for k in 0..<K {
                let i = newest - k - bufferBase
                if i < 0 { break }
                acc += buffer[i] * phase[k]
            }
            out.append(acc)
            outputCount += 1
        }
        // Bir sonraki çıkışın ihtiyaç duymayacağı eski girdiler atılır.
        let nextNewest = (outputCount * down) / up
        let keepFrom = nextNewest - K + 1
        if keepFrom > bufferBase {
            let drop = min(keepFrom - bufferBase, buffer.count)
            buffer.removeFirst(drop)
            bufferBase += drop
        }
        return out
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (a, b)
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }
}
