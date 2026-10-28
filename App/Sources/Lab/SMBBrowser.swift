import MediaIO
import Network
import SwiftUI
import UniformTypeIdentifiers

/// Ağdaki SMB sunucuları: Bonjour `_smb._tcp` (02-cozum M7). libsmb2 BSD soketi kullandığından hizmet kısa bir
/// TCP bağlantısıyla IPv4 adresine çözülür. İlk tarama yerel ağ iznini ister.
@MainActor
final class SMBDiscovery: ObservableObject {
    struct Found: Identifiable, Hashable {
        var name: String
        /// "192.168.1.10" ya da standart dışı portta "adres:port"; çözülene kadar `nil`.
        var host: String?

        var id: String { name }
    }

    @Published private(set) var found: [Found] = []
    @Published private(set) var note = "Aranıyor…"
    private var browser: NWBrowser?
    private var resolvers: [String: NWConnection] = [:]

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.update(state) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
    }

    private func update(_ state: NWBrowser.State) {
        switch state {
        case .failed(let error): note = "Bonjour hatası: \(error.localizedDescription)"
        case .waiting(let error): note = "Bekleniyor (yerel ağ izni?): \(error.localizedDescription)"
        case .ready: if found.isEmpty { note = "Aranıyor… (Windows paylaşımları Bonjour yayınlamaz: elle ekleyin)" }
        default: break
        }
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var list: [Found] = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            let known = found.first { $0.name == name }?.host
            list.append(Found(name: name, host: known))
            if known == nil { resolve(name: name, endpoint: result.endpoint) }
        }
        found = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !found.isEmpty { note = "" }
    }

    private func resolve(name: String, endpoint: NWEndpoint) {
        guard resolvers[name] == nil else { return }
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: endpoint, using: parameters)
        resolvers[name] = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, let connection = self.resolvers[name] else { return }
                switch state {
                case .ready:
                    var host: String?
                    if case .hostPort(let address, let port) = connection.currentPath?.remoteEndpoint {
                        var text: String
                        switch address {
                        case .ipv4(let v4): text = "\(v4)"
                        case .ipv6(let v6): text = "\(v6)"
                        case .name(let hostname, _): text = hostname
                        @unknown default: text = "\(address)"
                        }
                        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
                        host = port.rawValue == 445 ? text : "\(text):\(port.rawValue)"
                    }
                    connection.cancel()
                    if let index = self.found.firstIndex(where: { $0.name == name }) { self.found[index].host = host }
                case .failed, .cancelled:
                    self.resolvers[name] = nil
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }
}

/// SMB gezgini (S7, AS-3/AS-23): kayıtlı ve bulunan sunucular, bağlantı, paylaşım ve klasörler, hız testi.
/// Tüm libsmb2 çağrıları tek bir arka plan kuyruğunda; gezinme bağlantısı oynatmadan ayrıdır.
@MainActor
final class SMBBrowserModel: ObservableObject {
    enum Stage: Equatable {
        case servers
        case shares(SMBServer)
        case folder(SMBLocation)
    }

    struct Form: Equatable {
        var host = ""
        var user = ""
        var password = ""
        var domain = ""
        var name = ""
        /// Paylaşım listesi alınamazsa (bazı sunucular IPC$'ı kapatır) doğrudan bu paylaşım açılır.
        var share = ""
        var save = true

        var server: SMBServer {
            SMBServer(host: host.trimmingCharacters(in: .whitespaces), user: user.trimmingCharacters(in: .whitespaces),
                      domain: domain.trimmingCharacters(in: .whitespaces), name: name.trimmingCharacters(in: .whitespaces))
        }
    }

