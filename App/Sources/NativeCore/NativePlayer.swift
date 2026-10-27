import AVFoundation
import CoreMedia
import Foundation

/// Kendi oynatma hattımız (S2.2, S3): libavformat demux →
/// - Nit: VideoToolbox → kare kuyruğu; Referans: sıkıştırılmış örnekler → `AVSampleBufferVideoRenderer` (AS-1).
/// - Ses: `AVSampleBufferAudioRenderer`; E-AC-3 JOC sıkıştırılmış (Atmos, AS-9), diğerleri FFmpeg → PCM (AS-10).
/// Saat: `AVSampleBufferRenderSynchronizer` (ses varken ses donanımının saatine bağlı); Nit kareleri ve Referans
/// katmanı aynı saati izler. Demux thread'i bloklamayan bir olay döngüsüdür: video, ses ve okuma sırayla ilerler;
/// böylece dolu video kuyruğu sesi aç bırakmaz.
final class NativePlayer: @unchecked Sendable {
    enum Output: Equatable {
        case nit
        case reference
    }

    let info: VideoStreamInfo
    let audioInfo: AudioStreamInfo?
    /// Ses akışı var ama çözücü açılamadıysa nedeni.
    let audioOpenError: String?
    let frames = FrameQueue(capacity: 6)
    let synchronizer: AVSampleBufferRenderSynchronizer
    var timebase: CMTimebase { synchronizer.timebase }

    /// Döngü başa sardığında (ana thread'de).
    var onLoop: (() -> Void)?
    /// Kod çözme ya da Referans hatası (ana thread'de).
    var onError: ((String) -> Void)?
    /// Referans yoluna gidecek paketi yeniden yazar (S2.3: P7 → P8.1 RPU dönüşümü). `nil` dönerse paket değişmez.
    var referencePacketRewriter: ((DemuxedPacket) -> Data?)?
    /// Nit yolundaki her paket için (S2.3: RPU'dan L1 okuma).
    var nitPacketObserver: ((DemuxedPacket) -> Void)?

    private let demuxer: NativeDemuxer
    private let nitFormat: CMVideoFormatDescription
    private var referenceFormat: CMVideoFormatDescription
    private var decoder: NativeVideoDecoder?
    private var videoRenderer: AVSampleBufferVideoRenderer?
    private let audioRenderer: AVSampleBufferAudioRenderer
    private let audio: NativeAudioPipeline?

