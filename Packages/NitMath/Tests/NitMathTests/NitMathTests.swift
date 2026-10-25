import XCTest
@testable import NitMath

final class TransferFunctionTests: XCTestCase {
    func testPQRoundTrip() {
        for nits in [0.0, 0.01, 1, 100, 203, 1000, 4000, 10000] {
            XCTAssertEqual(PQ.eotf(PQ.inverseEOTF(nits)), nits, accuracy: max(nits * 1e-9, 1e-9))
        }
        XCTAssertEqual(PQ.eotf(1), 10000, accuracy: 1e-6)
        // 203 nit ≈ PQ 0,58 (BT.2408).
        XCTAssertEqual(PQ.inverseEOTF(203), 0.58, accuracy: 0.001)
    }

    func testHLGReferenceWhite() {
        // %75 HLG sinyali, 1000 nit ekranda ≈ 203 nit (BT.2408).
        let e = HLG.inverseOETF(0.75)
        let nits = HLG.ootf(SIMD3(repeating: e)).x
        XCTAssertEqual(nits, 203, accuracy: 2)
        XCTAssertEqual(HLG.inverseOETF(1), 1, accuracy: 1e-6)
    }
}

final class ColorMatrixTests: XCTestCase {
    func testConversionPreservesWhite() {
        for src in [ColorPrimaries.bt709, .bt2020] {
            let m = src.conversion(to: .displayP3)
            let white = m.apply(SIMD3(1, 1, 1))
            XCTAssertEqual(white.x, 1, accuracy: 1e-9)
            XCTAssertEqual(white.y, 1, accuracy: 1e-9)
            XCTAssertEqual(white.z, 1, accuracy: 1e-9)
        }
    }

    func testBT709ToP3KnownValues() {
        let m = ColorPrimaries.bt709.conversion(to: .displayP3)
        XCTAssertEqual(m.rows[0].x, 0.8225, accuracy: 1e-3)
        XCTAssertEqual(m.rows[0].y, 0.1774, accuracy: 1e-3)
        XCTAssertEqual(m.rows[1].y, 0.9669, accuracy: 1e-3)
        XCTAssertEqual(m.rows[2].z, 0.9108, accuracy: 1e-3)
    }

    func testInverse() {
        let m = ColorPrimaries.bt2020.rgbToXYZ
        let p = m * m.inverse
        for i in 0..<3 {
            for j in 0..<3 {
                XCTAssertEqual(p.rows[i][j], i == j ? 1 : 0, accuracy: 1e-12)
            }
        }
    }

    func testYCbCrGrayHasNoChroma() {
        for matrix in [YCbCrMatrix.bt601, .bt709, .bt2020] {
            let rgb = matrix.toRGB.apply(SIMD3(0.5, 0, 0))
            XCTAssertEqual(rgb.x, 0.5, accuracy: 1e-12)
            XCTAssertEqual(rgb.y, 0.5, accuracy: 1e-12)
            XCTAssertEqual(rgb.z, 0.5, accuracy: 1e-12)
        }
        // Saf kırmızının Y'si Kr olmalı: R=1 için Cr = (1 − Kr) / (2 − 2Kr) = 0,5.
        let m = YCbCrMatrix.bt709
        let red = m.toRGB.apply(SIMD3(m.kr, -m.kr / (2 - 2 * m.kb), 0.5))
        XCTAssertEqual(red.x, 1, accuracy: 1e-12)
        XCTAssertEqual(red.y, 0, accuracy: 1e-12)
        XCTAssertEqual(red.z, 0, accuracy: 1e-12)
    }

