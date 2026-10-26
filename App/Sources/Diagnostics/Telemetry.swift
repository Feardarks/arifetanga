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
        var out = "# Arifetanga Nit Laboratuvarı · S0\n"
        out += "# parametreler: \(paramsHeader)\n"
        out += "t_s,zaman,H_cur,H_pot,H_s,H_eff,parlaklik,durum,mod,kaynak,isi,dusuk_guc,ekran_kaydi,"
        out += "gpu_p50_ms,gpu_p95_ms,dusen_kare,kadans,sapma_ms,cikis_maks,oynatiyor,L_ref,W_f,W_hat,A,chromeVisible,panel,olay\n"
        func f(_ v: Double, _ d: Int = 4) -> String { String(format: "%.\(d)f", v) }
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func o(_ v: Double?) -> String { v.map { f($0, 1) } ?? "" }
        for r in rows {
            out += [f(r.t, 2), iso.string(from: r.date), f(r.hCur), f(r.hPot), f(r.hS), f(r.hEff), f(r.brightness, 3),
                    q(r.status), r.mode, q(r.source), r.thermal, r.lowPower ? "1" : "0", r.captured ? "1" : "0",
                    f(r.gpuP50, 3), f(r.gpuP95, 3), String(r.dropped), q(r.cadence), f(r.jitterMs, 2), f(r.outputMax),
                    r.playing ? "1" : "0", f(r.referenceWhite, 1), o(r.frameWhite), o(r.sceneWhite), o(r.anchor),
                    r.chromeVisible ? "1" : "0", r.panel, q(r.event)].joined(separator: ",")
            out += "\n"
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nit-lab-\(stamp.string(from: Date())).csv")
        try out.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
