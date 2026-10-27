import Foundation

/// İki sinyal arasındaki gecikme: FFT ile çapraz korelasyon (AS-12: AUSoundIsolation'ın bildirdiği gecikme
/// gerçekte doğru mu?). `signal`, `reference`'a göre `lag` örnek geride kabul edilir (0 … maxLag).
public enum LagEstimator {
    /// - Returns: En yüksek korelasyonun gecikmesi ve normalleştirilmiş değeri (−1…1); sinyal boşsa `nil`.
    public static func estimate(reference: [Float], signal: [Float], maxLag: Int) -> (lag: Int, correlation: Float)? {
        let n = min(reference.count, signal.count)
        guard n > 0, maxLag >= 0 else { return nil }
        var size = 1
        while size < n + maxLag { size <<= 1 }
        let fft = FFT(size: size)
        var xr = [Float](repeating: 0, count: size)
        var xi = [Float](repeating: 0, count: size)
        var yr = [Float](repeating: 0, count: size)
        var yi = [Float](repeating: 0, count: size)
        for i in 0..<n {
            xr[i] = reference[i]
            yr[i] = signal[i]
        }
        let energyX = xr.reduce(0) { $0 + Double($1) * Double($1) }
        let energyY = yr.reduce(0) { $0 + Double($1) * Double($1) }
        guard energyX > 0, energyY > 0 else { return nil }
        fft.transform(real: &xr, imag: &xi)
        fft.transform(real: &yr, imag: &yi)
        // R = conj(X) · Y → r[l] = Σ x[t] · y[t + l]
        var rr = [Float](repeating: 0, count: size)
        var ri = [Float](repeating: 0, count: size)
        for k in 0..<size {
            rr[k] = xr[k] * yr[k] + xi[k] * yi[k]
            ri[k] = xr[k] * yi[k] - xi[k] * yr[k]
        }
        fft.transform(real: &rr, imag: &ri, inverse: true)
        var best = 0
        for l in 0...min(maxLag, size - 1) where rr[l] > rr[best] { best = l }
        let norm = Float((energyX * energyY).squareRoot())
        return (best, rr[best] / norm)
    }
}
