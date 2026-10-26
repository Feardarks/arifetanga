import XCTest
@testable import NitMath

/// 02-cozum §3.5.1 davranışları. Beklentiler Python ikiziyle simüle edilerek doğrulandı.
final class SceneWhiteTests: XCTestCase {
    private let fps = 24.0

    /// (nit, oran) çiftlerinden 256 kutulu PQ histogramı.
    private func histogram(_ parts: [(Double, Double)], total: Double = 140_000) -> [UInt32] {
        var h = [UInt32](repeating: 0, count: 256)
        for (nits, fraction) in parts {
            h[SceneWhiteEstimator.bin(forNits: nits)] += UInt32(total * fraction)
        }
        return h
    }

    private var scene: [UInt32] { histogram([(30, 0.80), (120, 0.15), (600, 0.05)]) }
    private var bright: [UInt32] { histogram([(60, 0.80), (250, 0.15), (900, 0.05)]) }

    /// `seconds` boyunca aynı histogramla besler; zamanı ilerletir.
    private func feed(_ e: inout SceneWhiteEstimator, _ h: [UInt32], seconds: Double, time t: inout Double) {
        for _ in 0..<Int(seconds * fps) {
            e.update(histogram: h, time: t)
            t += 1 / fps
        }
    }

    private func stops(_ a: Double, _ b: Double) -> Double { log2(a / b) }

    func testPercentileIgnoresDarkPixels() {
        let h = histogram([(0.1, 0.5), (100, 0.5)])
        let p90 = SceneWhiteEstimator.percentileNits(h, percentile: 0.9, minNits: 1)
        XCTAssertNotNil(p90)
        XCTAssertEqual(p90 ?? 0, 100, accuracy: 5)
        XCTAssertNil(SceneWhiteEstimator.percentileNits(histogram([(0.2, 1)]), percentile: 0.9, minNits: 1))
    }

    func testInitialAnchorFromMaxFALL() {
        XCTAssertEqual(SceneWhiteEstimator.initialAnchor(maxFALL: nil), 203)
        XCTAssertEqual(SceneWhiteEstimator.initialAnchor(maxFALL: 50), 100)
        XCTAssertEqual(SceneWhiteEstimator.initialAnchor(maxFALL: 150), 150)
        XCTAssertEqual(SceneWhiteEstimator.initialAnchor(maxFALL: 400), 203)
    }

    func testSteadySceneConvergesToDiffuseWhite() {
        var e = SceneWhiteEstimator()
        var t = 0.0
        let p90 = SceneWhiteEstimator.percentileNits(scene, percentile: 0.9, minNits: 1) ?? 0
        feed(&e, scene, seconds: 2, time: &t)
        // Başta çapa 203: L_ref çapanın en fazla 0,5 stop altına iner.
        XCTAssertEqual(e.state.referenceWhite, 203 / pow(2, 0.5), accuracy: 1)
        feed(&e, scene, seconds: 20 * 60, time: &t)
        // Çapa ≤ 0,1 stop/dk ile filmin beyazına oturur.
        XCTAssertEqual(e.state.referenceWhite, p90, accuracy: p90 * 0.03)
        XCTAssertEqual(e.state.anchor, p90, accuracy: p90 * 0.05)
    }

    func testGradualBrightObjectRiseIsLimited() {
        var e = SceneWhiteEstimator(initialAnchor: 120)
        var t = 0.0
        feed(&e, scene, seconds: 60, time: &t)
        let start = e.state.referenceWhite
        let scenes = e.state.sceneCount
        let n = Int(3 * fps)
        for i in 0..<n {
            let f = 0.30 * Double(i + 1) / Double(n)
            e.update(histogram: histogram([(30, 0.80 - f * 0.8), (120, 0.15 - f * 0.15), (600, 0.05 - f * 0.05), (1000, f)]), time: t)
            t += 1 / fps
        }
        var maxRise = 0.0
        for _ in 0..<Int(60 * fps) {
            e.update(histogram: histogram([(30, 0.55), (120, 0.15), (1000, 0.30)]), time: t)
            t += 1 / fps
            maxRise = max(maxRise, stops(e.state.referenceWhite, start))
        }
        XCTAssertEqual(e.state.sceneCount, scenes, "Kademeli giren obje kesim sayılmamalı")
        XCTAssertLessThanOrEqual(maxRise, 0.2 + 1e-9, "Sahne içi yükselme en fazla +0,2 stop")
        XCTAssertGreaterThan(maxRise, 0)
    }

