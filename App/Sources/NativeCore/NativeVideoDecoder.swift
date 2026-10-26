import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// PTS'ye göre sıralı, sınırlı kare kuyruğu (VT çıkışı ↔ render). Geri basınç sağlar.
final class FrameQueue: @unchecked Sendable {
    struct Frame {
        let pts: Double
        let buffer: CVPixelBuffer
    }

    let capacity: Int
    private let condition = NSCondition()
    private var frames: [Frame] = []
    private var inFlight = 0
    private var cancelled = false

    init(capacity: Int = 6) {
        self.capacity = capacity
    }

    var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return frames.count
    }

    /// Kod çözmeye gönderilmeden önce yer ayırır; kuyruk doluysa bekler. İptal edilirse `false`.
    func reserve() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while frames.count + inFlight >= capacity, !cancelled {
            condition.wait(until: Date().addingTimeInterval(0.05))
        }
        guard !cancelled else { return false }
        inFlight += 1
        return true
    }

    /// Ayrılan yer kare olmadan serbest kalır (çözme hatası ya da kare üretmeyen paket).
    func release() {
        condition.lock()
        inFlight = max(inFlight - 1, 0)
        condition.signal()
        condition.unlock()
    }

    func push(_ frame: Frame) {
        condition.lock()
        inFlight = max(inFlight - 1, 0)
        let index = frames.firstIndex { $0.pts > frame.pts } ?? frames.count
        frames.insert(frame, at: index)
        condition.signal()
        condition.unlock()
    }

    /// Zamanı gelmiş en son kareyi döndürür, daha eskileri atar. Atılan kare sayısı da döner.
    func take(atOrBefore time: Double) -> (frame: Frame, skipped: Int)? {
        condition.lock()
        defer { condition.unlock() }
        guard let last = frames.lastIndex(where: { $0.pts <= time + 0.002 }) else { return nil }
        let frame = frames[last]
        frames.removeFirst(last + 1)
        condition.signal()
        return (frame, last)
    }

    var firstPTS: Double? {
        condition.lock()
        defer { condition.unlock() }
        return frames.first?.pts
    }

    func clear() {
        condition.lock()
        frames.removeAll()
        inFlight = 0
        condition.broadcast()
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    func resume() {
        condition.lock()
        cancelled = false
        condition.unlock()
    }
}

/// VideoToolbox donanım çözücüsü (02-cozum §4.2). Çıkış IOSurface destekli, Metal uyumlu piksel tamponları.
final class NativeVideoDecoder {
    private var session: VTDecompressionSession?
    private let format: CMVideoFormatDescription
    private let queue: FrameQueue
    private(set) var lastError: OSStatus = noErr

    /// - Parameter fullRange: Akışın kendi aralığı istenir; böylece çözücü kodları ölçeklemez (DV P5'in
    ///   şekillendirmesi ham koda göre tanımlıdır).
    init?(format: CMVideoFormatDescription, tenBit: Bool, fullRange: Bool, queue: FrameQueue) {
        self.format = format
        self.queue = queue
        let pixelFormat: OSType
        switch (tenBit, fullRange) {
        case (true, false): pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case (true, true): pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case (false, false): pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case (false, true): pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        // iOS HEVC/H.264'ü zaten donanımda çözer; özel bir çözücü belirtimi gerekmez.
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                                                  decoderSpecification: nil,
                                                  imageBufferAttributes: attributes as CFDictionary,
                                                  outputCallback: nil, decompressionSessionOut: &created)
        guard status == noErr, let created else { return nil }
        session = created
    }

    deinit {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    /// Bir örneği asenkron çözer; kare kuyruğa PTS'siyle girer. Kuyrukta yer yoksa bekler.
    @discardableResult
    func decode(_ sample: CMSampleBuffer) -> Bool {
        guard let session, queue.reserve() else { return false }
        let queue = self.queue
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
                                                       flags: [._EnableAsynchronousDecompression],
                                                       infoFlagsOut: nil) { status, _, imageBuffer, pts, _ in
            if status == noErr, let imageBuffer, pts.isValid {
                queue.push(FrameQueue.Frame(pts: pts.seconds, buffer: imageBuffer))
            } else {
                queue.release()
            }
        }
        if status != noErr {
            lastError = status
            queue.release()
            return false
        }
        return true
    }

    /// Sarma öncesi: bekleyen kareleri bitirir (kuyruk ayrıca temizlenir).
    func flush() {
        guard let session else { return }
        VTDecompressionSessionFinishDelayedFrames(session)
        VTDecompressionSessionWaitForAsynchronousFrames(session)
    }
}
