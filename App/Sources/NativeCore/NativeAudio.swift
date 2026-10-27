import AVFoundation
import CoreMedia
import Foundation
import MediaFormat

/// Ses hattının durumu (HUD, CSV). Demux thread'i yazar, ana thread okur.
struct NativeAudioStatus: Equatable {
    enum Path: Equatable {
        /// E-AC-3 JOC sıkıştırılmış olarak Apple'a: Atmos'u sistem render eder (AS-9).
        case atmos
        /// AC-3 / E-AC-3 sıkıştırılmış olarak Apple'a.
        case dolby
        /// FFmpeg → float32 PCM (TrueHD, DTS, FLAC, AAC…).
        case pcm
    }

    var codec: String
    var path: Path
    var layout: String
    var sampleRate: Int
    /// FFmpeg çözme süresi / çalınan süre, bir çekirdeğin yüzdesi (AS-10). Sıkıştırılmış yolda `nil`.
    var decodeCPUPercent: Double?
    var errors = 0
    var lastError: String?

    var label: String {
        var text = "Ses: \(codec) \(layout)"
        switch path {
        case .atmos: text += " → Apple (Dolby Atmos, sıkıştırılmış)"
        case .dolby: text += " → Apple (sıkıştırılmış)"
        case .pcm: text += " → PCM float32"
        }
        if sampleRate > 0 { text += " · \(sampleRate / 1000) kHz" }
        if let cpu = decodeCPUPercent { text += " · çözme %\(TR.num(cpu, 1))" }
        if errors > 0 { text += " · hata \(errors)" }
        return text
    }
}

/// Demux edilmiş ses paketlerini `AVSampleBufferAudioRenderer`'a uygun örneklere çevirir (S3, 02-cozum §5.1):
/// - AC-3 / E-AC-3 (JOC dahil): sıkıştırılmış. Biçim açıklaması ISO `ec-3`/`ac-3` örnek girdisinden kurulur;
///   CoreMedia akışı MP4'ten okunmuş gibi görür ve JOC'yi Atmos olarak tanır.
/// - Diğerleri: FFmpeg ile float32 PCM; kanal düzeni açık kanal tanımlarıyla (Ls/Rs ↔ Rls/Rrs karışmaz).
/// Yalnızca demux thread'inden kullanılır.
final class NativeAudioPipeline {
    private enum Mode {
        case dolby
        case decode
    }

    let stream: AudioStreamInfo
    private(set) var status: NativeAudioStatus
    private let mode: Mode

    // Dolby (sıkıştırılmış)
    private var packetizer = DolbyPacketizer()
    private var dolbyFormat: CMAudioFormatDescription?
    private var dolbyKey: [Int] = []

    // FFmpeg → PCM
    private var codec: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var avPacket: UnsafeMutablePointer<AVPacket>?
    private var pcmFormat: CMAudioFormatDescription?
    private var pcmKey: [Int] = []
    private var nextPTS: CMTime?
    private var cpuSeconds = 0.0
    private var mediaSeconds = 0.0

    init(stream: AudioStreamInfo) throws {
        self.stream = stream
        let dolby = stream.codecID == AV_CODEC_ID_AC3 || stream.codecID == AV_CODEC_ID_EAC3
        mode = dolby ? .dolby : .decode
        let layout = SpeakerLayout.name(SpeakerLayout.defaultPositions(channelCount: stream.channels))
        status = NativeAudioStatus(codec: Self.codecLabel(stream), path: dolby ? .dolby : .pcm, layout: layout,
                                   sampleRate: stream.sampleRate)
        if !dolby { try openDecoder() }
    }

    deinit {
        avcodec_free_context(&codec)
        av_frame_free(&frame)
        av_packet_free(&avPacket)
    }

    /// Bir paketi işler; renderer'a sırayla verilecek örnekleri döndürür (birikiyorsa boş).
    func process(_ packet: DemuxedPacket) -> [CMSampleBuffer] {
        switch mode {
        case .dolby: return processDolby(packet)
        case .decode: return processDecode(packet)
        }
    }

    /// Sarma sonrası: çözücü ve birleştirici sıfırlanır.
    func flush() {
        packetizer.reset()
        nextPTS = nil
        if let codec { avcodec_flush_buffers(codec) }
    }

    // MARK: Dolby

