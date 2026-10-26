import CoreMedia
import Foundation
import MediaFormat
import QuartzCore

/// Bir karenin Dolby Vision L1 meta verisi (12-bit PQ kodları, 0–4095).
struct DoviL1: Equatable {
    var minPQ: UInt16
    var maxPQ: UInt16
    var averagePQ: UInt16
    var sceneRefresh: Bool
}

/// libdovi ile Dolby Vision RPU işleme (S2.3, 02-cozum §3.5.1 ve §3.7):
/// - Nit yolu: her paketin RPU'sundaki L1 PTS'ye göre saklanır (sahne beyazı).
/// - Referans yolu, P7: EL NAL'ları (63) atılır, RPU (62) P8.1'e dönüştürülür. MEL'de eşleme korunur (kip 4),
///   FEL'de etkisizleştirilir (kip 2): FEL'siz BL zaten HDR10 uyumludur. Sistem BL + RPU'yu P8.1 olarak işler.
/// Paket çağrıları demux thread'inden, okumalar ana thread'den gelir.
final class DoviRpuProcessor: @unchecked Sendable {
    struct Stats: Equatable {
        var rpus = 0
        var conversions = 0
        var errors = 0
        var lastError: String?
        /// RPU başlığından tahmin edilen profil; P7'de EL türü ("MEL" / "FEL").
        var guessedProfile: UInt8?
        var elType: String?
        /// RPU başına süre (µs): ayrıştırma + L1 (+ Referans'ta dönüşüm ve yazma). AS-2 hedefi < 2000 µs.
        var meanMicros = 0.0
        var maxMicros = 0.0
    }

    let sourceProfile: UInt8
    private let lengthSize: Int
    private let lock = NSLock()
    private var recent: [(key: Int64, l1: DoviL1)] = []
    private var stats = Stats()
    private static let recentCapacity = 120

    init?(info: VideoStreamInfo) {
        guard info.codecType == kCMVideoCodecType_HEVC, let dovi = info.dovi, dovi.rpuPresent else { return nil }
        sourceProfile = dovi.profile
        lengthSize = info.nalLengthSize
    }

    /// Referans yolunda P7 yerine bildirilecek P8.1 yapılandırması; P7 değilse `nil`.
    static func referenceConfig(for source: DoviConfig) -> DoviConfig? {
        guard source.profile == 7 else { return nil }
        return DoviConfig(versionMajor: 1, versionMinor: 0, profile: 8, level: source.level, rpuPresent: true,
                          elPresent: false, blPresent: true, blCompatibilityID: 1)
    }

    var currentStats: Stats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    /// Verilen sunum zamanındaki karenin L1'i (Nit yolunda gözlenmişse).
    func l1(forPTS seconds: Double) -> DoviL1? {
        let key = Self.key(seconds)
        lock.lock()
        defer { lock.unlock() }
        return recent.last(where: { $0.key == key })?.l1
    }

    /// Nit yolu: paketteki RPU'nun L1'ini saklar; paket değişmez.
    func observe(_ packet: DemuxedPacket) {
        guard packet.pts.isValid else { return }
        let pts = packet.pts.seconds
        packet.data.withUnsafeBytes { raw in
            for r in NALUnits.lengthPrefixedRanges(raw, lengthSize: lengthSize) where NALUnits.hevcType(raw, r) == 62 {
                _ = process(raw, r, pts: pts, convert: false)
                break
            }
        }
    }

