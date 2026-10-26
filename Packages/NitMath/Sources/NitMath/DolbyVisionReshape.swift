import Foundation

/// Dolby Vision profil 5 (IPTPQc2) kod çözümü (S2.4, AS-30, 02-cozum §3.7).
///
/// Akış, libplacebo'nun `pl_shader_dovi_reshape` + `pl_shader_decode_color` (DOLBYVISION) yolunun aynısıdır:
/// 1. Örnek kodu / 2^bit; her bileşen kendi pivot aralığına kırpılır (MMR üç bileşeni de okur).
/// 2. Pivotlarla seçilen parça: polinom (`a0 + a1·s + a2·s²`) ya da MMR; sonuç [0, 1].
/// 3. IPT → L'M'S': RPU `ycc_to_rgb` matrisi, girdiden ofset çıkarılarak; [0, 1].
/// 4. PQ EOTF → LMS (nit). 5. LMS → doğrusal BT.2020: sabit HPE LMS→RGB × RPU `rgb_to_lms`.
/// Pivot birikimi ve katsayı ölçeği FFmpeg `dovi_rpudec.c` ile aynıdır.
public struct DolbyVisionReshape: Equatable, Sendable {
    /// RPU sabit noktalı katsayısı: `tam + kesir / 2^log2Denom`.
    public struct Fixed: Equatable, Sendable {
        public var int: Int64
        public var frac: UInt64

        public init(int: Int64, frac: UInt64) {
            self.int = int
            self.frac = frac
        }

        func value(log2Denom: Int) -> Double {
            Double(int) + Double(frac) * pow(2.0, -Double(log2Denom))
        }
    }

    /// RPU'daki ham eğri (libdovi `DoviReshapingCurve`).
    public struct RawCurve: Equatable, Sendable {
        /// `pred_pivot_value`: ilk değer mutlak, sonrakiler bir öncekine göre fark.
        public var pivotDeltas: [UInt16]
        public var pieces: [RawPiece]

        public init(pivotDeltas: [UInt16], pieces: [RawPiece]) {
            self.pivotDeltas = pivotDeltas
            self.pieces = pieces
        }
    }

    public enum RawPiece: Equatable, Sendable {
        /// 2 ya da 3 katsayı (derece 1 ya da 2).
        case polynomial([Fixed])
        /// Derece başına 7 katsayı: x, y, z, xy, xz, yz, xyz (derece 1…3).
        case mmr(constant: Fixed, orders: [[Fixed]])
    }

    public enum Piece: Equatable, Sendable {
        case polynomial(SIMD3<Double>)
        case mmr(constant: Double, orders: [[Double]])
    }

    public struct Component: Equatable, Sendable {
        /// Mutlak pivotlar (kod / 2^bit); parça sayısı + 1.
        public var pivots: [Double]
        public var pieces: [Piece]
    }

    public var components: [Component]
    /// IPT → L'M'S'. Girdiden önce `nonlinearOffset` çıkarılır.
    public var nonlinear: Matrix3
    public var nonlinearOffset: SIMD3<Double>
    /// LMS (nit) → doğrusal BT.2020 (nit).
    public var linear: Matrix3

    /// Dolby Vision her zaman BT.2020'ye göre HPE LMS verir; ters matris sabittir (libplacebo).
    public static let hpeLMSToBT2020 = Matrix3(rows: [
        SIMD3(3.06441879, -2.16597676, 0.10155818),
        SIMD3(-0.65612108, 1.78554118, -0.12943749),
        SIMD3(0.01736321, -0.04725154, 1.03004253),
    ])

    /// Ham RPU değerlerinden model. Desteklenmeyen ya da tutarsız veride `nil`.
    /// - Parameters:
    ///   - yccToRGB: 9 katsayı, payda 2^13. `yccToRGBOffset`: 3 değer, payda 2^28. `rgbToLMS`: 9 katsayı, payda 2^14.
    public static func make(blBitDepth: Int, log2Denom: Int, curves: [RawCurve],
                            yccToRGB: [Int16], yccToRGBOffset: [UInt32], rgbToLMS: [Int16]) -> DolbyVisionReshape? {
        guard (8...16).contains(blBitDepth), (0...63).contains(log2Denom), curves.count == 3,
              yccToRGB.count == 9, yccToRGBOffset.count == 3, rgbToLMS.count == 9 else { return nil }
        let codeScale = pow(2.0, -Double(blBitDepth))
        var components: [Component] = []
        for curve in curves {
            guard curve.pivotDeltas.count == curve.pieces.count + 1, (2...9).contains(curve.pivotDeltas.count) else { return nil }
            var accumulated = 0
            let pivots = curve.pivotDeltas.map { delta -> Double in
                accumulated = min(accumulated + Int(delta), 65535)
                return Double(accumulated) * codeScale
            }
            var pieces: [Piece] = []
            for raw in curve.pieces {
                switch raw {
                case .polynomial(let coefficients):
                    guard (1...3).contains(coefficients.count) else { return nil }
                    var a = SIMD3<Double>(repeating: 0)
                    for (k, c) in coefficients.enumerated() { a[k] = c.value(log2Denom: log2Denom) }
                    pieces.append(.polynomial(a))
                case .mmr(let constant, let orders):
                    guard (1...3).contains(orders.count), orders.allSatisfy({ $0.count == 7 }) else { return nil }
                    pieces.append(.mmr(constant: constant.value(log2Denom: log2Denom),
                                       orders: orders.map { $0.map { $0.value(log2Denom: log2Denom) } }))
                }
            }
            components.append(Component(pivots: pivots, pieces: pieces))
        }
        func matrix(_ v: [Int16], _ denominator: Double) -> Matrix3 {
            Matrix3(rows: (0..<3).map { r in SIMD3(Double(v[r * 3]), Double(v[r * 3 + 1]), Double(v[r * 3 + 2])) / denominator })
        }
        let offset = SIMD3(Double(yccToRGBOffset[0]), Double(yccToRGBOffset[1]), Double(yccToRGBOffset[2])) / 268_435_456
        return DolbyVisionReshape(components: components, nonlinear: matrix(yccToRGB, 8192), nonlinearOffset: offset,
                                  linear: hpeLMSToBT2020 * matrix(rgbToLMS, 16384))
    }

