import AVFoundation

/// Ses oturumu: kategori/kip ve örnekleme hızı (02-cozum §5.6, S6). Dosya açılırken dosyanın hızı istenir;
/// donanımın gerçekten o hıza geçip geçmediği (USB DAC'ta geçer, hoparlörde 48 kHz kalır) ayrıca okunur.
@MainActor
final class AudioSessionController {
    /// Oturum kipi. Film: `.moviePlayback` (sistemin film için çıkış işlemesi); Müzik: `.default` (bit-perfect yolu).
    enum ModeChoice: String, CaseIterable {
        case automatic = "Otomatik"
        case movie = "Film"
        case music = "Müzik"
    }

    struct State: Equatable {
        var mode = ""
        var requestedRate: Double?
        var hardwareRate = 0.0
        var routeName = "—"
        var outputChannels = 0
        var outputVolume: Float = 1
        var ioBufferMs = 0.0
        var outputLatencyMs = 0.0
        var error: String?
    }

    private(set) var state = State()
    private let session = AVAudioSession.sharedInstance()

    /// Kip ve hız (dosya açılırken, oynatma başlamadan önce). Hız değişimi donanımı yeniden kurar; kısa bir
    /// boşluk kaçınılmazdır (§5.6).
    func prepare(mode: AVAudioSession.Mode, sampleRate: Double?) {
        var errors: [String] = []
        if session.mode != mode {
            do {
                try session.setCategory(.playback, mode: mode, options: [])
            } catch {
                errors.append("kip: \(error.localizedDescription)")
            }
        }
        if let sampleRate {
            do {
                try session.setPreferredSampleRate(sampleRate)
            } catch {
                errors.append("hız: \(error.localizedDescription)")
            }
        }
        do {
            try session.setActive(true)
        } catch {
            errors.append("etkinleştirme: \(error.localizedDescription)")
        }
        state.requestedRate = sampleRate
        state.error = errors.isEmpty ? nil : errors.joined(separator: " · ")
        refresh()
    }

    func refresh() {
        state.mode = session.mode == .moviePlayback ? "Film" : session.mode == .default ? "Müzik" : session.mode.rawValue
        state.hardwareRate = session.sampleRate
        state.routeName = session.currentRoute.outputs.first?.portName ?? "—"
        state.outputChannels = session.outputNumberOfChannels
        state.outputVolume = session.outputVolume
        state.ioBufferMs = session.ioBufferDuration * 1000
        state.outputLatencyMs = session.outputLatency * 1000
    }
}

/// Sinyal yolu ve bit-perfect değerlendirmesi (§5.6 görünümü, AS-11). HUD ve CSV.
struct SignalPathStatus: Equatable {
    /// Ör. "Dosya 24/96 FLAC → FFmpeg (s32) → iOS mikseri @96 kHz → USB DAC «xDSD» 96 kHz".
    var path = ""
    /// `true`: bit-perfect; `false`: değil (`reasons`); `nil`: bu rotada/kaynakta anlamlı değil.
    var bitPerfect: Bool?
    var reasons: [String] = []
    /// Kesin olmayan uyarılar (ör. ses seviyesi %100 değil: DAC'ın donanım seviyesi yoksa dijital azaltma).
    var cautions: [String] = []
    var fileRate = 0
    var hardwareRate = 0.0
    var route = ""
    var md5 = ""

    var verdict: String {
        switch bitPerfect {
        case true?: "Bit-perfect ✓"
        case false?: "Bit-perfect değil: " + reasons.joined(separator: " · ")
        case nil: reasons.isEmpty ? "Bit-perfect: —" : "Bit-perfect: — (" + reasons.joined(separator: " · ") + ")"
        }
    }
}
