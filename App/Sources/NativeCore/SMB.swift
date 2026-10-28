import Foundation
import MediaIO
import Security

struct SMBError: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { message }
}

/// libsmb2 bağlamı (eşzamanlı API; 02-cozum K-18). Bağlam thread güvenli değildir: çağrılar kilitle sıralanır.
/// Gezinme ve oynatma ayrı bağlantı kullanır (oynatılan dosya `SMBFile`).
final class SMBConnection: @unchecked Sendable {
    let server: SMBServer
    let share: String
    private let password: String
    private var context: OpaquePointer?
    private let lock = NSLock()
    static let timeoutSeconds: Int32 = 10

    init(server: SMBServer, share: String, password: String) throws {
        self.server = server
        self.share = share
        self.password = password
        context = try Self.connect(server: server, share: share, password: password)
    }

    deinit {
        // Kapanış çağrıları (disconnect) ağ yoksa zaman aşımına kadar bloklar; soket kapatılır, sunucu oturumu bırakır.
        smb2_destroy_context(context)
    }

    /// Oturum açar ve paylaşıma bağlanır. NTLMSSP; imza desteklenir ama zorunlu değil, SMB3 şifreleme sunucu isterse.
    static func connect(server: SMBServer, share: String, password: String) throws -> OpaquePointer {
        guard let context = smb2_init_context() else { throw SMBError("SMB bağlamı oluşturulamadı") }
        smb2_set_security_mode(context, UInt16(SMB2_NEGOTIATE_SIGNING_ENABLED))
        // Kullanıcı yoksa misafir.
        smb2_set_user(context, server.user.isEmpty ? "Guest" : server.user)
        smb2_set_password(context, password)
        if !server.domain.isEmpty { smb2_set_domain(context, server.domain) }
        smb2_set_timeout(context, timeoutSeconds)
        if smb2_connect_share(context, server.host, share, nil) < 0 {
            let message = errorText(context)
            smb2_destroy_context(context)
            throw SMBError("\(server.displayName)/\(share): \(message)")
        }
        return context
    }

    static func errorText(_ context: OpaquePointer?) -> String {
        guard let context, let raw = smb2_get_error(context) else { return "bilinmeyen hata" }
        let text = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "bilinmeyen hata" : text
    }

