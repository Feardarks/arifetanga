import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Yerel ya da Dosyalar'dan seçilmiş (File Provider, ör. Dosyalar'ın SMB'si) dosya: `pread` ile aralıklı okuma.
/// Önden okuma tamponuyla birlikte Dosyalar yolunu (AS-23 yedek yol) libsmb2 ile aynı ölçümlerle karşılaştırır.
public final class FileRangeSource: RangeSource, @unchecked Sendable {
    public let size: Int64
    private let descriptor: Int32

    public init(path: String) throws {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fd
        size = Int64(info.st_size)
    }

    deinit {
        close(descriptor)
    }

    public func read(into buffer: UnsafeMutableRawBufferPointer, at offset: Int64) throws -> Int {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }
        while true {
            let n = pread(descriptor, base, buffer.count, off_t(offset))
            if n >= 0 { return n }
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
