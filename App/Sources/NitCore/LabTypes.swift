import AudioDSP
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

/// HDR referans beyazının kaynağı (02-cozum §3.5.1, tasarım C-13).
enum ReferenceWhiteMode: String, CaseIterable {
    case scene = "Sahne"
    case fixed = "Sabit 203"
    case manual = "Elle"
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
    /// Elle kipteki referans beyaz (100–300 nit).
    var referenceWhiteNits = NitTone.defaultReferenceWhiteNits
    var referenceWhiteMode: ReferenceWhiteMode = .scene
    /// Sahne kipinde film çapasından en fazla sapma (stop).
    var sceneDeviationStops = 0.5
    /// Sahne kesimi eşiği (CDF farkı); AS-38'de ayarlanır.
    var cutThreshold = 0.08
    var highQualityScaler = true
    /// MP4/MOV'u da kendi hattımızla aç (MKV/M2TS her zaman kendi hattımızdadır). Referans: AVSampleBufferDisplayLayer.
    var preferNativeEngine = false
    /// M9 diyalog netleştirme (S4): kademe 0–3 (+3/+6/+9 dB), motor, solo (kör test) ve AU modeli.
    var dialogTier = 0
    var dialogEngine: DialogSettings.Engine = .automatic
    var dialogSolo = false
    var dialogHighQuality = false

    var dialogSettings: DialogSettings {
        DialogSettings(tier: dialogTier, engine: dialogEngine, solo: dialogSolo, highQuality: dialogHighQuality)
    }

    /// M10 boost (S5): kaydırıcı %100–150, limiter kipi ve uzman seçenekleri.
    var boostPercent = 100.0
    var limiterMode: LimiterMode = .smart
    var boostAggressive = false
    var boostKeepAtmos = false
    var boostSpeakerHighPass = true
    /// AS-37 (g): renderer `volume = 1,5` denemesi (yalnızca bilgi; tasarım buna dayanmaz).
    var rendererVolumeTest = false
    /// S6 bit-perfect: kayıpsız kaynakta renderer'a tamsayı PCM (sonraki açılışta geçerli) ve oturum kipi.
    var integerAudio = true
    var sessionMode: AudioSessionController.ModeChoice = .automatic

    var boostSettings: BoostSettings {
        BoostSettings(percent: boostPercent, mode: limiterMode, aggressive: boostAggressive, keepAtmos: boostKeepAtmos,
                      speakerHighPass: boostSpeakerHighPass)
    }

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
            + "sdr_gama=\(sdrGamma); L_ref_kip=\(referenceWhiteMode.rawValue); L_ref_elle=\(referenceWhiteNits); "
            + "sapma_stop=\(sceneDeviationStops); kesim_esigi=\(cutThreshold); olcekleyici=\(highQualityScaler ? "kaliteli" : "bilineer"); "
            + "motor=\(preferNativeEngine ? "kendi hattimiz" : "AVPlayer (MP4/MOV)"); \(dialogSettings.csv); \(boostSettings.csv)"
            + (rendererVolumeTest ? "; renderer_volume_testi=1,5" : "")
            + "; tamsayi_pcm=\(integerAudio); oturum_kipi=\(sessionMode.rawValue)"
    }
}

/// M10 göstergeleri (AS-37). Ses evresinin PTS'li kayıtlarından, oynatma saatine hizalı toplanır (±20 ms).
struct BoostMeters: Equatable {
    private struct Entry: Equatable {
        var pts: Double
        var gainReduction: Double
        var clips: Int
    }

    /// Şu anki kazanç azaltma (kompresör + limiter) ve son 1 s'nin tepesi (dB).
    var gainReductionDB = 0.0
    var gainReductionPeakDB = 0.0
    /// Uygulanan boost (yönetici sonrası, dB).
    var appliedGainDB: Double?
    /// Kırpma LED'i: son kırpmadan sonra 500 ms yanar.
    var clipLit = false
    /// Kanal başına toplam kırpılan örnek (duyulan kısım; flush'la atılan sayılmaz).
    var clipsTotal: [Int] = []
    var clipsLastSecond = 0
    /// Görülen en büyük örnek tepesi (kırpma öncesi, dBFS).
    var maxPeakDBFS: Double?
    var truePeakOvers = 0
    /// Kazanç azaltmanın 3 dB'yi aştığı zamanın oranı (AS-37 a: ≤ %1).
    var heavyReductionFraction: Double?

    private var recent: [Entry] = []
    private var lastClip: Double?
    private var recordCount = 0
    private var heavyCount = 0

    var clipCount: Int { clipsTotal.reduce(0, +) }

    mutating func ingest(_ records: [AudioMeterRecord], now: Double) {
        for r in records {
            let clips = r.clipped.reduce(0, +)
            if clipsTotal.count < r.clipped.count { clipsTotal += [Int](repeating: 0, count: r.clipped.count - clipsTotal.count) }
            for (c, n) in r.clipped.enumerated() { clipsTotal[c] += n }
            if clips > 0 { lastClip = r.pts }
            truePeakOvers += r.truePeakOvers
            maxPeakDBFS = max(maxPeakDBFS ?? -120, r.peakDBFS)
            appliedGainDB = r.appliedGainDB
            gainReductionDB = r.gainReductionDB
            recordCount += 1
            if r.gainReductionDB > 3 { heavyCount += 1 }
            recent.append(Entry(pts: r.pts, gainReduction: r.gainReductionDB, clips: clips))
        }
        recent.removeAll { $0.pts <= now - 1 }
        if recent.isEmpty { gainReductionDB = 0 }
        gainReductionPeakDB = recent.map(\.gainReduction).max() ?? 0
        clipsLastSecond = recent.reduce(0) { $0 + $1.clips }
        clipLit = lastClip.map { now - $0 <= 0.5 } ?? false
        heavyReductionFraction = recordCount > 0 ? Double(heavyCount) / Double(recordCount) : nil
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
    /// Sahne beyazı (yalnızca HDR): kare P90, süzülmüş Ŵ, film çapası A ve kullanılan L_ref (nit).
    var frameWhite: Double?
    var sceneWhite: Double?
    var anchor: Double?
    var referenceWhite = NitTone.defaultReferenceWhiteNits
    /// Sahnenin beyazının çıktığı değer, H'nin kesri olarak: f(Ŵ / L_ref).
    var whiteFractionOfH: Double?
    var referenceWhiteSource = "sabit 203"
    var sceneCount = 0
    /// DV L1 kullanılırken karşılaştırma için kaynak histogramının P90'ı (AS-38'de `k` kalibrasyonu).
    var histogramWhite: Double?
    /// DV RPU işleme özeti (S2.3); DV yoksa `nil`. Süre RPU başına ortalama (µs).
    var rpuSummary: String?
    var rpuMeanMicros: Double?
    /// DV P5 Nit kod çözümü özeti (S2.4): parça türleri, eşleme sayısı, okunamayanlar.
    var reshapeSummary: String?
    /// Ses hattı (S3): codec, düzen, yol (Atmos sıkıştırılmış / PCM) ve FFmpeg çözme yükü (AS-10).
    var audioSummary: String?
    var audioCPUPercent: Double?
    /// M9 (S4) ve M10 (S5): HUD satırları ve CSV için son durum.
    var audioStageLines: [String] = []
    var audioStage: AudioStageStatus?
    var boostMeters: BoostMeters?
    var route: AudioRouteClass = .other
    /// S6: sinyal yolu ve bit-perfect değerlendirmesi (yalnızca kendi hattımızda).
    var signalPath: SignalPathStatus?
    var signalPathLines: [String] = []

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