    /// Sunucunun azami okuma boyutu (bayt).
    var maxReadSize: Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(smb2_get_max_read_size(context))
    }

    /// Klasör içeriği: önce klasörler, sonra dosyalar (ada göre). Gizli ("." ile başlayan) girdiler atlanır.
    func list(_ path: String) throws -> [SMBEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard let directory = smb2_opendir(context, path) else {
            throw SMBError("\(path.isEmpty ? share : path): \(Self.errorText(context))")
        }
        defer { smb2_closedir(context, directory) }
        var entries: [SMBEntry] = []
        while let entry = smb2_readdir(context, directory) {
            guard let raw = entry.pointee.name else { continue }
            let name = String(cString: raw)
            if name.hasPrefix(".") { continue }
            let st = entry.pointee.st
            entries.append(SMBEntry(name: name, isDirectory: st.smb2_type == UInt32(SMB2_TYPE_DIRECTORY),
                                    size: Int64(st.smb2_size),
                                    modified: st.smb2_mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(st.smb2_mtime)) : nil))
        }
        return entries.sorted {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Sunucudaki disk paylaşımları (IPC$ üzerinden srvsvc; gizli "$" paylaşımları hariç).
    static func shares(server: SMBServer, password: String) throws -> [String] {
        let context = try connect(server: server, share: "IPC$", password: password)
        defer { smb2_destroy_context(context) }
        var names: UnsafeMutablePointer<CChar>?
        let result = arif_smb2_share_enum(context, Int32(timeoutSeconds) * 1000, &names)
        guard result == 0, let names else {
            throw SMBError("Paylaşımlar listelenemedi: \(errorText(context)) (\(result))")
        }
        defer { free(names) }
        return String(cString: names).split(separator: "\n").map(String.init)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Oynatılan SMB dosyası: kendi bağlantısı, ardışık düzenli okuma (aynı anda 8 istek; tek isteklik gidiş-dönüş
/// beklemesi gizlenir), bağlantı koparsa bir sonraki okumada yeniden bağlanma. Yalnızca önden okuma thread'i çağırır.
final class SMBFile: RangeSource, @unchecked Sendable {
    let size: Int64
    let location: SMBLocation
    private let password: String
    private var context: OpaquePointer?
    private var handle: OpaquePointer?
    private(set) var maxReadSize = 0
    private let counterLock = NSLock()
    private var reconnects = 0

    /// Aynı anda uçuştaki okuma isteği ve bir okumanın ilerlemesiz bekleyebileceği süre.
    static let pipelineDepth: Int32 = 8
    static let stallTimeoutMs: Int32 = 8000

    init(location: SMBLocation, password: String) throws {
        self.location = location
        self.password = password
        let (context, handle, size) = try Self.open(location: location, password: password)
        self.context = context
        self.handle = handle
        self.size = size
        maxReadSize = Int(smb2_get_max_read_size(context))
    }

    deinit {
        smb2_destroy_context(context)
    }

    var reconnectCount: Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return reconnects
    }

    private static func open(location: SMBLocation, password: String) throws -> (OpaquePointer, OpaquePointer, Int64) {
        let context = try SMBConnection.connect(server: location.server, share: location.share, password: password)
        guard let handle = smb2_open(context, location.path, O_RDONLY) else {
            let message = SMBConnection.errorText(context)
            smb2_destroy_context(context)
            throw SMBError("\(location.fileName): \(message)")
        }
        var st = smb2_stat_64()
        guard smb2_fstat(context, handle, &st) >= 0 else {
            let message = SMBConnection.errorText(context)
            smb2_destroy_context(context)
            throw SMBError("\(location.fileName): \(message)")
        }
        return (context, handle, Int64(st.smb2_size))
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: Int64) throws -> Int {
        let count = min(Int64(buffer.count), size - offset)
        guard count > 0, let base = buffer.baseAddress else { return 0 }
        if context == nil {
            let (context, handle, _) = try Self.open(location: location, password: password)
            self.context = context
            self.handle = handle
            maxReadSize = Int(smb2_get_max_read_size(context))
            counterLock.lock()
            reconnects += 1
            counterLock.unlock()
        }
        // Parça: istek başına en çok sunucunun azami okuması; bir tampon parçası en az 8 isteğe bölünür.
        let piece = UInt32(max(64 << 10, min(maxReadSize, Int(count) / Int(Self.pipelineDepth))))
        let n = arif_smb2_pread_pipelined(context, handle, base.assumingMemoryBound(to: UInt8.self), UInt64(count),
                                          UInt64(offset), piece, Self.pipelineDepth, Self.stallTimeoutMs)
        if n < 0 {
            // Yarıda kalan istekler tampona yazabilir: bağlam hemen kapatılır, sonraki okuma yeniden bağlanır.
            let message = SMBConnection.errorText(context)
            smb2_destroy_context(context)
            context = nil
            handle = nil
            throw SMBError("okuma (\(n)): \(message)")
        }
        return Int(n)
    }
}

/// SMB parolaları Keychain'de (internet parolası, SMB protokolü; yalnızca bu cihaz, ilk kilit açılışından sonra).
enum SMBKeychain {
    private static func query(_ server: SMBServer) -> [String: Any] {
        [kSecClass as String: kSecClassInternetPassword,
         kSecAttrServer as String: server.host,
         kSecAttrAccount as String: server.user,
         kSecAttrProtocol as String: kSecAttrProtocolSMB]
    }

    static func password(for server: SMBServer) -> String? {
        var request = query(server)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ password: String, for server: SMBServer) {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(server) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(server)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func delete(for server: SMBServer) {
        SecItemDelete(query(server) as CFDictionary)
    }
}
