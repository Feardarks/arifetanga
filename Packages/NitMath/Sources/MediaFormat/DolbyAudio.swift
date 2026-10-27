import Foundation

/// AC-3 / E-AC-3 çerçeve başlığı (ETSI TS 102 366; FFmpeg `ac3_parser.c` ile aynı alan sırası).
/// S3 (AS-9): MKV/M2TS'deki E-AC-3'ü sıkıştırılmış hâliyle Apple'a vermek için `dec3`/`dac3` kutusu ve
/// JOC (Atmos) bayrağı buradan çıkarılır.
public struct DolbyAudioFrame: Equatable, Sendable {
    public enum FrameType: Int, Sendable {
        case independent = 0
        case dependent = 1
        /// AC-3 (bsid ≤ 10) ya da AC-3'ten dönüştürülmüş E-AC-3.
        case ac3Convert = 2
    }

    public var bitstreamID: Int
    public var frameType: FrameType
    public var substreamID: Int
    /// Bayt.
    public var frameSize: Int
    /// `fscod`; 3 ise yarı örnekleme hızı (E-AC-3).
    public var sampleRateCode: Int
    public var sampleRate: Int
    /// Ses bloğu sayısı (256 örnek); AC-3'te her zaman 6.
    public var blocks: Int
    /// `acmod`
    public var channelMode: Int
    public var lfeOn: Bool
    /// `bsmod` (bilgi meta verisi yoksa 0).
    public var bitstreamMode: Int
    /// Bağımlı alt akışın kanal haritası (`chanmap`, 16 bit), varsa.
    public var channelMap: UInt16?
    /// dB (−31…−1); 0 kodu −31 dB demektir.
    public var dialogNormalization: Int
    /// Yalnızca AC-3: `frmsizecod >> 1` (dac3 için).
    public var bitRateCode: Int?
    /// `flag_ec3_extension_type_a`: E-AC-3 JOC (Dolby Atmos).
    public var joc: Bool
    public var complexityIndex: Int

    public var isEAC3: Bool { bitstreamID > 10 }
    public var samples: Int { blocks * 256 }
    /// Tam bant kanal sayısı + LFE.
    public var channels: Int { Self.channelsPerMode[channelMode] + (lfeOn ? 1 : 0) }

    static let channelsPerMode = [2, 1, 2, 3, 3, 4, 4, 5]
    static let sampleRates = [48000, 44100, 32000]
    static let eac3Blocks = [1, 2, 3, 6]
    /// AC-3 çerçeve boyu (16-bit sözcük) [frmsizecod][fscod] (FFmpeg `ff_ac3_frame_size_tab`).
    static let ac3FrameWords: [[Int]] = [
        [64, 69, 96], [64, 70, 96], [80, 87, 120], [80, 88, 120], [96, 104, 144], [96, 105, 144],
        [112, 121, 168], [112, 122, 168], [128, 139, 192], [128, 140, 192], [160, 174, 240], [160, 175, 240],
        [192, 208, 288], [192, 209, 288], [224, 243, 336], [224, 244, 336], [256, 278, 384], [256, 279, 384],
        [320, 348, 480], [320, 349, 480], [384, 417, 576], [384, 418, 576], [448, 487, 672], [448, 488, 672],
        [512, 557, 768], [512, 558, 768], [640, 696, 960], [640, 697, 960], [768, 835, 1152], [768, 836, 1152],
        [896, 975, 1344], [896, 976, 1344], [1024, 1114, 1536], [1024, 1115, 1536], [1152, 1253, 1728],
        [1152, 1254, 1728], [1280, 1393, 1920], [1280, 1394, 1920],
    ]

