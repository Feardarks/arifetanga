import Foundation

/// SMB sunucusu (S7, AS-3). Parola Keychain'de tutulur (`SMBKeychain`); burada yalnızca kimlik.
public struct SMBServer: Codable, Hashable, Identifiable, Sendable {
    /// "nas.local", "192.168.1.10" ya da "adres:port".
    public var host: String
    public var user: String
    public var domain: String
    /// Bonjour adı ya da kullanıcının verdiği ad.
    public var name: String

    public init(host: String, user: String = "", domain: String = "", name: String = "") {
        self.host = host
        self.user = user
        self.domain = domain
        self.name = name
    }

    public var id: String { "\(user)@\(host)" }
    public var displayName: String { name.isEmpty ? host : name }
}

/// Paylaşım içindeki bir dosya ya da klasör. Yol paylaşıma göreli, "/" ile ayrılır; "" paylaşımın köküdür.
public struct SMBLocation: Codable, Hashable, Sendable {
    public var server: SMBServer
    public var share: String
    public var path: String

    public var fileName: String { path.split(separator: "/").last.map(String.init) ?? share }
    /// "DiskStation/Filmler/Alt/film.mkv"
    public var displayPath: String { ([server.displayName, share] + path.split(separator: "/").map(String.init)).joined(separator: "/") }

    /// `smb://[alan;]kullanıcı@sunucu[:port]/paylaşım/yol[?ad=görünen ad]` (parola içermez). Oynatıcı kaynakları URL taşır.
    public var url: URL? {
        var components = URLComponents()
        components.scheme = "smb"
        let parts = server.host.split(separator: ":", maxSplits: 1)
        components.host = parts.first.map(String.init)
        if parts.count == 2, let port = Int(parts[1]) { components.port = port }
        if !server.user.isEmpty { components.user = server.domain.isEmpty ? server.user : "\(server.domain);\(server.user)" }
        components.path = "/" + ([share] + path.split(separator: "/").map(String.init)).joined(separator: "/")
        if !server.name.isEmpty { components.queryItems = [URLQueryItem(name: "ad", value: server.name)] }
        return components.url
    }

    public init(server: SMBServer, share: String, path: String) {
        self.server = server
        self.share = share
        self.path = path
    }

    public init?(url: URL) {
        guard url.scheme == "smb", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty else { return nil }
        var segments = components.path.split(separator: "/").map(String.init)
        guard !segments.isEmpty else { return nil }
        let share = segments.removeFirst()
        var user = components.user ?? ""
        var domain = ""
        if let separator = user.firstIndex(of: ";") {
            domain = String(user[..<separator])
            user = String(user[user.index(after: separator)...])
        }
        let address = components.port.map { "\(host):\($0)" } ?? host
        let name = components.queryItems?.first { $0.name == "ad" }?.value ?? ""
        self.init(server: SMBServer(host: address, user: user, domain: domain, name: name), share: share,
                  path: segments.joined(separator: "/"))
    }
}

public struct SMBEntry: Identifiable, Hashable, Sendable {
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date?

    public init(name: String, isDirectory: Bool, size: Int64, modified: Date? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    public var id: String { name }

    /// Bir alt öğenin yolu (paylaşıma göreli).
    public static func join(_ directory: String, _ name: String) -> String {
        directory.isEmpty ? name : directory + "/" + name
    }
}
