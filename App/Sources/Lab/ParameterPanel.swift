import AudioDSP
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
                Picker("Referans beyaz", selection: $model.params.referenceWhiteMode) {
                    ForEach(ReferenceWhiteMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                switch model.params.referenceWhiteMode {
                case .scene:
                    slider("Sapma δ (stop)", value: $model.params.sceneDeviationStops, range: 0...1, digits: 2)
                    slider("Kesim eşiği", value: $model.params.cutThreshold, range: 0.03...0.15, digits: 2)
                    Text("Sahne beyazı her sahnede histogramın P90'ından ölçülür; film çapasından en fazla δ stop sapar (80–300 nit).")
                        .font(.caption).foregroundStyle(DS.secondary)
                case .fixed:
                    Text("BT.2408 referans beyazı: 203 nit.").font(.caption).foregroundStyle(DS.secondary)
                case .manual:
                    slider("L_ref (nit)", value: $model.params.referenceWhiteNits, range: 100...300, digits: 0)
                }

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

                group("Ölçekleyici")
                Picker("Ölçekleyici", selection: $model.params.highQualityScaler) {
                    Text("Kaliteli").tag(true)
                    Text("Bilineer").tag(false)
                }
                .pickerStyle(.segmented)
                Text("Kaliteli: büyütmede bicubic, 4K'yı küçültürken 2×2 süper örnekleme.")
                    .font(.caption).foregroundStyle(DS.secondary)

                group("Diyalog (M9)")
                Picker("Kademe", selection: $model.params.dialogTier) {
                    Text("Kapalı").tag(0)
                    Text("+3 dB").tag(1)
                    Text("+6 dB").tag(2)
                    Text("+9 dB").tag(3)
                }
                .pickerStyle(.segmented)
                Picker("Motor", selection: $model.params.dialogEngine) {
                    ForEach(DialogSettings.Engine.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("AU modeli", selection: $model.params.dialogHighQuality) {
                    Text("Voice").tag(false)
                    Text("HighQualityVoice").tag(true)
                }
                .pickerStyle(.segmented)
                Toggle("Solo: yalnızca ayrılmış ses", isOn: $model.params.dialogSolo)
                    .font(.subheadline)
                    .tint(DS.green)
                Text("Otomatik: ön planda AUSoundIsolation, arka planda F1. AU: arka planda da AU (AS-15). Solo kör test içindir; loudness eşleme uygulanmaz.")
                    .font(.caption).foregroundStyle(DS.secondary)

                group("Boost (M10)")
                slider("Boost %", value: $model.params.boostPercent, range: 100...150, digits: 0)
                Text("+\(TR.num(BoostConfig.gainDB(percent: model.params.boostPercent), 1)) dB · algısal eşleme, %150 = +6 dB (üst sınır)")
                    .font(.caption).foregroundStyle(DS.secondary)
                Picker("Limiter", selection: $model.params.limiterMode) {
                    Text("Akıllı").tag(LimiterMode.smart)
                    Text("Limiter").tag(LimiterMode.limiterOnly)
                    Text("Kapalı").tag(LimiterMode.off)
                    Text("Ham").tag(LimiterMode.rawFloat)
                }
                .pickerStyle(.segmented)
                Text("Akıllı: yönetici + kompresör + −1 dBTP limiter. Limiter: yalnızca limiter. Kapalı: ±1,0 sert kırpma ve sayaç. Ham: kırpmasız float (yalnızca AS-37 g).")
                    .font(.caption).foregroundStyle(DS.secondary)
                Toggle("Agresif (L_max −7 LUFS)", isOn: $model.params.boostAggressive).font(.subheadline).tint(DS.green)
                Toggle("Atmos'u koru (Atmos'ta boost %100)", isOn: $model.params.boostKeepAtmos).font(.subheadline).tint(DS.green)
                Toggle("Hoparlörde 150 Hz HPF", isOn: $model.params.boostSpeakerHighPass).font(.subheadline).tint(DS.green)
                Toggle("Renderer volume 1,5 (AS-37 g)", isOn: $model.params.rendererVolumeTest).font(.subheadline).tint(DS.green)
                Button("Kırpma/GR göstergelerini sıfırla") { model.resetBoostMeters() }
                    .font(.subheadline)

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
        Text(title)
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
