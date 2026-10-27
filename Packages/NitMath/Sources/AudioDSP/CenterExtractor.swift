import Foundation

/// F1: DSP ile merkez (diyalog) çıkarma (02-cozum §5.4, Avendano–Jot 2004).
/// Kayan STFT (2048 / 512, karekök-Hann analiz ve sentez). Her frekans kutusunda L ile R'nin benzerliği
/// `ψ = 2·|L·R*| / (|L|² + |R|²)`; maske `m = ψ^p · w(f)` (konuşma bandı ağırlığı), zamanda yumuşatılır;
/// çıktı `ISTFT(m · (L+R)/2)`. Çıktı girdiyle aynı sayıda örnektir ve `latency` örnek gecikmelidir.
public final class CenterExtractor {
    public let size: Int
    public let hop: Int
    /// `output[j]`, `input[j − latency]`'nin merkez bileşenidir.
    public let latency: Int

    private let fft: FFT
    private let window: [Float]
    private let bandWeight: [Float]
    private let exponent: Float
    private let identity: Bool
    private var frameL: [Float]
    private var frameR: [Float]
    private var pendingL: [Float] = []
    private var pendingR: [Float] = []
    private var accumulator: [Float]
    private var outputFIFO: [Float]
    private var smoothedMask: [Float]
    private var re: [Float]
    private var im: [Float]
    private var vRe: [Float]
    private var vIm: [Float]

    /// - Parameter identity: Test için: maske her yerde 1 (mükemmel yeniden kurma).
    public init(sampleRate: Double, size: Int = 2048, hop: Int = 512, exponent: Float = 2, identity: Bool = false) {
        self.size = size
        self.hop = hop
        self.exponent = exponent
        self.identity = identity
        latency = size
        fft = FFT(size: size)
        window = (0..<size).map { Float(sqrt(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size)))) }
        let binHz = sampleRate / Double(size)
        bandWeight = (0...size / 2).map { k in
            let f = Double(k) * binHz
            switch f {
            case ..<80: return 0
            case 80..<150: return Float((f - 80) / 70)
            case 150..<6000: return 1
            case 6000..<10000: return Float(1 - 0.7 * (f - 6000) / 4000)
            default: return 0.3
            }
        }
        frameL = [Float](repeating: 0, count: size)
        frameR = [Float](repeating: 0, count: size)
        accumulator = [Float](repeating: 0, count: size)
        outputFIFO = [Float](repeating: 0, count: hop)
        smoothedMask = [Float](repeating: 0, count: size / 2 + 1)
        re = [Float](repeating: 0, count: size)
        im = [Float](repeating: 0, count: size)
        vRe = [Float](repeating: 0, count: size)
        vIm = [Float](repeating: 0, count: size)
    }

    public func reset() {
        for i in 0..<size {
            frameL[i] = 0
            frameR[i] = 0
            accumulator[i] = 0
        }
        pendingL.removeAll(keepingCapacity: true)
        pendingR.removeAll(keepingCapacity: true)
        outputFIFO = [Float](repeating: 0, count: hop)
        for i in smoothedMask.indices { smoothedMask[i] = 0 }
    }

    /// Stereo girdiden aynı sayıda örnek merkez sesi (gecikmeli) üretir.
    public func process(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) -> [Float] {
        let count = min(left.count, right.count)
        pendingL.append(contentsOf: left.prefix(count))
        pendingR.append(contentsOf: right.prefix(count))
        var consumed = 0
        while pendingL.count - consumed >= hop {
            processHop(from: consumed)
            consumed += hop
        }
        if consumed > 0 {
            pendingL.removeFirst(consumed)
            pendingR.removeFirst(consumed)
        }
        let out = Array(outputFIFO.prefix(count))
        outputFIFO.removeFirst(min(count, outputFIFO.count))
        return out
    }

    private func processHop(from offset: Int) {
        // Çerçeveyi bir adım kaydır ve yeni örnekleri ekle.
        frameL.removeFirst(hop)
        frameR.removeFirst(hop)
        frameL.append(contentsOf: pendingL[offset..<(offset + hop)])
        frameR.append(contentsOf: pendingR[offset..<(offset + hop)])

        // İki gerçek sinyal tek karmaşık FFT'de: z = l + j·r.
        for i in 0..<size {
            re[i] = frameL[i] * window[i]
            im[i] = frameR[i] * window[i]
        }
        fft.transform(real: &re, imag: &im)

        // 0…N/2 ve simetrik eşleri her adımda yeniden yazılır.
        let half = size / 2
        for k in 0...half {
            let nk = (size - k) % size
            // L = (Z[k] + conj(Z[N−k])) / 2, R = (Z[k] − conj(Z[N−k])) / (2j)
            let lr = 0.5 * (re[k] + re[nk])
            let li = 0.5 * (im[k] - im[nk])
            let rr = 0.5 * (im[k] + im[nk])
            let ri = 0.5 * (re[nk] - re[k])
            var mask: Float = 1
            if !identity {
                let crossRe = lr * rr + li * ri
                let crossIm = li * rr - lr * ri
                let cross = (crossRe * crossRe + crossIm * crossIm).squareRoot()
                let power = lr * lr + li * li + rr * rr + ri * ri
                let psi = power > 1e-12 ? min(2 * cross / power, 1) : 0
                let target = pow(psi, exponent) * bandWeight[k]
                smoothedMask[k] = 0.6 * smoothedMask[k] + 0.4 * target
                mask = smoothedMask[k]
            }
            vRe[k] = mask * 0.5 * (lr + rr)
            vIm[k] = mask * 0.5 * (li + ri)
            if k != 0, k != half {
                vRe[size - k] = vRe[k]
                vIm[size - k] = -vIm[k]
            }
        }
        fft.transform(real: &vRe, imag: &vIm, inverse: true)

        // Örtüşen toplama: karekök-Hann × karekök-Hann = Hann; 512 adımda toplam 2.
        for i in 0..<size { accumulator[i] += vRe[i] * window[i] * 0.5 }
        outputFIFO.append(contentsOf: accumulator.prefix(hop))
        accumulator.removeFirst(hop)
        accumulator.append(contentsOf: [Float](repeating: 0, count: hop))
    }
}
