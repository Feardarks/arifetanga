import AudioDSP
import AVFoundation
import Foundation
import SoundAnalysis

/// Müzikli sahnelerde diyalog yükseltmesinin gevşetilmesi için sınıflandırıcı (02-cozum §5.4):
/// `SNClassifySoundRequest(.version1)`, girdi mono, pencere ≈ 1,5 s, %50 örtüşme. Analiz kendi kuyruğunda
/// yapılır (Apple'ın önerisi); sonuç gelince `relaxationTarget` güncellenir.
///
/// Sapma: karar işleme anındaki sesle verilir. İşleme oynatmanın ~1–2 s önünde olsa da sonuç pencere sonunda
/// geldiğinden `r`, içeriğin ≈ 0,75–1 s gerisinde kalır (belgedeki "ileriye bakma" yok).
final class MusicDetector: NSObject, SNResultsObserving, @unchecked Sendable {
    struct Probabilities: Equatable {
        var music = 0.0
        var singing = 0.0
        var speech = 0.0
    }

    let sampleRate: Double
    let windowSeconds: Double
    private let analyzer: SNAudioStreamAnalyzer
    private let format: AVAudioFormat
    private let queue = DispatchQueue(label: "arif.music", qos: .utility)
    private let lock = NSLock()
    private var latest: Probabilities?
    private var lastErrorValue: String?
    private var inFlight = 0
    private var dropped = 0
    private var cpuSeconds = 0.0
    private var decisions = 0

    // Yalnızca besleyen thread (demux).
    private var pending: [Float] = []
    private var position: AVAudioFramePosition = 0
    private let batch: Int

    init(sampleRate: Double) throws {
        self.sampleRate = sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "Sound Analysis: \(Int(sampleRate)) Hz mono biçimi kurulamadı"])
        }
        self.format = format
        analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        let wanted = CMTime(seconds: 1.5, preferredTimescale: 48000)
        switch request.windowDurationConstraint {
        case .durationRange(let range):
            request.windowDuration = CMTimeMinimum(CMTimeMaximum(wanted, range.start), CMTimeRangeGetEnd(range))
        case .enumeratedDurations(let durations):
            if let best = durations.min(by: { abs(($0 - wanted).seconds) < abs(($1 - wanted).seconds) }) {
                request.windowDuration = best
            }
        @unknown default:
            break
        }
        request.overlapFactor = 0.5
        windowSeconds = request.windowDuration.seconds
        batch = Int(sampleRate * 0.25)
        super.init()
        try analyzer.add(request, withObserver: self)
    }

    /// Son karar; henüz yoksa `nil`.
    var probabilities: Probabilities? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    var lastError: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastErrorValue
    }

    /// Analiz kuyruğunun karar başına CPU süresi (ms; bütçe ≤ 5 ms) ve kuyruk taşınca atılan parça sayısı.
    var load: (msPerDecision: Double?, dropped: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (decisions > 0 ? cpuSeconds / Double(decisions) * 1000 : nil, dropped)
    }

    /// `r` hedefi; karar yoksa 1 (gevşeme yok).
    var relaxationTarget: Double {
        guard let p = probabilities else { return 1 }
        return MusicRelaxation.target(music: p.music, singing: p.singing, speech: p.speech)
    }

    /// Mono örnekleri ekler (demux thread'i). 0,25 s'lik parçalar halinde analiz kuyruğuna gider.
    func feed(_ mono: UnsafeBufferPointer<Float>) {
        pending.append(contentsOf: mono)
        guard pending.count >= batch else { return }
        let samples = pending
        pending.removeAll(keepingCapacity: true)
        let at = position
        position += AVAudioFramePosition(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        lock.lock()
        // Analiz geride kalırsa (ör. arka planda) kuyruk büyümesin.
        guard inFlight < 8 else {
            dropped += 1
            lock.unlock()
            return
        }
        inFlight += 1
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let start = Self.threadCPUTime()
            self.analyzer.analyze(buffer, atAudioFramePosition: at)
            let spent = Self.threadCPUTime() - start
            self.lock.lock()
            self.inFlight -= 1
            self.cpuSeconds += spent
            self.lock.unlock()
        }
    }

    /// Sarmada son karar unutulur (yeni sahne); konum tekdüze artmaya devam eder.
    func reset() {
        pending.removeAll(keepingCapacity: true)
        lock.lock()
        latest = nil
        lock.unlock()
    }

    // MARK: SNResultsObserving

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let p = Probabilities(music: result.classification(forIdentifier: "music")?.confidence ?? 0,
                              singing: result.classification(forIdentifier: "singing")?.confidence ?? 0,
                              speech: result.classification(forIdentifier: "speech")?.confidence ?? 0)
        lock.lock()
        latest = p
        decisions += 1
        lock.unlock()
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        lock.lock()
        lastErrorValue = error.localizedDescription
        latest = nil
        lock.unlock()
    }

    private static func threadCPUTime() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }
}
