import CoreMedia
import Foundation
import MediaFormat
import NitMath

/// MKV/MP4/M2TS'deki Dolby Vision yapılandırması (`AVDOVIDecoderConfigurationRecord`).
struct DoviConfig: Equatable {
    var versionMajor: UInt8
    var versionMinor: UInt8
    var profile: UInt8
    var level: UInt8
    var rpuPresent: Bool
    var elPresent: Bool
    var blPresent: Bool
    var blCompatibilityID: UInt8

    /// Profil 7'ye kadar `dvcC`, sonrası `dvvC` kutusu.
    var atomName: String { profile > 7 ? "dvvC" : "dvcC" }

    /// ISO/IEC 14496-15 Dolby Vision yapılandırma kutusunun 24 baytlık gövdesi.
    var record: Data {
        var bytes = [UInt8](repeating: 0, count: 24)
        bytes[0] = versionMajor
        bytes[1] = versionMinor
        bytes[2] = (profile << 1) | (level >> 5)
        bytes[3] = ((level & 0x1F) << 3) | (rpuPresent ? 4 : 0) | (elPresent ? 2 : 0) | (blPresent ? 1 : 0)
        bytes[4] = blCompatibilityID << 4
        return Data(bytes)
    }

    var label: String {
        var s = "DV P\(profile)"
        if profile == 8 { s += ".\(blCompatibilityID)" }
        if profile == 7 { s += elPresent ? " (BL+EL)" : "" }
        return s
    }
}

/// Video akışının özellikleri; format description ve Nit hattı için gerekenler.
struct VideoStreamInfo {
    var codecType: CMVideoCodecType
    var codecName: String
    var width: Int
    var height: Int
    /// `hvcC` ya da `avcC` gövdesi. M2TS/TS'de Annex B parametre kümelerinden üretilir.
    var configurationRecord: Data
    /// Paketler kaynakta Annex B mi (M2TS/TS)? Öyleyse demux sırasında uzunluk önekliye çevrilir.
    var annexB: Bool
    /// Örneklerdeki NAL uzunluk önekinin bayt sayısı (`hvcC`/`avcC`'den).
    var nalLengthSize: Int
    var timeBase: (num: Int32, den: Int32)
    var frameRate: Double
    var primaries: SourcePrimaries
    var transfer: TransferFunction
    var matrix: YCbCrMatrix
    var fullRange: Bool
    var bitDepth: Int
    var dovi: DoviConfig?
    var maxCLL: Double?
    var maxFALL: Double?
    var duration: Double

    var isHDR: Bool { transfer.isHDR || dovi != nil }

    var label: String {
        var parts = ["\(width)×\(height)", codecName, "\(bitDepth)-bit"]
        parts.append(transfer == .pq ? "PQ" : transfer == .hlg ? "HLG" : "SDR")
        parts.append(primaries.rawValue)
        if let dovi { parts.append(dovi.label) }
        return parts.joined(separator: " · ")
    }
}

/// Seçilen ses akışı (S3). Çözücüyü açmak için codec parametrelerinin bir kopyasını taşır.
final class AudioStreamInfo: @unchecked Sendable {
    let codecID: AVCodecID
    let codecName: String
    let sampleRate: Int
    let channels: Int
    /// FFmpeg profili; E-AC-3 JOC ve TrueHD Atmos için `AV_PROFILE_*_ATMOS` (30) olabilir.
    let profile: Int32
    let language: String?
    let title: String?
    let parameters: UnsafeMutablePointer<AVCodecParameters>

    init?(stream: UnsafeMutablePointer<AVStream>) {
        guard let copy = avcodec_parameters_alloc() else { return nil }
        guard avcodec_parameters_copy(copy, stream.pointee.codecpar) >= 0 else {
            var p: UnsafeMutablePointer<AVCodecParameters>? = copy
            avcodec_parameters_free(&p)
            return nil
        }
        parameters = copy
        let par = stream.pointee.codecpar.pointee
        codecID = par.codec_id
        codecName = String(cString: avcodec_get_name(par.codec_id))
        sampleRate = Int(par.sample_rate)
        channels = Int(par.ch_layout.nb_channels)
        profile = par.profile
        func tag(_ key: String) -> String? {
            av_dict_get(stream.pointee.metadata, key, nil, 0).flatMap { $0.pointee.value.map { String(cString: $0) } }
        }
        language = tag("language")
        title = tag("title")
    }

    deinit {
        var p: UnsafeMutablePointer<AVCodecParameters>? = parameters
        avcodec_parameters_free(&p)
    }
}

/// Demux edilmiş bir paket. Video: uzunluk önekli NAL'lar, kod çözme sırasında. Ses: codec'in ham paketi.
struct DemuxedPacket {
    enum Kind {
        case video
        case audio
    }

    var data: Data
    var pts: CMTime
    var dts: CMTime
    var duration: CMTime
    var keyframe: Bool
    var kind: Kind = .video
}

