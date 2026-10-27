import NitMath
import SwiftUI

/// Laboratuvar şeridi (03-tasarim §9.1 S0-B): oynatma, ana kontroller, araçlar.
struct NitLabStrip: View {
    @ObservedObject var model: NitLabModel
    let onClose: () -> Void
    @State private var scrubbing: Double?

    var body: some View {
        let snap = model.snapshot
        VStack(alignment: .leading, spacing: 8) {
            // Satır 1: oynatma
            HStack(spacing: 10) {
                Button(action: model.togglePlay) {
                    Image(systemName: snap.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 36, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(snap.duration <= 0)
                Text(TR.time(scrubbing ?? snap.currentTime)).font(DS.mono)
                Slider(value: Binding(get: { scrubbing ?? snap.currentTime },
                                      set: { scrubbing = $0 }),
                       in: 0...max(snap.duration, 1)) { editing in
                    if !editing, let target = scrubbing {
                        model.seek(to: target)
                        scrubbing = nil
                    }
                }
                .tint(.white)
                .disabled(snap.duration <= 0)
                Text(TR.time(snap.duration)).font(DS.mono)
                PillButton(title: "Döngü", isOn: model.loop) { model.loop.toggle() }
            }
            // Satır 2: ana kontroller
            HStack(spacing: 8) {
                PillButton(title: "Dosya", isOn: nil) {
                    model.parameterPanelVisible = false
                    model.filePanelVisible.toggle()
                }
                SegmentToggle(options: [(RenderMode.nit, "Nit"), (RenderMode.reference, "Referans")],
                              selection: $model.params.mode)
                if snap.isHDR || model.params.mode == .reference {
                    SegmentToggle(options: [(CurveMode.maximum, "Maksimum"), (CurveMode.balanced, "Dengeli")],
                                  selection: $model.params.curveMode,
                                  disabled: model.params.mode == .reference)
                } else {
                    Text("SDR: beyaz = H").font(DS.mono).foregroundStyle(DS.secondary).padding(.horizontal, 6)
                }
                PillButton(title: "Tepe Kilidi", isOn: model.params.peakLock,
                           disabled: model.params.mode == .reference) { model.params.peakLock.toggle() }
                PillButton(title: "Titreşim", isOn: model.params.dither,
                           disabled: model.params.mode == .reference) { model.params.dither.toggle() }
            }
            // Satır 3: araçlar (dar ekranda yatay kayar)
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // M9: her dokunuş bir kademe (kapalı → +3 → +6 → +9 dB → kapalı).
                        PillButton(title: model.params.dialogTier == 0 ? "Diyalog" : "Diyalog +\(model.params.dialogTier * 3) dB",
                                   isOn: model.params.dialogTier > 0) {
                            model.params.dialogTier = (model.params.dialogTier + 1) % 4
                        }
                        // M10: %100 ↔ son boost değeri; Limiter: Akıllı ↔ Kapalı (tek dokunuş, §5.5).
                        PillButton(title: model.params.boostPercent > 100 ? "Boost %\(Int(model.params.boostPercent.rounded()))" : "Boost",
                                   isOn: model.params.boostPercent > 100) { model.toggleBoost() }
                        PillButton(title: model.limiterEngaged ? "Limiter" : "Limiter kapalı",
                                   isOn: model.limiterEngaged) { model.toggleLimiter() }
                        PillButton(title: "Eşitlik testi", isOn: nil) { model.openEqualitySetup() }
                        PillButton(title: "Tonalite testi", isOn: nil) { model.startToneTest() }
                        PillButton(title: "Parametreler", isOn: nil) {
                            model.filePanelVisible = false
                            model.parameterPanelVisible.toggle()
                        }
                        PillButton(title: "CSV paylaş", isOn: nil) { model.exportCSV() }
                        PillButton(title: model.hudCompact ? "HUD büyüt" : "HUD küçült", isOn: nil) { model.hudCompact.toggle() }
                    }
                }
                PillButton(title: "Kapat", isOn: nil, action: onClose)
            }
        }
        .foregroundStyle(.white)
        .oledIsland(padding: 12)
    }
}
