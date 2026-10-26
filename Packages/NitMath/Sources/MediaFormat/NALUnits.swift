import Foundation

/// HEVC/H.264 NAL birimi yardımcıları: uzunluk önekli (MKV/MP4) ve Annex B (M2TS/TS) akışlar.
/// VideoToolbox ve `AVSampleBufferVideoRenderer` yalnızca uzunluk önekli örnek + `hvcC/avcC` kabul eder;
/// M2TS'deki Annex B paketleri ve parametre kümeleri bu yüzden demux sırasında dönüştürülür.
public enum NALUnits {
    /// Veri Annex B başlangıç koduyla (00 00 01 ya da 00 00 00 01) başlıyor mu? `hvcC/avcC` 0x01 ile başlar.
    public static func isAnnexB(_ data: Data) -> Bool {
        let b = [UInt8](data.prefix(4))
        guard b.count >= 3, b[0] == 0, b[1] == 0 else { return false }
        return b[2] == 1 || (b.count == 4 && b[2] == 0 && b[3] == 1)
    }

    /// Annex B akışındaki NAL birimlerinin aralıkları (başlangıç kodları ve sondaki sıfır baytlar hariç).
    public static func annexBRanges(_ bytes: UnsafeRawBufferPointer) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        let n = bytes.count
        var i = 0
        var start = -1
        while i + 2 < n {
            let c = bytes[i + 2]
            // c > 1 ise i, i+1 ve i+2'de başlayan bir başlangıç kodu olamaz.
            if c > 1 {
                i += 3
                continue
            }
            if c == 1, bytes[i + 1] == 0, bytes[i] == 0 {
                if start >= 0 { ranges.append(start..<trimmedEnd(bytes, start, i)) }
                i += 3
                start = i
                continue
            }
            i += 1
        }
        if start >= 0, start < n { ranges.append(start..<trimmedEnd(bytes, start, n)) }
        return ranges.filter { !$0.isEmpty }
    }

    /// Uzunluk önekli paketteki NAL birimlerinin aralıkları (önek hariç).
    public static func lengthPrefixedRanges(_ bytes: UnsafeRawBufferPointer, lengthSize: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var i = 0
        while i + lengthSize <= bytes.count {
            var length = 0
            for k in 0..<lengthSize { length = (length << 8) | Int(bytes[i + k]) }
            i += lengthSize
            guard length > 0, i + length <= bytes.count else { break }
            ranges.append(i..<(i + length))
            i += length
        }
        return ranges
    }

    /// Annex B paketini 4 bayt uzunluk önekli biçime çevirir.
    public static func lengthPrefixed(fromAnnexB bytes: UnsafeRawBufferPointer) -> Data {
        let ranges = annexBRanges(bytes)
        var out = Data(capacity: bytes.count + ranges.count * 4)
        guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return out }
        for r in ranges {
            appendLength(r.count, size: 4, to: &out)
            out.append(base + r.lowerBound, count: r.count)
        }
        return out
    }

    /// Büyük uçlu uzunluk öneki ekler.
    public static func appendLength(_ length: Int, size: Int, to data: inout Data) {
        for k in stride(from: size - 1, through: 0, by: -1) {
            data.append(UInt8(truncatingIfNeeded: length >> (8 * k)))
        }
    }

    /// HEVC NAL türü (2 baytlık başlığın ilk baytından).
    public static func hevcType(_ bytes: UnsafeRawBufferPointer, _ range: Range<Int>) -> UInt8 {
        (bytes[range.lowerBound] >> 1) & 0x3F
    }

    /// Emülasyon önleme baytlarını (00 00 03) kaldırır.
    public static func unescape<C: Collection>(_ bytes: C) -> [UInt8] where C.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var zeros = 0
        for b in bytes {
            if zeros >= 2, b == 3 {
                zeros = 0
                continue
            }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return out
    }

    /// Annex B parametre kümelerinden (VPS/SPS/PPS) `hvcC` kaydı (ISO/IEC 14496-15 §8.3.3), 4 bayt uzunluk öneki.
    /// Profil/katman/seviye alanları SPS'in `profile_tier_level` başından kopyalanır; kod çözücü asıl değerleri SPS'ten okur.
    public static func hvcC(fromAnnexB extradata: Data, bitDepth: Int) -> Data? {
        var vps: [Data] = [], sps: [Data] = [], pps: [Data] = []
        extradata.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for r in annexBRanges(raw) where r.count >= 3 {
                let nal = Data(bytes: base + r.lowerBound, count: r.count)
                switch hevcType(raw, r) {
                case 32: vps.append(nal)
                case 33: sps.append(nal)
                case 34: pps.append(nal)
                default: break
                }
            }
        }
        guard let first = sps.first, !vps.isEmpty, !pps.isEmpty else { return nil }
        // 2 baytlık NAL başlığından sonraki RBSP: [0] VPS kimliği | alt katman sayısı | iç içelik, [1…12] genel PTL.
        let rbsp = unescape(first.dropFirst(2).prefix(24))
        guard rbsp.count >= 13 else { return nil }
        let depth = UInt8(clamping: max(bitDepth - 8, 0)) & 0x07
        var r: [UInt8] = [1]
        r.append(contentsOf: rbsp[1...12])
        let fixed: [UInt8] = [0xF0, 0x00, 0xFC, 0xFD, 0xF8 | depth, 0xF8 | depth, 0x00, 0x00]
        r += fixed
        let subLayers = ((rbsp[0] >> 1) & 0x07) + 1
        let nested = rbsp[0] & 0x01
        r.append((subLayers << 3) | (nested << 2) | 0x03)
        let arrays: [(type: UInt8, nals: [Data])] = [(32, vps), (33, sps), (34, pps)]
        r.append(UInt8(arrays.count))
        for array in arrays {
            r.append(0x80 | array.type)
            r += [UInt8(array.nals.count >> 8), UInt8(array.nals.count & 0xFF)]
            for nal in array.nals {
                r += [UInt8(nal.count >> 8 & 0xFF), UInt8(nal.count & 0xFF)]
                r.append(contentsOf: nal)
            }
        }
        return Data(r)
    }

    /// Annex B SPS/PPS'ten `avcC` kaydı (ISO/IEC 14496-15 §5.3.3), 4 bayt uzunluk öneki.
    public static func avcC(fromAnnexB extradata: Data, bitDepth: Int) -> Data? {
        var sps: [Data] = [], pps: [Data] = []
        extradata.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for r in annexBRanges(raw) where r.count >= 2 {
                let nal = Data(bytes: base + r.lowerBound, count: r.count)
                switch raw[r.lowerBound] & 0x1F {
                case 7: sps.append(nal)
                case 8: pps.append(nal)
                default: break
                }
            }
        }
        guard let first = sps.first, first.count >= 4, !pps.isEmpty else { return nil }
        let head = [UInt8](first.prefix(4))
        let spsList = sps.prefix(31)
        let ppsList = pps.prefix(255)
        var r: [UInt8] = [1, head[1], head[2], head[3], 0xFF, 0xE0 | UInt8(spsList.count)]
        for nal in spsList {
            r += [UInt8(nal.count >> 8 & 0xFF), UInt8(nal.count & 0xFF)]
            r.append(contentsOf: nal)
        }
        r.append(UInt8(ppsList.count))
        for nal in ppsList {
            r += [UInt8(nal.count >> 8 & 0xFF), UInt8(nal.count & 0xFF)]
            r.append(contentsOf: nal)
        }
        // High profilleri için uzantı: 4:2:0, bit derinliği, SPS uzantısı yok.
        if [100, 110, 122, 144].contains(head[1]) {
            let depth = UInt8(clamping: max(bitDepth - 8, 0)) & 0x07
            let tail: [UInt8] = [0xFD, 0xF8 | depth, 0xF8 | depth, 0x00]
            r += tail
        }
        return Data(r)
    }

    private static func trimmedEnd(_ bytes: UnsafeRawBufferPointer, _ start: Int, _ end: Int) -> Int {
        var e = end
        while e > start, bytes[e - 1] == 0 { e -= 1 }
        return e
    }
}