    private func processDolby(_ packet: DemuxedPacket) -> [CMSampleBuffer] {
        guard packet.pts.isValid else { return [] }
        let micros = Int64((packet.pts.seconds * 1_000_000).rounded())
        guard let unit = packetizer.push(packet.data, timestamp: micros),
              let access = DolbyAccessUnit.parse(unit.data) else { return [] }
        let p = access.primary
        let key = [p.bitstreamID, p.sampleRate, access.channels, access.joc ? 1 : 0, p.channelMode, p.lfeOn ? 1 : 0]
        if key != dolbyKey || dolbyFormat == nil {
            guard let format = Self.dolbyFormat(access) else {
                fail("Dolby biçim açıklaması kurulamadı")
                return []
            }
            dolbyFormat = format
            dolbyKey = key
            status.path = access.joc ? .atmos : .dolby
            status.codec = access.isEAC3 ? (access.joc ? "E-AC-3 JOC" : "E-AC-3") : "AC-3"
            status.layout = access.channels == 8 ? "7.1" : access.channels == 6 ? "5.1" : "\(access.channels) kanal"
            status.sampleRate = p.sampleRate
        }
        guard let format = dolbyFormat else { return [] }
        let pts = CMTime(value: unit.timestamp, timescale: 1_000_000)
        guard let sample = Self.compressedSample(unit.data, format: format, pts: pts) else { return [] }
        return [sample]
    }

