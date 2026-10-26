import CoreMedia
import Foundation
import MediaFormat
import NitMath
import QuartzCore

/// Bir karenin Dolby Vision L1 meta verisi (12-bit PQ kodları, 0–4095).
struct DoviL1: Equatable {
    var minPQ: UInt16
    var maxPQ: UInt16
    var averagePQ: UInt16
    var sceneRefresh: Bool
}

/// Bir DV P5 karesinin GPU'ya giden şekillendirme ve renk parametreleri (S2.4). Ardışık karelerde aynı
/// eşleme tekrar ettiğinde aynı örnek paylaşılır.
final class DoviShaderParams: @unchecked Sendable {
    let model: DolbyVisionReshape
    /// `DolbyVisionReshape.packed` düzeni; kod ölçeğini renderer doku biçimine göre yazar.
    let packed: [SIMD4<Float>]

    init(model: DolbyVisionReshape) {
        self.model = model
        packed = model.packed(codeScale: 1)
    }
}

/// libdovi ile Dolby Vision RPU işleme (S2.3–S2.4, 02-cozum §3.5.1 ve §3.7):
/// - Nit yolu: her paketin RPU'sundaki L1 PTS'ye göre saklanır (sahne beyazı). P5'te ayrıca şekillendirme
///   eğrileri ve IPT → LMS matrisleri GPU düzenine çevrilir (IPTPQc2 kod çözümü, AS-30).
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
        /// RPU başına süre (µs): ayrıştırma + L1 (+ P5 şekillendirme, Referans'ta dönüşüm ve yazma). AS-2 hedefi < 2000 µs.
        var meanMicros = 0.0
        var maxMicros = 0.0
        /// P5: son eşlemenin özeti ("Y 8 poli · Cb MMR3 · Cr MMR3"), farklı eşleme sayısı ve okunamayanlar.
        var reshapeSummary: String?
        var reshapeChanges = 0
        var reshapeFailures = 0
        var lastReshapeError: String?
    }

    private struct Entry {
        var key: Int64
        var l1: DoviL1?
        var reshape: DoviShaderParams?
    }

    private struct HeaderInfo {
        var profile: UInt8
        var elType: String?
        var blBitDepth: Int
        var log2Denom: Int
        var coefficientDataType: UInt8
    }

    /// RPU renk matrisleri (ham): `ycc_to_rgb` (2^13), ofsetler (2^28), `rgb_to_lms` (2^14).
    private struct ColorMatrices: Equatable {
        var ycc: [Int16]
        var offset: [UInt32]
        var lms: [Int16]

        /// dovi_tool'un P5 varsayılanları: RPU'da DM verisi hiç yoksa kullanılır.
        static let p5Default = ColorMatrices(ycc: [8192, 799, 1681, 8192, -933, 1091, 8192, 267, -5545],
                                             offset: [0, 134_217_728, 134_217_728],
                                             lms: [17081, -349, -349, -349, 17081, -349, -349, -349, 17081])
    }

    let sourceProfile: UInt8
    /// P5: Nit yolunda IPTPQc2 kod çözümü için şekillendirme okunur.
    var decodesReshaping: Bool { sourceProfile == 5 }
    private let lengthSize: Int
    private let lock = NSLock()
    private var recent: [Entry] = []
    private var stats = Stats()
    private static let recentCapacity = 120
    // Yalnızca demux thread'i: önceki RPU'dan devralınanlar (`use_prev_vdr_rpu_flag`, DM verisi olmayan RPU).
    private var lastReshape: DoviShaderParams?
    private var lastColor: ColorMatrices?

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
        return recent.last(where: { $0.key == key && $0.l1 != nil })?.l1
    }

    /// P5: verilen sunum zamanındaki karenin kod çözüm parametreleri.
    func reshape(forPTS seconds: Double) -> DoviShaderParams? {
        let key = Self.key(seconds)
        lock.lock()
        defer { lock.unlock() }
        return recent.last(where: { $0.key == key && $0.reshape != nil })?.reshape
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

        var header: HeaderInfo?
        if let h = dovi_rpu_get_header(rpu) {
            let v = h.pointee
            header = HeaderInfo(profile: v.guessed_profile, elType: v.el_type.map { String(cString: $0) },
                                blBitDepth: Int(v.bl_bit_depth_minus8) + 8, log2Denom: Int(v.coefficient_log2_denom),
                                coefficientDataType: v.coefficient_data_type)
            dovi_rpu_free_header(h)
        }
        var l1: DoviL1?
        if let dm = dovi_rpu_get_vdr_dm_data(rpu) {
            let d = dm.pointee
            if let level1 = d.dm_data.level1 {
                l1 = DoviL1(minPQ: level1.pointee.min_pq, maxPQ: level1.pointee.max_pq, averagePQ: level1.pointee.avg_pq,
                            sceneRefresh: d.scene_refresh_flag != 0)
            }
            if decodesReshaping {
                lastColor = ColorMatrices(
                    ycc: [d.ycc_to_rgb_coef0, d.ycc_to_rgb_coef1, d.ycc_to_rgb_coef2, d.ycc_to_rgb_coef3, d.ycc_to_rgb_coef4,
                          d.ycc_to_rgb_coef5, d.ycc_to_rgb_coef6, d.ycc_to_rgb_coef7, d.ycc_to_rgb_coef8],
                    offset: [d.ycc_to_rgb_offset0, d.ycc_to_rgb_offset1, d.ycc_to_rgb_offset2],
                    lms: [d.rgb_to_lms_coef0, d.rgb_to_lms_coef1, d.rgb_to_lms_coef2, d.rgb_to_lms_coef3, d.rgb_to_lms_coef4,
                          d.rgb_to_lms_coef5, d.rgb_to_lms_coef6, d.rgb_to_lms_coef7, d.rgb_to_lms_coef8])
            }
            dovi_rpu_free_vdr_dm_data(dm)
        }

        guard convert else {
            var reshape: ReshapeOutcome?
            if decodesReshaping, let header { reshape = reshapeParams(rpu, header: header) }
            finish(start: start, pts: pts, l1: l1, header: header, converted: false, error: nil, reshape: reshape)
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

    private func finish(start: CFTimeInterval, pts: Double?, l1: DoviL1?, header: HeaderInfo?,
                        converted: Bool, error: String?, reshape: ReshapeOutcome? = nil) {
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
        if let reshape {
            if let failure = reshape.failure {
                stats.reshapeFailures += 1
                stats.lastReshapeError = failure
            }
            if reshape.changed, let params = reshape.params {
                stats.reshapeChanges += 1
                stats.reshapeSummary = Self.summary(params.model)
            }
        }
        if let pts, l1 != nil || reshape?.params != nil {
            recent.append(Entry(key: Self.key(pts), l1: l1, reshape: reshape?.params))
            if recent.count > Self.recentCapacity { recent.removeFirst(recent.count - Self.recentCapacity) }
        }
    }

    // MARK: P5 şekillendirme (S2.4)

    private struct ReshapeOutcome {
        var params: DoviShaderParams?
        var changed = false
        var failure: String?
    }

    /// RPU eşlemesinden kod çözüm parametreleri. Eşleme yoksa (`use_prev_vdr_rpu_flag`) ya da okunamazsa
    /// önceki karenin parametreleri sürer; ilk karede hiç yoksa `nil` (kare gösterilmez, yanlış renk yerine siyah).
    private func reshapeParams(_ rpu: OpaquePointer, header: HeaderInfo) -> ReshapeOutcome {
        guard let pointer = dovi_rpu_get_data_mapping(rpu) else { return ReshapeOutcome(params: lastReshape) }
        defer { dovi_rpu_free_data_mapping(pointer) }
        guard header.coefficientDataType == 0 else {
            return ReshapeOutcome(params: lastReshape, failure: "kayan noktalı RPU katsayıları desteklenmiyor")
        }
        let mapping = pointer.pointee
        var curves: [DolbyVisionReshape.RawCurve] = []
        for curve in [mapping.curves.0, mapping.curves.1, mapping.curves.2] {
            guard let raw = Self.rawCurve(curve) else {
                return ReshapeOutcome(params: lastReshape, failure: "şekillendirme eğrisi okunamadı (doğrusal ara değerleme?)")
            }
            curves.append(raw)
        }
        let color = lastColor ?? .p5Default
        guard let model = DolbyVisionReshape.make(blBitDepth: header.blBitDepth, log2Denom: header.log2Denom, curves: curves,
                                                  yccToRGB: color.ycc, yccToRGBOffset: color.offset, rgbToLMS: color.lms) else {
            return ReshapeOutcome(params: lastReshape, failure: "tutarsız şekillendirme verisi")
        }
        if let last = lastReshape, last.model == model { return ReshapeOutcome(params: last) }
        let params = DoviShaderParams(model: model)
        lastReshape = params
        return ReshapeOutcome(params: params, changed: true)
    }

    private static func rawCurve(_ curve: DoviReshapingCurve) -> DolbyVisionReshape.RawCurve? {
        let deltas = buffer(curve.pivots.data, curve.pivots.len)
        let pieceCount = deltas.count - 1
        guard pieceCount >= 1 else { return nil }
        var pieces: [DolbyVisionReshape.RawPiece] = []
        if curve.mapping_idc == 0, let poly = curve.polynomial?.pointee {
            // Doğrusal ara değerleme (linear_interp_flag) libdovi'de de uygulanmıyor.
            guard !buffer(poly.linear_interp_flag.data, poly.linear_interp_flag.len).contains(where: { $0 != 0 }) else { return nil }
            let ints = rows(poly.poly_coef_int)
            let fracs = rows(poly.poly_coef)
            guard ints.count >= pieceCount, fracs.count >= pieceCount else { return nil }
            for i in 0..<pieceCount {
                guard ints[i].count == fracs[i].count else { return nil }
                pieces.append(.polynomial(zip(ints[i], fracs[i]).map { DolbyVisionReshape.Fixed(int: $0, frac: $1) }))
            }
        } else if curve.mapping_idc == 1, let mmr = curve.mmr?.pointee {
            let orders = buffer(mmr.mmr_order_minus1.data, mmr.mmr_order_minus1.len)
            let constantInts = buffer(mmr.mmr_constant_int.data, mmr.mmr_constant_int.len)
            let constantFracs = buffer(mmr.mmr_constant.data, mmr.mmr_constant.len)
            let coefInts = cubes(mmr.mmr_coef_int)
            let coefFracs = cubes(mmr.mmr_coef)
            guard orders.count >= pieceCount, constantInts.count >= pieceCount, constantFracs.count >= pieceCount,
                  coefInts.count >= pieceCount, coefFracs.count >= pieceCount else { return nil }
            for i in 0..<pieceCount {
                let order = Int(orders[i]) + 1
                guard coefInts[i].count >= order, coefFracs[i].count >= order else { return nil }
                let weights = (0..<order).map { j in
                    zip(coefInts[i][j], coefFracs[i][j]).map { DolbyVisionReshape.Fixed(int: $0, frac: $1) }
                }
                pieces.append(.mmr(constant: DolbyVisionReshape.Fixed(int: constantInts[i], frac: constantFracs[i]),
                                   orders: weights))
            }
        } else {
            return nil
        }
        return DolbyVisionReshape.RawCurve(pivotDeltas: deltas, pieces: pieces)
    }

    private static func buffer<T>(_ pointer: UnsafePointer<T>?, _ count: Int) -> [T] {
        guard let pointer, count > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    private static func rows(_ d: DoviI64Data2D) -> [[Int64]] {
        buffer(d.list, d.len).map { row in row.map { buffer($0.pointee.data, $0.pointee.len) } ?? [] }
    }

    private static func rows(_ d: DoviU64Data2D) -> [[UInt64]] {
        buffer(d.list, d.len).map { row in row.map { buffer($0.pointee.data, $0.pointee.len) } ?? [] }
    }

    private static func cubes(_ d: DoviI64Data3D) -> [[[Int64]]] {
        buffer(d.list, d.len).map { plane in plane.map { rows($0.pointee) } ?? [] }
    }

    private static func cubes(_ d: DoviU64Data3D) -> [[[UInt64]]] {
        buffer(d.list, d.len).map { plane in plane.map { rows($0.pointee) } ?? [] }
    }

    /// "Y 8 poli · Cb MMR3 · Cr MMR3"
    private static func summary(_ model: DolbyVisionReshape) -> String {
        zip(["Y", "Cb", "Cr"], model.components).map { name, component in
            let polynomials = component.pieces.filter { if case .polynomial = $0 { return true } else { return false } }.count
            let mmrOrder = component.pieces.compactMap { piece -> Int? in
                if case .mmr(_, let orders) = piece { return orders.count } else { return nil }
            }.max()
            var text = "\(name) \(component.pieces.count) parça"
            if polynomials > 0 { text += " poli" }
            if let mmrOrder { text += " MMR\(mmrOrder)" }
            return text
        }.joined(separator: " · ")
    }
}
