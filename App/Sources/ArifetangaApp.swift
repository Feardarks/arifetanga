import AVFoundation
import SwiftUI

@main
struct ArifetangaApp: App {
    init() {
        // Sessize alma anahtarından bağımsız oynatma; arka planda ses (UIBackgroundModes: audio).
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            LabHomeView()
                .preferredColorScheme(.dark)
        }
    }
}
