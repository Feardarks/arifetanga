import Foundation

/// Hız testi sonucu (AS-23): ardışık okuma hızı ve rastgele erişim gecikmesi.
public struct ThroughputResult: Equatable, Sendable {
    public var label: String
    public var bytes: Int64 = 0
    public var seconds = 0.0
    /// İlk ardışık okumanın süresi (ms): bağlantının ilk bayt gecikmesi.
    public var firstReadMs = 0.0
    public var randomReads = 0
    public var randomMeanMs = 0.0
    public var randomMaxMs = 0.0

    public var megabytesPerSecond: Double { seconds > 0 ? Double(bytes) / seconds / 1_000_000 : 0 }

    public init(label: String) {
        self.label = label
    }
}

/// Bir kaynağın ham okuma başarımı (önden okuma tamponu olmadan): libsmb2 ile Dosyalar'ın SMB'si aynı yöntemle
/// karşılaştırılır. Ardışık bölüm `seconds` süresince ya da `maxBytes`'a kadar, `requestSize` baytlık okumalarla;
/// rastgele bölüm dosyanın farklı yerlerinden `randomSize` baytlık okumalarla (sarma maliyetinin ağ kısmı).
public enum ThroughputTest {
    /// - Parameter start: Ardışık bölümün başlangıcı; art arda testler farklı bölgeleri okusun (sunucu önbelleği
    ///   ikinci testi kayırmasın).
    public static func run(source: RangeSource, label: String, start: Int64 = 0, seconds: Double = 8, maxBytes: Int64 = 1 << 30,
                           requestSize: Int = 4 << 20, randomReads: Int = 16, randomSize: Int = 1 << 20,
                           seed: UInt64 = 0x5EED, cancelled: () -> Bool = { false }) throws -> ThroughputResult {
        var result = ThroughputResult(label: label)
        guard source.size > 0 else { return result }
        var buffer = [UInt8](repeating: 0, count: max(requestSize, randomSize))
        let first = min(max(start, 0), source.size)
        let limit = min(first + maxBytes, source.size)
        let began = DispatchTime.now().uptimeNanoseconds
        var offset = first
        try buffer.withUnsafeMutableBytes { raw in
            while offset < limit, !cancelled() {
                let want = Int(min(Int64(requestSize), limit - offset))
                let readStart = DispatchTime.now().uptimeNanoseconds
                let n = try source.read(into: UnsafeMutableRawBufferPointer(rebasing: raw[0..<want]), at: offset)
                if offset == first { result.firstReadMs = elapsed(since: readStart) * 1000 }
                if n <= 0 { break }
                offset += Int64(n)
                if elapsed(since: began) >= seconds { break }
            }
        }
        result.bytes = offset - first
        result.seconds = elapsed(since: began)

        // Rastgele okumalar: dosyanın her yerinden (ardışık bölüm atlanır), sabit tohumla tekrarlanabilir.
        var state = seed
        var total = 0.0
        let span = source.size - Int64(randomSize)
        try buffer.withUnsafeMutableBytes { raw in
            for _ in 0..<randomReads where span > 0 && !cancelled() {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let fraction = Double(state >> 11) / Double(1 << 53)
                var position = Int64(fraction * Double(span))
                if position >= first, position < offset { position = (position + (offset - first)) % max(span, 1) }
                let readStart = DispatchTime.now().uptimeNanoseconds
                var filled = 0
                while filled < randomSize {
                    let n = try source.read(into: UnsafeMutableRawBufferPointer(rebasing: raw[filled..<randomSize]),
                                            at: position + Int64(filled))
                    if n <= 0 { break }
                    filled += n
                }
                let ms = elapsed(since: readStart) * 1000
                total += ms
                result.randomMaxMs = max(result.randomMaxMs, ms)
                result.randomReads += 1
            }
        }
        result.randomMeanMs = result.randomReads > 0 ? total / Double(result.randomReads) : 0
        return result
    }

    private static func elapsed(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }
}
