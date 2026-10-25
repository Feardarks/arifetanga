import Foundation

/// 3×3 matris; satır öncelikli saklanır (`m[satır][sütun]`).
public struct Matrix3: Equatable, Sendable {
    public var rows: [SIMD3<Double>]

    public init(rows: [SIMD3<Double>]) {
        precondition(rows.count == 3)
        self.rows = rows
    }

    public static let identity = Matrix3(rows: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)])

    public func apply(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3((rows[0] * v).sum(), (rows[1] * v).sum(), (rows[2] * v).sum())
    }

    public static func * (a: Matrix3, b: Matrix3) -> Matrix3 {
        let bt = b.transposed
        return Matrix3(rows: a.rows.map { r in SIMD3((r * bt.rows[0]).sum(), (r * bt.rows[1]).sum(), (r * bt.rows[2]).sum()) })
    }

    public var transposed: Matrix3 {
        Matrix3(rows: [
            SIMD3(rows[0].x, rows[1].x, rows[2].x),
            SIMD3(rows[0].y, rows[1].y, rows[2].y),
            SIMD3(rows[0].z, rows[1].z, rows[2].z),
        ])
    }

    public var inverse: Matrix3 {
        let a = rows[0], b = rows[1], c = rows[2]
        let r0 = SIMD3(b.y * c.z - b.z * c.y, a.z * c.y - a.y * c.z, a.y * b.z - a.z * b.y)
        let r1 = SIMD3(b.z * c.x - b.x * c.z, a.x * c.z - a.z * c.x, a.z * b.x - a.x * b.z)
        let r2 = SIMD3(b.x * c.y - b.y * c.x, a.y * c.x - a.x * c.y, a.x * b.y - a.y * b.x)
        let det = a.x * r0.x + a.y * r1.x + a.z * r2.x
        return Matrix3(rows: [r0 / det, r1 / det, r2 / det])
    }
}

/// Renk primerleri (CIE 1931 xy) ve beyaz noktası.
public struct ColorPrimaries: Equatable, Sendable {
    public var red: SIMD2<Double>
    public var green: SIMD2<Double>
    public var blue: SIMD2<Double>
    public var white: SIMD2<Double>

    public static let d65 = SIMD2(0.3127, 0.3290)
    public static let bt709 = ColorPrimaries(red: SIMD2(0.640, 0.330), green: SIMD2(0.300, 0.600), blue: SIMD2(0.150, 0.060), white: d65)
    public static let bt2020 = ColorPrimaries(red: SIMD2(0.708, 0.292), green: SIMD2(0.170, 0.797), blue: SIMD2(0.131, 0.046), white: d65)
    public static let displayP3 = ColorPrimaries(red: SIMD2(0.680, 0.320), green: SIMD2(0.265, 0.690), blue: SIMD2(0.150, 0.060), white: d65)

    /// Doğrusal RGB → XYZ (beyaz Y = 1).
    public var rgbToXYZ: Matrix3 {
        func xyz(_ p: SIMD2<Double>) -> SIMD3<Double> { SIMD3(p.x / p.y, 1, (1 - p.x - p.y) / p.y) }
        let r = xyz(red), g = xyz(green), b = xyz(blue), w = xyz(white)
        let m = Matrix3(rows: [SIMD3(r.x, g.x, b.x), SIMD3(r.y, g.y, b.y), SIMD3(r.z, g.z, b.z)])
        let s = m.inverse.apply(w)
        return Matrix3(rows: m.rows.map { $0 * s })
    }

    /// Bu primerlerdeki doğrusal RGB'yi hedef primerlere çeviren matris.
    public func conversion(to target: ColorPrimaries) -> Matrix3 {
        target.rgbToXYZ.inverse * rgbToXYZ
    }
}

/// Y'CbCr → R'G'B' (sabit olmayan parlaklık) katsayıları.
public enum YCbCrMatrix: Int, Sendable {
    case bt601 = 0, bt709 = 1, bt2020 = 2

    public var kr: Double { [0.299, 0.2126, 0.2627][rawValue] }
    public var kb: Double { [0.114, 0.0722, 0.0593][rawValue] }

    /// Girdi: (Y, Cb, Cr); Y 0–1, Cb/Cr −0,5…+0,5. Çıkış: R'G'B'.
    public var toRGB: Matrix3 {
        let kg = 1 - kr - kb
        return Matrix3(rows: [
            SIMD3(1, 0, 2 - 2 * kr),
            SIMD3(1, -(2 - 2 * kb) * kb / kg, -(2 - 2 * kr) * kr / kg),
            SIMD3(1, 2 - 2 * kb, 0),
        ])
    }
}

/// Kod değerlerini normalize Y'CbCr'ye açmak için ofset/ölçek.
/// `storageScale`: dokudan okunan unorm değerin kod değerine oranı (8-bit: 255, MSB hizalı 10-bit: 65535/64).
public struct YCbCrRange: Equatable, Sendable {
    public var yOffset: Double
    public var yScale: Double
    public var cOffset: Double
    public var cScale: Double

    public static func make(bitDepth: Int, fullRange: Bool, storageScale: Double) -> YCbCrRange {
        let k = pow(2.0, Double(bitDepth - 8))
        let maxCode = pow(2.0, Double(bitDepth)) - 1
        if fullRange {
            return YCbCrRange(yOffset: 0, yScale: storageScale / maxCode,
                              cOffset: 128 * k / storageScale, cScale: storageScale / maxCode)
        }
        return YCbCrRange(yOffset: 16 * k / storageScale, yScale: storageScale / (219 * k),
                          cOffset: 128 * k / storageScale, cScale: storageScale / (224 * k))
    }

    /// Dokudan okunan (Y, Cb, Cr) unorm → normalize (Y 0–1, C ±0,5).
    public func normalize(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3((v.x - yOffset) * yScale, (v.y - cOffset) * cScale, (v.z - cOffset) * cScale)
    }
}