    /// Şekillendirme: kod / 2^bit → [0, 1] IPT sinyali.
    public func reshape(_ code: SIMD3<Double>) -> SIMD3<Double> {
        var sig = code
        for c in 0..<3 {
            sig[c] = min(max(sig[c], components[c].pivots.first ?? 0), components[c].pivots.last ?? 1)
        }
        let cross = SIMD4(sig.x * sig.y, sig.x * sig.z, sig.y * sig.z, sig.x * sig.y * sig.z)
        var out = SIMD3<Double>(repeating: 0)
        for c in 0..<3 {
            let component = components[c]
            let s = sig[c]
            let inner = component.pivots.dropFirst().dropLast()
            let index = min(inner.filter { s >= $0 }.count, component.pieces.count - 1)
            var r: Double
            switch component.pieces[index] {
            case .polynomial(let a):
                r = (a.z * s + a.y) * s + a.x
            case .mmr(let constant, let orders):
                r = constant
                for (d, w) in orders.enumerated() {
                    let p = Double(d + 1)
                    for k in 0..<3 { r += w[k] * pow(sig[k], p) }
                    for k in 0..<4 { r += w[3 + k] * pow(cross[k], p) }
                }
            }
            out[c] = min(max(r, 0), 1)
        }
        return out
    }

    /// Tam kod çözümü: kod / 2^bit → doğrusal BT.2020 (nit).
    public func decode(_ code: SIMD3<Double>) -> SIMD3<Double> {
        let ipt = reshape(code)
        let lmsSignal = nonlinear.apply(ipt - nonlinearOffset)
        let lms = SIMD3(PQ.eotf(min(max(lmsSignal.x, 0), 1)), PQ.eotf(min(max(lmsSignal.y, 0), 1)),
                        PQ.eotf(min(max(lmsSignal.z, 0), 1)))
        return linear.apply(lms)
    }

    // MARK: GPU düzeni

    /// Metal `DoviParams` (NitShaders.metal) float4 sayısı.
    public static let packedCount = 184
    static let componentStride = 11
    static let nonlinearIndex = 33
    static let linearIndex = 36
    public static let infoIndex = 39
    static let mmrIndex = 40
    static let mmrSlotsPerComponent = 48

    /// Shader'a giden düzen (hepsi float4):
    /// - Bileşen `c` (taban `11c`): [0–1] iç pivotlar (en çok 7, kalanı 1e9), [2–9] parça katsayıları
    ///   (polinom: a0, a1, a2, 0; MMR: sabit, MMR yuva indeksi, 0, derece), [10] giriş aralığı (alt, üst).
    /// - [33–35] IPT → L'M'S' satırları, `.w` = −satır · ofset. [36–38] LMS → BT.2020 satırları.
    /// - [39] (kod ölçeği, -, -, -). [40 + 48c + k] MMR: derece başına (x, y, z, 0) ve (xy, xz, yz, xyz).
    /// - Parameter codeScale: doku örneğinden `kod / 2^bit`'e çarpan (10-bit MSB hizalı r16Unorm: 65535/65536).
    public func packed(codeScale: Double) -> [SIMD4<Float>] {
        var p = [SIMD4<Float>](repeating: .zero, count: Self.packedCount)
        for (c, component) in components.enumerated() {
            let base = c * Self.componentStride
            var inner = component.pivots.dropFirst().dropLast().map { Float($0) }
            inner += [Float](repeating: 1e9, count: 8 - inner.count)
            p[base] = SIMD4(inner[0], inner[1], inner[2], inner[3])
            p[base + 1] = SIMD4(inner[4], inner[5], inner[6], inner[7])
            var slot = 0
            for (i, piece) in component.pieces.enumerated() {
                switch piece {
                case .polynomial(let a):
                    p[base + 2 + i] = SIMD4(Float(a.x), Float(a.y), Float(a.z), 0)
                case .mmr(let constant, let orders):
                    p[base + 2 + i] = SIMD4(Float(constant), Float(slot), 0, Float(orders.count))
                    for w in orders {
                        let m = Self.mmrIndex + c * Self.mmrSlotsPerComponent + slot
                        p[m] = SIMD4(Float(w[0]), Float(w[1]), Float(w[2]), 0)
                        p[m + 1] = SIMD4(Float(w[3]), Float(w[4]), Float(w[5]), Float(w[6]))
                        slot += 2
                    }
                }
            }
            p[base + 10] = SIMD4(Float(component.pivots.first ?? 0), Float(component.pivots.last ?? 1), 0, 0)
        }
        for r in 0..<3 {
            let row = nonlinear.rows[r]
            p[Self.nonlinearIndex + r] = SIMD4(Float(row.x), Float(row.y), Float(row.z), Float(-(row * nonlinearOffset).sum()))
            let l = linear.rows[r]
            p[Self.linearIndex + r] = SIMD4(Float(l.x), Float(l.y), Float(l.z), 0)
        }
        p[Self.infoIndex] = SIMD4(Float(codeScale), 0, 0, 0)
        return p
    }
}