    private static func dolbyFormat(_ unit: DolbyAccessUnit) -> CMAudioFormatDescription? {
        guard let entry = unit.isoSampleEntry() else { return nil }
        var format: CMAudioFormatDescription?
        let status = entry.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionData(
                allocator: kCFAllocatorDefault, bigEndianSoundDescriptionData: base, size: entry.count,
                soundDescriptionFlavor: kCMSoundDescriptionFlavor_ISOFamily, formatDescriptionOut: &format)
        }
        return status == noErr ? format : nil
    }

    private static func compressedSample(_ data: Data, format: CMAudioFormatDescription, pts: CMTime) -> CMSampleBuffer? {
        guard let block = blockBuffer(data) else { return nil }
        var description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                       mDataByteSize: UInt32(data.count))
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            presentationTimeStamp: pts, packetDescriptions: &description, sampleBufferOut: &sample)
        return status == noErr ? sample : nil
    }

    // MARK: FFmpeg → PCM

    private func openDecoder() throws {
        guard let decoder = avcodec_find_decoder(stream.codecID) else {
            throw DemuxError.open("ses çözücüsü yok: \(stream.codecName)")
        }
        guard let ctx = avcodec_alloc_context3(decoder) else { throw DemuxError.open("ses bağlamı açılamadı") }
        codec = ctx
        guard avcodec_parameters_to_context(ctx, stream.parameters) >= 0 else {
            throw DemuxError.open("ses parametreleri aktarılamadı")
        }
        ctx.pointee.pkt_timebase = AVRational(num: 1, den: 1_000_000)
        guard avcodec_open2(ctx, decoder, nil) >= 0 else { throw DemuxError.open("ses çözücüsü açılamadı: \(stream.codecName)") }
        frame = av_frame_alloc()
        avPacket = av_packet_alloc()
        guard frame != nil, avPacket != nil else { throw DemuxError.open("ses tamponu ayrılamadı") }
    }

    private func processDecode(_ packet: DemuxedPacket) -> [CMSampleBuffer] {
        guard let codec, let frame, let avPacket, !packet.data.isEmpty else { return [] }
        let start = Self.threadCPUTime()
        defer { cpuSeconds += Self.threadCPUTime() - start }

        guard av_new_packet(avPacket, Int32(packet.data.count)) >= 0 else { return [] }
        defer { av_packet_unref(avPacket) }
        packet.data.withUnsafeBytes { raw in
            if let base = raw.baseAddress { avPacket.pointee.data.update(from: base.assumingMemoryBound(to: UInt8.self), count: raw.count) }
        }
        avPacket.pointee.pts = packet.pts.isValid ? Int64((packet.pts.seconds * 1_000_000).rounded()) : arif_nopts_value()
        avPacket.pointee.dts = avPacket.pointee.pts
        let sent = avcodec_send_packet(codec, avPacket)
        // Sarmadan sonra TrueHD büyük senkron, DTS çekirdek başı bekler: hatalar sessizce geçilir.
        if sent < 0, sent != arif_averror_eagain() { return [] }

        var out: [CMSampleBuffer] = []
        while avcodec_receive_frame(codec, frame) >= 0 {
            defer { av_frame_unref(frame) }
            if let sample = pcmSample(frame) { out.append(sample) }
        }
        return out
    }

    /// AVFrame → float32 karışık (interleaved) PCM örneği.
    private func pcmSample(_ frame: UnsafeMutablePointer<AVFrame>) -> CMSampleBuffer? {
        let f = frame.pointee
        let count = Int(f.nb_samples)
        let channels = Int(f.ch_layout.nb_channels)
        let rate = Int(f.sample_rate)
        guard count > 0, channels > 0, rate > 0, let planes = f.extended_data else { return nil }

        // Biçim: oran, kanal sayısı ve kanal sırası değişince yeniden kurulur.
        var layout = f.ch_layout
        var ffChannels: [Int32] = []
        if layout.order == AV_CHANNEL_ORDER_NATIVE || layout.order == AV_CHANNEL_ORDER_CUSTOM {
            for i in 0..<channels { ffChannels.append(av_channel_layout_channel_from_index(&layout, UInt32(i)).rawValue) }
        }
        let key = [rate, channels] + ffChannels.map { Int($0) }
        if key != pcmKey || pcmFormat == nil {
            let positions = ffChannels.isEmpty ? SpeakerLayout.defaultPositions(channelCount: channels)
                                               : SpeakerLayout.positions(ffmpegChannels: ffChannels)
            guard let format = Self.pcmFormat(rate: rate, positions: positions) else {
                fail("PCM biçim açıklaması kurulamadı (\(channels) kanal)")
                return nil
            }
            pcmFormat = format
            pcmKey = key
            status.layout = SpeakerLayout.name(positions)
            status.sampleRate = rate
        }
        guard let format = pcmFormat else { return nil }

        var samples = [Float](repeating: 0, count: count * channels)
        let planar = av_sample_fmt_is_planar(AVSampleFormat(rawValue: f.format)) != 0
        let packed = av_get_packed_sample_fmt(AVSampleFormat(rawValue: f.format))
        for c in 0..<channels {
            guard let plane = planes[planar ? c : 0] else { return nil }
            let stride = planar ? 1 : channels
            let offset = planar ? 0 : c
            for i in 0..<count {
                samples[i * channels + c] = Self.sample(plane, index: i * stride + offset, format: packed)
            }
        }

        let ptsMicros = f.best_effort_timestamp != arif_nopts_value() ? f.best_effort_timestamp : f.pts
        let pts = ptsMicros != arif_nopts_value() ? CMTime(value: ptsMicros, timescale: 1_000_000)
                                                  : (nextPTS ?? .zero)
        nextPTS = pts + CMTime(value: CMTimeValue(count), timescale: CMTimeScale(rate))
        mediaSeconds += Double(count) / Double(rate)
        if mediaSeconds > 0 { status.decodeCPUPercent = cpuSeconds / mediaSeconds * 100 }

        let data = samples.withUnsafeBytes { Data($0) }
        guard let block = Self.blockBuffer(data) else { return nil }
        var sample: CMSampleBuffer?
        let result = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sample)
        return result == noErr ? sample : nil
    }

    private static func sample(_ plane: UnsafeMutablePointer<UInt8>, index: Int, format: AVSampleFormat) -> Float {
        let raw = UnsafeRawPointer(plane)
        switch format {
        case AV_SAMPLE_FMT_U8: return (Float(raw.load(fromByteOffset: index, as: UInt8.self)) - 128) / 128
        case AV_SAMPLE_FMT_S16: return Float(raw.load(fromByteOffset: index * 2, as: Int16.self)) / 32768
        case AV_SAMPLE_FMT_S32: return Float(Double(raw.load(fromByteOffset: index * 4, as: Int32.self)) / 2_147_483_648)
        case AV_SAMPLE_FMT_FLT: return raw.load(fromByteOffset: index * 4, as: Float.self)
        case AV_SAMPLE_FMT_DBL: return Float(raw.load(fromByteOffset: index * 8, as: Double.self))
        case AV_SAMPLE_FMT_S64: return Float(Double(raw.load(fromByteOffset: index * 8, as: Int64.self)) / 9.223372036854775808e18)
        default: return 0
        }
    }

    /// float32 karışık PCM; kanal düzeni açık kanal tanımlarıyla.
    private static func pcmFormat(rate: Int, positions: [SpeakerPosition]) -> CMAudioFormatDescription? {
        let channels = positions.count
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        let headerSize = MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions) ?? 12
        let size = headerSize + channels * MemoryLayout<AudioChannelDescription>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: max(size, MemoryLayout<AudioChannelLayout>.size),
                                                   alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: max(size, MemoryLayout<AudioChannelLayout>.size))
        let layout = raw.bindMemory(to: AudioChannelLayout.self, capacity: 1)
        layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        layout.pointee.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
        layout.pointee.mNumberChannelDescriptions = UInt32(channels)
        let descriptions = (raw + headerSize).bindMemory(to: AudioChannelDescription.self, capacity: channels)
        for (i, position) in positions.enumerated() {
            descriptions[i] = AudioChannelDescription(mChannelLabel: label(position), mChannelFlags: AudioChannelFlags(rawValue: 0),
                                                      mCoordinates: (0, 0, 0))
        }
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: size,
                                                    layout: layout, magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                    formatDescriptionOut: &format)
        return status == noErr ? format : nil
    }

    private static func label(_ position: SpeakerPosition) -> AudioChannelLabel {
        switch position {
        case .left: kAudioChannelLabel_Left
        case .right: kAudioChannelLabel_Right
        case .center: kAudioChannelLabel_Center
        case .lfe: kAudioChannelLabel_LFEScreen
        case .lfe2: kAudioChannelLabel_LFE2
        case .surroundLeft: kAudioChannelLabel_LeftSurround
        case .surroundRight: kAudioChannelLabel_RightSurround
        case .rearSurroundLeft: kAudioChannelLabel_RearSurroundLeft
        case .rearSurroundRight: kAudioChannelLabel_RearSurroundRight
        case .centerSurround: kAudioChannelLabel_CenterSurround
        case .leftCenter: kAudioChannelLabel_LeftCenter
        case .rightCenter: kAudioChannelLabel_RightCenter
        case .leftWide: kAudioChannelLabel_LeftWide
        case .rightWide: kAudioChannelLabel_RightWide
        case .surroundDirectLeft: kAudioChannelLabel_LeftSurroundDirect
        case .surroundDirectRight: kAudioChannelLabel_RightSurroundDirect
        case .topCenter: kAudioChannelLabel_TopCenterSurround
        case .topFrontLeft: kAudioChannelLabel_VerticalHeightLeft
        case .topFrontCenter: kAudioChannelLabel_VerticalHeightCenter
        case .topFrontRight: kAudioChannelLabel_VerticalHeightRight
        case .topMiddleLeft: kAudioChannelLabel_LeftTopMiddle
        case .topMiddleRight: kAudioChannelLabel_RightTopMiddle
        case .topBackLeft: kAudioChannelLabel_TopBackLeft
        case .topBackCenter: kAudioChannelLabel_TopBackCenter
        case .topBackRight: kAudioChannelLabel_TopBackRight
        case .leftTotal: kAudioChannelLabel_LeftTotal
        case .rightTotal: kAudioChannelLabel_RightTotal
        case .unknown: kAudioChannelLabel_Unknown
        }
    }

    // MARK: Yardımcılar

    private static func blockBuffer(_ data: Data) -> CMBlockBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: data.count, flags: 0,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        return copied == kCMBlockBufferNoErr ? block : nil
    }

    /// Bu thread'in CPU süresi (s): duvar saati değil, gerçekten harcanan çekirdek süresi (AS-10).
    private static func threadCPUTime() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    private func fail(_ message: String) {
        status.errors += 1
        status.lastError = message
    }

    private static func codecLabel(_ stream: AudioStreamInfo) -> String {
        switch stream.codecID {
        case AV_CODEC_ID_TRUEHD: stream.profile == 30 ? "TrueHD Atmos (yatak)" : "TrueHD"
        case AV_CODEC_ID_DTS: "DTS"
        case AV_CODEC_ID_FLAC: "FLAC"
        case AV_CODEC_ID_AAC: "AAC"
        case AV_CODEC_ID_AC3: "AC-3"
        case AV_CODEC_ID_EAC3: "E-AC-3"
        case AV_CODEC_ID_OPUS: "Opus"
        default: stream.codecName.uppercased()
        }
    }
}