    /// Bir çerçevenin başlığını ayrıştırır; senkron sözcüğü (0x0B77) ile başlamalıdır.
    public static func parse(_ bytes: some Collection<UInt8>) -> DolbyAudioFrame? {
        var r = BitReader(Array(bytes.prefix(128)))
        guard r.read(16) == 0x0B77 else { return nil }
        guard let bsid = r.peek(29).map({ Int($0 & 0x1F) }), bsid <= 16 else { return nil }
        return bsid <= 10 ? parseAC3(&r, bsid: bsid) : parseEAC3(&r, bsid: bsid)
    }

    private static func parseAC3(_ r: inout BitReader, bsid: Int) -> DolbyAudioFrame? {
        r.skip(16) // crc1
        guard let fscod = r.read(2).map({ Int($0) }), fscod < 3,
              let frmsizecod = r.read(6).map({ Int($0) }), frmsizecod <= 37 else { return nil }
        r.skip(5) // bsid
        guard let bsmod = r.read(3).map({ Int($0) }), let acmod = r.read(3).map({ Int($0) }) else { return nil }
        if acmod == 2 {
            r.skip(2) // dsurmod
        } else {
            if acmod & 1 != 0, acmod != 1 { r.skip(2) } // cmixlev
            if acmod & 4 != 0 { r.skip(2) } // surmixlev
        }
        guard let lfe = r.read(1), let dialnorm = r.read(5) else { return nil }
        let shift = max(bsid, 8) - 8
        return DolbyAudioFrame(bitstreamID: bsid, frameType: .ac3Convert, substreamID: 0,
                               frameSize: ac3FrameWords[frmsizecod][fscod] * 2, sampleRateCode: fscod,
                               sampleRate: sampleRates[fscod] >> shift, blocks: 6, channelMode: acmod, lfeOn: lfe == 1,
                               bitstreamMode: bsmod, channelMap: nil, dialogNormalization: dialnorm == 0 ? -31 : -Int(dialnorm),
                               bitRateCode: frmsizecod >> 1, joc: false, complexityIndex: 0)
    }

