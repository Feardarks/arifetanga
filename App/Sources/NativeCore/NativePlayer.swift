import AVFoundation
import CoreMedia
import Foundation

/// Kendi oynatma hattımız (S2.2): libavformat demux → Nit: VideoToolbox → kare kuyruğu,
/// Referans: sıkıştırılmış örnekler → `AVSampleBufferVideoRenderer` (sistemin HDR/DV işleyişi, AS-1).
/// Saat: ana makine saatine bağlı `CMTimebase`; Referans katmanı da aynı saati kullanır.
/// Ses S3'te gelir; bu sürüm yalnızca görüntü oynatır.
final class NativePlayer: @unchecked Sendable {
    enum Output: Equatable {
        case nit
        case reference
    }

    let info: VideoStreamInfo
    let frames = FrameQueue(capacity: 6)
    let timebase: CMTimebase

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
    private var renderer: AVSampleBufferVideoRenderer?

    private let lock = NSLock()
    private var output: Output
    private var pendingSeek: Double?
    private var stopped = false
    private var playing = true
    private var clockStarted = false
    private var loopEnabled = true
    private var thread: Thread?
    /// Açılış ve sarmadan sonra ilk anahtar kareye kadar paketler atlanır (yalnızca demux thread'i).
    private var awaitingKeyframe = true
    private var skippedBeforeKeyframe = 0

    init(path: String, output: Output) throws {
        let demuxer = try NativeDemuxer(path: path)
        guard let nitFormat = FormatDescriptions.make(demuxer.info, forReference: false),
              let referenceFormat = FormatDescriptions.make(demuxer.info, forReference: true) else {
            throw DemuxError.open("format açıklaması oluşturulamadı")
        }
        var tb: CMTimebase?
        guard CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(),
                                              timebaseOut: &tb) == noErr, let tb else {
            throw DemuxError.open("saat oluşturulamadı")
        }
        CMTimebaseSetRate(tb, rate: 0)
        self.demuxer = demuxer
        self.info = demuxer.info
        self.nitFormat = nitFormat
        self.referenceFormat = referenceFormat
        self.timebase = tb
        self.output = output
    }

    /// Referans katmanının oluşturucusu ana thread'de bağlanır; katman aynı saati kullanır.
    func attach(renderer: AVSampleBufferVideoRenderer) {
        lock.lock()
        self.renderer = renderer
        lock.unlock()
    }

    /// P7 → P8.1 dönüşümünde Referans format açıklaması değişir (S2.3).
    func setReferenceDovi(_ config: DoviConfig) {
        guard let format = FormatDescriptions.make(info, forReference: true, doviOverride: config) else { return }
        lock.lock()
        referenceFormat = format
        lock.unlock()
    }

    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "arif.demux"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        frames.cancel()
        CMTimebaseSetRate(timebase, rate: 0)
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
        if started { CMTimebaseSetRate(timebase, rate: value ? 1 : 0) }
    }

    func seek(to seconds: Double) {
        lock.lock()
        pendingSeek = max(seconds, 0)
        lock.unlock()
        frames.cancel()
    }

    /// Yol değişimi: yalnızca etkin yol beslenir; değişimde o anki zamana sarılarak yeniden doldurulur.
    func setOutput(_ newOutput: Output) {
        lock.lock()
        let changed = newOutput != output
        output = newOutput
        if changed { pendingSeek = mediaTime }
        lock.unlock()
        if changed { frames.cancel() }
    }

    // MARK: Demux thread'i

    private func run() {
        while true {
            lock.lock()
            if stopped {
                lock.unlock()
                break
            }
            let seekTarget = pendingSeek
            pendingSeek = nil
            let out = output
            let renderer = self.renderer
            let referenceFormat = self.referenceFormat
            lock.unlock()

            if let seekTarget {
                performSeek(to: seekTarget, output: out, renderer: renderer)
                continue
            }

            guard let packet = demuxer.readPacket() else {
                if loop {
                    performSeek(to: 0, output: out, renderer: renderer)
                    DispatchQueue.main.async { [weak self] in self?.onLoop?() }
                } else {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                continue
            }

            // TS'de akış GOP ortasından başlayabilir; anahtar karesi hiç işaretlenmemiş dosyalar için sınır var.
            if awaitingKeyframe, !packet.keyframe, skippedBeforeKeyframe < 600 {
                skippedBeforeKeyframe += 1
                continue
            }
            awaitingKeyframe = false

            switch out {
            case .nit:
                nitPacketObserver?(packet)
                guard let sample = FormatDescriptions.sampleBuffer(packet, format: nitFormat) else { continue }
                if decoder == nil {
                    decoder = NativeVideoDecoder(format: nitFormat, tenBit: info.bitDepth > 8 || info.isHDR, queue: frames)
                    if decoder == nil { report("VideoToolbox oturumu açılamadı") }
                }
                if let decoder, !decoder.decode(sample), decoder.lastError != noErr {
                    report("VideoToolbox çözme hatası \(decoder.lastError)")
                }
                startClockIfNeeded(firstPTS: frames.firstPTS)
            case .reference:
                guard let renderer else {
                    Thread.sleep(forTimeInterval: 0.01)
                    continue
                }
                let data = referencePacketRewriter?(packet)
                guard let sample = FormatDescriptions.sampleBuffer(packet, format: referenceFormat, data: data) else { continue }
                while !renderer.isReadyForMoreMediaData, !interrupted() {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                if interrupted() { continue }
                renderer.enqueue(sample)
                if renderer.status == .failed {
                    report("Referans oluşturucu hatası: \(renderer.error?.localizedDescription ?? "?")")
                }
                startClockIfNeeded(firstPTS: packet.pts.isValid ? packet.pts.seconds : 0)
            }
        }
        decoder = nil
    }

    private func interrupted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped || pendingSeek != nil
    }

    /// Saat ilk kare hazır olunca o karenin zamanından başlar (preroll).
    private func startClockIfNeeded(firstPTS: Double?) {
        lock.lock()
        guard !clockStarted, let firstPTS else {
            lock.unlock()
            return
        }
        clockStarted = true
        let rate: Float64 = playing ? 1 : 0
        lock.unlock()
        CMTimebaseSetTime(timebase, time: CMTime(seconds: firstPTS, preferredTimescale: 90_000))
        CMTimebaseSetRate(timebase, rate: rate)
    }

    private func performSeek(to target: Double, output: Output, renderer: AVSampleBufferVideoRenderer?) {
        frames.clear()
        decoder?.flush()
        frames.clear()
        // Yol değiştiyse de Referans katmanında eski kareler kalmasın.
        renderer?.flush()
        demuxer.seek(to: target)
        awaitingKeyframe = true
        skippedBeforeKeyframe = 0
        frames.resume()
        lock.lock()
        let rate: Float64 = playing ? 1 : 0
        clockStarted = true
        lock.unlock()
        CMTimebaseSetTime(timebase, time: CMTime(seconds: target, preferredTimescale: 90_000))
        CMTimebaseSetRate(timebase, rate: rate)
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }
}