    private let lock = NSLock()
    private var output: Output
    private var pendingSeek: (target: Double, keepAudio: Bool)?
    private var stopped = false
    private var playing = true
    private var clockStarted = false
    private var loopEnabled = true
    private var audioStatusValue: NativeAudioStatus?
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)

    // Yalnızca demux thread'i.
    private var videoPending: [DemuxedPacket] = []
    private var videoPendingBytes = 0
    private var audioPending: [CMSampleBuffer] = []
    private var audioEnqueuedUntil: CMTime?
    /// Bu zamandan önce başlayan ses atlanır (sarma hedefi ya da yol değişiminde zaten kuyruğa girmiş ses).
    private var audioSkipUntil: CMTime?
    /// Saatin başlayacağı medya zamanı; `nil` ise ilk karenin zamanı (açılış).
    private var clockStart: Double?
    private var clockWaitBegan = CACurrentMediaTime()
    private var endOfFile = false
    private var endTime = 0.0
    private var referenceEnqueued = false
    private var firstReferencePTS: Double?
    /// Açılış ve sarmadan sonra ilk anahtar kareye kadar paketler atlanır.
    private var awaitingKeyframe = true
    private var skippedBeforeKeyframe = 0
    private var reportedAudioRenderer = false

    private static let maxVideoPackets = 360
    private static let maxVideoBytes = 64 << 20
    /// Renderer'ın kendi tamponunun önünde hazır tutulan ses (s).
    private static let audioLead = 2.0
    private static let audioHardCap = 10.0

    init(path: String, output: Output, synchronizer: AVSampleBufferRenderSynchronizer,
         audioRenderer: AVSampleBufferAudioRenderer) throws {
        let demuxer = try NativeDemuxer(path: path)
        guard let nitFormat = FormatDescriptions.make(demuxer.info, forReference: false),
              let referenceFormat = FormatDescriptions.make(demuxer.info, forReference: true) else {
            throw DemuxError.open("format açıklaması oluşturulamadı")
        }
        var pipeline: NativeAudioPipeline?
        var audioError: String?
        if let stream = demuxer.audio {
            do {
                pipeline = try NativeAudioPipeline(stream: stream)
            } catch {
                audioError = error.localizedDescription
            }
        }
        self.demuxer = demuxer
        self.info = demuxer.info
        self.audioInfo = demuxer.audio
        self.audioOpenError = audioError
        self.audio = pipeline
        self.audioStatusValue = pipeline?.status
        self.nitFormat = nitFormat
        self.referenceFormat = referenceFormat
        self.synchronizer = synchronizer
        self.audioRenderer = audioRenderer
        self.output = output
    }

    /// Referans katmanının oluşturucusu ana thread'de bağlanır; katman synchronizer'a eklidir.
    func attach(renderer: AVSampleBufferVideoRenderer) {
        lock.lock()
        videoRenderer = renderer
        lock.unlock()
    }

    /// P7 → P8.1 dönüşümünde Referans format açıklaması değişir (S2.3).
    func setReferenceDovi(_ config: DoviConfig) {
        guard let format = FormatDescriptions.make(info, forReference: true, doviOverride: config) else { return }
        lock.lock()
        referenceFormat = format
        lock.unlock()
    }

    /// Yalnızca ekrana bağlanan oyuncu çağırır; paylaşılan saat burada sıfırlanır.
    func start() {
        synchronizer.setRate(0, time: .zero)
        clockWaitBegan = CACurrentMediaTime()
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "arif.demux"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    /// Durdurur ve demux thread'inin çıkmasını bekler (en çok 0,5 s): paylaşılan renderer'lara sonraki
    /// dosyanın oyuncusundan başka kimse yazmasın. Hiç başlatılmamış oyuncu (geç kalan açılış) paylaşılan
    /// saate ve renderer'lara dokunmaz; o sırada çalan dosyayı etkilemez.
    func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        let renderer = videoRenderer
        lock.unlock()
        frames.cancel()
        guard thread != nil, !wasStopped else { return }
        synchronizer.rate = 0
        _ = finished.wait(timeout: .now() + 0.5)
        audioRenderer.flush()
        renderer?.flush()
    }

    var loop: Bool {
        get { lock.lock(); defer { lock.unlock() }; return loopEnabled }
        set { lock.lock(); loopEnabled = newValue; lock.unlock() }
    }

    var isPlaying: Bool {
        lock.lock()
        defer { lock.unlock() }
        return playing
    }

    var currentOutput: Output {
        lock.lock()
        defer { lock.unlock() }
        return output
    }

    /// Ses hattının son durumu (HUD).
    var audioStatus: NativeAudioStatus? {
        lock.lock()
        defer { lock.unlock() }
        return audioStatusValue
    }

    var mediaTime: Double {
        let t = CMTimebaseGetTime(timebase).seconds
        return t.isFinite ? t : 0
    }

    /// Verilen ana makine zamanındaki (CADisplayLink.targetTimestamp) medya zamanı.
    func mediaTime(atHostTime hostTime: CFTimeInterval) -> Double {
        let host = CMTime(seconds: hostTime, preferredTimescale: 1_000_000_000)
        let t = CMSyncConvertTime(host, from: CMClockGetHostTimeClock(), to: timebase).seconds
        return t.isFinite ? t : mediaTime
    }

    func setPlaying(_ value: Bool) {
        lock.lock()
        playing = value
        let started = clockStarted
        lock.unlock()
        if started { synchronizer.rate = value ? 1 : 0 }
    }

    func seek(to seconds: Double) {
        lock.lock()
        pendingSeek = (max(seconds, 0), false)
        lock.unlock()
        frames.cancel()
    }

    /// Yol değişimi: yalnızca etkin video yolu beslenir; o anki zamana sarılarak yeniden doldurulur.
    /// Saat ve ses kesilmez (K6).
    func setOutput(_ newOutput: Output) {
        lock.lock()
        let changed = newOutput != output
        output = newOutput
        if changed { pendingSeek = (mediaTime, true) }
        lock.unlock()
        if changed { frames.cancel() }
    }

    // MARK: Demux thread'i

    private func run() {
        defer {
            decoder = nil
            finished.signal()
        }
        while true {
            lock.lock()
            if stopped {
                lock.unlock()
                return
            }
            let seek = pendingSeek
            pendingSeek = nil
            let out = output
            let renderer = videoRenderer
            let referenceFormat = self.referenceFormat
            let playing = self.playing
            lock.unlock()

            if let seek {
                performSeek(to: seek.target, keepAudio: seek.keepAudio, renderer: renderer)
                continue
            }

            var worked = false
            if let packet = videoPending.first,
               feedVideo(packet, output: out, renderer: renderer, referenceFormat: referenceFormat) {
                videoPending.removeFirst()
                videoPendingBytes -= packet.data.count
                worked = true
            }
            if !audioPending.isEmpty, audioRenderer.isReadyForMoreMediaData {
                let sample = audioPending.removeFirst()
                audioRenderer.enqueue(sample)
                audioEnqueuedUntil = Self.end(of: sample)
                checkAudioRenderer()
                worked = true
            }
            if wantsInput() {
                if let packet = demuxer.readPacket() {
                    route(packet)
                } else {
                    endOfFile = true
                }
                worked = true
            }
            startClockIfReady(output: out, playing: playing)

            if endOfFile, videoPending.isEmpty, audioPending.isEmpty, loop, mediaTime >= endTime - 0.05 {
                performSeek(to: 0, keepAudio: false, renderer: renderer)
                DispatchQueue.main.async { [weak self] in self?.onLoop?() }
                continue
            }
            if !worked { Thread.sleep(forTimeInterval: 0.004) }
        }
    }

    /// Okumaya devam edilsin mi? Video ve ses tamponları sınırlıdır; video açken ses sınırı gevşer.
    private func wantsInput() -> Bool {
        guard !endOfFile else { return false }
        guard videoPending.count < Self.maxVideoPackets, videoPendingBytes < Self.maxVideoBytes else { return false }
        guard audio != nil else { return true }
        let buffered = audioPendingSeconds()
        if videoPending.isEmpty { return buffered < Self.audioHardCap }
        return buffered < Self.audioLead
    }

    private func audioPendingSeconds() -> Double {
        guard let first = audioPending.first, let last = audioPending.last else { return 0 }
        let span = (Self.end(of: last) - CMSampleBufferGetPresentationTimeStamp(first)).seconds
        return span.isFinite ? span : 0
    }

    private func route(_ packet: DemuxedPacket) {
        switch packet.kind {
        case .video:
            if packet.pts.isValid {
                let end = packet.pts.seconds + (packet.duration.isValid ? packet.duration.seconds : 0)
                endTime = max(endTime, end)
            }
            videoPending.append(packet)
            videoPendingBytes += packet.data.count
        case .audio:
            guard let audio else { return }
            for sample in audio.process(packet) {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if let skip = audioSkipUntil {
                    // 1 ms pay: tam sınırdaki örnek atılmaz.
                    if pts.isValid, (pts + CMTime(value: 1, timescale: 1000)) < skip { continue }
                    audioSkipUntil = nil
                }
                audioPending.append(sample)
            }
            lock.lock()
            audioStatusValue = audio.status
            lock.unlock()
        }
    }

    /// Bir video paketini etkin yola verir. `false`: yol şu an dolu, paket sırada kalır.
    private func feedVideo(_ packet: DemuxedPacket, output: Output, renderer: AVSampleBufferVideoRenderer?,
                           referenceFormat: CMVideoFormatDescription) -> Bool {
        // TS'de akış GOP ortasından başlayabilir; anahtar karesi hiç işaretlenmemiş dosyalar için sınır var.
        if awaitingKeyframe, !packet.keyframe, skippedBeforeKeyframe < 600 {
            skippedBeforeKeyframe += 1
            return true
        }
        awaitingKeyframe = false

        switch output {
        case .nit:
            guard frames.tryReserve() else { return false }
            nitPacketObserver?(packet)
            guard let sample = FormatDescriptions.sampleBuffer(packet, format: nitFormat) else {
                frames.release()
                return true
            }
            if decoder == nil {
                decoder = NativeVideoDecoder(format: nitFormat, tenBit: info.bitDepth > 8 || info.isHDR, fullRange: info.fullRange,
                                             queue: frames)
                if decoder == nil { report("VideoToolbox oturumu açılamadı") }
            }
            guard let decoder else {
                frames.release()
                return true
            }
            if !decoder.decode(sample), decoder.lastError != noErr {
                report("VideoToolbox çözme hatası \(decoder.lastError)")
            }
            return true
        case .reference:
            guard let renderer, renderer.isReadyForMoreMediaData else { return false }
            let data = referencePacketRewriter?(packet)
            guard let sample = FormatDescriptions.sampleBuffer(packet, format: referenceFormat, data: data) else { return true }
            renderer.enqueue(sample)
            if !referenceEnqueued {
                referenceEnqueued = true
                firstReferencePTS = packet.pts.isValid ? packet.pts.seconds : 0
            }
            if renderer.status == .failed {
                report("Referans oluşturucu hatası: \(renderer.error?.localizedDescription ?? "?")")
            }
            return true
        }
    }

    /// Saat ilk kare ve en az 0,2 s ses hazır olunca başlar (preroll). Ses gelmezse 1,5 s sonra sessiz başlar.
    private func startClockIfReady(output: Output, playing: Bool) {
        lock.lock()
        let started = clockStarted
        lock.unlock()
        guard !started else { return }
        let videoStart: Double? = switch output {
        case .nit: frames.firstPTS
        case .reference: referenceEnqueued ? firstReferencePTS : nil
        }
        guard let first = videoStart else { return }
        let start = clockStart ?? first
        if audio != nil, !endOfFile, CACurrentMediaTime() - clockWaitBegan < 1.5 {
            let buffered = audioEnqueuedUntil.map { $0.seconds - start } ?? -1
            guard buffered >= 0.2 else { return }
        }
        lock.lock()
        clockStarted = true
        lock.unlock()
        synchronizer.setRate(playing ? 1 : 0, time: CMTime(seconds: start, preferredTimescale: 90_000))
    }

    /// - Parameter keepAudio: Yol değişimi: saat ve ses sürer, zaten kuyruğa girmiş ses yeniden okunurken atlanır.
    private func performSeek(to target: Double, keepAudio: Bool, renderer: AVSampleBufferVideoRenderer?) {
        frames.clear()
        decoder?.flush()
        frames.clear()
        renderer?.flush()
        videoPending.removeAll()
        videoPendingBytes = 0
        demuxer.seek(to: target)
        awaitingKeyframe = true
        skippedBeforeKeyframe = 0
        endOfFile = false
        referenceEnqueued = false
        firstReferencePTS = nil
        audio?.flush()
        if keepAudio {
            audioSkipUntil = audioPending.last.map { Self.end(of: $0) } ?? audioEnqueuedUntil
        } else {
            audioRenderer.flush()
            audioPending.removeAll()
            audioEnqueuedUntil = nil
            let time = CMTime(seconds: target, preferredTimescale: 90_000)
            audioSkipUntil = time
            clockStart = target
            clockWaitBegan = CACurrentMediaTime()
            lock.lock()
            clockStarted = false
            lock.unlock()
            synchronizer.setRate(0, time: time)
        }
        frames.resume()
    }

    private func checkAudioRenderer() {
        guard !reportedAudioRenderer, audioRenderer.status == .failed else { return }
        reportedAudioRenderer = true
        report("Ses oluşturucu hatası: \(audioRenderer.error?.localizedDescription ?? "?")")
    }

    private static func end(of sample: CMSampleBuffer) -> CMTime {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let duration = CMSampleBufferGetDuration(sample)
        return duration.isValid ? pts + duration : pts
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }
}
