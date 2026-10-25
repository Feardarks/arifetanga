import Foundation

/// Sinyal (0–1) ile doğrusal ışık arasındaki dönüşümler.
/// CPU referansıdır; Metal shader'ı aynı formülleri kullanır (02-cozum §3.4).
public enum TransferFunction: Int, Sendable, CaseIterable {
    /// SDR: BT.1886 (saf güç eğrisi, siyah seviyesi 0 kabulüyle). Çıkış beyaz-göreli (beyaz = 1).
    case sdrGamma = 0
    /// SMPTE ST 2084 (PQ). Çıkış mutlak nit.
    case pq = 1
    /// ARIB STD-B67 / BT.2100 HLG, 1000 nit nominal tepe. Çıkış mutlak nit.
    case hlg = 2

    public var isHDR: Bool { self != .sdrGamma }
}

public enum PQ {
    public static let m1 = 2610.0 / 16384.0
    public static let m2 = 2523.0 / 4096.0 * 128.0
    public static let c1 = 3424.0 / 4096.0
    public static let c2 = 2413.0 / 4096.0 * 32.0
    public static let c3 = 2392.0 / 4096.0 * 32.0

    /// PQ sinyali (0–1) → mutlak nit (0–10000).
    public static func eotf(_ e: Double) -> Double {
        let ep = pow(max(e, 0), 1.0 / m2)
        let num = max(ep - c1, 0)
        let den = c2 - c3 * ep
        return 10000.0 * pow(num / den, 1.0 / m1)
    }

    /// Mutlak nit → PQ sinyali (0–1).
    public static func inverseEOTF(_ nits: Double) -> Double {
        let y = pow(max(nits, 0) / 10000.0, m1)
        return pow((c1 + c2 * y) / (1 + c3 * y), m2)
    }
}

public enum HLG {
    public static let a = 0.17883277
    public static let b = 1 - 4 * a
    public static let c = 0.5 - a * log(4 * a)
    /// BT.2100'ün 1000 nit nominal ekran tepesi için sistem gaması.
    public static let systemGamma = 1.2
    public static let nominalPeak = 1000.0

    /// HLG sinyali (0–1) → sahne doğrusal (0–1).
    public static func inverseOETF(_ e: Double) -> Double {
        let e = max(e, 0)
        if e <= 0.5 { return e * e / 3.0 }
        return (exp((e - c) / a) + b) / 12.0
    }

    /// Sahne doğrusal RGB → ekran nit (OOTF). `luma` BT.2020 katsayılarıyla hesaplanır.
    public static func ootf(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let ys = 0.2627 * rgb.x + 0.6780 * rgb.y + 0.0593 * rgb.z
        let gain = nominalPeak * pow(max(ys, 1e-12), systemGamma - 1)
        return rgb * gain
    }
}

public enum SDRGamma {
    /// SDR sinyali → beyaz-göreli doğrusal ışık (BT.1886, Lb = 0).
    public static func eotf(_ e: Double, gamma: Double) -> Double {
        pow(max(e, 0), gamma)
    }
}
