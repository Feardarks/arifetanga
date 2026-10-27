import Foundation
import XCTest
@testable import AudioDSP

/// Tekrarlanabilir gürültü (LCG), [-amp, amp].
private struct Noise {
    var state: UInt32
    init(seed: UInt32) { state = seed }
    mutating func next(_ amp: Float = 0.5) -> Float {
        state = state &* 1_664_525 &+ 1_013_904_223
        return (Float(state >> 8) / Float(1 << 24) * 2 - 1) * amp
    }
}

private func rms(_ x: ArraySlice<Float>) -> Float {
    guard !x.isEmpty else { return 0 }
    return (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
}

final class FFTAndLoudnessTests: XCTestCase {
    func testFFTMatchesDFTAndInverts() {
        let n = 16
        var re = (0..<n).map { Float(sin(Double($0) * 0.7) + 0.3 * cos(Double($0) * 2.1)) }
        var im = [Float](repeating: 0, count: n)
        let original = re
        FFT(size: n).transform(real: &re, imag: &im)
        for k in 0..<n {
            var dr = 0.0, di = 0.0
            for t in 0..<n {
                let w = -2 * Double.pi * Double(k * t) / Double(n)
                dr += Double(original[t]) * cos(w)
                di += Double(original[t]) * sin(w)
            }
            XCTAssertEqual(Double(re[k]), dr, accuracy: 1e-4)
            XCTAssertEqual(Double(im[k]), di, accuracy: 1e-4)
        }
        FFT(size: n).transform(real: &re, imag: &im, inverse: true)
        for t in 0..<n { XCTAssertEqual(re[t], original[t], accuracy: 1e-5) }
    }

    func testKWeightingMatchesBS1770At48k() {
        let (shelf, highPass) = KWeighting.filters(sampleRate: 48000)
        XCTAssertEqual(shelf.b.0, 1.53512485958697, accuracy: 1e-9)
        XCTAssertEqual(shelf.b.1, -2.69169618940638, accuracy: 1e-9)
        XCTAssertEqual(shelf.b.2, 1.19839281085285, accuracy: 1e-9)
        XCTAssertEqual(shelf.a.0, -1.69065929318241, accuracy: 1e-9)
        XCTAssertEqual(shelf.a.1, 0.73248077421585, accuracy: 1e-9)
        XCTAssertEqual(highPass.a.0, -1.99004745483398, accuracy: 1e-9)
        XCTAssertEqual(highPass.a.1, 0.99007225036621, accuracy: 1e-9)
    }

    /// BS.1770: tek kanalda 0 dBFS 1 kHz sinüs −3,01 LKFS ölçülür.
    func testFullScaleSineIsMinus3LUFS() {
        var meter = LoudnessMeter(sampleRate: 48000, weights: [1])
        let samples = (0..<(48000 * 4)).map { Float(sin(2 * Double.pi * 997 * Double($0) / 48000)) }
        samples.withUnsafeBufferPointer { meter.add(interleaved: $0, frames: samples.count) }
        XCTAssertEqual(meter.loudness ?? 0, -3.01, accuracy: 0.1)
    }

    func testLagEstimatorFindsDelay() throws {
        var noise = Noise(seed: 7)
        let x = (0..<20000).map { _ in noise.next() }
        let y = [Float](repeating: 0, count: 1234) + x.prefix(20000 - 1234)
        let result = try XCTUnwrap(LagEstimator.estimate(reference: x, signal: y, maxLag: 4000))
        XCTAssertEqual(result.lag, 1234)
        XCTAssertGreaterThan(result.correlation, 0.9)
    }
}

final class CenterExtractorTests: XCTestCase {
    private func run(_ extractor: CenterExtractor, left: [Float], right: [Float]) -> [Float] {
        var out: [Float] = []
        var offset = 0
        let chunks = [700, 333, 1024, 1, 4096, 512]
        var i = 0
        while offset < left.count {
            let n = min(chunks[i % chunks.count], left.count - offset)
            let l = Array(left[offset..<(offset + n)])
            let r = Array(right[offset..<(offset + n)])
            out += l.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in extractor.process(left: lp, right: rp) } }
            offset += n
            i += 1
        }
        return out
    }

    func testIdentityMaskReconstructsWithLatency() {
        let extractor = CenterExtractor(sampleRate: 48000, identity: true)
        XCTAssertEqual(extractor.latency, 2048)
        var noise = Noise(seed: 1)
        let x = (0..<20000).map { _ in noise.next() }
        let out = run(extractor, left: x, right: x)
        XCTAssertEqual(out.count, x.count, "her çağrıda girdi kadar çıktı")
        for j in 0..<2048 { XCTAssertEqual(out[j], 0, accuracy: 1e-6) }
        for j in 2048..<x.count { XCTAssertEqual(out[j], x[j - 2048], accuracy: 1e-4) }
    }

    func testCenteredToneKeptHardPannedRemoved() {
        let n = 48000
        let tone = (0..<n).map { Float(0.5 * sin(2 * Double.pi * 1000 * Double($0) / 48000)) }
        let silence = [Float](repeating: 0, count: n)

        let center = run(CenterExtractor(sampleRate: 48000), left: tone, right: tone)
        XCTAssertEqual(rms(center[24000...]) / rms(tone[24000...]), 1, accuracy: 0.06, "merkezdeki ton kalır")

        let side = run(CenterExtractor(sampleRate: 48000), left: tone, right: silence)
        XCTAssertLessThan(rms(side[24000...]) / rms(tone[24000...]), 0.01, "yalnızca soldaki ton atılır")

        let inverted = tone.map { -$0 }
        let antiphase = run(CenterExtractor(sampleRate: 48000), left: tone, right: inverted)
        XCTAssertLessThan(rms(antiphase[24000...]), 1e-3, "ters fazlı (L+R = 0) sinyalde merkez yok")
    }
}

