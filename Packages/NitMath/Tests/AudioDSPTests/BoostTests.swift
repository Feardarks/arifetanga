import Foundation
import XCTest
@testable import AudioDSP

private struct Random {
    var state: UInt32
    mutating func next(_ amp: Float) -> Float {
        state = state &* 1_664_525 &+ 1_013_904_223
        return (Float(state >> 8) / Float(1 << 24) * 2 - 1) * amp
    }
}

private func rootMeanSquare(_ x: ArraySlice<Float>) -> Float {
    guard !x.isEmpty else { return 0 }
    return (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
}

/// Zinciri 1024 karelik bloklarla işler; sonuna gecikme kadar sıfır eklenir (tüm girdi çıkar).
private func runChain(_ chain: BoostChain, _ input: [Float], flush: Bool = true) -> (out: [Float], stats: [BoostBlockStats]) {
    let C = chain.channels
    var data = input
    if flush { data += [Float](repeating: 0, count: chain.latency * C) }
    var out: [Float] = []
    var stats: [BoostBlockStats] = []
    let frames = data.count / C
    var f = 0
    while f < frames {
        let n = min(1024, frames - f)
        let block = Array(data[(f * C)..<((f + n) * C)])
        out += block.withUnsafeBufferPointer { chain.process($0, frames: n) }
        stats += chain.stats
        f += n
    }
    return (out, stats)
}

private func truePeak(_ x: [Float], channels: Int) -> Double {
    var meter = TruePeakMeter(channels: channels)
    let padded = x + [Float](repeating: 0, count: (TruePeak.delay + 1) * channels)
    padded.withUnsafeBufferPointer { meter.add(interleaved: $0, frames: padded.count / channels) }
    return meter.dBTP
}

final class BoostTests: XCTestCase {
    func testGainCurveIsPerceptualAndCappedAt6dB() {
        XCTAssertEqual(BoostConfig.gainDB(percent: 100), 0, accuracy: 1e-12)
        XCTAssertEqual(BoostConfig.gainDB(percent: 125), 3.302, accuracy: 1e-3)
        XCTAssertEqual(BoostConfig.gainDB(percent: 150), 6, accuracy: 1e-12)
        XCTAssertEqual(BoostConfig.gainDB(percent: 400), 6, accuracy: 1e-12, "üst sınır kod düzeyinde")
        XCTAssertEqual(BoostConfig.gainDB(percent: 50), 0, accuracy: 1e-12)
        XCTAssertEqual(BoostConfig.gainDB(percent: .nan), 0, accuracy: 1e-12)
    }

    /// fs/4'te 45° fazlı sinüs: örnek tepesi 0,707, gerçek tepe ≈ 1.
    func testTruePeakFindsInterSamplePeak() {
        let x = (0..<400).map { Float(sin(2 * Double.pi * Double($0) / 4 + Double.pi / 4)) }
        XCTAssertEqual(x.map(abs).max()!, 0.7071, accuracy: 1e-3)
        XCTAssertEqual(truePeak(x, channels: 1), 0, accuracy: 0.2)
        let low = (0..<4000).map { Float(0.5 * sin(2 * Double.pi * 1000 * Double($0) / 48000)) }
        XCTAssertEqual(truePeak(low, channels: 1), 20 * log10(0.5), accuracy: 0.05)
    }

    func testCompressorCurveIsContinuousSoftKnee() {
        XCTAssertEqual(BoostChain.compressorGainDB(level: -20), 0)
        XCTAssertEqual(BoostChain.compressorGainDB(level: -11), 0, accuracy: 1e-12)
        XCTAssertEqual(BoostChain.compressorGainDB(level: -8), -0.375, accuracy: 1e-12)
        XCTAssertEqual(BoostChain.compressorGainDB(level: -5), -1.5, accuracy: 1e-12)
        XCTAssertEqual(BoostChain.compressorGainDB(level: 2), -5, accuracy: 1e-12)
    }

    /// AS-37 (a): yüksek kayıtlı içerik +6 dB ile → çıkışta gerçek tepe tavanı (−1 dBTP) aşmaz.
    func testLimiterHoldsTrueCeiling() {
        for mode in [LimiterMode.limiterOnly, .smart] {
            var random = Random(state: 3)
            var input: [Float] = []
            for f in 0..<(48000 * 2) {
                // Gürültü + fs/4 ara tepe üreten sinüs patlamaları + tek örnek darbeler.
                let burst: Float = (f / 4800) % 2 == 0 ? Float(0.6 * sin(2 * Double.pi * Double(f) / 4 + 0.7)) : 0
                let impulse: Float = f % 9000 == 0 ? 1 : 0
                let l = max(min(random.next(0.5) + burst + impulse, 1), -1)
                let r = max(min(random.next(0.5) + burst, 1), -1)
                input += [l, r]
            }
            let chain = BoostChain(sampleRate: 48000, weights: [1, 1], config: BoostConfig(percent: 150, mode: mode),
                                   managerLookahead: 0.1)
            let (out, stats) = runChain(chain, input)
            XCTAssertLessThanOrEqual(truePeak(out, channels: 2), -1.0 + 0.01, "\(mode)")
            XCTAssertEqual(stats.reduce(0) { $0 + $1.truePeakOvers }, 0, "\(mode): gösterge de aşım görmez")
            // Akıllı kipte yönetici yüksek kayıtlı içerikte boost'u zaten geri çeker; sınırlama azdır.
            XCTAssertGreaterThan(stats.map { $0.gainReductionDB }.max()!, mode == .limiterOnly ? 3 : 0.5, "\(mode): limiter çalıştı")
        }
    }

    /// Gecikme kipten bağımsız: anahtar değişince zamanlama sıçramaz.
    func testLatencyIsIdenticalInAllModes() {
        var latencies: Set<Int> = []
        for mode in LimiterMode.allCases {
            let chain = BoostChain(sampleRate: 48000, weights: [1], config: BoostConfig(percent: 150, mode: mode),
                                   managerLookahead: 0.05)
            latencies.insert(chain.latency)
            var input = [Float](repeating: 0, count: 6000)
            input[100] = 0.1
            let (out, _) = runChain(chain, input)
            let peakIndex = out.indices.max { abs(out[$0]) < abs(out[$1]) }!
            XCTAssertEqual(peakIndex, 100 + chain.latency, "\(mode)")
            if mode != .smart {
                XCTAssertEqual(out[peakIndex], 0.1 * Float(pow(10, 6.0 / 20)), accuracy: 1e-6, "\(mode): boost birebir")
            }
        }
        XCTAssertEqual(latencies.count, 1)
        XCTAssertEqual(latencies.first, Int(0.05 * 48000) + 96 + TruePeak.delay)
    }

    /// AS-37 (c): kapalı kipte kırpma sayacı, sentetik sinyalde beklenen sayıyla birebir.
    func testHardClipCountIsExact() {
        let gain = Float(pow(10, 6.0 / 20))
        var input: [Float] = []
        var expected = [0, 0]
        for f in 0..<48000 {
            let l = Float(0.7 * sin(2 * Double.pi * 1000 * Double(f) / 48000))
            let r = Float(0.55 * sin(2 * Double.pi * 440 * Double(f) / 48000))
            input += [l, r]
            if abs(l * gain) > 1 { expected[0] += 1 }
            if abs(r * gain) > 1 { expected[1] += 1 }
        }
        let chain = BoostChain(sampleRate: 48000, weights: [1, 1], config: BoostConfig(percent: 150, mode: .off),
                               managerLookahead: 0.05)
        let (out, stats) = runChain(chain, input)
        let counted = (0..<2).map { c in stats.reduce(0) { $0 + $1.clipped[c] } }
        XCTAssertEqual(counted, expected)
        XCTAssertGreaterThan(expected[0], 1000)
        XCTAssertLessThanOrEqual(out.map(abs).max()!, 1, "sert kırpma ±1,0")
        XCTAssertGreaterThan(stats.reduce(0) { $0 + $1.truePeakOvers }, 0, "kırpılan dalgada ara tepeler 0 dBTP'yi aşar")
        // Ham float: kırpma yok, aynı sayılar yalnızca raporlanır.
        let raw = BoostChain(sampleRate: 48000, weights: [1, 1], config: BoostConfig(percent: 150, mode: .rawFloat),
                             managerLookahead: 0.05)
        let (rawOut, rawStats) = runChain(raw, input)
        XCTAssertEqual((0..<2).map { c in rawStats.reduce(0) { $0 + $1.clipped[c] } }, expected)
        XCTAssertGreaterThan(rawOut.map(abs).max()!, 1.3)
    }

    /// Yönetici: sessiz içerikte tam +6 dB uygular, yüksek kayıtlı içerik gelince kendiliğinden geri çeker.
    func testManagerBacksOffOnLoudContentOnly() {
        let rate = 16000.0
        var random = Random(state: 9)
        func feed(_ chain: BoostChain, amplitude: Float, seconds: Double) {
            let input = (0..<Int(rate * seconds) * 2).map { _ in random.next(amplitude) }
            _ = runChain(chain, input, flush: false)
        }
        let chain = BoostChain(sampleRate: rate, weights: [1, 1], config: BoostConfig(percent: 150, mode: .smart),
                               managerLookahead: 0.2)
        feed(chain, amplitude: 0.02, seconds: 15)
        XCTAssertGreaterThan(chain.managerGainDB, 5.5, "≈ −34 LUFS: tam +6 dB")
        feed(chain, amplitude: 0.9, seconds: 8)
        XCTAssertLessThan(chain.managerGainDB, 0.5, "≈ −1 LUFS: içerik zaten tavanda")

        let settling = BoostChain(sampleRate: rate, weights: [1, 1], config: BoostConfig(percent: 150, mode: .smart),
                                  managerLookahead: 0.2)
        settling.reset(settleSeconds: 1)
        feed(settling, amplitude: 0.02, seconds: 1)
        XCTAssertGreaterThan(settling.managerGainDB, 5, "ısınmada hızlı oturur")
    }

    func testSpeakerHighPassRemovesDeepBass() {
        func level(_ highPass: Bool) -> Float {
            let input = (0..<48000).map { Float(0.1 * sin(2 * Double.pi * 50 * Double($0) / 48000)) }
            let chain = BoostChain(sampleRate: 48000, weights: [1],
                                   config: BoostConfig(percent: 150, mode: .limiterOnly, speakerHighPass: highPass),
                                   managerLookahead: 0.05)
            return rootMeanSquare(runChain(chain, input).out[24000..<48000])
        }
        XCTAssertLessThan(level(true) / level(false), 0.15, "150 Hz HPF, 50 Hz'te ≈ −19 dB")
    }
}
