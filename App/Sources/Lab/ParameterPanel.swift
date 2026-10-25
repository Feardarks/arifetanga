import NitMath
import SwiftUI

/// Parametreler paneli (03-tasarim §9.1 S0-E). Her değişiklik CSV'ye olay satırı olarak yazılır.
struct ParameterPanel: View {
    @ObservedObject var model: NitLabModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Parametreler").font(.headline)

                group("Eğri · Maksimum")
                slider("w", value: $model.params.maxW, range: 0.90...0.98, digits: 2)
                slider("κ", value: $model.params.maxKappa, range: 0.70...0.90, digits: 2)

                group("Eğri · Dengeli")
                slider("w", value: $model.params.balancedW, range: 0.70...0.80, digits: 2)
                slider("κ", value: $model.params.balancedKappa, range: 0.40...0.60, digits: 2)

                group("HDR referans beyazı")
                slider("L_ref (nit)", value: $model.params.referenceWhiteNits, range: 100...300, digits: 0)

                group("Headroom")
                slider("τ_up (ms)", value: $model.params.tauUpMs, range: 50...1000, digits: 0)
                slider("Ölü bant (%)", value: $model.params.deadbandPercent, range: 0.5...3, digits: 1)

                group("Tepe Kilidi")
                slider("Adım", value: $model.params.peakStep, range: 0.01...0.05, digits: 2)
                slider("Aralık (ms)", value: $model.params.peakIntervalMs, range: 100...1000, digits: 0)
                slider("Eşik × H_pot", value: $model.params.peakThreshold, range: 0.95...0.99, digits: 2)
                Button("b_k'yi sıfırla") { model.resetKnee() }
                    .font(.subheadline)

                group("Titreşim")
                Picker("b", selection: $model.params.ditherBits) {
                    Text("8 bit").tag(8)
                    Text("10 bit").tag(10)
                }
                .pickerStyle(.segmented)

                group("SDR gaması")
                Picker("Gama", selection: $model.params.sdrGamma) {
                    Text("2,2").tag(2.2)
                    Text("2,4").tag(2.4)
                    Text("1,96").tag(1.96)
                }
                .pickerStyle(.segmented)

                Button("Hepsini varsayılana döndür") { model.resetParams() }
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 8)
            }
            .padding(4)
        }
        .frame(width: 340)
        .frame(maxHeight: 320)
        .foregroundStyle(.white)
        .oledIsland(padding: 12)
    }

    private func group(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(DS.secondary)
            .padding(.top, 6)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, digits: Int) -> some View {
        HStack {
            Text(title).font(.subheadline).frame(width: 110, alignment: .leading)
            Slider(value: value, in: range).tint(.white)
            Text(TR.num(value.wrappedValue, digits)).font(DS.mono).frame(width: 52, alignment: .trailing)
        }
    }
}