    @Published var stage: Stage = .servers
    @Published private(set) var servers: [SMBServer] = []
    @Published private(set) var shares: [String] = []
    @Published private(set) var entries: [SMBEntry] = []
    @Published private(set) var busy: String?
    @Published var error: String?
    @Published var form = Form()
    @Published var formVisible = false
    @Published private(set) var speedResults: [ThroughputResult] = []
    @Published private(set) var speedRunning: String?
    @Published var filesSpeedImporter = false
    let discovery = SMBDiscovery()

    var onOpen: ((URL) -> Void)?
    var onEvent: ((String) -> Void)?

    private var connection: SMBConnection?
    private var password = ""
    private let speedCancel = CancelFlag()
    private let queue = DispatchQueue(label: "arif.smb.browse", qos: .userInitiated)
    private static let serversKey = "smb.servers"

    /// Oynatılabilir uzantılar: kendi hattımızın açtığı video kapsayıcıları ve müzik dosyaları.
    static let playableExtensions = LabEngine.audioExtensions.union(["mkv", "webm", "m2ts", "mts", "ts", "mp4", "m4v", "mov"])

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.serversKey),
           let list = try? JSONDecoder().decode([SMBServer].self, from: data) {
            servers = list
        }
    }

    var title: String {
        switch stage {
        case .servers: "SMB sunucuları"
        case .shares(let server): server.displayName
        case .folder(let location): location.path.isEmpty ? "\(location.server.displayName)/\(location.share)" : location.displayPath
        }
    }

    func appear() { discovery.start() }

    func disappear() {
        discovery.stop()
        speedCancel.set(true)
    }

    // MARK: Gezinme

    /// Kayıtlı sunucu: Keychain'deki parolayla bağlanılır; yoksa form açılır.
    func open(server: SMBServer) {
        if let saved = SMBKeychain.password(for: server) {
            connect(server: server, password: saved, share: nil, save: false)
        } else {
            form = Form(host: server.host, user: server.user, domain: server.domain, name: server.name)
            formVisible = true
        }
    }

    func open(found: SMBDiscovery.Found) {
        guard let host = found.host else {
            error = "\(found.name): adres henüz çözülmedi"
            return
        }
        if let saved = servers.first(where: { $0.host == host }) {
            open(server: saved)
            return
        }
        form = Form(host: host, name: found.name)
        formVisible = true
    }

    func submitForm() {
        let server = form.server
        guard !server.host.isEmpty else {
            error = "Sunucu adresi boş"
            return
        }
        let share = form.share.trimmingCharacters(in: .whitespaces)
        connect(server: server, password: form.password, share: share.isEmpty ? nil : share, save: form.save)
    }

    func remove(server: SMBServer) {
        servers.removeAll { $0 == server }
        SMBKeychain.delete(for: server)
        saveServers()
    }

    private func connect(server: SMBServer, password: String, share: String?, save: Bool) {
        busy = "\(server.displayName): bağlanılıyor…"
        error = nil
        let started = CACurrentMediaTime()
        queue.async { [weak self] in
            let result: Result<[String], Error>
            if let share {
                result = .success([share])
            } else {
                result = Result { try SMBConnection.shares(server: server, password: password) }
            }
            let ms = (CACurrentMediaTime() - started) * 1000
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.busy = nil
                    switch result {
                    case .success(let names):
                        self.password = password
                        SMBKeychain.remember(password, for: server)
                        if save { SMBKeychain.save(password, for: server) }
                        if !self.servers.contains(server) {
                            self.servers.removeAll { $0.host == server.host && $0.user == server.user }
                            self.servers.insert(server, at: 0)
                            self.saveServers()
                        }
                        self.formVisible = false
                        self.onEvent?("SMB: \(server.displayName) · \(names.count) paylaşım · \(TR.num(ms, 0)) ms")
                        if let share, names == [share] {
                            self.openShare(share, on: server)
                        } else {
                            self.shares = names
                            self.stage = .shares(server)
                        }
                    case .failure(let failure):
                        self.error = failure.localizedDescription
                        self.form = Form(host: server.host, user: server.user, password: password, domain: server.domain,
                                         name: server.name, share: share ?? "", save: save)
                        self.formVisible = true
                        self.onEvent?("SMB bağlantı hatası: \(failure.localizedDescription)")
                    }
                }
            }
        }
    }

    func openShare(_ share: String, on server: SMBServer) {
        busy = "\(share) açılıyor…"
        error = nil
        let password = self.password
        queue.async { [weak self] in
            let result = Result { () -> (SMBConnection, [SMBEntry]) in
                let connection = try SMBConnection(server: server, share: share, password: password)
                return (connection, try connection.list(""))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.busy = nil
                    switch result {
                    case .success(let (connection, entries)):
                        self.connection = connection
                        self.entries = entries
                        self.stage = .folder(SMBLocation(server: server, share: share, path: ""))
                    case .failure(let failure):
                        self.error = failure.localizedDescription
                    }
                }
            }
        }
    }

    func open(entry: SMBEntry) {
        guard case .folder(let location) = stage else { return }
        let child = SMBLocation(server: location.server, share: location.share, path: SMBEntry.join(location.path, entry.name))
        if entry.isDirectory {
            list(child)
        } else if let url = child.url {
            onOpen?(url)
        }
    }

    func back() {
        error = nil
        switch stage {
        case .servers:
            break
        case .shares:
            stage = .servers
        case .folder(let location):
            if location.path.isEmpty {
                connection = nil
                stage = .shares(location.server)
                if shares.isEmpty { shares = [location.share] }
            } else {
                var parent = location
                parent.path = location.path.split(separator: "/").dropLast().joined(separator: "/")
                list(parent)
            }
        }
    }

    private func list(_ location: SMBLocation) {
        guard let connection else { return }
        busy = "Okunuyor…"
        queue.async { [weak self] in
            let result = Result { try connection.list(location.path) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.busy = nil
                    switch result {
                    case .success(let entries):
                        self.entries = entries
                        self.stage = .folder(location)
                    case .failure(let failure):
                        self.error = failure.localizedDescription
                    }
                }
            }
        }
    }

    func isPlayable(_ entry: SMBEntry) -> Bool {
        entry.isDirectory || Self.playableExtensions.contains((entry.name as NSString).pathExtension.lowercased())
    }

    // MARK: Hız testi (AS-23)

    /// libsmb2: aynı dosyada önce 8 istek (ardışık düzen), sonra tek istek; farklı bölgelerden (sunucu önbelleği
    /// ikinci testi kayırmasın).
    func speedTest(entry: SMBEntry) {
        guard case .folder(let location) = stage, !entry.isDirectory, speedRunning == nil else { return }
        let target = SMBLocation(server: location.server, share: location.share, path: SMBEntry.join(location.path, entry.name))
        let password = self.password
        speedRunning = "libsmb2 · \(entry.name)"
        let cancel = speedCancel
        cancel.set(false)
        queue.async { [weak self] in
            var results: [ThroughputResult] = []
            var failure: String?
            do {
                let file = try SMBFile(location: target, password: password)
                let maxRead = file.maxReadSize / 1024
                file.pipelineDepth = 8
                results.append(try ThroughputTest.run(source: file, label: "libsmb2 · 8 istek · azami okuma \(maxRead) KB",
                                                      cancelled: cancel.get))
                file.pipelineDepth = 1
                results.append(try ThroughputTest.run(source: file, label: "libsmb2 · tek istek", start: file.size / 2,
                                                      cancelled: cancel.get))
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishSpeed(results, file: entry.name, failure: failure) }
            }
        }
    }

    /// Dosyalar yolu: kullanıcının Dosyalar'da (iOS'un SMB bağlantısı) seçtiği dosya, aynı yöntemle.
    func speedTest(filesURL url: URL) {
        guard speedRunning == nil else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        let kind = LabEngine.locationKind(url)
        speedRunning = "\(kind) · \(url.lastPathComponent)"
        let cancel = speedCancel
        cancel.set(false)
        queue.async { [weak self] in
            var results: [ThroughputResult] = []
            var failure: String?
            do {
                let file = try FileRangeSource(path: url.path)
                results.append(try ThroughputTest.run(source: file, label: "Dosyalar (\(kind)) · pread", start: file.size / 4,
                                                      cancelled: cancel.get))
            } catch {
                failure = error.localizedDescription
            }
            if accessed { url.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishSpeed(results, file: url.lastPathComponent, failure: failure) }
            }
        }
    }

    private func finishSpeed(_ results: [ThroughputResult], file: String, failure: String?) {
        speedRunning = nil
        speedResults.insert(contentsOf: results.reversed(), at: 0)
        for r in results { onEvent?("Hız testi (AS-23): \(file) · " + Self.describe(r)) }
        if let failure {
            error = "Hız testi: \(failure)"
            onEvent?("Hız testi hatası: \(failure)")
        }
    }

    static func describe(_ r: ThroughputResult) -> String {
        "\(r.label): \(TR.num(r.megabytesPerSecond, 1)) MB/s (\(TR.num(Double(r.bytes) / 1e6, 0)) MB / \(TR.num(r.seconds, 1)) s)"
            + " · ilk okuma \(TR.num(r.firstReadMs, 0)) ms · rastgele 1 MB ort \(TR.num(r.randomMeanMs, 0)), en çok \(TR.num(r.randomMaxMs, 0)) ms"
    }

    private func saveServers() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: Self.serversKey)
        }
    }
}

