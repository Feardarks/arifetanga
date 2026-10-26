import Foundation
import XCTest
@testable import MediaFormat

/// M2TS/TS (Annex B) → VideoToolbox (uzunluk önekli + hvcC/avcC) dönüşümü.
final class NALUnitsTests: XCTestCase {
    // x265 1080p Main çıktısındaki parametre kümeleri (kaçışlı, NAL başlığı dahil).
    private let vps: [UInt8] = [0x40, 0x01, 0x0C, 0x01, 0xFF, 0xFF, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00,
                                0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x5D, 0x95, 0x98, 0x09]
    private let sps: [UInt8] = [0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00,
                                0x00, 0x03, 0x00, 0x5D, 0xA0, 0x02, 0x80, 0x80, 0x2D, 0x16, 0x59, 0x59, 0xA4, 0x93,
                                0x2B, 0xC0, 0x5A, 0x70, 0x80]
    private let pps: [UInt8] = [0x44, 0x01, 0xC1, 0x72, 0xB4, 0x62, 0x40]

    private func annexB(_ nals: [[UInt8]], longCodes: Bool = true) -> Data {
        var out: [UInt8] = []
        for (i, nal) in nals.enumerated() {
            out += (longCodes || i == 0) ? [0, 0, 0, 1] : [0, 0, 1]
            out += nal
        }
        return Data(out)
    }

    func testDetectsAnnexB() {
        XCTAssertTrue(NALUnits.isAnnexB(Data([0, 0, 0, 1, 0x40])))
        XCTAssertTrue(NALUnits.isAnnexB(Data([0, 0, 1, 0x40])))
        XCTAssertFalse(NALUnits.isAnnexB(Data([1, 0x01, 0x60, 0x00])), "hvcC 0x01 ile başlar")
        XCTAssertFalse(NALUnits.isAnnexB(Data([0, 0])))
    }

    func testAnnexBToLengthPrefixedRoundTrip() {
        let slice: [UInt8] = [0x26, 0x01, 0xAF, 0x00, 0x00, 0x03, 0x01, 0x7F]
        let rpu: [UInt8] = [0x7C, 0x01, 0x19, 0x08, 0x09]
        // Karışık 3/4 baytlık başlangıç kodları ve NAL sonrası sıfır dolgu.
        var stream = [UInt8](annexB([vps, sps, pps], longCodes: false))
        stream += [0, 0, 0, 0, 1] + slice + [0, 0] + [0, 0, 1] + rpu
        let converted = Data(stream).withUnsafeBytes { NALUnits.lengthPrefixed(fromAnnexB: $0) }

        let nals: [[UInt8]] = converted.withUnsafeBytes { raw in
            NALUnits.lengthPrefixedRanges(raw, lengthSize: 4).map { [UInt8](raw[$0]) }
        }
        XCTAssertEqual(nals, [vps, sps, pps, slice, rpu])
        let types: [UInt8] = converted.withUnsafeBytes { raw in
            NALUnits.lengthPrefixedRanges(raw, lengthSize: 4).map { NALUnits.hevcType(raw, $0) }
        }
        XCTAssertEqual(types, [32, 33, 34, 19, 62])
    }

    func testLengthPrefixedRangesStopsAtTruncatedUnit() {
        let data = Data([0, 0, 0, 2, 0xAA, 0xBB, 0, 0, 0, 9, 0xCC])
        let ranges = data.withUnsafeBytes { NALUnits.lengthPrefixedRanges($0, lengthSize: 4) }
        XCTAssertEqual(ranges, [4..<6])
    }

    func testUnescapeRemovesEmulationPrevention() {
        XCTAssertEqual(NALUnits.unescape([0x60, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x01]),
                       [0x60, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x01])
        XCTAssertEqual(NALUnits.unescape([0x00, 0x03, 0x00]), [0x00, 0x03, 0x00], "tek sıfırdan sonraki 03 korunur")
    }

    func testBuildsHvcCFromAnnexBParameterSets() throws {
        let record = try XCTUnwrap(NALUnits.hvcC(fromAnnexB: annexB([vps, sps, pps]), bitDepth: 10))
        let r = [UInt8](record)
        XCTAssertEqual(r[0], 1, "configurationVersion")
        // Genel profil/katman/seviye: SPS'in kaçışsız PTL'i (Main, uyumluluk 0x60, kısıt 0x90, seviye 3.1).
        XCTAssertEqual(Array(r[1...12]), [0x01, 0x60, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 0x5D])
        XCTAssertEqual(r[16], 0xFD, "4:2:0")
        XCTAssertEqual(r[17], 0xFA, "luma 10 bit")
        XCTAssertEqual(r[18], 0xFA, "chroma 10 bit")
        XCTAssertEqual(r[21], 0x0F, "1 zamansal katman, iç içe, 4 bayt uzunluk öneki")
        XCTAssertEqual(r[22], 3, "VPS, SPS, PPS dizileri")

        var i = 23
        for (type, nal) in [(UInt8(32), vps), (33, sps), (34, pps)] {
            XCTAssertEqual(r[i], 0x80 | type)
            XCTAssertEqual(Int(r[i + 1]) << 8 | Int(r[i + 2]), 1)
            let length = Int(r[i + 3]) << 8 | Int(r[i + 4])
            XCTAssertEqual(Array(r[(i + 5)..<(i + 5 + length)]), nal)
            i += 5 + length
        }
        XCTAssertEqual(i, r.count)
    }

    func testHvcCRequiresAllParameterSets() {
        XCTAssertNil(NALUnits.hvcC(fromAnnexB: annexB([sps, pps]), bitDepth: 10))
    }

    func testBuildsAvcCFromAnnexB() throws {
        let sps: [UInt8] = [0x67, 0x64, 0x00, 0x28, 0xAC, 0xD9, 0x40, 0x78]
        let pps: [UInt8] = [0x68, 0xEB, 0xE3, 0xCB]
        let record = try XCTUnwrap(NALUnits.avcC(fromAnnexB: annexB([sps, pps], longCodes: false), bitDepth: 8))
        var expected: [UInt8] = [1, 0x64, 0x00, 0x28, 0xFF, 0xE1, 0x00, UInt8(sps.count)]
        expected += sps
        expected += [1, 0x00, UInt8(pps.count)]
        expected += pps
        expected += [0xFD, 0xF8, 0xF8, 0x00]
        XCTAssertEqual([UInt8](record), expected)
    }

    func testAppendLengthIsBigEndian() {
        var data = Data()
        NALUnits.appendLength(0x0102_0304, size: 4, to: &data)
        NALUnits.appendLength(0x0506, size: 2, to: &data)
        XCTAssertEqual([UInt8](data), [1, 2, 3, 4, 5, 6])
    }
}
