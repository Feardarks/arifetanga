import AudioDSP
import Foundation

/// Laboratuvar telemetrisi: döngüsel kayıt (son 3 saat, 2 Hz) ve CSV dışa aktarımı.
/// Kolonlar 02-cozum §10.1 HUD alanları + 03-tasarim G-20 (`chromeVisible`, `panel`).
@MainActor
final class Telemetry {
    struct Row {
        var t: Double
        var date: Date
        var hCur: Double
        var hPot: Double
        var hS: Double
        var hEff: Double
        var brightness: Double
        var status: String
        var mode: String
        var source: String
        var thermal: String
        var lowPower: Bool
        var captured: Bool
        var gpuP50: Double
        var gpuP95: Double
        var dropped: Int
        var cadence: String
        var jitterMs: Double
        var outputMax: Double
        var playing: Bool
        var referenceWhite: Double
        var frameWhite: Double?
        var sceneWhite: Double?
        var anchor: Double?
        var histogramWhite: Double?
        var rpuMicros: Double?
        var audioCPU: Double?
        /// M9 (S4): etkin motor, r, c, evre yükü, AU yükü ve gecikmeleri, Sound Analysis olasılıkları.
        /// M10 (S5): boost, limiter kipi, rota ve tavan; göstergeler oynatma saatine hizalı.
        var audioStage: AudioStageStatus?
        var boostMeters: BoostMeters?
        var route: String
        var chromeVisible: Bool
        var panel: String
        var event: String
    }

    private(set) var rows: [Row] = []
    private let capacity = 3 * 3600 * 2
    private let start = Date()
    private(set) var paramsHeader = ""

    var elapsed: TimeInterval { Date().timeIntervalSince(start) }

    func setParams(_ summary: String) {
        paramsHeader = summary
    }

    func append(_ row: Row) {
        rows.append(row)
        if rows.count > capacity { rows.removeFirst(rows.count - capacity) }
    }

    /// CSV'yi geçici dizine yazar ve dosya adresini döndürür.
    func exportCSV() throws -> URL {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out = "# Arifetanga Nit Laboratuvarı · S2\n"
        out += "# parametreler: \(paramsHeader)\n"
        out += "t_s,zaman,H_cur,H_pot,H_s,H_eff,parlaklik,durum,mod,kaynak,isi,dusuk_guc,ekran_kaydi,"
        out += "gpu_p50_ms,gpu_p95_ms,dusen_kare,kadans,sapma_ms,cikis_maks,oynatiyor,L_ref,W_f,W_hat,A,W_hist,rpu_us,ses_cpu_yuzde,"
        out += "diyalog,diyalog_motor,diyalog_r,diyalog_c_db,diyalog_evre_cpu_yuzde,au_cpu_yuzde,au_duvar_yuzde,au_blok_maks_ms,"
        out += "au_gecikme_ms,au_olculen_ms,sa_muzik,sa_sarki,sa_konusma,"
        out += "rota,boost_yuzde,limiter,tavan_dbtp,boost_hedef_db,boost_etkin_db,gr_db,gr_tepe_1s_db,gr_3db_ustu_oran,"
        out += "kirpma_led,kirpma_toplam,kirpma_1s,en_buyuk_tepe_dbfs,tp_asim,chromeVisible,panel,olay\n"
        func f(_ v: Double, _ d: Int = 4) -> String { String(format: "%.\(d)f", v) }
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func o(_ v: Double?) -> String { v.map { f($0, 1) } ?? "" }
        for r in rows {
            out += [f(r.t, 2), iso.string(from: r.date), f(r.hCur), f(r.hPot), f(r.hS), f(r.hEff), f(r.brightness, 3),
                    q(r.status), r.mode, q(r.source), r.thermal, r.lowPower ? "1" : "0", r.captured ? "1" : "0",
                    f(r.gpuP50, 3), f(r.gpuP95, 3), String(r.dropped), q(r.cadence), f(r.jitterMs, 2), f(r.outputMax),
                    r.playing ? "1" : "0", f(r.referenceWhite, 1), o(r.frameWhite), o(r.sceneWhite), o(r.anchor),
                    o(r.histogramWhite), o(r.rpuMicros), r.audioCPU.map { f($0, 2) } ?? ""]
                .joined(separator: ",")
            out += "," + Self.dialogColumns(r.audioStage, f).joined(separator: ",")
            out += "," + Self.boostColumns(r.audioStage, r.boostMeters, route: r.route, f).joined(separator: ",")
            out += "," + [r.chromeVisible ? "1" : "0", r.panel, q(r.event)].joined(separator: ",")
            out += "\n"
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nit-lab-\(stamp.string(from: Date())).csv")
        try out.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func dialogColumns(_ d: AudioStageStatus?, _ f: (Double, Int) -> String) -> [String] {
        guard let d, d.settings.dialog.active else { return ["0", "", "", "", "", "", "", "", "", "", "", "", ""] }
        func o(_ v: Double?, _ digits: Int = 2) -> String { v.map { f($0, digits) } ?? "" }
        let au = d.isolation
        let dialog = d.settings.dialog
        return [dialog.solo ? "solo" : String(dialog.tier), "\"\(d.engine)\"", f(d.relaxation, 3), f(d.compensationDB, 2),
                o(d.stageCPUPercent), o(au?.cpuPercent), o(au?.wallPercent), o(au?.worstBlockMs, 3), o(au?.usedLatencyMs, 1),
                o(au?.measuredLatencyMs, 1), o(d.music?.music, 3), o(d.music?.singing, 3), o(d.music?.speech, 3)]
    }

    private static func boostColumns(_ d: AudioStageStatus?, _ m: BoostMeters?, route: String,
                                     _ f: (Double, Int) -> String) -> [String] {
        func o(_ v: Double?, _ digits: Int = 2) -> String { v.map { f($0, digits) } ?? "" }
        guard let d else { return [route] + [String](repeating: "", count: 13) }
        let boost = d.settings.boost
        return [route, f(boost.percent, 0), boost.mode.rawValue, f(d.ceilingDBTP, 1), f(boost.gainDB, 2), o(m?.appliedGainDB),
                o(m?.gainReductionDB), o(m?.gainReductionPeakDB), o(m?.heavyReductionFraction, 4), m?.clipLit == true ? "1" : "0",
                m.map { String($0.clipCount) } ?? "", m.map { String($0.clipsLastSecond) } ?? "", o(m?.maxPeakDBFS),
                m.map { String($0.truePeakOvers) } ?? ""]
    }
}
