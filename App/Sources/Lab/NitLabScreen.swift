import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// E-61 Nit Laboratuvarı (03-tasarim §9.1).
struct NitLabScreen: View {
    @StateObject private var model = NitLabModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            VideoSurface(view: model.engine.surface)
                .ignoresSafeArea()

            // Videoya tek dokunuş şeridi gizler ya da gösterir; HUD sabit kalır.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { if !isTesting { model.chromeVisible.toggle() } }

            if isTesting {
                // Testler sırasında yalnızca test arayüzü görünür; telemetri kaydı sürer.
                EqualityTestOverlay(model: model)
                ToneTestOverlay(model: model)
            } else {
                labChrome
            }
        }
        .background(Color.black)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
        .fileImporter(isPresented: $model.importerPresented,
                      allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
            switch result {
            case .success(let url): model.open(url: url)
            case .failure(let error): model.showToast("Dosya seçilemedi: \(error.localizedDescription)")
            }
        }
        .sheet(item: $model.shareItem) { item in
            ActivityView(items: [item.url])
        }
    }

    private var isTesting: Bool { model.equality != nil || model.toneTestActive }

    private var labChrome: some View {
            VStack(spacing: 8) {
                HStack(alignment: .top) {
                    NitLabHUD(snapshot: model.snapshot, params: model.params,
                              sourceTitle: model.snapshot.formatLabel, compact: model.hudCompact)
                    Spacer(minLength: 12)
                    RecordingBadge(seconds: model.snapshot.recordingSeconds)
                }
                .offset(model.microShift)

                if let toast = model.toast {
                    Text(toast)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .oledIsland(padding: 12)
                        .transition(.opacity)
                }

                Spacer(minLength: 0)

                HStack(alignment: .bottom) {
                    if model.filePanelVisible {
                        FilePanel(model: model)
                    }
                    Spacer(minLength: 0)
                    if model.parameterPanelVisible {
                        ParameterPanel(model: model)
                    }
                }

                if model.chromeVisible {
                    NitLabStrip(model: model) { dismiss() }
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .animation(.easeOut(duration: 0.2), value: model.chromeVisible)
            .animation(.easeOut(duration: 0.2), value: model.toast)
    }
}

/// Kayıt göstergesi: Laboratuvar açıkken telemetri sürekli kaydedilir.
struct RecordingBadge: View {
    let seconds: Double

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(DS.red).frame(width: 8, height: 8)
            Text("Kayıt \(TR.time(seconds))").font(DS.mono)
        }
        .foregroundStyle(.white)
        .oledIsland(padding: 8)
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