    /// Referans yolu, yalnızca P7. Dönüşüm başarısızsa RPU da atılır: kare HDR10 BL olarak görünür;
    /// P8.1 yapılandırması altında P7 RPU'su göndermekten güvenlidir.
    func rewriteForReference(_ packet: DemuxedPacket) -> Data? {
        guard sourceProfile == 7 else { return nil }
        let pts: Double? = packet.pts.isValid ? packet.pts.seconds : nil
        return packet.data.withUnsafeBytes { raw -> Data in
            var out = Data(capacity: raw.count)
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return out }
            for r in NALUnits.lengthPrefixedRanges(raw, lengthSize: lengthSize) {
                switch NALUnits.hevcType(raw, r) {
                case 63:
                    continue
                case 62:
                    if let converted = process(raw, r, pts: pts, convert: true) {
                        NALUnits.appendLength(converted.count, size: lengthSize, to: &out)
                        out.append(converted)
                    }
                default:
                    NALUnits.appendLength(r.count, size: lengthSize, to: &out)
                    out.append(base + r.lowerBound, count: r.count)
                }
            }
            return out
        }
    }

    // MARK: Özel

    private static func key(_ seconds: Double) -> Int64 {
        Int64((seconds * 1000).rounded())
    }

    /// RPU'yu (0x7C01 başlıklı, kaçışlı NAL) ayrıştırır ve L1'i saklar. `convert` ise P8.1'e dönüştürür ve
    /// yeni NAL'ı (0x7C01 başlıklı, kaçışlı) döndürür.
    private func process(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>, pts: Double?, convert: Bool) -> Data? {
        let start = CACurrentMediaTime()
        guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
              let rpu = dovi_parse_unspec62_nalu(base + range.lowerBound, range.count) else {
            finish(start: start, pts: pts, l1: nil, header: nil, converted: false, error: "RPU ayrıştırılamadı")
            return nil
        }
        defer { dovi_rpu_free(rpu) }
        if let error = dovi_rpu_get_error(rpu) {
            finish(start: start, pts: pts, l1: nil, header: nil, converted: false, error: String(cString: error))
            return nil
        }

        var header: (profile: UInt8, elType: String?)?
        if let h = dovi_rpu_get_header(rpu) {
            header = (h.pointee.guessed_profile, h.pointee.el_type.map { String(cString: $0) })
            dovi_rpu_free_header(h)
        }
        var l1: DoviL1?
        if let dm = dovi_rpu_get_vdr_dm_data(rpu) {
            if let level1 = dm.pointee.dm_data.level1 {
                l1 = DoviL1(minPQ: level1.pointee.min_pq, maxPQ: level1.pointee.max_pq, averagePQ: level1.pointee.avg_pq,
                            sceneRefresh: dm.pointee.scene_refresh_flag != 0)
            }
            dovi_rpu_free_vdr_dm_data(dm)
        }

        guard convert else {
            finish(start: start, pts: pts, l1: l1, header: header, converted: false, error: nil)
            return nil
        }
        let mode: UInt8 = header?.elType == "FEL" ? 2 : 4
        var output: Data?
        var error: String?
        if dovi_convert_rpu_with_mode(rpu, mode) == 0, let written = dovi_write_unspec62_nalu(rpu) {
            if let data = written.pointee.data, written.pointee.len > 0 {
                output = Data(bytes: data, count: Int(written.pointee.len))
            } else {
                error = dovi_rpu_get_error(rpu).map { String(cString: $0) } ?? "RPU yazılamadı"
            }
            dovi_data_free(written)
        } else {
            error = dovi_rpu_get_error(rpu).map { String(cString: $0) } ?? "RPU dönüştürülemedi (kip \(mode))"
        }
        finish(start: start, pts: pts, l1: l1, header: header, converted: output != nil, error: error)
        return output
    }

    private func finish(start: CFTimeInterval, pts: Double?, l1: DoviL1?, header: (profile: UInt8, elType: String?)?,
                        converted: Bool, error: String?) {
        let micros = (CACurrentMediaTime() - start) * 1_000_000
        lock.lock()
        defer { lock.unlock() }
        stats.rpus += 1
        stats.meanMicros += (micros - stats.meanMicros) / Double(stats.rpus)
        stats.maxMicros = max(stats.maxMicros, micros)
        if converted { stats.conversions += 1 }
        if let error {
            stats.errors += 1
            stats.lastError = error
        }
        if let header {
            stats.guessedProfile = header.profile
            if let el = header.elType { stats.elType = el }
        }
        if let l1, let pts {
            recent.append((Self.key(pts), l1))
            if recent.count > Self.recentCapacity { recent.removeFirst(recent.count - Self.recentCapacity) }
        }
    }
}