    private static func parseEAC3(_ r: inout BitReader, bsid: Int) -> DolbyAudioFrame? {
        guard let strmtyp = r.read(2).map({ Int($0) }), strmtyp != 3, let type = FrameType(rawValue: strmtyp),
              let substreamID = r.read(3).map({ Int($0) }), let frmsiz = r.read(11).map({ Int($0) }),
              let fscod = r.read(2).map({ Int($0) }) else { return nil }
        let frameSize = (frmsiz + 1) * 2
        guard frameSize >= 7 else { return nil }
        var sampleRate: Int
        var blocks = 6
        if fscod == 3 {
            guard let fscod2 = r.read(2).map({ Int($0) }), fscod2 < 3 else { return nil }
            sampleRate = sampleRates[fscod2] / 2
        } else {
            guard let numblkscod = r.read(2).map({ Int($0) }) else { return nil }
            blocks = eac3Blocks[numblkscod]
            sampleRate = sampleRates[fscod]
        }
        guard let acmod = r.read(3).map({ Int($0) }), let lfe = r.read(1) else { return nil }
        r.skip(5) // bsid
        var dialnorm = 31
        for i in 0..<(acmod == 0 ? 2 : 1) {
            guard let d = r.read(5), let compre = r.read(1) else { return nil }
            if i == 0 { dialnorm = Int(d) }
            if compre == 1 { r.skip(8) }
        }
        var channelMap: UInt16?
        if type == .dependent, r.read(1) == 1 {
            guard let map = r.read(16) else { return nil }
            channelMap = UInt16(map)
        }
        // Karıştırma meta verisi (mixmdate).
        if r.read(1) == 1 {
            if acmod > 2 {
                r.skip(2) // dmixmod
                if acmod & 1 != 0 { r.skip(6) } // ltrtcmixlev, lorocmixlev
                if acmod & 4 != 0 { r.skip(6) } // ltrtsurmixlev, lorosurmixlev
            }
            if lfe == 1, r.read(1) == 1 { r.skip(5) } // lfemixlevcod
            if type == .independent {
                for _ in 0..<(acmod == 0 ? 2 : 1) where r.read(1) == 1 { r.skip(6) } // pgmscl
                if r.read(1) == 1 { r.skip(6) } // extpgmscl
                switch r.read(2) {
                case 1: r.skip(5)
                case 2: r.skip(12)
                case 3:
                    guard let n = r.read(5) else { return nil }
                    r.skip((Int(n) + 2) * 8)
                default: break
                }
                if acmod < 2 {
                    for _ in 0..<(acmod == 0 ? 2 : 1) where r.read(1) == 1 { r.skip(14) } // paninfo
                }
                if r.read(1) == 1 { // frmmixcfginfoe
                    for _ in 0..<blocks where blocks == 1 || r.read(1) == 1 { r.skip(5) }
                }
            }
        }
        // Bilgi meta verisi (infomdate).
        var bsmod = 0
        if r.read(1) == 1 {
            guard let m = r.read(3) else { return nil }
            bsmod = Int(m)
            r.skip(2) // copyrightb, origbs
            if acmod == 2 { r.skip(4) } // dsurmod, dheadphonmod
            if acmod >= 6 { r.skip(2) } // dsurexmod
            for _ in 0..<(acmod == 0 ? 2 : 1) where r.read(1) == 1 { r.skip(8) } // audprodie
            if fscod != 3 { r.skip(1) } // sourcefscod
        }
        if type == .independent, blocks != 6 { r.skip(1) } // convsync
        if type == .ac3Convert, blocks == 6 || r.read(1) == 1 { r.skip(6) } // frmsizecod
        // Ek bit akışı bilgisi: ilk baytın son biti flag_ec3_extension_type_a (JOC).
        var joc = false
        var complexity = 0
        if r.read(1) == 1, r.read(6) != nil { // addbsie, addbsil
            r.skip(7)
            if r.read(1) == 1, let c = r.read(8) {
                joc = true
                complexity = Int(c)
            }
        }
        return DolbyAudioFrame(bitstreamID: bsid, frameType: type, substreamID: substreamID, frameSize: frameSize,
                               sampleRateCode: fscod, sampleRate: sampleRate, blocks: blocks, channelMode: acmod,
                               lfeOn: lfe == 1, bitstreamMode: bsmod, channelMap: channelMap,
                               dialogNormalization: dialnorm == 0 ? -31 : -dialnorm, bitRateCode: nil,
                               joc: joc, complexityIndex: complexity)
    }
}

/// Bir paketteki AC-3/E-AC-3 erişim birimi: bağımsız alt akış ve ona bağlı alt akışlar.
public struct DolbyAccessUnit: Equatable, Sendable {
    public var frames: [DolbyAudioFrame]

    /// Paketteki çerçeveleri sırayla ayrıştırır. Bozuk ya da eksik veride `nil`.
    public static func parse(_ data: Data) -> DolbyAccessUnit? {
        let bytes = [UInt8](data)
        var frames: [DolbyAudioFrame] = []
        var offset = 0
        while offset + 7 <= bytes.count {
            guard let frame = DolbyAudioFrame.parse(bytes[offset...]), frame.frameSize > 0,
                  offset + frame.frameSize <= bytes.count else { break }
            frames.append(frame)
            offset += frame.frameSize
        }
        return frames.isEmpty ? nil : DolbyAccessUnit(frames: frames)
    }

    public var primary: DolbyAudioFrame { frames[0] }
    public var isEAC3: Bool { primary.isEAC3 }
    public var joc: Bool { frames.contains { $0.joc } }
    /// İlk bağımsız alt akışın kanalları + bağımlı alt akışların eklediği kanallar.
    public var channels: Int {
        var total = primary.channels
        for frame in frames.dropFirst() where frame.frameType == .dependent {
            total += Self.addedChannels(frame)
        }
        return total
    }

