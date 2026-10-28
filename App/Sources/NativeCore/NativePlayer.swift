import AVFoundation
import CoreMedia
import Foundation
import MediaIO

/// Kendi oynatma hattımız (S2.2, S3): libavformat demux →
/// - Nit: VideoToolbox → kare kuyruğu; Referans: sıkıştırılmış örnekler → `AVSampleBufferVideoRenderer` (AS-1).
/// - Ses: `AVSampleBufferAudioRenderer`; E-AC-3 JOC sıkıştırılmış (Atmos, AS-9), diğerleri FFmpeg → PCM (AS-10).
/// Saat: `AVSampleBufferRenderSynchronizer` (ses varken ses donanımının saatine bağlı); Nit kareleri ve Referans
/// katmanı aynı saati izler. Demux thread'i bloklamayan bir olay döngüsüdür: video, ses ve okuma sırayla ilerler;
/// böylece dolu video kuyruğu sesi aç bırakmaz.
/// M9 (S4) ve M10 (S5): ham ses, renderer'a girmeden hemen önce `AudioStage`'den geçer. Ayar değişince renderer
/// `flush(fromSourceTime:)` ile ~0,5 s ileriden kesilir ve son birkaç saniyenin ham sesinden yeniden işlenir;
/// kesim ham örnek sınırına düştüğünden dikişsizdir. Arka planda video atılır, ses sürer (F1).
final class NativePlayer: @unchecked Sendable {
    enum Output: Equatable {
        case nit
        case reference
    }

    /// Video akışı; müzik dosyasında (yalnızca ses, S6) `nil`.
    let info: VideoStreamInfo?
    /// Dosyanın süresi (s).
    let duration: Double
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
    /// Bilgi olayı (ana thread'de; ör. ağ kesintisinden kurtarma).
    var onNotice: ((String) -> Void)?
    /// Referans yoluna gidecek paketi yeniden yazar (S2.3: P7 → P8.1 RPU dönüşümü). `nil` dönerse paket değişmez.
    var referencePacketRewriter: ((DemuxedPacket) -> Data?)?
    /// Nit yolundaki her paket için (S2.3: RPU'dan L1 okuma).
    var nitPacketObserver: ((DemuxedPacket) -> Void)?

    private let demuxer: NativeDemuxer
    private let nitFormat: CMVideoFormatDescription?
    private var referenceFormat: CMVideoFormatDescription?
    private var decoder: NativeVideoDecoder?
    private var videoRenderer: AVSampleBufferVideoRenderer?
    private let audioRenderer: AVSampleBufferAudioRenderer
    private let audio: NativeAudioPipeline?
    private let stage: AudioStage?

