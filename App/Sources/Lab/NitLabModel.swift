import AudioDSP
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

    /// Eşitlik testi (S0-C, AS-26/K2) durumu.
    struct EqualityTest {
        enum Answer: String { case leftBrighter = "A daha parlak", same = "Aynı", rightBrighter = "B daha parlak" }
        struct Trial: Identifiable {
            let id: Int
            let nitOnLeft: Bool
            var answer: Answer?

            /// Yanıtı yollar cinsinden yorumlar.
            var verdict: String {
                guard let answer else { return "—" }
                switch answer {
                case .same: return "Aynı"
                case .leftBrighter: return nitOnLeft ? "Nit daha parlak" : "Referans daha parlak"
                case .rightBrighter: return nitOnLeft ? "Referans daha parlak" : "Nit daha parlak"
                }
            }
        }
        enum Phase { case setup, running, blank, done }

        static let trialCount = 5
        var windowPercent = 10.0
        var levelNits = 1000.0
        var phase: Phase = .setup
        var trials: [Trial] = []

        var current: Int { trials.count }
        var sameCount: Int { trials.filter { $0.answer == .same }.count }
        var passed: Bool { sameCount >= 4 }
    }

    @Published var equality: EqualityTest?
    @Published private(set) var toneTestActive = false

    let engine = LabEngine()
    private static let gammaKey = "nitLab.sdrGamma"
    private var toastHistory: [HeadroomStatus: Date] = [:]
    private var toastTask: Task<Void, Never>?
    private var shiftTask: Task<Void, Never>?
    private static let recentsKey = "nitLab.recents"

    init() {
        engine.onSnapshot = { [weak self] snap in self?.snapshot = snap }
        engine.onStatusChange = { [weak self] status in self?.statusChanged(status) }
        engine.onBoostRecall = { [weak self] value, route in
            self?.params.boostPercent = value
            self?.showToast("Rota \(route.rawValue): boost %\(Int(value.rounded())) (rota hafızası)")
        }
        loadRecents()
        // Tonalite testinde seçilen gama varsayılan olur (K11).
        let savedGamma = UserDefaults.standard.double(forKey: Self.gammaKey)
        if savedGamma > 0 { params.sdrGamma = savedGamma }
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

    // MARK: M10 boost

    /// Şeritteki Boost düğmesi %100 ile son boost değeri arasında geçer.
    private var lastBoost = 150.0

    var limiterEngaged: Bool { params.limiterMode == .smart || params.limiterMode == .limiterOnly }

    func toggleBoost() {
        if params.boostPercent > 100 {
            lastBoost = params.boostPercent
            params.boostPercent = 100
        } else {
            params.boostPercent = lastBoost
        }
    }

    func toggleLimiter() {
        params.limiterMode = limiterEngaged ? .off : .smart
    }

    func resetBoostMeters() { engine.resetBoostMeters() }

    func resetParams() {
        UserDefaults.standard.removeObject(forKey: Self.gammaKey)
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

    // MARK: Eşitlik testi (S0-C)

    func openEqualitySetup() {
        endToneTest()
        filePanelVisible = false
        parameterPanelVisible = false
        equality = EqualityTest()
    }

    func startEquality() {
        guard var test = equality else { return }
        test.trials = []
        test.phase = .running
        equality = test
        engine.event("Eşitlik testi başladı: %\(Int(test.windowPercent)) pencere · PQ \(Int(test.levelNits))")
        nextEqualityTrial()
    }

    func answerEquality(_ answer: EqualityTest.Answer) {
        guard var test = equality, test.phase == .running, !test.trials.isEmpty else { return }
        var trial = test.trials.removeLast()
        trial.answer = answer
        test.trials.append(trial)
        engine.event("Eşitlik denemesi \(trial.id): Nit \(trial.nitOnLeft ? "solda" : "sağda") · yanıt \(answer.rawValue) · \(trial.verdict)")
        if test.trials.count >= EqualityTest.trialCount {
            test.phase = .done
            equality = test
            engine.endTest()
            engine.event("Eşitlik testi sonucu: \(test.sameCount)/\(EqualityTest.trialCount) Aynı · K2 \(test.passed ? "geçti" : "geçmedi")")
            return
        }
        // Denemeler arası 500 ms siyah ekran (göz uyumu).
        test.phase = .blank
        equality = test
        engine.blankEquality()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.nextEqualityTrial()
        }
    }

    func closeEquality() {
        equality = nil
        engine.endTest()
    }

    private func nextEqualityTrial() {
        guard var test = equality, test.phase != .done, test.phase != .setup else { return }
        let nitOnLeft = Bool.random()
        test.trials.append(EqualityTest.Trial(id: test.trials.count + 1, nitOnLeft: nitOnLeft))
        test.phase = .running
        equality = test
        engine.beginEqualityTrial(windowFraction: test.windowPercent / 100, levelNits: test.levelNits, nitOnLeft: nitOnLeft)
    }

    // MARK: Tonalite testi (S0-D)

    func startToneTest() {
        guard engine.canRunToneTest else {
            showToast("Tonalite testi için önce bir SDR video aç")
            return
        }
        equality = nil
        filePanelVisible = false
        parameterPanelVisible = false
        toneTestActive = true
        engine.beginToneTest()
    }

    func confirmToneMatch() {
        UserDefaults.standard.set(params.sdrGamma, forKey: Self.gammaKey)
        engine.event("Tonalite testi: seçilen SDR gaması \(params.sdrGamma)")
        showToast("SDR gaması \(TR.num(params.sdrGamma)) varsayılan oldu")
        endToneTest()
    }

    func endToneTest() {
        guard toneTestActive else { return }
        toneTestActive = false
        engine.endTest()
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