    /// `dec3` gövdesi (ETSI TS 102 366 Ek F.6). Tek bağımsız alt akış (num_ind_sub = 0).
    /// - Parameter dataRate: kbps; verilmezse bu birimden hesaplanır.
    public func dec3(dataRate: Int? = nil) -> Data {
        let p = primary
        let dependents = frames.dropFirst().filter { $0.frameType == .dependent }
        var chanLoc = 0
        for frame in dependents {
            if let map = frame.channelMap {
                chanLoc |= Self.chanLoc(fromChannelMap: map)
            } else {
                chanLoc |= frame.channelMode
            }
        }
        let totalSize = frames.reduce(0) { $0 + $1.frameSize }
        let rate = dataRate ?? (8 * totalSize * p.sampleRate / max(p.samples, 1) / 1000)
        var w = BitWriter()
        w.write(rate, 13)
        w.write(0, 3) // num_ind_sub - 1
        w.write(p.sampleRateCode, 2)
        w.write(p.bitstreamID, 5)
        w.write(0, 1) // reserved
        w.write(0, 1) // asvc
        w.write(p.bitstreamMode, 3)
        w.write(p.channelMode, 3)
        w.write(p.lfeOn ? 1 : 0, 1)
        w.write(0, 3) // reserved
        w.write(dependents.count, 4)
        if dependents.isEmpty {
            w.write(0, 1) // reserved
        } else {
            w.write(chanLoc, 9)
        }
        if let jocFrame = frames.first(where: { $0.joc }) {
            w.write(0, 7) // reserved
            w.write(1, 1) // flag_ec3_extension_type_a
            w.write(jocFrame.complexityIndex, 8)
        }
        return w.bytes
    }

    /// `dac3` gövdesi (3 bayt). Yalnızca AC-3.
    public func dac3() -> Data? {
        let p = primary
        guard !p.isEAC3, let code = p.bitRateCode else { return nil }
        var w = BitWriter()
        w.write(p.sampleRateCode, 2)
        w.write(p.bitstreamID, 5)
        w.write(p.bitstreamMode, 3)
        w.write(p.channelMode, 3)
        w.write(p.lfeOn ? 1 : 0, 1)
        w.write(code, 5)
        w.write(0, 5) // reserved
        return w.bytes
    }

    /// ISO/IEC 14496-12 AudioSampleEntry (`ec-3` + `dec3` ya da `ac-3` + `dac3`), büyük uçlu.
    /// CoreMedia `CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionData` (ISO ailesi) ile okunur;
    /// böylece akış bir MP4'ten okunmuş gibi görünür ve JOC bayrağı Atmos olarak tanınır.
    public func isoSampleEntry(dataRate: Int? = nil) -> Data? {
        let type: String
        let child: Data
        if isEAC3 {
            type = "ec-3"
            child = Self.box("dec3", dec3(dataRate: dataRate))
        } else {
            guard let d = dac3() else { return nil }
            type = "ac-3"
            child = Self.box("dac3", d)
        }
        var body = Data(count: 6)                             // reserved
        body.append(contentsOf: [0, 1])                       // data_reference_index
        body.append(Data(count: 8))                           // version, revision, vendor
        body.append(contentsOf: Self.u16(channels))           // channelcount
        body.append(contentsOf: Self.u16(16))                 // samplesize
        body.append(Data(count: 4))                           // compression id, packet size
        body.append(contentsOf: Self.u32(UInt32(primary.sampleRate) << 16))
        body.append(child)
        return Self.box(type, body)
    }

    // MARK: Yardımcılar

    /// `chanmap` (16 bit, MSB = konum 0) → `chan_loc` (9 bit, MSB = Lc/Rc): konumlar 5…12 ve 14 (LFE2).
    static func chanLoc(fromChannelMap map: UInt16) -> Int {
        let m = Int(map)
        return (((m >> 3) & 0xFF) << 1) | ((m >> 1) & 1)
    }