    private let lock = NSLock()
    private var output: Output
    private var pendingSeek: (target: Double, keepAudio: Bool)?
    private var stopped = false
    private var playing = true
    private var clockStarted = false
    private var loopEnabled = true
    private var audioStatusValue: NativeAudioStatus?
    private var stageSettings = AudioStageSettings()
    private var stageDirty = false
    /// Etkin evreden geçişe (Atmos'a) dönüş isteği zamanı: 2 s beklenir, sürekli geçiş olmasın (§5.5).
    private var passthroughRequestedAt: CFTimeInterval?
    private var backgroundRequested = false
    private var flushResult: (generation: Int, ok: Bool)?
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)
    /// Açılış ve sarma süreleri (S7, AS-3: sarma < 1,5 s).
    private let createdAt = CACurrentMediaTime()
    private var seekRequestedAt: CFTimeInterval?
    private var timingValue = PlaybackTiming()

    // Yalnızca demux thread'i.
    private var videoPending: [DemuxedPacket] = []
    private var videoPendingBytes = 0
    /// Ham (evre öncesi) ses örnekleri.
    private var audioPending: [CMSampleBuffer] = []
    /// Evreden çıkmış, renderer'a girmeyi bekleyen örnekler.
    private var audioReady: [CMSampleBuffer] = []
    /// Evreye verilmiş ham örnekler (son ~12 s): yeniden işleme bunlardan yapılır.
    private var audioHistory: [CMSampleBuffer] = []
    /// Renderer'a verilmiş örneklerin zaman aralıkları (yakın geçmiş): flush'ın kestiği sınırı bulmak için.
    /// Renderer'a verilmiş örnekler (yakın geçmiş): flush'ın kestiği sınır ve çapraz geçiş için eski yolun çıktısı.
    private var enqueuedSpans: [(pts: CMTime, end: CMTime, sample: CMSampleBuffer)] = []
    private var flushGeneration = 0
    private var flushWaiting: (generation: Int, time: CMTime, began: CFTimeInterval)?
    private var backgroundApplied = false
    private var drained = false
    /// Son açılış/sarmadan beri renderer'a giren ilk ses örneğinin PTS'i (videosuz saat başlangıcı).
    private var firstAudioPTS: Double?
    /// Son sarma hedefi: bundan önceki ses yalnızca ısınmadır, çalınmaz.
    private var audioFloor: CMTime = .zero
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
    /// Ağ okuması kalıcı hata verdiyse yeniden deneme zamanı (dosya sonu sayılmaz, döngü başa sarmaz).
    private var readRetryAt: CFTimeInterval?
    private var lastVideoPacketTime: Double?

    private static let maxVideoPackets = 360
    private static let maxVideoBytes = 64 << 20
    /// Renderer'ın kendi tamponunun önünde hazır tutulan ses (s).
    private static let audioLead = 2.0
    private static let audioHardCap = 10.0
    /// Yeniden işlemede kesimin oynatma başının ne kadar önünde yapılacağı ve ısınma süresi (s).
    /// AU çalışıyorsa yeniden işleme ağırdır (≈ 0,5 s); yalnızca DSP ise ≤ 100 ms tepki hedeflenir (AS-37 d).
    private static let reprocessLeadHeavy = 0.5
    private static let reprocessLeadLight = 0.12
    private static let crossfadeSeconds = 0.020
    private static let reprocessWarmup = 1.5
    private static let historySeconds = 12.0

    /// - Parameter integerAudio: Kayıpsız kaynakta renderer'a tamsayı PCM (S6, bit-perfect yolu).
    init(input: MediaInput, output: Output, synchronizer: AVSampleBufferRenderSynchronizer,
         audioRenderer: AVSampleBufferAudioRenderer, integerAudio: Bool = true) throws {
        let demuxer = try NativeDemuxer(input: input)
        var nitFormat: CMVideoFormatDescription?
        var referenceFormat: CMVideoFormatDescription?
        if let video = demuxer.info {
            guard let nit = FormatDescriptions.make(video, forReference: false),
                  let reference = FormatDescriptions.make(video, forReference: true) else {
                throw DemuxError.open("format açıklaması oluşturulamadı")
            }
            nitFormat = nit
            referenceFormat = reference
        }
        var pipeline: NativeAudioPipeline?
        var audioError: String?
        if let stream = demuxer.audio {
            do {
                pipeline = try NativeAudioPipeline(stream: stream, integerOutput: integerAudio)
            } catch {
                audioError = error.localizedDescription
            }
        }
        self.demuxer = demuxer
        self.info = demuxer.info
        self.duration = demuxer.info?.duration ?? demuxer.duration
        self.audioInfo = demuxer.audio
        self.audioOpenError = audioError
        self.audio = pipeline
        self.stage = pipeline != nil ? AudioStage() : nil
        self.audioStatusValue = pipeline?.status
        self.nitFormat = nitFormat
        self.referenceFormat = referenceFormat
        self.synchronizer = synchronizer
        self.audioRenderer = audioRenderer
        self.output = output
        stage?.onIsolationChange = { [weak self] in self?.markStageDirty() }
    }

    /// Referans katmanının oluşturucusu ana thread'de bağlanır; katman synchronizer'a eklidir.
    func attach(renderer: AVSampleBufferVideoRenderer) {
        lock.lock()
        videoRenderer = renderer
        lock.unlock()
    }

    /// P7 → P8.1 dönüşümünde Referans format açıklaması değişir (S2.3).
    func setReferenceDovi(_ config: DoviConfig) {
        guard let info, let format = FormatDescriptions.make(info, forReference: true, doviOverride: config) else { return }
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
        // Ağdan veri beklerken bloklanmış demux okuması hemen bırakılır.
        demuxer.interrupt()
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

    /// Saat çalışıyor mu (açılış/sarma sonrası ilk kare ve ses hazır)?
    var isClockRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return clockStarted
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

    /// Akış girdisinin önden okuma ölçümleri (SMB, Dosyalar'ın ağ konumları); yerel dosyada `nil`.
    var networkStats: ReadAheadStats? { demuxer.stream?.stats }
    /// Akış girdisinin toplam boyutu (bayt).
    var inputSize: Int64? { demuxer.stream?.size }

    /// Açılış ve sarma süreleri, ağ kurtarmaları.
    var timing: PlaybackTiming {
        lock.lock()
        defer { lock.unlock() }
        return timingValue
    }

    /// M9 durumu (HUD, CSV); ses yoksa `nil`.
    var audioStageStatus: AudioStageStatus? { stage?.status }

    /// M10 göstergeleri: PTS'i oynatma noktasına kadar olan kayıtlar (o an duyulan sesle hizalı).
    func takeAudioMeters() -> [AudioMeterRecord] {
        stage?.takeMeters(until: mediaTime) ?? []
    }

    /// M9/M10 ayarları ve rota. Demux thread'i, çalmakta olan sesi kesip yeniden işleyerek uygular
    /// (yalnızca DSP ise ≈ 0,12 s, AU varsa ≈ 0,5 s içinde duyulur).
    func setAudioStage(_ settings: AudioStageSettings) {
        lock.lock()
        if settings != stageSettings {
            stageSettings = settings
            stageDirty = true
        }
        lock.unlock()
    }

    /// Uygulama arka plana geçti/döndü: arka planda video atılır, diyalog F1'e geçer (çapraz geçişle);
    /// dönüşte video o anki zamandan yeniden doldurulur, ses kesilmez.
    func setBackground(_ value: Bool) {
        lock.lock()
        let changed = value != backgroundRequested
        backgroundRequested = value
        if changed, !value { pendingSeek = (mediaTime, true) }
        lock.unlock()
        if changed, !value { frames.cancel() }
    }

    private func markStageDirty() {
        lock.lock()
        stageDirty = true
        lock.unlock()
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
        seekRequestedAt = CACurrentMediaTime()
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
            let background = backgroundRequested
            let stageChanged = stageDirty
            let flushDone = flushResult
            flushResult = nil
            lock.unlock()

            if let seek {
                performSeek(to: seek.target, keepAudio: seek.keepAudio, renderer: renderer)
                continue
            }

            var worked = false
            if let stage {
                if background != backgroundApplied {
                    backgroundApplied = background
                    stage.setBackground(background)
                }
                if let done = flushDone, let waiting = flushWaiting, done.generation == waiting.generation {
                    finishReprocess(ok: done.ok, waiting: waiting)
                    worked = true
                } else if stageChanged, flushWaiting == nil, !holdPassthrough(stage) {
                    beginReprocess()
                }
            }
            if background {
                // Ekran yokken kareler tüketilmez; video beklerse ses aç kalırdı.
                videoPending.removeAll()
                videoPendingBytes = 0
            } else if let packet = videoPending.first,
                      feedVideo(packet, output: out, renderer: renderer, referenceFormat: referenceFormat) {
                videoPending.removeFirst()
                videoPendingBytes -= packet.data.count
                worked = true
            }
            if flushWaiting == nil, audioRenderer.isReadyForMoreMediaData {
                if audioReady.isEmpty, !audioPending.isEmpty {
                    let raw = audioPending.removeFirst()
                    remember(raw)
                    audioReady += stage?.process(raw) ?? [raw]
                    worked = true
                }
                if !audioReady.isEmpty {
                    enqueueAudio(audioReady.removeFirst())
                    worked = true
                }
            }
            if let retryAt = readRetryAt, CACurrentMediaTime() >= retryAt {
                // Ağ kesintisinden kurtarma: son okunan video paketinden (yoksa oynatma noktasından) yeniden okunur;
                // saat ve ses sürer, kuyruğa girmiş ses atlanır.
                readRetryAt = nil
                demuxer.recover()
                performSeek(to: lastVideoPacketTime ?? mediaTime, keepAudio: true, renderer: renderer)
                continue
            }
            if readRetryAt == nil, wantsInput() {
                if let packet = demuxer.readPacket() {
                    if packet.kind == .video, packet.pts.isValid { lastVideoPacketTime = packet.pts.seconds }
                    route(packet, background: background)
                } else if let error = demuxer.readError, demuxer.stream != nil {
                    lock.lock()
                    timingValue.recoveries += 1
                    let stopping = stopped
                    lock.unlock()
                    if !stopping {
                        notice("Ağ okuması başarısız (\(error)); 1 s sonra yeniden denenecek")
                        readRetryAt = CACurrentMediaTime() + 1
                    }
                } else {
                    endOfFile = true
                    // FLAC: baştan sona kesintisiz çözüldüyse STREAMINFO MD5'i karşılaştırılır (S6).
                    if let audio {
                        audio.finishVerification()
                        lock.lock()
                        audioStatusValue = audio.status
                        lock.unlock()
                    }
                }
                worked = true
            }
            if endOfFile, audioPending.isEmpty, audioReady.isEmpty, !drained, let stage {
                drained = true
                audioReady += stage.drain()
            }
            startClockIfReady(output: out, playing: playing, background: background)

            if endOfFile, videoPending.isEmpty, audioPending.isEmpty, audioReady.isEmpty, loop, mediaTime >= endTime - 0.05 {
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

    private func route(_ packet: DemuxedPacket, background: Bool) {
        switch packet.kind {
        case .video:
            if packet.pts.isValid {
                let end = packet.pts.seconds + (packet.duration.isValid ? packet.duration.seconds : 0)
                endTime = max(endTime, end)
            }
            guard !background else { return }
            videoPending.append(packet)
            videoPendingBytes += packet.data.count
        case .audio:
            guard let audio else { return }
            for sample in audio.process(packet) {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                // Yalnızca-ses dosyada döngü sonu sesten belirlenir.
                if info == nil, pts.isValid { endTime = max(endTime, Self.end(of: sample).seconds) }
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
                           referenceFormat: CMVideoFormatDescription?) -> Bool {
        guard let info, let nitFormat, let referenceFormat else { return true }
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
    /// Arka planda (ör. döngü başa sarınca) kare beklenmez.
    private func startClockIfReady(output: Output, playing: Bool, background: Bool) {
        lock.lock()
        let started = clockStarted
        lock.unlock()
        guard !started else { return }
        let videoStart: Double?
        if background || info == nil {
            // Ekran yok ya da video yok: saat ilk ses örneğiyle başlar.
            videoStart = clockStart ?? firstAudioPTS
        } else {
            switch output {
            case .nit: videoStart = frames.firstPTS
            case .reference: videoStart = referenceEnqueued ? firstReferencePTS : nil
            }
        }
        guard let first = videoStart else { return }
        let start = clockStart ?? first
        if audio != nil, !endOfFile, CACurrentMediaTime() - clockWaitBegan < 1.5 {
            let buffered = audioEnqueuedUntil.map { $0.seconds - start } ?? -1
            guard buffered >= 0.2 else { return }
        }
        let now = CACurrentMediaTime()
        lock.lock()
        clockStarted = true
        if let requested = seekRequestedAt {
            // Kullanıcı sarması: istekten saatin yeniden başlamasına (ilk kare + 0,2 s ses hazır).
            let ms = (now - requested) * 1000
            timingValue.lastSeekMs = ms
            timingValue.maxSeekMs = max(timingValue.maxSeekMs ?? 0, ms)
            timingValue.seeks += 1
            seekRequestedAt = nil
        } else if timingValue.startupMs == nil {
            timingValue.startupMs = (now - createdAt) * 1000
        }
        lock.unlock()
        synchronizer.setRate(playing ? 1 : 0, time: CMTime(seconds: start, preferredTimescale: 90_000))
    }

    /// - Parameter keepAudio: Yol değişimi: saat ve ses sürer, zaten kuyruğa girmiş ses yeniden okunurken atlanır.
    private func performSeek(to target: Double, keepAudio: Bool, renderer: AVSampleBufferVideoRenderer?) {
        if readRetryAt != nil {
            // Kullanıcı kurtarma beklerken sardı: hata durumu temizlenip yeni hedeften okunur.
            readRetryAt = nil
            demuxer.recover()
        }
        frames.clear()
        decoder?.flush()
        frames.clear()
        renderer?.flush()
        videoPending.removeAll()
        videoPendingBytes = 0
        lastVideoPacketTime = nil
        demuxer.seek(to: target)
        awaitingKeyframe = true
        skippedBeforeKeyframe = 0
        endOfFile = false
        referenceEnqueued = false
        firstReferencePTS = nil
        audio?.flush()
        if keepAudio {
            // Evreye verilmiş son ham örnekten devam edilir; evre sıfırlanmaz (ses kesilmez).
            audioSkipUntil = audioPending.last.map { Self.end(of: $0) } ?? audioHistory.last.map { Self.end(of: $0) }
                ?? audioEnqueuedUntil
        } else {
            audioRenderer.flush()
            audioPending.removeAll()
            audioReady.removeAll()
            audioHistory.removeAll()
            enqueuedSpans.removeAll()
            audioEnqueuedUntil = nil
            firstAudioPTS = nil
            drained = false
            let time = CMTime(seconds: target, preferredTimescale: 90_000)
            audioFloor = time
            if let stage {
                // Hedef öncesi ses (anahtar kareden hedefe) ısınma olarak işlenir, çıktısı atılır (§5.4).
                flushGeneration += 1
                flushWaiting = nil
                passthroughRequestedAt = nil
                lock.lock()
                stageDirty = false
                lock.unlock()
                stage.apply(effectiveStageSettings())
                stage.reset(startAt: time, settleSeconds: Self.reprocessWarmup, seek: true)
                audioSkipUntil = nil
            } else {
                audioSkipUntil = time
            }
            clockStart = target
            clockWaitBegan = CACurrentMediaTime()
            lock.lock()
            clockStarted = false
            lock.unlock()
            synchronizer.setRate(0, time: time)
        }
        frames.resume()
    }

    // MARK: Ses çıkışı ve M9 yeniden işleme

    private func enqueueAudio(_ sample: CMSampleBuffer) {
        audioRenderer.enqueue(sample)
        let end = Self.end(of: sample)
        audioEnqueuedUntil = end
        enqueuedSpans.append((CMSampleBufferGetPresentationTimeStamp(sample), end, sample))
        if firstAudioPTS == nil { firstAudioPTS = CMSampleBufferGetPresentationTimeStamp(sample).seconds }
        if enqueuedSpans.count > 512 {
            let horizon = CMTime(seconds: mediaTime - 2, preferredTimescale: 90_000)
            enqueuedSpans.removeAll { $0.end < horizon }
        }
        checkAudioRenderer()
    }

    private func remember(_ raw: CMSampleBuffer) {
        audioHistory.append(raw)
        let horizon = Self.end(of: raw) - CMTime(seconds: Self.historySeconds, preferredTimescale: 90_000)
        while let first = audioHistory.first, Self.end(of: first) < horizon { audioHistory.removeFirst() }
    }

    /// Ayar değişti: renderer'daki işlenmiş ses oynatma başının `reprocessLead` önünden kesilir; sonuç gelince
    /// (`finishReprocess`) o sınırdan itibaren geçmiş yeniden işlenir. Beklerken renderer'a ses verilmez.
    private func beginReprocess() {
        guard audioEnqueuedUntil != nil else {
            // Henüz renderer'a ses girmedi: hazır bekleyen ses doğrudan yeniden üretilir.
            let first = audioHistory.first.map { CMSampleBufferGetPresentationTimeStamp($0) } ?? .zero
            regenerate(from: CMTimeMaximum(first, audioFloor))
            return
        }
        lock.lock()
        let started = clockStarted
        lock.unlock()
        let now = started ? mediaTime : (clockStart ?? 0)
        let heavy = usesIsolation(stage?.settings) || usesIsolation(effectiveStageSettings())
        let lead = heavy ? Self.reprocessLeadHeavy : Self.reprocessLeadLight
        let time = CMTime(seconds: now + lead, preferredTimescale: 90_000)
        flushGeneration += 1
        let generation = flushGeneration
        flushWaiting = (generation, time, CACurrentMediaTime())
        audioRenderer.flush(fromSourceTime: time) { [weak self] ok in self?.flushFinished(generation: generation, ok: ok) }
    }

    private func flushFinished(generation: Int, ok: Bool) {
        lock.lock()
        flushResult = (generation, ok)
        lock.unlock()
    }

    private func finishReprocess(ok: Bool, waiting: (generation: Int, time: CMTime, began: CFTimeInterval)) {
        flushWaiting = nil
        // Renderer, PTS'i kesim zamanından küçük örnekleri tutar: devam noktası ilk atılan örneğin başıdır (ham
        // örnek sınırı). Flush yapılamadıysa (zaman geçmiş) renderer'daki her şey çalar; devam onun sonundan.
        var resumeAt = audioEnqueuedUntil ?? waiting.time
        if ok, let first = enqueuedSpans.first(where: { $0.pts >= waiting.time }) { resumeAt = first.pts }
        let flushed = ok ? enqueuedSpans.filter { $0.pts >= resumeAt }.map(\.sample) : []
        enqueuedSpans.removeAll { $0.pts >= resumeAt }
        if ok, let end = audioEnqueuedUntil, resumeAt < end { audioEnqueuedUntil = resumeAt }
        regenerate(from: resumeAt)
        // Eski yolun atılan çıktısı ile yeni yol 20 ms doğrusal geçişle birleşir: tıklama olmaz (AS-37 d).
        NativeAudioPipeline.crossfade(&audioReady, old: flushed, start: resumeAt, seconds: Self.crossfadeSeconds)
        stage?.noteReprocess(milliseconds: (CACurrentMediaTime() - waiting.began) * 1000)
    }

    /// Son ayarlarla, `resumeAt`'ten itibaren çalınacak sesi geçmişten yeniden üretir (öncesi ısınma).
    private func regenerate(from resumeAt: CMTime) {
        guard let stage else { return }
        lock.lock()
        stageDirty = false
        lock.unlock()
        passthroughRequestedAt = nil
        stage.apply(effectiveStageSettings())
        let warmStart = resumeAt - CMTime(seconds: Self.reprocessWarmup, preferredTimescale: 90_000)
        let firstUsed = audioHistory.firstIndex { Self.end(of: $0) > warmStart } ?? audioHistory.count
        let settle = audioHistory.indices.contains(firstUsed)
            ? max((resumeAt - CMSampleBufferGetPresentationTimeStamp(audioHistory[firstUsed])).seconds, 0) : 0
        stage.reset(startAt: resumeAt, settleSeconds: settle, seek: false)
        audioReady.removeAll()
        drained = false
        for raw in audioHistory[firstUsed...] {
            audioReady += stage.process(raw, warm: true)
        }
    }

    /// "Atmos'u koru": Atmos içerikte boost %100'e kilitlenir (ses sıkıştırılmış kalır).
    private func effectiveStageSettings() -> AudioStageSettings {
        lock.lock()
        var settings = stageSettings
        let path = audioStatusValue?.path
        lock.unlock()
        if settings.boost.keepAtmos, path == .atmos { settings.boost.percent = 100 }
        return settings
    }

    private func usesIsolation(_ settings: AudioStageSettings?) -> Bool {
        guard let settings else { return false }
        return settings.dialog.active && settings.dialog.engine != .dsp
    }

    /// Etkin evreden sıkıştırılmış Dolby geçişine dönüş 2 s bekletilir (kaydırıcı %100'e dönüp hemen
    /// yeniden açılırsa Atmos ↔ PCM arasında gidip gelinmesin).
    private func holdPassthrough(_ stage: AudioStage) -> Bool {
        let path = audioStatus?.path
        guard stage.settings.active, !effectiveStageSettings().active, path == .atmos || path == .dolby else {
            passthroughRequestedAt = nil
            return false
        }
        let now = CACurrentMediaTime()
        guard let since = passthroughRequestedAt else {
            passthroughRequestedAt = now
            return true
        }
        return now - since < 2
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

    private func notice(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onNotice?(message) }
    }
}

/// Açılış/sarma süreleri ve ağ kurtarmaları (HUD, CSV; AS-3).
struct PlaybackTiming: Equatable {
    /// Oyuncunun oluşturulmasından saatin başlamasına (ms); açılışın ağ kısmı (bağlanma) ayrıca ölçülür.
    var startupMs: Double?
    var lastSeekMs: Double?
    var maxSeekMs: Double?
    var seeks = 0
    /// Ağ okuması kalıcı hata verip yeniden denenme sayısı.
    var recoveries = 0
}