/// `M = (L+R)/2`'yi `latency` örnek geciktirip `gain` ile ölçekleyen sahte izolatör.
private final class DelayIsolator: VoiceIsolator {
    let latency: Int
    let gain: Float
    private var fifo: [Float]

    init(latency: Int, gain: Float = 1) {
        self.latency = latency
        self.gain = gain
        fifo = [Float](repeating: 0, count: latency)
    }

    func isolate(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) -> [Float] {
        for i in 0..<left.count { fifo.append(gain * 0.5 * (left[i] + right[i])) }
        let out = Array(fifo.prefix(left.count))
        fifo.removeFirst(left.count)
        return out
    }

    func reset() { fifo = [Float](repeating: 0, count: latency) }
}

final class DialogCoreTests: XCTestCase {
    private let rate = 48000.0

    /// Karışık girdiyi 1024 karelik bloklarla işler.
    private func run(_ core: DialogCore, _ input: [Float], channels: Int) -> [Float] {
        var out: [Float] = []
        let frames = input.count / channels
        var f = 0
        while f < frames {
            let n = min(1024, frames - f)
            let block = Array(input[(f * channels)..<((f + n) * channels)])
            out += block.withUnsafeBufferPointer { core.process($0, frames: n) }
            f += n
        }
        return out
    }

    private func stereoNoise(seconds: Double, seed: UInt32 = 3, correlated: Bool = true) -> [Float] {
        var noise = Noise(seed: seed)
        var out: [Float] = []
        for _ in 0..<Int(seconds * rate) {
            let l = noise.next()
            out += [l, correlated ? l : noise.next()]
        }
        return out
    }

    private func channel(_ x: [Float], _ c: Int, of n: Int) -> [Float] {
        stride(from: c, to: x.count, by: n).map { x[$0] }
    }

    func testTierZeroIsPureDelayToCommonLatency() {
        let core = DialogCore(sampleRate: rate, roles: [.left, .right],
                              primary: DelayIsolator(latency: 100), fallback: DelayIsolator(latency: 300))
        XCTAssertEqual(core.latency, 300)
        let input = stereoNoise(seconds: 1, correlated: false)
        let out = run(core, input, channels: 2)
        for j in 300..<48000 {
            XCTAssertEqual(out[2 * j], input[2 * (j - 300)], accuracy: 1e-6)
            XCTAssertEqual(out[2 * j + 1], input[2 * (j - 300) + 1], accuracy: 1e-6)
        }
    }

