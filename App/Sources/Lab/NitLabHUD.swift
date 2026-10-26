import NitMath
import SwiftUI

/// Laboratuvar HUD'u (03-tasarim §9.1 S0-B): headroom göstergesi ve ölçümler.
struct NitLabHUD: View {
    let snapshot: LabSnapshot
    let params: NitParams
    let sourceTitle: String
    let compact: Bool

    var body: some View {
        Group {
            if compact {
                Text("H \(TR.num(snapshot.hCur))/\(TR.num(snapshot.hPot)) · \(snapshot.status.rawValue.lowercased()) · GPU \(TR.num(snapshot.gpuP95, 1)) ms · düşen \(snapshot.droppedFrames)")
                    .font(DS.mono)
                    .foregroundStyle(statusColor)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(params.mode.rawValue) · \(sourceTitle)\(curveSuffix)")
                        .font(DS.mono.weight(.semibold))
                        .lineLimit(1)
                    HeadroomGauge(hEff: snapshot.hEff, hPot: snapshot.hPot, outputMax: snapshot.outputMax,
                                  violated: !snapshot.p2OK)
                        .frame(height: 30)
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(snapshot.status.rawValue).foregroundStyle(statusColor)
                        Spacer(minLength: 8)
                        Text("P-1 ✓").foregroundStyle(DS.green)
                        Text(snapshot.p2OK ? "P-2 ✓" : "P-2 ✗").foregroundStyle(snapshot.p2OK ? DS.green : DS.red)
                    }
                    line("H_cur \(TR.num(snapshot.hCur))  H_pot \(TR.num(snapshot.hPot))  H_s \(TR.num(snapshot.hSmoothed))  H_eff \(params.mode == .nit ? TR.num(snapshot.hEff) : "sistem")")
                    line(brightnessLine)
                    line("ısı \(snapshot.thermal.label) · DGM \(snapshot.lowPower ? "açık" : "kapalı") · ekran kaydı \(snapshot.captured ? "var" : "yok")",
                         color: snapshot.lowPower || snapshot.thermal.rawValue >= 2 ? DS.amber : .white)
                    if snapshot.isHDR, params.mode == .nit {
                        line(sceneWhiteLine, color: params.referenceWhiteMode == .scene ? .white : DS.secondary)
                    }
                    if let rpu = snapshot.rpuSummary {
                        line(rpu, color: DS.secondary)
                    }
                    line("GPU p50 \(TR.num(snapshot.gpuP50, 1)) · p95 \(TR.num(snapshot.gpuP95, 1)) ms (hedef ≤ \(snapshot.isHDR ? "3,0" : "1,5"))")
                    line("kare: düşen \(snapshot.droppedFrames) · kadans \(snapshot.cadence) · sapma \(TR.num(snapshot.vsyncJitterMs, 1)) ms")
                    if let ms = snapshot.lastSwitchMs {
                        line("son geçiş \(TR.num(ms, 0)) ms", color: DS.secondary)
                    }
                    if snapshot.externalDimCount > 0 {
                        line("dışarıdan parlaklık düşüşü: \(snapshot.externalDimCount)", color: DS.amber)
                    }
                    if let error = snapshot.errorMessage {
                        line(error, color: DS.red)
                    }
                }
                .font(DS.mono)
                .frame(width: 380, alignment: .leading)
            }
        }
        .foregroundStyle(.white)
        .oledIsland()
    }

    private var curveSuffix: String {
        guard params.mode == .nit, snapshot.isHDR else { return "" }
        return params.curveMode == .maximum ? " · Maksimum" : " · Dengeli"
    }

    /// "sahne beyazı 128 nit · çapa 135 · L_ref 128 → 0,95 H · histogram P90"
    private var sceneWhiteLine: String {
        var parts: [String] = []
        if let white = snapshot.sceneWhite {
            parts.append("sahne beyazı \(TR.num(white, 0)) nit")
        }
        if let anchor = snapshot.anchor {
            parts.append("çapa \(TR.num(anchor, 0))")
        }
        var ref = "L_ref \(TR.num(snapshot.referenceWhite, 0))"
        if let fraction = snapshot.whiteFractionOfH {
            ref += " → \(TR.num(fraction)) H"
        }
        parts.append(ref)
        parts.append(snapshot.referenceWhiteSource)
        if let hist = snapshot.histogramWhite {
            parts.append("hist P90 \(TR.num(hist, 0))")
        }
        return parts.joined(separator: " · ")
    }

    private var brightnessLine: String {
        var text = "parlaklık \(TR.num(snapshot.brightness))"
        if snapshot.raising { text += " ↑ Tepe Kilidi" }
        if let knee = snapshot.kneeBrightness { text += " · b_k \(TR.num(knee))" }
        if !params.peakLock { text += " · kilit kapalı" }
        return text
    }

    private var statusColor: Color {
        switch snapshot.status {
        case .panelPeak: DS.green
        case .sliderLimited: snapshot.raising ? DS.green : DS.amber
        case .collapsed, .lowPower, .thermal, .captured: DS.amber
        }
    }

    private func line(_ text: String, color: Color = .white) -> some View {
        Text(text).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.8)
    }
}

/// Headroom göstergesi (C-12): log2 eksen 1×–8× (gerekirse 16×).
/// Dolgu `H_eff`, kesikli çizgi `H_pot`, üçgen çıkış maksimumu.
struct HeadroomGauge: View {
    let hEff: Double
    let hPot: Double
    let outputMax: Double
    let violated: Bool

    var body: some View {
        Canvas { context, size in
            let maxStops = hPot > 8 ? 4.0 : 3.0
            func x(_ h: Double) -> CGFloat { CGFloat(min(max(log2(max(h, 1)) / maxStops, 0), 1)) * size.width }
            let barY = size.height * 0.45
            let barH = size.height * 0.30
            context.fill(Path(CGRect(x: 0, y: barY, width: size.width, height: barH)), with: .color(.white.opacity(0.12)))
            context.fill(Path(CGRect(x: 0, y: barY, width: x(hEff), height: barH)), with: .color(.white))
            var dash = Path()
            dash.move(to: CGPoint(x: x(hPot), y: barY - 3))
            dash.addLine(to: CGPoint(x: x(hPot), y: barY + barH + 3))
            context.stroke(dash, with: .color(DS.amber), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
            if outputMax > 0 {
                let ox = x(outputMax)
                var tri = Path()
                tri.move(to: CGPoint(x: ox, y: barY + barH + 1))
                tri.addLine(to: CGPoint(x: ox - 4, y: size.height))
                tri.addLine(to: CGPoint(x: ox + 4, y: size.height))
                tri.closeSubpath()
                context.fill(tri, with: .color(violated ? DS.red : .white))
            }
            for stop in 0...Int(maxStops) {
                let h = pow(2.0, Double(stop))
                context.draw(Text("\(Int(h))×").font(DS.monoSmall).foregroundColor(DS.secondary),
                             at: CGPoint(x: min(max(x(h), 10), size.width - 12), y: barY / 2 - 1))
            }
        }
    }
}
