import Foundation

/// Aralıklı okunabilen bir kaynak (SMB dosyası, HTTP Range, yerel dosya). Okumalar bloklar; aynı anda yalnızca
/// tek bir thread'den (önden okuma thread'i) çağrılır.
public protocol RangeSource: AnyObject {
    /// Toplam boyut (bayt).
    var size: Int64 { get }
    /// `offset`'ten en çok `buffer.count` bayt okur ve okunan bayt sayısını döndürür (0: dosya sonu).
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: Int64) throws -> Int
}

/// Önden okuma tamponunun ölçümleri (HUD, CSV; AS-3, AS-23).
public struct ReadAheadStats: Equatable, Sendable {
    /// Okuma konumundan itibaren kesintisiz hazır bayt.
    public var bufferedAhead: Int64 = 0
    public var bytesFetched: Int64 = 0
    /// Son okumaların hızı (MB/s, üstel ortalama); henüz okuma yoksa `nil`.
    public var throughputMBps: Double?
    /// Okuyucunun (demux) veri beklediği kez sayısı, toplam ve en uzun bekleme (s).
    public var waits = 0
    public var waitSeconds = 0.0
    public var longestWait = 0.0
    public var errors = 0
    public var lastError: String?
}

/// Aralıklı kaynağın önünde, ayrı bir thread'in doldurduğu parça önbelleği (02-cozum §7.4: önden okuma).
/// Okuyucu (FFmpeg'in AVIOContext'i) yalnızca önbellekten okur ve kaynağa hiç dokunmaz; böylece kaynak tek
/// thread'den kullanılır. Pencere: okuma konumundan `aheadLimit` ileri, `behindLimit` geri; dışındaki parçalar atılır.
public final class ReadAheadStream: @unchecked Sendable {
    public let size: Int64
    public let chunkSize: Int
    public let aheadLimit: Int64
    public let behindLimit: Int64

    private let source: RangeSource
    private let condition = NSCondition()
    private var chunks: [Int64: Data] = [:]
    private var position: Int64 = 0
    private var closed = false
    private var failedChunk: Int64?
    private var statsValue = ReadAheadStats()
    private var thread: Thread?
    private let retries: Int

