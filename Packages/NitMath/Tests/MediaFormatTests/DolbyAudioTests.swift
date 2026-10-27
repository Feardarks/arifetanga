import Foundation
import XCTest
@testable import MediaFormat

/// E-AC-3 / AC-3 başlığı, JOC (Atmos) tespiti ve `dec3`/`dac3`. Beklenen baytlar ETSI TS 102 366 Ek F alan
/// sırasıyla elle hesaplandı; ayrıştırma sırası FFmpeg `ac3_parser.c` ile aynı.
final class DolbyAudioTests: XCTestCase {
    /// 48 kHz E-AC-3 çerçevesi. `joc` verilirse addbsi'de flag_ec3_extension_type_a ve karmaşıklık yazılır.
    private func eac3Frame(size: Int, numblkscod: Int = 3, acmod: Int = 7, lfe: Bool = true, joc: Int? = nil,
                           dependentMap: UInt16? = nil) -> [UInt8] {
        let dependent = dependentMap != nil
        var w = BitWriter()
        w.write(0x0B77, 16)
        w.write(dependent ? 1 : 0, 2) // strmtyp
        w.write(0, 3)                 // substreamid
        w.write(size / 2 - 1, 11)     // frmsiz
        w.write(0, 2)                 // fscod: 48 kHz
        w.write(numblkscod, 2)
        w.write(acmod, 3)
        w.write(lfe ? 1 : 0, 1)
        w.write(16, 5)                // bsid
        w.write(27, 5)                // dialnorm
        w.write(0, 1)                 // compre
        if let map = dependentMap {
            w.write(1, 1)
            w.write(Int(map), 16)
        }
        w.write(0, 1)                 // mixmdate
        w.write(1, 1)                 // infomdate
        w.write(0, 3)                 // bsmod
        w.write(0, 2)                 // copyrightb, origbs
        if acmod == 2 { w.write(0, 4) }
        if acmod >= 6 { w.write(0, 2) }
        w.write(0, 1)                 // audprodie
        w.write(0, 1)                 // sourcefscod
        if !dependent, numblkscod != 3 { w.write(0, 1) } // convsync
        if let joc {
            w.write(1, 1)             // addbsie
            w.write(1, 6)             // addbsil
            w.write(1, 8)             // 7 ayrılmış bit + flag_ec3_extension_type_a
            w.write(joc, 8)           // complexity_index_type_a
        } else {
            w.write(0, 1)
        }
        var bytes = [UInt8](w.bytes)
        bytes += [UInt8](repeating: 0, count: size - bytes.count)
        return bytes
    }

    /// AC-3 5.1, 48 kHz, 448 kbps (frmsizecod 28 → 1792 bayt), bsid 8.
    private func ac3Frame() -> [UInt8] {
        var w = BitWriter()
        w.write(0x0B77, 16)
        w.write(0, 16)  // crc1
        w.write(0, 2)   // fscod
        w.write(28, 6)  // frmsizecod
        w.write(8, 5)   // bsid
        w.write(0, 3)   // bsmod
        w.write(7, 3)   // acmod 3/2
        w.write(1, 2)   // cmixlev
        w.write(1, 2)   // surmixlev
        w.write(1, 1)   // lfeon
        w.write(27, 5)  // dialnorm
        var bytes = [UInt8](w.bytes)
        bytes += [UInt8](repeating: 0, count: 1792 - bytes.count)
        return bytes
    }

    func testParsesEAC3JOCFrame() throws {
        let f = try XCTUnwrap(DolbyAudioFrame.parse(eac3Frame(size: 768, joc: 16)))
        XCTAssertTrue(f.isEAC3)
        XCTAssertEqual(f.frameType, .independent)
        XCTAssertEqual(f.frameSize, 768)
        XCTAssertEqual(f.sampleRate, 48000)
        XCTAssertEqual(f.blocks, 6)
        XCTAssertEqual(f.channels, 6)
        XCTAssertEqual(f.dialogNormalization, -27)
        XCTAssertTrue(f.joc)
        XCTAssertEqual(f.complexityIndex, 16)
    }

    func testDec3MarksAtmos() throws {
        let unit = try XCTUnwrap(DolbyAccessUnit.parse(Data(eac3Frame(size: 768, joc: 16))))
        XCTAssertTrue(unit.joc)
        XCTAssertEqual([UInt8](unit.dec3()), [0x06, 0x00, 0x20, 0x0F, 0x00, 0x01, 0x10])
    }

    func testDec3WithDependentSubstream() throws {
        // 7.1: bağımsız 5.1 + bağımlı (Ls, Rs, Lrs/Rrs) → chan_loc yalnızca Lrs/Rrs biti (0x80).
        let packet = eac3Frame(size: 768) + eac3Frame(size: 512, acmod: 2, lfe: false, dependentMap: 0x1A00)
        let unit = try XCTUnwrap(DolbyAccessUnit.parse(Data(packet)))
        XCTAssertEqual(unit.frames.count, 2)
        XCTAssertEqual(unit.frames[1].frameType, .dependent)
        XCTAssertEqual(unit.channels, 8)
        XCTAssertFalse(unit.joc)
        XCTAssertEqual([UInt8](unit.dec3()), [0x0A, 0x00, 0x20, 0x0F, 0x02, 0x80])
    }