    func testVideoRangeNormalization() {
        // 8-bit video aralığı: 16 → 0, 235 → 1, 128 → 0 kroma.
        let r8 = YCbCrRange.make(bitDepth: 8, fullRange: false, storageScale: 255)
        let n8 = r8.normalize(SIMD3(235.0 / 255, 128.0 / 255, 240.0 / 255))
        XCTAssertEqual(n8.x, 1, accuracy: 1e-12)
        XCTAssertEqual(n8.y, 0, accuracy: 1e-12)
        XCTAssertEqual(n8.z, 0.5, accuracy: 1e-12)
        // MSB hizalı 10-bit: 64 → 0, 940 → 1.
        let s10 = 65535.0 / 64
        let r10 = YCbCrRange.make(bitDepth: 10, fullRange: false, storageScale: s10)
        XCTAssertEqual(r10.normalize(SIMD3(64 / s10, 512 / s10, 512 / s10)).x, 0, accuracy: 1e-12)
        XCTAssertEqual(r10.normalize(SIMD3(940 / s10, 512 / s10, 512 / s10)).x, 1, accuracy: 1e-12)
    }
}

final class NitCurveTests: XCTestCase {
    func testWhiteHitsTarget() {
        for curve in [NitCurve.maximum, .balanced] {
            XCTAssertEqual(curve(1), curve.w, accuracy: 1e-12)
        }
    }

    func testContinuityAtKnee() {
        for curve in [NitCurve.maximum, .balanced] {
            let xk = curve.xk
            XCTAssertEqual(curve(xk * (1 - 1e-9)), curve(xk * (1 + 1e-9)), accuracy: 1e-8)
            XCTAssertEqual(curve(xk), curve.kappa, accuracy: 1e-12)
        }
    }

    func testMonotonicAndBelowOne() {
        for curve in [NitCurve.maximum, .balanced, NitCurve(w: 0.98, kappa: 0.9)] {
            var previous = 0.0
            var x = 1e-4
            while x < 1e4 {
                let y = curve(x)
                XCTAssertGreaterThanOrEqual(y, previous)
                // Matematiksel olarak f < 1; çok büyük x'te Double 1,0'a doyar. Garanti edilen: f ≤ 1 (P-2).
                XCTAssertLessThanOrEqual(y, 1)
                if x <= 10 { XCTAssertLessThan(y, 1) }
                previous = y
                x *= 1.05
            }
        }
    }

    func testDocumentTableValues() {
        // 02-cozum §3.5 örnek tablosu: 1200 nitlik tepe, L_ref = 203 nit.
        let peak = 1200.0
        let maximum: [(Double, Double)] = [(1, 7), (10, 66), (50, 328), (100, 657), (150, 983),
                                           (203, 1140), (300, 1189), (406, 1197), (600, 1200)]
        for (src, expected) in maximum {
            XCTAssertEqual(peak * NitCurve.maximum(src / 203), expected, accuracy: 1, "Maksimum \(src) nit")
        }
        let balanced: [(Double, Double)] = [(1, 5), (10, 54), (50, 272), (100, 544), (150, 769),
                                            (203, 900), (300, 1019), (406, 1079), (600, 1130), (1000, 1166)]
        for (src, expected) in balanced {
            XCTAssertEqual(peak * NitCurve.balanced(src / 203), expected, accuracy: 1, "Dengeli \(src) nit")
        }
    }

    func testInvalidParametersAreClamped() {
        let c = NitCurve(w: 0.9, kappa: 0.9)
        XCTAssertLessThan(c.kappa, c.w)
        XCTAssertEqual(c(1), c.w, accuracy: 1e-12)
    }

    func testOutputNeverExceedsHeadroom() {
        let h = 6.0
        for v in stride(from: 0.0, through: 50.0, by: 0.37) {
            let out = NitTone.output(rgb: SIMD3(v, v * 0.3, 0), isHDR: true, curve: .maximum, headroom: h)
            XCTAssertLessThanOrEqual(max(out.x, max(out.y, out.z)), h + 1e-12)
            let sdr = NitTone.output(rgb: SIMD3(v, v, v), isHDR: false, curve: .maximum, headroom: h)
            XCTAssertLessThanOrEqual(sdr.x, h + 1e-12)
        }
        XCTAssertEqual(NitTone.output(rgb: SIMD3(1, 1, 1), isHDR: false, curve: .maximum, headroom: h).x, h)
    }
}