enum DemuxError: LocalizedError {
    case open(String)
    case noVideo
    case unsupportedCodec(String)

    var errorDescription: String? {
        switch self {
        case .open(let m): "Dosya açılamadı: \(m)"
        case .noVideo: "Dosyada video izi yok"
        case .unsupportedCodec(let c): "Bu sürümde desteklenmeyen video codec'i: \(c) (S2'de HEVC ve H.264)"
        }
    }
}

/// libavformat ile demux (02-cozum §4.1): video akışı ve (varsa) en uygun ses akışı.
/// Tek bir thread'den kullanılmalıdır (NativePlayer'ın demux thread'i).
final class NativeDemuxer {
    private var context: UnsafeMutablePointer<AVFormatContext>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private let streamIndex: Int32
    private let audioIndex: Int32
    private let audioTimeBase: (num: Int32, den: Int32)
    let info: VideoStreamInfo
    let audio: AudioStreamInfo?

    init(path: String) throws {
        // `opened` kapatma için isteğe bağlı kalır; `ctx` açık bağlamın kendisidir.
        var opened: UnsafeMutablePointer<AVFormatContext>?
        let openResult = avformat_open_input(&opened, path, nil, nil)
        guard openResult >= 0, let ctx = opened else { throw DemuxError.open(Self.errorString(openResult)) }
        guard avformat_find_stream_info(ctx, nil) >= 0 else {
            avformat_close_input(&opened)
            throw DemuxError.open("akış bilgisi okunamadı")
        }
        let index = av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard index >= 0, let stream = ctx.pointee.streams[Int(index)] else {
            avformat_close_input(&opened)
            throw DemuxError.noVideo
        }
        // Ses: videoyla ilişkili en iyi akış (S3). Diğer akışlar yok sayılır; paket okuma maliyeti düşer.
        let audioIndex = av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, index, nil, 0)
        var audio: AudioStreamInfo?
        var audioTimeBase: (num: Int32, den: Int32) = (1, 1)
        if audioIndex >= 0, let audioStream = ctx.pointee.streams[Int(audioIndex)] {
            audio = AudioStreamInfo(stream: audioStream)
            audioTimeBase = (audioStream.pointee.time_base.num, audioStream.pointee.time_base.den)
        }
        for i in 0..<Int(ctx.pointee.nb_streams) where i != Int(index) && (audio == nil || i != Int(audioIndex)) {
            ctx.pointee.streams[i]?.pointee.discard = AVDISCARD_ALL
        }
        do {
            info = try Self.makeInfo(stream: stream, context: ctx)
        } catch {
            avformat_close_input(&opened)
            throw error
        }
        context = ctx
        streamIndex = index
        self.audio = audio
        self.audioIndex = audio == nil ? -1 : audioIndex
        self.audioTimeBase = audioTimeBase
        packet = av_packet_alloc()
    }

    deinit {
        av_packet_free(&packet)
        avformat_close_input(&context)
    }

    /// Bir sonraki video ya da ses paketini okur; dosya sonunda `nil`.
    func readPacket() -> DemuxedPacket? {
        guard let context, let packet else { return nil }
        while true {
            let result = av_read_frame(context, packet)
            if result < 0 { return nil }
            defer { av_packet_unref(packet) }
            let index = packet.pointee.stream_index
            guard index == streamIndex || index == audioIndex, packet.pointee.size > 0,
                  let bytes = packet.pointee.data else { continue }
            let size = Int(packet.pointee.size)
            let isAudio = index == audioIndex
            let data = info.annexB && !isAudio
                ? NALUnits.lengthPrefixed(fromAnnexB: UnsafeRawBufferPointer(start: bytes, count: size))
                : Data(bytes: bytes, count: size)
            let tb = isAudio ? audioTimeBase : info.timeBase
            let nopts = arif_nopts_value()
            let rawPTS = packet.pointee.pts != nopts ? packet.pointee.pts : packet.pointee.dts
            let rawDTS = packet.pointee.dts != nopts ? packet.pointee.dts : rawPTS
            func time(_ v: Int64) -> CMTime {
                v == nopts ? .invalid : CMTime(value: v * Int64(tb.num), timescale: tb.den)
            }
            return DemuxedPacket(data: data,
                                 pts: time(rawPTS), dts: time(rawDTS),
                                 duration: packet.pointee.duration > 0 ? time(packet.pointee.duration) : .invalid,
                                 keyframe: packet.pointee.flags & AV_PKT_FLAG_KEY != 0, kind: isAudio ? .audio : .video)
        }
    }

    /// Hedef zamandan önceki en yakın anahtar kareye sarar.
    func seek(to seconds: Double) {
        guard let context else { return }
        let target = Int64(max(seconds, 0) * Double(arif_time_base()))
        av_seek_frame(context, -1, target, AVSEEK_FLAG_BACKWARD)
    }

    // MARK: Özel

    private static func makeInfo(stream: UnsafeMutablePointer<AVStream>,
                                 context: UnsafeMutablePointer<AVFormatContext>) throws -> VideoStreamInfo {
        let par = stream.pointee.codecpar.pointee
        let codecType: CMVideoCodecType
        let codecName: String
        switch par.codec_id {
        case AV_CODEC_ID_HEVC:
            codecType = kCMVideoCodecType_HEVC
            codecName = "HEVC"
        case AV_CODEC_ID_H264:
            codecType = kCMVideoCodecType_H264
            codecName = "H.264"
        default:
            throw DemuxError.unsupportedCodec(String(cString: avcodec_get_name(par.codec_id)))
        }
        guard let extradata = par.extradata, par.extradata_size > 0 else {
            throw DemuxError.open("codec yapılandırması (hvcC/avcC) yok")
        }
        let isHEVC = par.codec_id == AV_CODEC_ID_HEVC

        let primaries: SourcePrimaries
        switch par.color_primaries {
        case AVCOL_PRI_BT2020: primaries = .bt2020
        case AVCOL_PRI_SMPTE432: primaries = .displayP3
        default: primaries = .bt709
        }
        let transfer: TransferFunction
        switch par.color_trc {
        case AVCOL_TRC_SMPTE2084: transfer = .pq
        case AVCOL_TRC_ARIB_STD_B67: transfer = .hlg
        default: transfer = .sdrGamma
        }
        let matrix: YCbCrMatrix
        switch par.color_space {
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: matrix = .bt2020
        case AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M: matrix = .bt601
        default: matrix = primaries == .bt2020 ? .bt2020 : .bt709
        }

        var bitDepth = Int(par.bits_per_raw_sample)
        if bitDepth <= 0, let desc = av_pix_fmt_desc_get(AVPixelFormat(rawValue: par.format)) {
            bitDepth = Int(desc.pointee.comp.0.depth)
        }
        if bitDepth <= 0 { bitDepth = transfer.isHDR ? 10 : 8 }

        // MKV/MP4: hvcC/avcC. M2TS/TS: Annex B parametre kümeleri → kayıt burada üretilir.
        var record = Data(bytes: extradata, count: Int(par.extradata_size))
        let annexB = NALUnits.isAnnexB(record)
        if annexB {
            guard let converted = isHEVC ? NALUnits.hvcC(fromAnnexB: record, bitDepth: bitDepth)
                                         : NALUnits.avcC(fromAnnexB: record, bitDepth: bitDepth) else {
                throw DemuxError.open("Annex B parametre kümeleri (VPS/SPS/PPS) okunamadı")
            }
            record = converted
        }
        let lengthIndex = isHEVC ? 21 : 4
        let nalLengthSize = record.count > lengthIndex ? Int(record[record.startIndex + lengthIndex] & 0x03) + 1 : 4

        var dovi: DoviConfig?
        if let sd = arif_stream_side_data(stream, AV_PKT_DATA_DOVI_CONF), let raw = sd.pointee.data,
           sd.pointee.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size {
            let r = raw.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee }
            dovi = DoviConfig(versionMajor: r.dv_version_major, versionMinor: r.dv_version_minor, profile: r.dv_profile,
                              level: r.dv_level, rpuPresent: r.rpu_present_flag != 0, elPresent: r.el_present_flag != 0,
                              blPresent: r.bl_present_flag != 0, blCompatibilityID: r.dv_bl_signal_compatibility_id)
        }

        var maxCLL: Double?
        var maxFALL: Double?
        if let sd = arif_stream_side_data(stream, AV_PKT_DATA_CONTENT_LIGHT_LEVEL), let raw = sd.pointee.data {
            let light = raw.withMemoryRebound(to: AVContentLightMetadata.self, capacity: 1) { $0.pointee }
            if light.MaxCLL > 0 { maxCLL = Double(light.MaxCLL) }
            if light.MaxFALL > 0 { maxFALL = Double(light.MaxFALL) }
        }

        let rate = stream.pointee.avg_frame_rate.den > 0 && stream.pointee.avg_frame_rate.num > 0
            ? Double(stream.pointee.avg_frame_rate.num) / Double(stream.pointee.avg_frame_rate.den)
            : 24000.0 / 1001.0
        let duration = context.pointee.duration > 0 ? Double(context.pointee.duration) / Double(arif_time_base()) : 0

        return VideoStreamInfo(codecType: codecType, codecName: codecName,
                               width: Int(par.width), height: Int(par.height),
                               configurationRecord: record, annexB: annexB, nalLengthSize: nalLengthSize,
                               timeBase: (stream.pointee.time_base.num, stream.pointee.time_base.den),
                               frameRate: rate, primaries: primaries, transfer: transfer, matrix: matrix,
                               fullRange: par.color_range == AVCOL_RANGE_JPEG, bitDepth: bitDepth, dovi: dovi,
                               maxCLL: maxCLL, maxFALL: maxFALL, duration: duration)
    }

    static func errorString(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        av_strerror(code, &buffer, buffer.count)
        return String(cString: buffer)
    }
}
