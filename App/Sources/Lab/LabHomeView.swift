import SwiftUI

/// E-60 Laboratuvar kökü. Sprint 1'de uygulamanın ana ekranıdır (03-tasarim §9.1).
struct LabHomeView: View {
    @State private var nitLabPresented = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text("Laboratuvar")
                    .font(.largeTitle.weight(.bold))
                Text("S0 · Nit Çekirdeği prototipi")
                    .font(.subheadline)
                    .foregroundStyle(DS.secondary)

                Button { nitLabPresented = true } label: {
                    labRow(title: "Nit Laboratuvarı", detail: "Headroom, Tepe Kilidi, Nit ↔ Referans, CSV kaydı", enabled: true)
                }
                .buttonStyle(.plain)

                labRow(title: "Ses Laboratuvarı", detail: "Boost, limiter ve kırpma ölçerleri · Sprint 1, 2. hafta", enabled: false)
                labRow(title: "Tasarım Kataloğu", detail: "Bileşenler ve okunabilirlik deseni · Sprint 1", enabled: false)

                Spacer()
                Text("Sürüm \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                    .font(.footnote)
                    .foregroundStyle(DS.secondary)
            }
            .foregroundStyle(.white)
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .fullScreenCover(isPresented: $nitLabPresented) {
            NitLabScreen()
        }
    }

    private func labRow(title: String, detail: String, enabled: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(DS.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(DS.secondary)
        }
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(enabled ? 1 : 0.4)
    }
}
