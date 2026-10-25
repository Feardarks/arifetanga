import Foundation

/// Headroom durumunun sınıflandırması (HUD durum satırı).
public enum HeadroomStatus: String, Sendable {
    case panelPeak = "Panel tepesinde"
    case sliderLimited = "Kaydırıcı sınırlı"
    case collapsed = "Sistem HDR'yi kıstı"
    case lowPower = "Düşük Güç Modu"
    case thermal = "Isıl kısma"
    case captured = "Ekran kaydı"
}

/// Tepe Kilidi (02-cozum §3.6). Ekran parlaklığını **yalnızca yükseltir** (P-1).
/// Saf durum makinesi; UIKit'e dokunmaz. Çağıran, döndürülen hedef parlaklığı uygular.
public struct PeakLock: Sendable {
    public struct Config: Equatable, Sendable {
        public var step = 0.03
        public var interval = 0.300
        /// `H_cur ≥ threshold · H_pot` ise kaydırıcı sınırlı sayılır.
        public var threshold = 0.97
        /// Kaydırıcı sınırlı durumunun yükseltmeden önce sürmesi gereken süre (s).
        public var holdTime = 3.0
        /// Headroom çöküşü: `H_cur < collapseLevel` bu süreden uzun sürerse.
        public var collapseLevel = 1.1
        public var collapseTime = 5.0
        /// Otomatik parlaklık geri çekerse yeniden yükseltme için en kısa aralık (s).
        public var reraiseCooldown = 30.0

        public init() {}
    }

    public struct Input: Sendable {
        public var time: Double
        public var current: Double
        public var potential: Double
        public var brightness: Double
        public var lowPower: Bool
        public var thermalSerious: Bool
        public var captured: Bool

        public init(time: Double, current: Double, potential: Double, brightness: Double,
                    lowPower: Bool, thermalSerious: Bool, captured: Bool) {
            self.time = time
            self.current = current
            self.potential = potential
            self.brightness = brightness
            self.lowPower = lowPower
            self.thermalSerious = thermalSerious
            self.captured = captured
        }
    }

    public struct Output: Equatable, Sendable {
        /// Uygulanacak yeni parlaklık; `nil` ise dokunma. Her zaman ≥ girişteki parlaklık.
        public var brightness: Double?
        public var status: HeadroomStatus
        public var raising: Bool
    }

    public var config: Config
    public var enabled: Bool
    /// Bir önceki oynatmada bulunan dirsek parlaklığı; bir sonrakinde doğrudan buraya çıkılır.
    public var kneeBrightness: Double?

    private var limitedSince: Double?
    private var collapsedSince: Double?
    private var lastStepTime = -Double.infinity
    private var lastRaisedTo: Double?
    private var lastReraiseTime = -Double.infinity

    public init(config: Config = Config(), enabled: Bool = true) {
        self.config = config
        self.enabled = enabled
    }

    public mutating func update(_ i: Input) -> Output {
        let sliderLimited = i.current >= config.threshold * i.potential
        limitedSince = sliderLimited ? (limitedSince ?? i.time) : nil
        collapsedSince = i.current < config.collapseLevel ? (collapsedSince ?? i.time) : nil
        let collapsed = (collapsedSince.map { i.time - $0 > config.collapseTime } ?? false) && !i.lowPower

        let status: HeadroomStatus
        if i.lowPower { status = .lowPower }
        else if collapsed { status = .collapsed }
        else if i.thermalSerious { status = .thermal }
        else if i.captured { status = .captured }
        else if sliderLimited { status = .sliderLimited }
        else { status = .panelPeak }

        guard enabled else { return Output(brightness: nil, status: status, raising: false) }

        // Headroom çöktüyse ya da Düşük Güç Modu açıksa beyaz en azından SDR tepesinde kalsın.
        if collapsed || i.lowPower {
            return raise(to: 1.0, from: i.brightness, at: i.time, status: status)
        }

        // Önceki oynatmada bulunan dirseğe doğrudan çık.
        if let knee = kneeBrightness, i.brightness < knee - 0.005 {
            return raise(to: knee, from: i.brightness, at: i.time, status: status)
        }

        if let since = limitedSince, i.time - since >= config.holdTime, i.brightness < 1.0 {
            // Otomatik parlaklık bizim yükselttiğimiz değeri geri çektiyse bekleme süresine uy.
            if let last = lastRaisedTo, i.brightness < last - 0.005 {
                guard i.time - lastReraiseTime >= config.reraiseCooldown else {
                    return Output(brightness: nil, status: status, raising: false)
                }
                lastReraiseTime = i.time
            }
            guard i.time - lastStepTime >= config.interval else {
                return Output(brightness: nil, status: status, raising: true)
            }
            lastStepTime = i.time
            let target = min(1.0, i.brightness + config.step)
            lastRaisedTo = target
            return Output(brightness: target, status: status, raising: true)
        }

        // Kaydırıcı artık sınırlamıyorsa (panel tepesi) dirseği kaydet.
        if !sliderLimited, lastRaisedTo != nil, kneeBrightness == nil {
            kneeBrightness = i.brightness
        }
        return Output(brightness: nil, status: status, raising: false)
    }

    private mutating func raise(to target: Double, from current: Double, at time: Double, status: HeadroomStatus) -> Output {
        guard current < target - 0.005 else { return Output(brightness: nil, status: status, raising: false) }
        lastRaisedTo = target
        lastStepTime = time
        return Output(brightness: target, status: status, raising: true)
    }

    public mutating func resetKnee() {
        kneeBrightness = nil
        lastRaisedTo = nil
    }
}
