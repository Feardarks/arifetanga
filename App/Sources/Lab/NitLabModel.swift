import Foundation
import NitMath
import SwiftUI

/// Nit Laboratuvarı ekran durumu (03-tasarim §9.1).
@MainActor
final class NitLabModel: ObservableObject {
    struct RecentFile: Codable, Identifiable, Equatable {
        var id: String { name }
        var name: String
        var bookmark: Data
    }

    @Published private(set) var snapshot = LabSnapshot()
    @Published var params = NitParams() {
        didSet { if params != oldValue { engine.params = params } }
    }
    @Published var filePanelVisible = true { didSet { syncPanel() } }
    @Published var parameterPanelVisible = false { didSet { syncPanel() } }
    @Published var chromeVisible = true { didSet { engine.chromeVisible = chromeVisible } }
    @Published var hudCompact = false
    @Published var loop = true { didSet { engine.loop = loop } }
    @Published var importerPresented = false
    @Published var toast: String?
    @Published var shareItem: ShareItem?
    @Published private(set) var recents: [RecentFile] = []
    @Published private(set) var microShift = CGSize.zero

    struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    let engine = LabEngine()
    private var toastHistory: [HeadroomStatus: Date] = [:]
    private var toastTask: Task<Void, Never>?
    private var shiftTask: Task<Void, Never>?
    private static let recentsKey = "nitLab.recents"

    init() {
        engine.onSnapshot = { [weak self] snap in self?.snapshot = snap }
        engine.onStatusChange = { [weak self] status in self?.statusChanged(status) }
        loadRecents()
    }

    func appear() {
        engine.start()
        // OLED koruması: HUD ve kayıt göstergesi dakikada bir 2 pt kayar; video ve altyazıya dokunulmaz.
        shiftTask = Task { [weak self] in
            var phase = 0
            let offsets = [CGSize(width: 0, height: 0), CGSize(width: 2, height: 0), CGSize(width: 2, height: 2), CGSize(width: 0, height: 2)]
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                phase = (phase + 1) % offsets.count
                self?.microShift = offsets[phase]
            }
        }
    }

    func disappear() {
        shiftTask?.cancel()
        toastTask?.cancel()
        engine.stop()
    }

    // MARK: Kaynaklar

    func open(url: URL) {
        engine.load(url: url)
        rememberRecent(url)
        filePanelVisible = false
    }

    func open(recent: RecentFile) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: recent.bookmark, options: [], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else {
            showToast("Dosyaya artık erişilemiyor: \(recent.name)")
            recents.removeAll { $0 == recent }
            saveRecents()
            return
        }
        open(url: url)
    }

    func open(pattern: PatternSpec) {
        engine.showPattern(pattern)
        filePanelVisible = false
        if params.mode == .reference {
            showToast("Desenler yalnızca Nit yolunda çizilir")
        }
    }

    // MARK: Eylemler

    func togglePlay() { engine.togglePlay() }
    func seek(to seconds: Double) { engine.seek(to: seconds) }
    func resetKnee() { engine.resetKnee() }

    func resetParams() {
        params = NitParams(mode: params.mode)
        engine.event("Parametreler varsayılana döndü")
    }

    func exportCSV() {
        do {
            shareItem = ShareItem(url: try engine.exportCSV())
        } catch {
            showToast("CSV yazılamadı: \(error.localizedDescription)")
        }
    }

    // MARK: HUD mesajları (03-tasarim §4.8; aynı mesaj en fazla dakikada bir)

    private func statusChanged(_ status: HeadroomStatus) {
        let text: String
        switch status {
        case .collapsed: text = "Sistem HDR'yi kıstı (uzun süreli HDR politikası). Beyaz SDR tepesinde."
        case .lowPower: text = "Düşük Güç Modu HDR'yi kapatıyor."
        case .thermal: text = "Cihaz ısındı: sistem parlaklık tavanını düşürüyor."
        case .captured: text = "Ekran kaydı sürüyor: HDR davranışı değişebilir."
        case .panelPeak, .sliderLimited: return
        }
        if let last = toastHistory[status], Date().timeIntervalSince(last) < 60 { return }
        toastHistory[status] = Date()
        showToast(text)
    }

    func showToast(_ text: String) {
        toastTask?.cancel()
        toast = text
        engine.event("HUD: \(text)")
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Özel

    private func syncPanel() {
        engine.panelName = filePanelVisible ? "dosya" : (parameterPanelVisible ? "parametreler" : "yok")
    }

    private func rememberRecent(_ url: URL) {
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        let entry = RecentFile(name: url.lastPathComponent, bookmark: data)
        recents.removeAll { $0.name == entry.name }
        recents.insert(entry, at: 0)
        if recents.count > 5 { recents.removeLast(recents.count - 5) }
        saveRecents()
    }

    private func loadRecents() {
        guard let data = UserDefaults.standard.data(forKey: Self.recentsKey),
              let list = try? JSONDecoder().decode([RecentFile].self, from: data) else { return }
        recents = list
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: Self.recentsKey)
        }
    }
}