    func testSmallBrightObjectDoesNotMoveWhite() {
        var e = SceneWhiteEstimator(initialAnchor: 120)
        var t = 0.0
        feed(&e, scene, seconds: 60, time: &t)
        let start = e.state.referenceWhite
        feed(&e, histogram([(30, 0.75), (120, 0.15), (600, 0.02), (1000, 0.08)]), seconds: 20, time: &t)
        XCTAssertLessThan(abs(stops(e.state.referenceWhite, start)), 0.1)
    }

    func testSingleFrameFlashIsIgnored() {
        var e = SceneWhiteEstimator()
        var t = 0.0
        feed(&e, scene, seconds: 60, time: &t)
        let before = e.state.referenceWhite
        e.update(histogram: histogram([(1000, 1)]), time: t)
        t += 1 / fps
        feed(&e, scene, seconds: 3, time: &t)
        XCTAssertEqual(e.state.referenceWhite, before, accuracy: before * 0.02)
    }

    func testStrongCutAdaptsQuicklyWithinAnchorLimit() {
        var e = SceneWhiteEstimator()
        var t = 0.0
        feed(&e, scene, seconds: 10 * 60, time: &t)
        let scenes = e.state.sceneCount
        let exterior = histogram([(150, 0.6), (220, 0.3), (800, 0.1)])
        feed(&e, exterior, seconds: 1, time: &t)
        XCTAssertEqual(e.state.sceneCount, scenes + 1)
        let p90 = SceneWhiteEstimator.percentileNits(exterior, percentile: 0.9, minNits: 1) ?? 0
        let cap = e.state.anchor * pow(2, 0.5)
        XCTAssertEqual(e.state.referenceWhite, min(p90, cap), accuracy: 2)
    }

    func testSeekForcesCut() {
        var e = SceneWhiteEstimator()
        var t = 0.0
        feed(&e, scene, seconds: 60, time: &t)
        let scenes = e.state.sceneCount
        e.markCut()
        feed(&e, bright, seconds: 2, time: &t)
        XCTAssertEqual(e.state.sceneCount, scenes + 1)
        let p90 = SceneWhiteEstimator.percentileNits(bright, percentile: 0.9, minNits: 1) ?? 0
        XCTAssertEqual(e.state.referenceWhite, p90, accuracy: p90 * 0.03)
    }

    func testAbsoluteBounds() {
        var dark = SceneWhiteEstimator()
        var t = 0.0
        feed(&dark, histogram([(5, 1)]), seconds: 30 * 60, time: &t)
        XCTAssertEqual(dark.state.referenceWhite, 80, accuracy: 1e-9)

        var hot = SceneWhiteEstimator(initialAnchor: 1000)
        t = 0
        feed(&hot, histogram([(2000, 1)]), seconds: 10, time: &t)
        XCTAssertEqual(hot.state.referenceWhite, 300, accuracy: 1e-9)
    }

    func testNoiseDoesNotCreateCuts() {
        var e = SceneWhiteEstimator()
        var t = 0.0
        var seed: UInt64 = 12345
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for _ in 0..<Int(60 * fps) {
            let a = 0.97 + 0.06 * random()
            let b = 0.97 + 0.06 * random()
            e.update(histogram: histogram([(30 * a, 0.80), (120 * b, 0.15), (600, 0.05)]), time: t)
            t += 1 / fps
        }
        XCTAssertEqual(e.state.sceneCount, 1, "Yalnızca ilk kare sahne başlangıcı sayılır")
    }

    func testOutputCurveStillBoundedForAnyReferenceWhite() {
        // P-2: L_ref ne olursa olsun çıkış H'yi aşmaz.
        for lRef in [80.0, 120, 203, 300] {
            for nits in [1.0, 100, 1000, 10000] {
                let out = NitTone.output(rgb: SIMD3(repeating: nits / lRef), isHDR: true, curve: .maximum, headroom: 6)
                XCTAssertLessThanOrEqual(out.x, 6 + 1e-12)
            }
        }
    }
}
