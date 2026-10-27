import Foundation

/// Yerinde, radix-2 karmaşık FFT (Float). Boyut 2'nin kuvveti olmalıdır. Bellek ayırmaz (tablolar init'te).
public final class FFT {
    public let size: Int
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let bitReverse: [Int]

    public init(size: Int) {
        precondition(size >= 2 && size & (size - 1) == 0, "FFT boyutu 2'nin kuvveti olmalı")
        self.size = size
        cosTable = (0..<size / 2).map { Float(cos(2 * Double.pi * Double($0) / Double(size))) }
        sinTable = (0..<size / 2).map { Float(sin(2 * Double.pi * Double($0) / Double(size))) }
        bitReverse = (0..<size).map { i in
            var r = 0
            var x = i
            for _ in 0..<Int(log2(Double(size))) {
                r = (r << 1) | (x & 1)
                x >>= 1
            }
            return r
        }
    }

    /// İleri (`inverse = false`, e^{-jωt}) ya da ters dönüşüm. Ters dönüşüm 1/N ile ölçeklenir.
    public func transform(real: inout [Float], imag: inout [Float], inverse: Bool = false) {
        precondition(real.count == size && imag.count == size)
        for i in 0..<size {
            let j = bitReverse[i]
            if j > i {
                real.swapAt(i, j)
                imag.swapAt(i, j)
            }
        }
        let sign: Float = inverse ? 1 : -1
        var length = 2
        while length <= size {
            let half = length / 2
            let step = size / length
            var start = 0
            while start < size {
                for k in 0..<half {
                    let wr = cosTable[k * step]
                    let wi = sign * sinTable[k * step]
                    let a = start + k
                    let b = a + half
                    let tr = wr * real[b] - wi * imag[b]
                    let ti = wr * imag[b] + wi * real[b]
                    real[b] = real[a] - tr
                    imag[b] = imag[a] - ti
                    real[a] += tr
                    imag[a] += ti
                }
                start += length
            }
            length <<= 1
        }
        if inverse {
            let scale = 1 / Float(size)
            for i in 0..<size {
                real[i] *= scale
                imag[i] *= scale
            }
        }
    }
}
