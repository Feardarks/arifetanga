import Foundation
import NitMath

enum RenderMode: String, CaseIterable {
    case nit = "Nit"
    case reference = "Referans"
}

/// Test desenleri. Video yerine doğrudan Nit Çekirdeği'nde üretilir (dosya gerektirmez).
enum PatternKind: Int, CaseIterable, Identifiable {
    case sdrWindow = 1
    case pqWindow = 2
    case rampFine = 3
    case rampDark = 4
    case sdrGrayRamp = 5
    case readability = 6
    /// Eşitlik testindeki Referans yaması (PQ katmanına doğrudan PQ kodu). Dosya panelinde görünmez.
    case pqReference = 7

    /// Dosya panelinde listelenen desenler.
    static let panelCases: [PatternKind] = [.sdrWindow, .pqWindow, .rampFine, .rampDark, .sdrGrayRamp, .readability]

    var id: Int { rawValue }

    var isHDR: Bool { self == .pqWindow || self == .readability || self == .pqReference }

    var title: String {
        switch self {
        case .sdrWindow: "Beyaz pencereler · SDR"
        case .pqWindow: "Beyaz pencereler · PQ"
        case .rampFine: "Rampa · ince (AS-33)"
        case .rampDark: "Rampa · karanlık (AS-33)"
        case .sdrGrayRamp: "SDR gri rampa (gama)"
        case .readability: "Okunabilirlik deseni (K-T1)"
        case .pqReference: "Referans PQ yaması"
        }
    }

    var hasWindow: Bool { self == .sdrWindow || self == .pqWindow }
}

struct PatternSpec: Equatable {
    var kind: PatternKind
    /// Ekran alanının kesri (0,01–1).
    var windowFraction: Double = 0.10
    /// PQ desenleri için mutlak nit.
    var levelNits: Double = 1000
    /// Pencerenin yatay merkezi (0–1); eşitlik testinde 0,25 ya da 0,75.
    var centerX: Double = 0.5

    var label: String {
        var parts = [kind.title]
        if kind.hasWindow { parts.append("%\(Int((windowFraction * 100).rounded()))") }
        if kind == .pqWindow { parts.append("\(Int(levelNits)) nit") }
        return parts.joined(separator: " · ")
    }
}

enum LabSource: Equatable {
    case none
    case file(URL)
    case pattern(PatternSpec)
}

/// Laboratuvarın ayarlanabilir parametreleri (03-tasarim §9.1 S0-E).
struct NitParams: Equatable {
    var mode: RenderMode = .nit
    var curveMode: CurveMode = .maximum
    var maxW = 0.95
    var maxKappa = 0.80
    var balancedW = 0.75
    var balancedKappa = 0.50
    var tauUpMs = 150.0
    var deadbandPercent = 1.0
    var peakLock = true
    var peakStep = 0.03
    var peakIntervalMs = 300.0
    var peakThreshold = 0.97
    var dither = true
    var ditherBits = 10
    var sdrGamma = 2.4
    var referenceWhiteNits = NitTone.defaultReferenceWhiteNits
    var highQualityScaler = true

    var curve: NitCurve {
        curveMode == .maximum ? NitCurve(w: maxW, kappa: maxKappa) : NitCurve(w: balancedW, kappa: balancedKappa)
    }

    var renderSettings: RenderSettings {
        RenderSettings(curve: curve, sdrGamma: sdrGamma, referenceWhiteNits: referenceWhiteNits,
                       dither: dither, ditherBits: ditherBits, highQualityScaler: highQualityScaler)
    }

    var peakLockConfig: PeakLock.Config {
        var c = PeakLock.Config()
        c.step = peakStep
        c.interval = peakIntervalMs / 1000
        c.threshold = peakThreshold
        return c
    }

    /// CSV başlığına yazılan parametre özeti.
    var csvSummary: String {
        let c = curve
        return "mod=\(mode.rawValue); egri=\(curveMode == .maximum ? "Maksimum" : "Dengeli"); w=\(c.w); kappa=\(c.kappa); "
            + "tau_up_ms=\(tauUpMs); olu_bant_%=\(deadbandPercent); tepe_kilidi=\(peakLock); adim=\(peakStep); "
            + "aralik_ms=\(peakIntervalMs); esik=\(peakThreshold); titresim=\(dither); b=\(ditherBits); "
            + "sdr_gama=\(sdrGamma); L_ref=\(referenceWhiteNits); olcekleyici=\(highQualityScaler ? "kaliteli" : "bilineer")"
    }
}

/// Arayüze 10 Hz'de giden anlık görüntü.
struct LabSnapshot {
    var hCur = 1.0
    var hPot = 1.0
    var hSmoothed = 1.0
    var hEff = 1.0
    var brightness = 0.0
    var brightnessTarget: Double?
    var kneeBrightness: Double?
    var status: HeadroomStatus = .panelPeak
    var raising = false
    var thermal: ProcessInfo.ThermalState = .nominal
    var lowPower = false
    var captured = false
    var gpuP50 = 0.0
    var gpuP95 = 0.0
    var droppedFrames = 0
    var cadence = "—"
    var vsyncJitterMs = 0.0
    var outputMax = 0.0
    /// Uygulamanın parlaklığı hiç düşürmediğinin kaydı (P-1). Dışarıdan (kullanıcı/sistem) düşüşler ayrıca sayılır.
    var externalDimCount = 0
    var formatLabel = "Dosya yok"
    var isHDR = false
    var currentTime = 0.0
    var duration = 0.0
    var playing = false
    var recordingSeconds = 0.0
    var lastSwitchMs: Double?
    var errorMessage: String?

    /// P-2: çıkış hiçbir zaman sistemin o an verdiği headroom'u aşmaz.
    var p2OK: Bool { outputMax <= hCur + 1e-6 }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "ılık"
        case .serious: "sıcak"
        case .critical: "kritik"
        @unknown default: "?"
        }
    }
}

enum TR {
    static let locale = Locale(identifier: "tr_TR")

    static func num(_ v: Double, _ digits: Int = 2) -> String {
        v.formatted(.number.precision(.fractionLength(digits)).locale(locale))
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
