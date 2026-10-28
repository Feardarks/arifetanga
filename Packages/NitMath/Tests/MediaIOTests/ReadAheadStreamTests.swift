import Foundation
import XCTest
@testable import MediaIO

/// Bayt değeri konumdan türeyen, gecikmeli ve okuma boyutu sınırlı sahte kaynak (SMB'nin azami okuma boyutu gibi).
private final class FakeSource: RangeSource, @unchecked Sendable {
    let size: Int64
    let latency: TimeInterval
    let maxRead: Int
    private let lock = NSLock()
    private var failing: Set<Int64> = []
    private(set) var reads = 0

    init(size: Int64, latency: TimeInterval = 0.001, maxRead: Int = 64 << 10) {
        self.size = size
        self.latency = latency
        self.maxRead = maxRead
    }

    static func byte(at offset: Int64) -> UInt8 { UInt8(truncatingIfNeeded: offset &* 31 &+ (offset >> 9) &+ 7) }

    /// Bu konumu içeren okumalar hata verir (ağ kesintisi).
    func fail(at offset: Int64, _ on: Bool) {
        lock.lock()
        if on { failing.insert(offset) } else { failing.remove(offset) }
        lock.unlock()
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: Int64) throws -> Int {
        if latency > 0 { Thread.sleep(forTimeInterval: latency) }
        let count = Int(min(Int64(min(buffer.count, maxRead)), max(size - offset, 0)))
        lock.lock()
        reads += 1
        let broken = failing.contains { $0 >= offset && $0 < offset + Int64(count) }
        lock.unlock()
        if broken { throw NSError(domain: "fake", code: 5) }
        for i in 0..<count { buffer[i] = Self.byte(at: offset + Int64(i)) }
        return count
    }
}

private final class ResultBox: @unchecked Sendable {
    var value = 0
}

final class ReadAheadStreamTests: XCTestCase {
    private func readAll(_ stream: ReadAheadStream, sizes: [Int]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while true {
            var buffer = [UInt8](repeating: 0, count: sizes[i % sizes.count])
            let n = buffer.withUnsafeMutableBytes { stream.read(into: $0) }
            if n <= 0 { break }
            out += buffer[0..<n]
            i += 1
        }
        return out
    }

    func testSequentialReadReturnsExactBytes() {
        let source = FakeSource(size: 5_000_123)
        let stream = ReadAheadStream(source: source, chunkSize: 256 << 10, aheadLimit: 2 << 20, behindLimit: 512 << 10)
        defer { stream.close() }
        let bytes = readAll(stream, sizes: [32768, 1, 100_000, 4096, 777])
        XCTAssertEqual(bytes.count, 5_000_123)
        for (i, b) in bytes.enumerated() where b != FakeSource.byte(at: Int64(i)) {
            XCTFail("bayt \(i) farklı")
            break
        }
        XCTAssertEqual(stream.stats.bytesFetched, 5_000_123)
        XCTAssertNotNil(stream.stats.throughputMBps)
    }

    func testSeekReadsFromNewPosition() {
        let source = FakeSource(size: 20 << 20)
        let stream = ReadAheadStream(source: source, chunkSize: 1 << 20, aheadLimit: 4 << 20, behindLimit: 1 << 20)
        defer { stream.close() }
        for target: Int64 in [15_000_000, 3, 9_999_999, 20 << 20 - 10, 0] {
            stream.seek(to: target)
            XCTAssertEqual(stream.offset, target)
            var buffer = [UInt8](repeating: 0, count: 64)
            let n = buffer.withUnsafeMutableBytes { stream.read(into: $0) }
            XCTAssertEqual(n, Int(min(64, (20 << 20) - target)))
            for i in 0..<n { XCTAssertEqual(buffer[i], FakeSource.byte(at: target + Int64(i))) }
        }
        stream.seek(to: 20 << 20)
        var tail = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(tail.withUnsafeMutableBytes { stream.read(into: $0) }, 0, "dosya sonu")
    }

