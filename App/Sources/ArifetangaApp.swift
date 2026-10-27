import AVFoundation
import SwiftUI

@main
struct ArifetangaApp: App {
    init() {
        // Sessize alma anahtarından bağımsız oynatma; arka planda ses (UIBackgroundModes: audio).
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        // S3: çok kanallı PCM (TrueHD/DTS 7.1) ve Atmos uzamsal sese gidebilsin (02-cozum §5.3).
        try? session.setSupportsMultichannelContent(true)
        try? session.setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            LabHomeView()
                .preferredColorScheme(.dark)
        }
    }
}
