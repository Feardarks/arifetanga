import XCTest
@testable import NitMath

/// DV P5 kod çözümü. Beklenen değerler libplacebo yolunu satır satır izleyen bağımsız bir Python
/// uygulamasından (scratchpad dovi_ref.py) alındı; matrisler dovi_tool'un P5 varsayılanlarıdır.
final class DolbyVisionReshapeTests: XCTestCase {
    private typealias R = DolbyVisionReshape
    private let denom = 23

    private func F(_ v: Double) -> R.Fixed {
        let i = v.rounded(.down)
        return R.Fixed(int: Int64(i), frac: UInt64(((v - i) * 8_388_608).rounded()))
    }

    private let p5YCC: [Int16] = [8192, 799, 1681, 8192, -933, 1091, 8192, 267, -5545]
    private let p5Offset: [UInt32] = [0, 134_217_728, 134_217_728]
    private let p5LMS: [Int16] = [17081, -349, -349, -349, 17081, -349, -349, -349, 17081]

    /// Parlaklık: 3 parçalı 2. derece polinom. Krominans: tek parçalı MMR (Cb 3. derece, Cr 1. derece).
    private func model() throws -> R {
        let luma = R.RawCurve(pivotDeltas: [64, 300, 300, 276], pieces: [
            .polynomial([F(-0.0625), F(1.05), F(0.02)]),
            .polynomial([F(-0.07), F(1.08), F(-0.01)]),
            .polynomial([F(-0.09), F(1.12), F(-0.03)]),
        ])
        let cb = R.RawCurve(pivotDeltas: [0, 1023], pieces: [
            .mmr(constant: F(0.03), orders: [
                [F(0.01), F(0.9), F(0.02), F(-0.05), F(0.01), F(0.03), F(-0.02)],
                [F(0.005), F(-0.01), F(0.002), F(0.01), F(-0.004), F(0.001), F(0.003)],
                [F(-0.001), F(0.002), F(0.0), F(-0.002), F(0.001), F(0.0), F(0.0005)],
            ]),
        ])
        let cr = R.RawCurve(pivotDeltas: [0, 1023], pieces: [
            .mmr(constant: F(0.02), orders: [[F(-0.02), F(0.01), F(0.95), F(0.03), F(-0.04), F(0.02), F(0.01)]]),
        ])
        return try XCTUnwrap(R.make(blBitDepth: 10, log2Denom: denom, curves: [luma, cb, cr],
                                    yccToRGB: p5YCC, yccToRGBOffset: p5Offset, rgbToLMS: p5LMS))
    }

    private func code(_ y: Double, _ cb: Double, _ cr: Double) -> SIMD3<Double> { SIMD3(y, cb, cr) / 1024 }

    func testFixedPointAndPivotAccumulation() throws {
        XCTAssertEqual(F(-0.0625), R.Fixed(int: -1, frac: 7_864_320))
        let m = try model()
        // Farklar 64, 300, 300, 276 → mutlak 64, 364, 664, 940 (/1024).
        XCTAssertEqual(m.components[0].pivots, [64, 364, 664, 940].map { $0 / 1024.0 })
        guard case .polynomial(let a) = m.components[0].pieces[1] else { return XCTFail("polinom bekleniyordu") }
        XCTAssertEqual(a.x, -0.07, accuracy: 1e-6)
        XCTAssertEqual(a.y, 1.08, accuracy: 1e-6)
        XCTAssertEqual(m.nonlinearOffset, SIMD3(0, 0.5, 0.5))
    }

    func testReshapeMatchesReference() throws {
        let m = try model()
        let cases: [(SIMD3<Double>, SIMD3<Double>)] = [
            (code(100, 512, 512), SIMD3(0.040229793, 0.494410333, 0.502802732)),
            (code(480, 512, 512), SIMD3(0.434052704, 0.490135547, 0.494453130)),
            (code(700, 400, 620), SIMD3(0.661605971, 0.396697716, 0.583231787)),
            (code(900, 600, 450), SIMD3(0.871200707, 0.558837881, 0.433174680)),
            (code(30, 1000, 10), SIMD3(0.003203122, 0.899337293, 0.039796276)),
            (code(1010, 512, 512), SIMD3(0.912844996, 0.486814039, 0.484345718)),
        ]
        for (input, expected) in cases {
            let out = m.reshape(input)
            for c in 0..<3 { XCTAssertEqual(out[c], expected[c], accuracy: 1e-7, "\(input * 1024) bileşen \(c)") }
        }
    }

    func testDecodeMatchesReference() throws {
        let m = try model()
        let cases: [(SIMD3<Double>, SIMD3<Double>)] = [
            (code(480, 512, 512), SIMD3(43.186364, 47.640843, 48.671458)),
            (code(700, 400, 620), SIMD3(274.730803, 636.624023, 227.146182)),
            (code(900, 600, 450), SIMD3(3379.103362, 2130.943037, 4783.865440)),
            (code(30, 1000, 10), SIMD3(1.227006, -2.249193, 15.199524)),
        ]
        for (input, expected) in cases {
            let out = m.decode(input)
            for c in 0..<3 {
                XCTAssertEqual(out[c], expected[c], accuracy: max(abs(expected[c]) * 1e-5, 1e-4), "\(input * 1024) kanal \(c)")
            }
        }
    }

