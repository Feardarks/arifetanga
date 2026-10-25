import Foundation

/// Headroom yumuşatıcısı (02-cozum §3.6): düşüşte anında, yükselişte log uzayında `τ_up` ile.
/// `effective` hiçbir zaman o anki `H_cur`'u aşmaz (P-2).
public struct HeadroomFilter: Sendable {
    public var tauUp: Double
    /// Bağıl ölü bant; bu oranın altındaki yükselişler yok sayılır.
    public var deadband: Double

    public private(set) var smoothed: Double = 1
    public private(set) var effective: Double = 1
    private var log2Smoothed: Double = 0
    private var initialized = false

    public init(tauUp: Double = 0.150, deadband: Double = 0.01) {
        self.tauUp = tauUp
        self.deadband = deadband
    }

    /// - Parameters:
    ///   - current: `H_cur` (sistemin o an verdiği headroom, ≥ 1).
    ///   - dt: Son güncellemeden bu yana geçen süre (s).
    @discardableResult
    public mutating func update(current: Double, dt: Double) -> Double {
        let h = max(current, 1)
        if !initialized || h < smoothed {
            smoothed = h
            log2Smoothed = log2(h)
            initialized = true
        } else if (h - smoothed) / smoothed >= deadband {
            let alpha = 1 - exp(-max(dt, 0) / max(tauUp, 1e-6))
            log2Smoothed += alpha * (log2(h) - log2Smoothed)
            smoothed = pow(2, log2Smoothed)
        }
        effective = min(smoothed, h)
        return effective
    }

    public mutating func reset() {
        initialized = false
        smoothed = 1
        effective = 1
        log2Smoothed = 0
    }
}
