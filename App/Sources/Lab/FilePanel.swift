import SwiftUI

/// Dosya paneli (03-tasarim §9.1 S0-A): kendi dosyaların, desenler, son açılanlar.
struct FilePanel: View {
    @ObservedObject var model: NitLabModel
    @State private var windowPercent = 10.0
    @State private var pqLevel = 1000.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Dosya").font(.headline)

                Button {
                    model.importerPresented = true
                } label: {
                    row("Dosyalar'dan aç…", detail: "MP4 / MOV · SDR ya da HDR10")
                }
                .buttonStyle(.plain)

                if !model.recents.isEmpty {
                    section("Son açılanlar")
                    ForEach(model.recents) { recent in
                        Button { model.open(recent: recent) } label: { row(recent.name, detail: nil) }
                            .buttonStyle(.plain)
                    }
                }

                section("Desenler")
                HStack {
                    Text("Pencere").font(.footnote).foregroundStyle(DS.secondary)
                    Picker("Pencere", selection: $windowPercent) {
                        ForEach([1.0, 10, 25, 50, 100], id: \.self) { Text("%\(Int($0))").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                HStack {
                    Text("PQ").font(.footnote).foregroundStyle(DS.secondary)
                    Picker("PQ seviyesi", selection: $pqLevel) {
                        ForEach([1000.0, 4000, 10000], id: \.self) { Text("\(Int($0))").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                ForEach(PatternKind.allCases) { kind in
                    Button {
                        model.open(pattern: PatternSpec(kind: kind, windowFraction: windowPercent / 100, levelNits: pqLevel))
                    } label: {
                        row(kind.title, detail: kind.hasWindow ? "%\(Int(windowPercent))\(kind == .pqWindow ? " · \(Int(pqLevel)) nit" : "")" : nil)
                    }
                    .buttonStyle(.plain)
                }

                Text("MKV desteklenmez (S2'de gelir). Kendi rip'ini `ffmpeg -i film.mkv -c copy film.mp4` ile MP4'e kopyalayabilirsin.")
                    .font(.footnote)
                    .foregroundStyle(DS.secondary)
                    .padding(.top, 4)
            }
            .padding(4)
        }
        .frame(width: 340)
        .frame(maxHeight: 320)
        .foregroundStyle(.white)
        .oledIsland(padding: 12)
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(DS.secondary)
            .padding(.top, 6)
    }

    private func row(_ title: String, detail: String?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                if let detail { Text(detail).font(.caption).foregroundStyle(DS.secondary) }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(DS.secondary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