    /// - Parameters:
    ///   - chunkSize: Önbellek parçası (bayt). Kaynak bir okumada daha azını verirse parça döngüyle tamamlanır.
    ///   - retries: Bir parçanın okunması bu kadar kez denenir (ağ kesintisi); sonra okuyucuya hata döner.
    public init(source: RangeSource, chunkSize: Int = 2 << 20, aheadLimit: Int64 = 96 << 20, behindLimit: Int64 = 16 << 20,
                retries: Int = 6) {
        self.source = source
        size = source.size
        self.chunkSize = max(chunkSize, 4096)
        self.aheadLimit = max(aheadLimit, Int64(chunkSize))
        self.behindLimit = behindLimit
        self.retries = max(retries, 1)
        let thread = Thread { [self] in prefetchLoop() }
        thread.name = "arif.readahead"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    /// Okuma konumu.
    public var offset: Int64 {
        condition.lock()
        defer { condition.unlock() }
        return position
    }

    public var stats: ReadAheadStats {
        condition.lock()
        defer { condition.unlock() }
        var s = statsValue
        s.bufferedAhead = contiguousAhead()
        return s
    }

    /// Okuma konumundan en çok `buffer.count` bayt okur. Veri gelene kadar bloklar.
    /// - Returns: Okunan bayt; 0 dosya sonu; −1 hata ya da kapatıldı.
    public func read(into buffer: UnsafeMutableRawBufferPointer) -> Int {
        guard buffer.count > 0 else { return 0 }
        condition.lock()
        defer { condition.unlock() }
        guard !closed else { return -1 }
        guard position < size else { return 0 }
        let index = position / Int64(chunkSize)
        var waitStart: UInt64?
        while chunks[index] == nil, !closed, failedChunk != index {
            if waitStart == nil {
                waitStart = DispatchTime.now().uptimeNanoseconds
                condition.broadcast()
            }
            condition.wait()
        }
        if let waitStart {
            let waited = Double(DispatchTime.now().uptimeNanoseconds - waitStart) / 1e9
            statsValue.waits += 1
            statsValue.waitSeconds += waited
            statsValue.longestWait = max(statsValue.longestWait, waited)
        }
        guard !closed, let chunk = chunks[index] else { return -1 }
        let inChunk = Int(position - index * Int64(chunkSize))
        let count = min(buffer.count, chunk.count - inChunk)
        guard count > 0 else { return 0 }
        chunk.withUnsafeBytes { raw in
            buffer.baseAddress!.copyMemory(from: raw.baseAddress! + inChunk, byteCount: count)
        }
        position += Int64(count)
        condition.broadcast()
        return count
    }

    /// Okuma konumunu taşır (FFmpeg sarması). Pencere yeni konuma kayar; önbellekte olan parçalar korunur.
    public func seek(to offset: Int64) {
        condition.lock()
        position = min(max(offset, 0), size)
        if let failed = failedChunk, failed != position / Int64(chunkSize) { failedChunk = nil }
        condition.broadcast()
        condition.unlock()
    }

    /// Kapatır: bekleyen okuma −1 döner, önden okuma thread'i o anki kaynak okuması bitince çıkar.
    public func close() {
        condition.lock()
        closed = true
        chunks.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    // MARK: Önden okuma

    private func prefetchLoop() {
        condition.lock()
        while !closed {
            guard let next = nextMissingChunk() else {
                condition.wait()
                continue
            }
            condition.unlock()
            let start = DispatchTime.now().uptimeNanoseconds
            let result = fetch(chunk: next)
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            condition.lock()
            switch result {
            case .success(let data):
                if !closed {
                    chunks[next] = data
                    evict()
                }
                statsValue.bytesFetched += Int64(data.count)
                if seconds > 0, data.count > 0 {
                    let rate = Double(data.count) / seconds / 1_000_000
                    statsValue.throughputMBps = statsValue.throughputMBps.map { $0 * 0.7 + rate * 0.3 } ?? rate
                }
            case .failure(let error):
                statsValue.errors += 1
                statsValue.lastError = "\(error)"
                failedChunk = next
            }
            condition.broadcast()
        }
        condition.unlock()
    }

    /// Okuma konumundan ileriye doğru ilk eksik parça (pencere içinde); hepsi hazırsa `nil`.
    private func nextMissingChunk() -> Int64? {
        guard size > 0 else { return nil }
        let first = position / Int64(chunkSize)
        let last = min((size - 1) / Int64(chunkSize), (position + aheadLimit) / Int64(chunkSize))
        guard first <= last else { return nil }
        for index in first...last where chunks[index] == nil && failedChunk != index { return index }
        return nil
    }

    private func evict() {
        let low = max(position - behindLimit, 0) / Int64(chunkSize)
        let high = (position + aheadLimit) / Int64(chunkSize)
        for key in chunks.keys where key < low || key > high { chunks.removeValue(forKey: key) }
    }

    private func contiguousAhead() -> Int64 {
        var index = position / Int64(chunkSize)
        var total: Int64 = 0
        var inChunk = position - index * Int64(chunkSize)
        while let chunk = chunks[index] {
            total += Int64(chunk.count) - inChunk
            inChunk = 0
            index += 1
        }
        return max(total, 0)
    }

    private func fetch(chunk index: Int64) -> Result<Data, Error> {
        let start = index * Int64(chunkSize)
        let length = Int(min(Int64(chunkSize), size - start))
        var data = Data(count: length)
        var lastError: Error?
        for attempt in 0..<retries {
            do {
                var filled = 0
                try data.withUnsafeMutableBytes { raw in
                    while filled < length {
                        let slice = UnsafeMutableRawBufferPointer(rebasing: raw[filled..<length])
                        let n = try source.read(into: slice, at: start + Int64(filled))
                        if n <= 0 { break }
                        filled += n
                    }
                }
                if filled < length { data.count = filled }
                return .success(data)
            } catch {
                lastError = error
                condition.lock()
                let stop = closed
                condition.unlock()
                if stop { break }
                // Ağ kesintisinde artan bekleme: 0,25 s, 0,5 s, 0,75 s…
                Thread.sleep(forTimeInterval: 0.25 * Double(attempt + 1))
            }
        }
        return .failure(lastError ?? ReadAheadError.closed)
    }
}

public enum ReadAheadError: Error, CustomStringConvertible {
    case closed

    public var description: String { "kapatıldı" }
}