    /// Bağımlı alt akışın eklediği kanal sayısı: kanal haritası varsa çiftler 2, tekler 1 sayılır.
    static func addedChannels(_ frame: DolbyAudioFrame) -> Int {
        guard let map = frame.channelMap else { return frame.channels }
        // Konum (MSB'den) → kanal sayısı (ETSI Tablo E.1.4): L, C, R, Ls, Rs, Lc/Rc, Lrs/Rrs, Cs, Ts,
        // Lsd/Rsd, Lw/Rw, Vhl/Vhr, Vhc, Lts/Rts, LFE2, LFE.
        let counts = [1, 1, 1, 1, 1, 2, 2, 1, 1, 2, 2, 2, 1, 2, 1, 1]
        var total = 0
        for i in 0..<16 where map & (1 << (15 - i)) != 0 { total += counts[i] }
        // Bağımlı alt akış bağımsızdaki kanalların yerine geçebilir; yalnızca yeni konumlar eklenir.
        let replaced = (0..<5).filter { map & (1 << (15 - $0)) != 0 }.count + (map & 1 != 0 ? 1 : 0)
        return max(total - replaced, 0)
    }

    static func box(_ type: String, _ payload: Data) -> Data {
        var d = Data(u32(UInt32(payload.count + 8)))
        d.append(contentsOf: Array(type.utf8))
        d.append(payload)
        return d
    }

    static func u16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }
    static func u32(_ v: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8),
         UInt8(truncatingIfNeeded: v)]
    }
}

/// E-AC-3'te 6'dan az bloklu çerçeveleri 1536 örneklik erişim birimlerine birleştirir (MP4'teki gibi).
/// AC-3 ve zaten 6 bloklu paketler olduğu gibi geçer.
public struct DolbyPacketizer: Sendable {
    private var pending = Data()
    private var pendingBlocks = 0
    private var pendingStart: Int64?

    public init() {}

    /// - Returns: Tamamlanan birim (veri, ilk paketin zaman damgası) ya da birikiyorsa `nil`.
    public mutating func push(_ data: Data, timestamp: Int64) -> (data: Data, timestamp: Int64)? {
        guard let unit = DolbyAccessUnit.parse(data) else { return nil }
        let blocks = unit.primary.blocks
        if pendingBlocks == 0, blocks >= 6 { return (data, timestamp) }
        if pendingBlocks == 0 { pendingStart = timestamp }
        pending.append(data)
        pendingBlocks += blocks
        guard pendingBlocks >= 6, let start = pendingStart else { return nil }
        let out = (pending, start)
        reset()
        return out
    }

    public mutating func reset() {
        pending = Data()
        pendingBlocks = 0
        pendingStart = nil
    }
}

// MARK: Bit okuma / yazma

struct BitReader {
    private let bytes: [UInt8]
    private var position = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    func peek(_ n: Int) -> UInt32? {
        var copy = self
        return copy.read(n)
    }

    mutating func read(_ n: Int) -> UInt32? {
        guard n <= 32, position + n <= bytes.count * 8 else { return nil }
        var v: UInt32 = 0
        for _ in 0..<n {
            let bit = (bytes[position >> 3] >> (7 - UInt8(position & 7))) & 1
            v = (v << 1) | UInt32(bit)
            position += 1
        }
        return v
    }

    mutating func skip(_ n: Int) {
        position += n
    }
}

struct BitWriter {
    private(set) var data = Data()
    private var current: UInt8 = 0
    private var count = 0

    mutating func write(_ value: Int, _ bits: Int) {
        for i in stride(from: bits - 1, through: 0, by: -1) {
            current = (current << 1) | UInt8((value >> i) & 1)
            count += 1
            if count == 8 {
                data.append(current)
                current = 0
                count = 0
            }
        }
    }

    /// Kalan bitleri sıfırla tamamlar.
    var bytes: Data {
        var copy = self
        while copy.count != 0 { copy.write(0, 1) }
        return copy.data
    }
}