/// SMB gezgini sayfası.
struct SMBBrowserView: View {
    @ObservedObject var model: SMBBrowserModel
    @ObservedObject var discovery: SMBDiscovery
    var onClose: () -> Void

    init(model: SMBBrowserModel, onClose: @escaping () -> Void) {
        self.model = model
        discovery = model.discovery
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
                if let error = model.error {
                    Text(error).font(.subheadline).foregroundStyle(DS.red)
                }
                if let busy = model.busy {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(busy).font(.subheadline).foregroundStyle(DS.secondary)
                    }
                }
                switch model.stage {
                case .servers: serverSections
                case .shares(let server): shareSection(server)
                case .folder: folderSection
                }
                speedSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
        .fileImporter(isPresented: $model.filesSpeedImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { model.speedTest(filesURL: url) }
        }
    }

    private var header: some View {
        HStack {
            if model.stage != .servers {
                Button { model.back() } label: { Image(systemName: "chevron.left") }
                    .font(.headline)
            }
            Text(model.title).font(.headline).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Kapat", action: onClose).font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .foregroundStyle(.white)
    }

    @ViewBuilder private var serverSections: some View {
        if !model.servers.isEmpty {
            Section("Kayıtlı") {
                ForEach(model.servers) { server in
                    Button { model.open(server: server) } label: {
                        row(server.displayName, detail: (server.user.isEmpty ? "misafir" : server.user) + " @ " + server.host,
                            icon: "externaldrive.connected.to.line.below")
                    }
                    .swipeActions {
                        Button("Sil", role: .destructive) { model.remove(server: server) }
                    }
                }
            }
        }
        Section {
            ForEach(discovery.found) { found in
                Button { model.open(found: found) } label: {
                    row(found.name, detail: found.host ?? "adres çözülüyor…", icon: "network")
                }
            }
            if !discovery.note.isEmpty {
                Text(discovery.note).font(.caption).foregroundStyle(DS.secondary)
            }
        } header: {
            Text("Ağda (Bonjour)")
        }
        Section("Sunucu") {
            if model.formVisible {
                TextField("Adres (nas.local, 192.168.1.10 ya da adres:port)", text: $model.form.host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Kullanıcı (boş: misafir)", text: $model.form.user)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Parola", text: $model.form.password)
                TextField("Etki alanı (isteğe bağlı)", text: $model.form.domain)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Görünen ad (isteğe bağlı)", text: $model.form.name)
                TextField("Paylaşım (liste alınamazsa)", text: $model.form.share)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Parolayı Keychain'e kaydet", isOn: $model.form.save).tint(DS.green)
                Button("Bağlan") { model.submitForm() }
                    .font(.subheadline.weight(.semibold))
                    .disabled(model.busy != nil)
            } else {
                Button {
                    model.form = SMBBrowserModel.Form()
                    model.formVisible = true
                } label: {
                    row("Sunucu ekle…", detail: "SMB2/3 · NTLM (NAS, Windows, macOS paylaşımı)", icon: "plus")
                }
            }
        }
    }

    private func shareSection(_ server: SMBServer) -> some View {
        Section("Paylaşımlar") {
            if model.shares.isEmpty {
                Text("Paylaşım bulunamadı").font(.subheadline).foregroundStyle(DS.secondary)
            }
            ForEach(model.shares, id: \.self) { share in
                Button { model.openShare(share, on: server) } label: { row(share, detail: nil, icon: "folder") }
            }
        }
    }

    private var folderSection: some View {
        Section {
            if model.entries.isEmpty, model.busy == nil {
                Text("Klasör boş").font(.subheadline).foregroundStyle(DS.secondary)
            }
            ForEach(model.entries.filter { model.isPlayable($0) }) { entry in
                Button { model.open(entry: entry) } label: {
                    row(entry.name, detail: entry.isDirectory ? nil : Self.size(entry.size), icon: Self.icon(entry))
                }
                .swipeActions {
                    if !entry.isDirectory {
                        Button("Hız testi") { model.speedTest(entry: entry) }.tint(DS.green)
                    }
                }
            }
        } footer: {
            Text("Dosyaya dokununca oynar. Sola kaydırınca hız testi (AS-23). Oynatılamayan dosyalar gizli.")
        }
    }

    private var speedSection: some View {
        Section {
            Button { model.filesSpeedImporter = true } label: {
                row("Dosyalar yolu: dosya seç…", detail: "iOS'un SMB bağlantısıyla aynı testi yapar", icon: "folder.badge.gearshape")
            }
            .disabled(model.speedRunning != nil)
            if let running = model.speedRunning {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Ölçülüyor: \(running)").font(.caption).foregroundStyle(DS.secondary)
                }
            }
            ForEach(Array(model.speedResults.enumerated()), id: \.offset) { _, result in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(TR.num(result.megabytesPerSecond, 1)) MB/s · \(result.label)")
                        .font(.subheadline)
                        .foregroundStyle(result.megabytesPerSecond >= 20 ? DS.green : DS.amber)
                    Text("ilk okuma \(TR.num(result.firstReadMs, 0)) ms · rastgele 1 MB ort \(TR.num(result.randomMeanMs, 0)) / en çok \(TR.num(result.randomMaxMs, 0)) ms")
                        .font(.caption).foregroundStyle(DS.secondary)
                }
            }
        } header: {
            Text("Hız testi (AS-23 · hedef ≥ 20 MB/s)")
        }
    }

    private func row(_ title: String, detail: String?, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(DS.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(.white).lineLimit(2)
                if let detail { Text(detail).font(.caption).foregroundStyle(DS.secondary) }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private static func icon(_ entry: SMBEntry) -> String {
        if entry.isDirectory { return "folder" }
        return LabEngine.audioExtensions.contains((entry.name as NSString).pathExtension.lowercased()) ? "music.note" : "film"
    }

    private static func size(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? "\(TR.num(Double(bytes) / 1e9, 2)) GB" : "\(TR.num(Double(bytes) / 1e6, 1)) MB"
    }
}

/// Arka plan kuyruğundaki ölçümü durdurma bayrağı (sayfa kapanınca).
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