    func testAC3AndDac3() throws {
        let f = try XCTUnwrap(DolbyAudioFrame.parse(ac3Frame()))
        XCTAssertFalse(f.isEAC3)
        XCTAssertEqual(f.frameSize, 1792)
        XCTAssertEqual(f.bitRateCode, 14)
        XCTAssertEqual(f.channels, 6)
        XCTAssertEqual(f.dialogNormalization, -27)
        let unit = try XCTUnwrap(DolbyAccessUnit.parse(Data(ac3Frame())))
        XCTAssertEqual(unit.dac3().map { [UInt8]($0) }, [0x10, 0x3D, 0xC0])
    }

    func testISOSampleEntryLayout() throws {
        let unit = try XCTUnwrap(DolbyAccessUnit.parse(Data(eac3Frame(size: 768, joc: 16))))
        let entry = [UInt8](try XCTUnwrap(unit.isoSampleEntry()))
        XCTAssertEqual(entry.count, 36 + 8 + 7)
        XCTAssertEqual(Array(entry[0..<4]), [0, 0, 0, 51])
        XCTAssertEqual(String(decoding: entry[4..<8], as: UTF8.self), "ec-3")
        XCTAssertEqual(Array(entry[14..<16]), [0, 1], "data_reference_index")
        XCTAssertEqual(Array(entry[24..<26]), [0, 6], "channelcount")
        XCTAssertEqual(Array(entry[32..<36]), [0xBB, 0x80, 0, 0], "48000 << 16")
        XCTAssertEqual(Array(entry[36..<40]), [0, 0, 0, 15])
        XCTAssertEqual(String(decoding: entry[40..<44], as: UTF8.self), "dec3")
        XCTAssertEqual(Array(entry[44...]), [0x06, 0x00, 0x20, 0x0F, 0x00, 0x01, 0x10])
    }

    func testPacketizerJoinsShortFrames() {
        var p = DolbyPacketizer()
        let frame = Data(eac3Frame(size: 256, numblkscod: 1))
        XCTAssertNil(p.push(frame, timestamp: 100))
        XCTAssertNil(p.push(frame, timestamp: 110))
        let out = p.push(frame, timestamp: 120)
        XCTAssertEqual(out?.data.count, 768)
        XCTAssertEqual(out?.timestamp, 100)
        let full = Data(eac3Frame(size: 768))
        XCTAssertEqual(p.push(full, timestamp: 200)?.timestamp, 200, "6 bloklu paket olduğu gibi geçer")
    }

    func testTruncatedPacketIsRejected() {
        let frame = eac3Frame(size: 768)
        XCTAssertNil(DolbyAccessUnit.parse(Data(frame.prefix(500))))
        XCTAssertNil(DolbyAudioFrame.parse([0x12, 0x34, 0x56]))
    }
}

final class SpeakerLayoutTests: XCTestCase {
    private typealias C = SpeakerLayout.FFChannel

    func testSevenOneMapsBackPairToRearSurround() {
        // FFmpeg 7.1 sırası: FL FR FC LFE BL BR SL SR.
        let p = SpeakerLayout.positions(ffmpegChannels: [C.frontLeft, C.frontRight, C.frontCenter, C.lowFrequency,
                                                         C.backLeft, C.backRight, C.sideLeft, C.sideRight])
        XCTAssertEqual(p, [.left, .right, .center, .lfe, .rearSurroundLeft, .rearSurroundRight, .surroundLeft, .surroundRight])
        XCTAssertEqual(SpeakerLayout.name(p), "7.1")
    }

    func testFiveOneBackAndSideBothBecomeSurround() {
        let back = SpeakerLayout.positions(ffmpegChannels: [C.frontLeft, C.frontRight, C.frontCenter, C.lowFrequency,
                                                            C.backLeft, C.backRight])
        let side = SpeakerLayout.positions(ffmpegChannels: [C.frontLeft, C.frontRight, C.frontCenter, C.lowFrequency,
                                                            C.sideLeft, C.sideRight])
        XCTAssertEqual(back, [.left, .right, .center, .lfe, .surroundLeft, .surroundRight])
        XCTAssertEqual(back, side)
        XCTAssertEqual(SpeakerLayout.name(back), "5.1")
    }

    func testHeightChannelsAndNames() {
        let p = SpeakerLayout.positions(ffmpegChannels: [C.frontLeft, C.frontRight, C.frontCenter, C.lowFrequency,
                                                         C.backLeft, C.backRight, C.sideLeft, C.sideRight,
                                                         C.topFrontLeft, C.topFrontRight, C.topBackLeft, C.topBackRight])
        XCTAssertEqual(SpeakerLayout.name(p), "7.1.4")
        XCTAssertEqual(SpeakerLayout.name([.left, .right]), "2.0")
        XCTAssertEqual(SpeakerLayout.name([.center]), "1.0")
        XCTAssertEqual(SpeakerLayout.defaultPositions(channelCount: 8).count, 8)
        XCTAssertEqual(SpeakerLayout.positions(ffmpegChannels: [99]), [.unknown])
    }
}