final class HeadroomFilterTests: XCTestCase {
    func testDropIsImmediate() {
        var f = HeadroomFilter()
        f.update(current: 8, dt: 0)
        XCTAssertEqual(f.update(current: 2, dt: 0.016), 2)
    }

    func testRiseIsSmoothedAndNeverAboveCurrent() {
        var f = HeadroomFilter(tauUp: 0.150)
        f.update(current: 1, dt: 0)
        let first = f.update(current: 8, dt: 0.016)
        XCTAssertGreaterThan(first, 1)
        XCTAssertLessThan(first, 8)
        var t = 0.0
        var value = first
        while t < 2 {
            value = f.update(current: 8, dt: 0.016)
            XCTAssertLessThanOrEqual(value, 8)
            t += 0.016
        }
        // Ölü bandın içine girince hedefe tam oturur; %1 altında takılı kalmaz.
        XCTAssertEqual(value, 8, accuracy: 1e-12)
    }

    func testTinyRisesApplyDirectly() {
        var f = HeadroomFilter(deadband: 0.01)
        f.update(current: 4, dt: 0)
        f.update(current: 3.98, dt: 0.016)
        XCTAssertEqual(f.update(current: 4.0, dt: 0.016), 4.0, accuracy: 1e-12)
    }

    func testLargeRiseIsNotInstant() {
        var f = HeadroomFilter(tauUp: 0.150, deadband: 0.01)
        f.update(current: 2, dt: 0)
        XCTAssertLessThan(f.update(current: 4, dt: 0.016), 2.2)
    }
}

final class PeakLockTests: XCTestCase {
    private func input(_ t: Double, current: Double, potential: Double = 8, brightness: Double,
                       lowPower: Bool = false) -> PeakLock.Input {
        PeakLock.Input(time: t, current: current, potential: potential, brightness: brightness,
                       lowPower: lowPower, thermalSerious: false, captured: false)
    }

    func testRaisesOnlyAfterHoldAndNeverLowers() {
        var lock = PeakLock()
        var brightness = 0.2
        var t = 0.0
        var raisedAt: Double?
        while t < 20 {
            // Kaydırıcı 0,6'ya kadar sınırlıyor; sonra panel tepesi.
            let current = brightness < 0.6 ? 8.0 : 8.0 * (0.6 / brightness)
            let out = lock.update(input(t, current: current, brightness: brightness))
            if let b = out.brightness {
                XCTAssertGreaterThan(b, brightness, "Tepe Kilidi parlaklığı asla düşürmez")
                if raisedAt == nil { raisedAt = t }
                brightness = b
            }
            t += 0.1
        }
        XCTAssertNotNil(raisedAt)
        XCTAssertGreaterThanOrEqual(raisedAt ?? 0, 3.0)
        XCTAssertGreaterThanOrEqual(brightness, 0.6)
        XCTAssertLessThan(brightness, 0.7)
        XCTAssertNotNil(lock.kneeBrightness)
    }

    func testCollapseRaisesToFull() {
        var lock = PeakLock()
        var out = lock.update(input(0, current: 1.0, brightness: 0.5))
        XCTAssertNil(out.brightness)
        out = lock.update(input(6, current: 1.0, brightness: 0.5))
        XCTAssertEqual(out.status, .collapsed)
        XCTAssertEqual(out.brightness, 1.0)
    }

    func testDisabledNeverTouchesBrightness() {
        var lock = PeakLock(enabled: false)
        for t in stride(from: 0.0, to: 10, by: 0.1) {
            XCTAssertNil(lock.update(input(t, current: 8, brightness: 0.1)).brightness)
        }
    }

    func testLowPowerTargetsSDRPeak() {
        var lock = PeakLock()
        let out = lock.update(input(0, current: 1, brightness: 0.3, lowPower: true))
        XCTAssertEqual(out.status, .lowPower)
        XCTAssertEqual(out.brightness, 1.0)
    }
}