    func testDialogBoostIsLoudnessMatchedAndAligned() throws {
        let core = DialogCore(sampleRate: rate, roles: [.left, .right], primary: DelayIsolator(latency: 200), fallback: nil)
        core.tier = 2
        let input = stereoNoise(seconds: 10)
        let out = run(core, input, channels: 2)
        let left = channel(out, 0, of: 2)
        let dry = channel(input, 0, of: 2)
        // Ses = girdinin kendisi: L' = c·(1 + a)·L ≈ c·2·L; c −6 dB'ye oturunca çıkış ≈ girdi.
        XCTAssertEqual(core.compensationDB, -6, accuracy: 0.3)
        let ratioDB = 20 * log10(Double(rms(left[(8 * 48000)...]) / rms(dry[(8 * 48000 - 200)..<(10 * 48000 - 200)])))
        XCTAssertEqual(ratioDB, 0, accuracy: 0.5)
        let lag = try XCTUnwrap(LagEstimator.estimate(reference: Array(dry[0..<48000]),
                                                      signal: Array(left[0..<48000]), maxLag: 1000))
        XCTAssertEqual(lag.lag, 200, "kuru yol ve ses aynı gecikmede; A/V kayması yok")
    }

    func testCompensationClampsAtMinus6() {
        let core = DialogCore(sampleRate: rate, roles: [.left, .right], primary: DelayIsolator(latency: 0), fallback: nil)
        core.tier = 3
        let input = stereoNoise(seconds: 10)
        let out = run(core, input, channels: 2)
        // +9 dB (×2,818 toplam 1+a) ve c en çok −6 dB → net ≈ +3 dB.
        let net = 20 * log10(Double(rms(channel(out, 0, of: 2)[(8 * 48000)...]) / rms(channel(input, 0, of: 2)[(8 * 48000)...])))
        XCTAssertEqual(net, 20 * log10(pow(10, 9.0 / 20)) - 6, accuracy: 0.5)
    }

    func testMultichannelBoostsCenterOnly() {
        // 5.1: L R C LFE Ls Rs; aynı sinyal her kanalda. Kademe 1 (+3 dB) merkezi diğerlerine göre ×1,41 yapar.
        let core = DialogCore(sampleRate: rate, roles: [.left, .right, .center, .lfe, .surround, .surround],
                              primary: DelayIsolator(latency: 0), fallback: nil)
        core.tier = 1
        var noise = Noise(seed: 9)
        var input: [Float] = []
        for _ in 0..<Int(4 * rate) {
            let s = noise.next()
            input += [s, s, s, s, s, s]
        }
        let out = run(core, input, channels: 6)
        let centerOverLeft = rms(channel(out, 2, of: 6)[48000...]) / rms(channel(out, 0, of: 6)[48000...])
        XCTAssertEqual(Double(centerOverLeft), pow(10, 3.0 / 20), accuracy: 0.02)
        XCTAssertEqual(Double(rms(channel(out, 4, of: 6)[48000...]) / rms(channel(out, 0, of: 6)[48000...])), 1, accuracy: 1e-3)
    }

    func testSoloOutputsOnlyTheVoice() {
        let core = DialogCore(sampleRate: rate, roles: [.left, .right], primary: DelayIsolator(latency: 0, gain: 0.5), fallback: nil)
        core.tier = 1
        core.solo = true
        let input = stereoNoise(seconds: 0.5)
        let out = run(core, input, channels: 2)
        for j in 0..<1000 { XCTAssertEqual(out[2 * j], 0.5 * input[2 * j], accuracy: 1e-6) }
    }

    func testEngineCrossfadeSwitchesToFallback() {
        let core = DialogCore(sampleRate: rate, roles: [.left, .right], primary: DelayIsolator(latency: 0),
                              fallback: DelayIsolator(latency: 0, gain: 0))
        core.tier = 3
        XCTAssertEqual(core.activeEngine, .primary)
        _ = run(core, stereoNoise(seconds: 0.5), channels: 2)
        core.select(.fallback)
        _ = run(core, stereoNoise(seconds: 1, seed: 5), channels: 2)
        XCTAssertEqual(core.activeEngine, .fallback, "ısınma 0,3 s + çapraz geçiş 0,2 s içinde")
    }

