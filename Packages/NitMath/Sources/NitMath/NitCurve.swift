import Foundation

/// Nit eğrisi (02-cozum §3.5). `x` beyaz-göreli doğrusal değer (beyaz = 1).
/// Çıkış `H`'nin kesridir: `y = H_eff · f(x)`, `f < 1`, `f(1) = w`.
public struct NitCurve: Equatable, Sendable {
    /// Beyaz hedefi (H'nin kesri).
    public var w: Double
    /// Dirsek başlangıcı (H'nin kesri). `w > κ` olmalı.
    public var kappa: Double

    public static let maximum = NitCurve(w: 0.95, kappa: 0.80)
    public static let balanced = NitCurve(w: 0.75, kappa: 0.50)

    /// Değerler `0 < κ < w < 1` olacak şekilde kıstırılır; kaydırıcılar hiçbir kombinasyonda eğriyi bozamaz.
    public init(w: Double, kappa: Double) {
        let w = min(max(w, 0.10), 0.995)
        self.w = w
        self.kappa = min(max(kappa, 0.05), w - 0.01)
    }

    /// Omuz yüksekliği (stop).
    public var d: Double { log2(1 / kappa) }
    /// Dirsek girişi, log2(x) cinsinden.
    public var uk: Double { d * log(log2(1 / w) / d) }
    /// Dirsek girişi, doğrusal.
    public var xk: Double { pow(2, uk) }
    /// Doğrusal bölgenin kazancı (H biriminde).
    public var gain: Double { kappa / xk }

    public func callAsFunction(_ x: Double) -> Double {
        guard x > 0 else { return 0 }
        if x <= xk { return gain * x }
        return pow(2, -d * exp(-(log2(x) - uk) / d))
    }

    /// Shader'a giden parametreler: (D, u_k, x_k, g).
    public var shaderParams: SIMD4<Double> { SIMD4(d, uk, xk, gain) }
}

/// İçeriğe göre hangi eğrinin kullanılacağı.
public enum CurveMode: Int, Sendable, CaseIterable {
    case maximum = 0
    case balanced = 1
}

public enum NitTone {
    /// HDR referans beyazı (BT.2408). S0'da sabit; sahne bazlı tespit S0b'de (§3.5.1).
    public static let defaultReferenceWhiteNits = 203.0

    /// Tek piksel için Nit çıkışı (H biriminde değil, EDR değeri olarak; 1 = SDR beyazı).
    /// - `rgb`: HDR'da beyaz-göreli doğrusal (nit / L_ref), SDR'da beyaz-göreli doğrusal.
    public static func output(rgb: SIMD3<Double>, isHDR: Bool, curve: NitCurve, headroom: Double) -> SIMD3<Double> {
        let c = SIMD3(max(rgb.x, 0), max(rgb.y, 0), max(rgb.z, 0))
        if !isHDR {
            return SIMD3(min(c.x, 1), min(c.y, 1), min(c.z, 1)) * headroom
        }
        let m = max(c.x, max(c.y, c.z))
        guard m > 0 else { return .zero }
        let y = headroom * curve(m)
        return c * (y / m)
    }
}