    /// Önbellek doluyken okuma beklemez; soğuk başlangıçta bekleme sayılır.
    func testWaitsAreCountedAndBufferFillsAhead() {
        let source = FakeSource(size: 8 << 20, latency: 0.01)
        let stream = ReadAheadStream(source: source, chunkSize: 512 << 10, aheadLimit: 4 << 20, behindLimit: 0)
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 1024)
        _ = buffer.withUnsafeMutableBytes { stream.read(into: $0) }
        XCTAssertGreaterThanOrEqual(stream.stats.waits, 1)
        // Pencere dolana kadar bekle (en çok 5 s).
        let deadline = Date().addingTimeInterval(5)
        while stream.stats.bufferedAhead < (4 << 20) - 1024, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertGreaterThanOrEqual(stream.stats.bufferedAhead, (4 << 20) - 1024)
        XCTAssertLessThanOrEqual(stream.stats.bufferedAhead, (4 << 20) + (512 << 10), "ileri pencere sınırı")
        let waitsBefore = stream.stats.waits
        _ = buffer.withUnsafeMutableBytes { stream.read(into: $0) }
        XCTAssertEqual(stream.stats.waits, waitsBefore, "hazır veride bekleme yok")
    }

    /// Ağ yanıt vermezken kapatma, bloklanan okuyucuyu hemen bırakır (oynatıcı durdurulabilir).
    func testCloseUnblocksWaitingReader() {
        let source = FakeSource(size: 1 << 20, latency: 1.0)
        let stream = ReadAheadStream(source: source, chunkSize: 1 << 20)
        let done = expectation(description: "okuma döndü")
        let result = ResultBox()
        DispatchQueue.global().async {
            var buffer = [UInt8](repeating: 0, count: 16)
            result.value = buffer.withUnsafeMutableBytes { stream.read(into: $0) }
            done.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)
        let start = Date()
        stream.close()
        wait(for: [done], timeout: 0.5)
        XCTAssertEqual(result.value, -1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    /// Geçici hata yeniden denemeyle atlatılır; kalıcı hata okuyucuya −1 döner, sarınca akış sürer.
    func testTransientAndPermanentFailures() {
        let source = FakeSource(size: 4 << 20, latency: 0)
        source.fail(at: 100, true)
        let stream = ReadAheadStream(source: source, chunkSize: 1 << 20, aheadLimit: 1 << 20, retries: 2)
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 64)
        XCTAssertEqual(buffer.withUnsafeMutableBytes { stream.read(into: $0) }, -1, "kalıcı hata")
        XCTAssertGreaterThanOrEqual(stream.stats.errors, 1)
        stream.seek(to: 3 << 20)
        XCTAssertEqual(buffer.withUnsafeMutableBytes { stream.read(into: $0) }, 64, "başka yere sarınca sürer")
        // Ağ geri geldi: aynı yere dönüp yeniden denenince okunur.
        source.fail(at: 100, false)
        stream.seek(to: 0)
        stream.retry()
        XCTAssertEqual(buffer.withUnsafeMutableBytes { stream.read(into: $0) }, 64, "yeniden deneme")
        XCTAssertEqual(buffer[63], FakeSource.byte(at: 63))

        let flaky = FakeSource(size: 2 << 20, latency: 0)
        flaky.fail(at: 10, true)
        let recovering = ReadAheadStream(source: flaky, chunkSize: 1 << 20, aheadLimit: 1 << 20, retries: 6)
        defer { recovering.close() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { flaky.fail(at: 10, false) }
        XCTAssertEqual(buffer.withUnsafeMutableBytes { recovering.read(into: $0) }, 64, "kesinti geçince okunur")
        XCTAssertEqual(buffer[10], FakeSource.byte(at: 10))
    }
}

final class FileRangeSourceTests: XCTestCase {
    func testReadsFileThroughStream() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mediaio-\(UUID().uuidString).bin")
        let bytes = (0..<3_000_001).map { FakeSource.byte(at: Int64($0)) }
        try Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try FileRangeSource(path: url.path)
        XCTAssertEqual(source.size, 3_000_001)
        let stream = ReadAheadStream(source: source, chunkSize: 1 << 20, aheadLimit: 2 << 20)
        defer { stream.close() }
        stream.seek(to: 2_999_990)
        var tail = [UInt8](repeating: 0, count: 64)
        XCTAssertEqual(tail.withUnsafeMutableBytes { stream.read(into: $0) }, 11)
        XCTAssertEqual(Array(tail[0..<11]), Array(bytes[2_999_990...]))
        stream.seek(to: 0)
        var all: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 70_000)
        while true {
            let n = buffer.withUnsafeMutableBytes { stream.read(into: $0) }
            if n <= 0 { break }
            all += buffer[0..<n]
        }
        XCTAssertEqual(all, bytes)
        XCTAssertThrowsError(try FileRangeSource(path: url.path + ".yok"))
    }
}