    /// P5 matrisleri: tarafsız IPT (P = T = 0,5) griye, I = PQ(100 nit) ≈ 100 nite gider.
    func testNeutralIPTIsGray() throws {
        let m = try model()
        let i = PQ.inverseEOTF(100)
        let lmsSignal = m.nonlinear.apply(SIMD3(i, 0.5, 0.5) - m.nonlinearOffset)
        let lms = SIMD3(PQ.eotf(lmsSignal.x), PQ.eotf(lmsSignal.y), PQ.eotf(lmsSignal.z))
        let rgb = m.linear.apply(lms)
        for c in 0..<3 { XCTAssertEqual(rgb[c], 100, accuracy: 0.05) }
    }

    func testPieceSelectionAndClamping() throws {
        let m = try model()
        // Alt pivotun (64) altı ilk parçanın girişine kırpılır: 0 ve 64 aynı sonucu verir.
        XCTAssertEqual(m.reshape(code(0, 512, 512)).x, m.reshape(code(64, 512, 512)).x, accuracy: 1e-12)
        // 364 ikinci parçanın başı: a0 + a1·s + a2·s² ile ikinci parça katsayıları.
        let s = 364.0 / 1024
        XCTAssertEqual(m.reshape(code(364, 512, 512)).x, -0.07 + 1.08 * s - 0.01 * s * s, accuracy: 1e-6)
    }

    func testRejectsInconsistentCurves() {
        let bad = R.RawCurve(pivotDeltas: [0, 512, 511], pieces: [.polynomial([F(0), F(1)])])
        let ok = R.RawCurve(pivotDeltas: [0, 1023], pieces: [.polynomial([F(0), F(1)])])
        XCTAssertNil(R.make(blBitDepth: 10, log2Denom: denom, curves: [bad, ok, ok],
                            yccToRGB: p5YCC, yccToRGBOffset: p5Offset, rgbToLMS: p5LMS))
        let badMMR = R.RawCurve(pivotDeltas: [0, 1023], pieces: [.mmr(constant: F(0), orders: [[F(1)]])])
        XCTAssertNil(R.make(blBitDepth: 10, log2Denom: denom, curves: [ok, badMMR, ok],
                            yccToRGB: p5YCC, yccToRGBOffset: p5Offset, rgbToLMS: p5LMS))
    }

    func testPackedLayout() throws {
        let m = try model()
        let p = m.packed(codeScale: 65535.0 / 65536.0)
        XCTAssertEqual(p.count, R.packedCount)
        // Parlaklık: iç pivotlar 364, 664 (/1024), kalanı 1e9; parça 0 katsayıları; aralık 64…940.
        XCTAssertEqual(p[0].x, Float(364.0 / 1024), accuracy: 1e-7)
        XCTAssertEqual(p[0].y, Float(664.0 / 1024), accuracy: 1e-7)
        XCTAssertEqual(p[0].z, 1e9)
        XCTAssertEqual(p[1].w, 1e9)
        XCTAssertEqual(p[2].y, 1.05, accuracy: 1e-6)
        XCTAssertEqual(p[2].w, 0, "polinom işareti")
        XCTAssertEqual(p[10].x, Float(64.0 / 1024), accuracy: 1e-7)
        XCTAssertEqual(p[10].y, Float(940.0 / 1024), accuracy: 1e-7)
        // Cb: tek parça MMR, derece 3, yuva 0; Cr: derece 1.
        XCTAssertEqual(p[11 + 2].x, 0.03, accuracy: 1e-6)
        XCTAssertEqual(p[11 + 2].y, 0, "MMR yuva indeksi")
        XCTAssertEqual(p[11 + 2].w, 3, "MMR derecesi")
        XCTAssertEqual(p[22 + 2].w, 1)
        // Cb MMR yuvaları: 40 + 48 · 1; 1. derece (x, y, z) ve (xy, xz, yz, xyz), sonra 2. derece.
        XCTAssertEqual(p[88].y, 0.9, accuracy: 1e-6)
        XCTAssertEqual(p[89].x, -0.05, accuracy: 1e-6)
        XCTAssertEqual(p[90].x, 0.005, accuracy: 1e-6)
        XCTAssertEqual(p[93].w, 0.0005, accuracy: 1e-6)
        // Cr MMR: 40 + 48 · 2.
        XCTAssertEqual(p[136].z, 0.95, accuracy: 1e-6)
        // IPT → L'M'S': .w = −satır · ofset (P ve T 0,5 merkezli).
        XCTAssertEqual(p[34].w, Float(-(-933.0 + 1091.0) / 8192 * 0.5), accuracy: 1e-7)
        XCTAssertEqual(p[39].x, Float(65535.0 / 65536.0))
    }
}
