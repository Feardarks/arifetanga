import SwiftUI

/// S0-C · Eşitlik testi (03-tasarim §9.1). Yanıt şeridi opak ve küçüktür; ABL'yi etkilemez.
struct EqualityTestOverlay: View {
    @ObservedObject var model: NitLabModel

    var body: some View {
        if let test = model.equality {
            VStack {
                if test.phase == .running || test.phase == .blank {
                    // Yalnızca "A" ve "B" etiketleri; hangi yarının Nit olduğu gösterilmez.
                    HStack {
                        sideLabel("A").frame(maxWidth: .infinity)
                        sideLabel("B").frame(maxWidth: .infinity)
                    }
                    .opacity(test.phase == .running ? 1 : 0)
                }
                Spacer()
                switch test.phase {
                case .setup: setup(test)
                case .running, .blank: answerBar(test)
                case .done: result(test)
                }
            }
            .padding(8)
        }
    }

    private func sideLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .oledIsland(padding: 8)
    }

    private func setup(_ test: NitLabModel.EqualityTest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Eşitlik testi").font(.headline)
            Text("Bir yarıda Nit (SDR beyaz × H), diğerinde Apple'ın kendi HDR beyazı. Hangisinin hangisi olduğu her denemede rastgele atanır.")
                .font(.footnote).foregroundStyle(DS.secondary)
            HStack {
                Text("Pencere").font(.subheadline).frame(width: 80, alignment: .leading)
                Picker("Pencere", selection: binding(\.windowPercent)) {
                    Text("%10").tag(10.0)
                    Text("%25").tag(25.0)
                }
                .pickerStyle(.segmented)
            }
            HStack {
                Text("PQ").font(.subheadline).frame(width: 80, alignment: .leading)
                Picker("PQ seviyesi", selection: binding(\.levelNits)) {
                    Text("1000").tag(1000.0)
                    Text("4000").tag(4000.0)
                    Text("10000").tag(10000.0)
                }
                .pickerStyle(.segmented)
            }
            HStack {
                PillButton(title: "Başlat", isOn: nil) { model.startEquality() }
                PillButton(title: "Vazgeç", isOn: nil) { model.closeEquality() }
            }
        }
        .frame(width: 420)
        .foregroundStyle(.white)
        .oledIsland(padding: 14)
    }

    private func answerBar(_ test: NitLabModel.EqualityTest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Deneme \(test.current) / \(NitLabModel.EqualityTest.trialCount) · %\(Int(test.windowPercent)) pencere · PQ \(Int(test.levelNits))")
                .font(DS.mono)
            HStack(spacing: 10) {
                PillButton(title: "A daha parlak", isOn: nil) { model.answerEquality(.leftBrighter) }
                PillButton(title: "Aynı", isOn: nil) { model.answerEquality(.same) }
                PillButton(title: "B daha parlak", isOn: nil) { model.answerEquality(.rightBrighter) }
                Spacer(minLength: 16)
                PillButton(title: "Bitir", isOn: nil) { model.closeEquality() }
            }
            .disabled(test.phase == .blank)
        }
        .foregroundStyle(.white)
        .oledIsland(padding: 12)
    }

    private func result(_ test: NitLabModel.EqualityTest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(NitLabModel.EqualityTest.trialCount) denemenin \(test.sameCount)'\(suffix(test.sameCount)) \"Aynı\" → K2 eşitlik ölçütü \(test.passed ? "geçti" : "geçmedi")")
                .font(.headline)
                .foregroundStyle(test.passed ? DS.green : DS.amber)
            ForEach(test.trials) { trial in
                Text("\(trial.id). Nit \(trial.nitOnLeft ? "A (sol)" : "B (sağ)") · yanıt: \(trial.answer?.rawValue ?? "—") → \(trial.verdict)")
                    .font(DS.mono)
            }
            Text("Sonuç CSV'ye olay satırı olarak yazıldı.").font(.footnote).foregroundStyle(DS.secondary)
            PillButton(title: "Kapat", isOn: nil) { model.closeEquality() }
        }
        .frame(width: 460, alignment: .leading)
        .foregroundStyle(.white)
        .oledIsland(padding: 14)
    }

    /// Türkçe bulunma hâli eki (4'ünde, 5'inde…).
    private func suffix(_ n: Int) -> String {
        switch n % 10 {
        case 0: return n == 0 ? "ında" : "unda"
        case 1, 5, 8: return "inde"
        case 2, 7: return "sinde"
        case 3, 4: return "ünde"
        case 6: return "sında"
        default: return "inde"
        }
    }

    private func binding(_ keyPath: WritableKeyPath<NitLabModel.EqualityTest, Double>) -> Binding<Double> {
        Binding(get: { model.equality?[keyPath: keyPath] ?? 0 },
                set: { model.equality?[keyPath: keyPath] = $0 })
    }
}

/// S0-D · Tonalite testi (03-tasarim §9.1): solda Referans (Apple SDR video), sağda Nit (H = 1).
struct ToneTestOverlay: View {
    @ObservedObject var model: NitLabModel

    var body: some View {
        if model.toneTestActive {
            VStack {
                HStack {
                    label("Referans").frame(maxWidth: .infinity)
                    label("Nit · H = 1").frame(maxWidth: .infinity)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Hangi gama soldakine en yakın?").font(.subheadline.weight(.semibold))
                    HStack(spacing: 10) {
                        SegmentToggle(options: [(2.2, "2,2"), (2.4, "2,4"), (1.96, "1,96")],
                                      selection: $model.params.sdrGamma)
                        PillButton(title: "Bu eşleşiyor", isOn: nil) { model.confirmToneMatch() }
                        Spacer(minLength: 16)
                        PillButton(title: "Bitir", isOn: nil) { model.endToneTest() }
                    }
                }
                .foregroundStyle(.white)
                .oledIsland(padding: 12)
            }
            .padding(8)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .oledIsland(padding: 8)
    }
}