    /// Yeniden işlemede ısınma: `c` 1 s içinde yerine oturur (τ = 2 s ile yalnızca −2,4 dB'ye varırdı).
    func testResetWithSettleConvergesQuickly() {
        let core = DialogCore(sampleRate: rate, roles: [.left, .right], primary: DelayIsolator(latency: 0), fallback: nil)
        core.tier = 2
        _ = run(core, stereoNoise(seconds: 3), channels: 2)
        core.reset(settleSeconds: 1)
        XCTAssertEqual(core.compensationDB, 0)
        _ = run(core, stereoNoise(seconds: 1, seed: 11), channels: 2)
        XCTAssertEqual(core.compensationDB, -6, accuracy: 0.5)
    }

    func testMusicRelaxationTargetsAndSmoothing() {
        XCTAssertEqual(MusicRelaxation.target(music: 1, singing: 0, speech: 0), 0.2, accuracy: 1e-9)
        XCTAssertEqual(MusicRelaxation.target(music: 0, singing: 0, speech: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(MusicRelaxation.target(music: 1, singing: 0, speech: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(MusicRelaxation.target(music: 0.5, singing: 0, speech: 0.5), 0.8, accuracy: 1e-9)
        let core = DialogCore(sampleRate: rate, roles: [.left, .right], primary: DelayIsolator(latency: 0), fallback: nil)
        core.tier = 2
        core.relaxationTarget = 0.2
        _ = run(core, stereoNoise(seconds: 0.5), channels: 2)
        XCTAssertLessThan(core.relaxation, 0.55, "gevşeme τ = 0,5 s")
        XCTAssertGreaterThan(core.relaxation, 0.2)
    }
}

final class ResamplerTests: XCTestCase {
    private func roundTrip(rate: Int, via middle: Int, input: [Float]) -> (out: [Float], latency: Double) {
        let down = Resampler(inputRate: rate, outputRate: middle)
        let up = Resampler(inputRate: middle, outputRate: rate)
        var out: [Float] = []
        var offset = 0
        let chunks = [1, 40, 512, 1536, 700, 4096]
        var i = 0
        while offset < input.count {
            let n = min(chunks[i % chunks.count], input.count - offset)
            let low = Array(input[offset..<(offset + n)]).withUnsafeBufferPointer { down.process($0) }
            out += low.withUnsafeBufferPointer { up.process($0) }
            // Çıkış girdinin gerisinde en çok birkaç örnek kalır (sarmalayıcının FIFO payı buna göre).
            XCTAssertLessThanOrEqual(offset + n - out.count, 8)
            offset += n
            i += 1
        }
        return (out, down.latency * Double(rate) / Double(middle) + up.latency)
    }

    private func sine(_ hz: Double, rate: Int, count: Int, delay: Double = 0) -> [Float] {
        (0..<count).map { Float(0.5 * sin(2 * Double.pi * hz * (Double($0) - delay) / Double(rate))) }
    }

    func test48kVia16kRoundTripHasIntegerLatency() {
        let input = sine(1000, rate: 48000, count: 24000)
        let (out, latency) = roundTrip(rate: 48000, via: 16000, input: input)
        XCTAssertEqual(latency, 143, accuracy: 1e-9, "48k ↔ 16k: gecikme tam sayı, kuru yol birebir hizalanır")
        let ideal = sine(1000, rate: 48000, count: out.count, delay: latency)
        XCTAssertLessThan(rms(zip(out, ideal).map { $0 - $1 }[4000...]), 1e-3)
    }

    func test44kVia16kRoundTripMatchesFractionalLatency() {
        let input = sine(1000, rate: 44100, count: 22050)
        let (out, latency) = roundTrip(rate: 44100, via: 16000, input: input)
        let ideal = sine(1000, rate: 44100, count: out.count, delay: latency)
        XCTAssertLessThan(rms(zip(out, ideal).map { $0 - $1 }[4000...]), 1e-3)
    }

    func testDecimationRejectsAboveNewNyquist() {
        let down = Resampler(inputRate: 48000, outputRate: 16000)
        let input = sine(12000, rate: 48000, count: 24000)
        let out = input.withUnsafeBufferPointer { down.process($0) }
        XCTAssertEqual(out.count, 8000)
        XCTAssertLessThan(rms(out[2000...]), 1e-3, "8 kHz üstü katlanmaz")
    }
}
