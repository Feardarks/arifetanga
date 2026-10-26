import AVFoundation
import SwiftUI
import UIKit

/// Yüzeyin katman düzeni.
enum SurfaceLayout: Equatable {
    /// Tek yol tam ekran: Nit (`CAMetalLayer`) ya da Referans (`AVPlayerLayer`).
    case single(RenderMode)
    /// Eşitlik testi (S0-C): bir yarıda Nit SDR × H, diğerinde Referans PQ yaması.
    case equality(nitOnLeft: Bool)
    /// Denemeler arası siyah ekran (göz uyumu).
    case blank
    /// Tonalite testi (S0-D): solda Referans (AVPlayerLayer), sağda Nit (H = 1).
    case tonality
}

/// Katmanlı video yüzeyi (03-tasarim §9.6):
/// altta `AVPlayerLayer` (Referans: sistemin HDR işleyişi), üstte `CAMetalLayer` (Nit Çekirdeği, EDR),
/// en üstte yalnızca eşitlik testinde kullanılan PQ Referans yaması katmanı.
final class VideoSurfaceView: UIView {
    let playerLayer = AVPlayerLayer()
    let metalLayer = CAMetalLayer()
    let referencePatchLayer = CAMetalLayer()

    /// Pencereye eklendiğinde ve boyut değiştiğinde çağrılır.
    var onLayout: (() -> Void)?

    private(set) var layout: SurfaceLayout = .single(.nit)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(playerLayer)
        layer.addSublayer(metalLayer)
        layer.addSublayer(referencePatchLayer)
        referencePatchLayer.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) desteklenmiyor") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = window?.screen.nativeScale ?? traitCollection.displayScale
        let pixels = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        playerLayer.frame = bounds
        for metal in [metalLayer, referencePatchLayer] {
            metal.frame = bounds
            metal.contentsScale = scale
            metal.drawableSize = pixels
        }
        applyMasks()
        CATransaction.commit()
        onLayout?()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
        onLayout?()
    }

    /// Yalnızca katman görünürlüğü ve maskeleri değişir; oynatma ve ses kesilmez (K6).
    func apply(_ newLayout: SurfaceLayout) {
        layout = newLayout
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch newLayout {
        case .single(let mode):
            metalLayer.isHidden = mode != .nit
            playerLayer.isHidden = mode != .reference
            referencePatchLayer.isHidden = true
        case .equality:
            metalLayer.isHidden = false
            playerLayer.isHidden = true
            referencePatchLayer.isHidden = false
        case .blank:
            metalLayer.isHidden = true
            playerLayer.isHidden = true
            referencePatchLayer.isHidden = true
        case .tonality:
            metalLayer.isHidden = false
            playerLayer.isHidden = false
            referencePatchLayer.isHidden = true
        }
        applyMasks()
        CATransaction.commit()
    }

    private func applyMasks() {
        let left = CGRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height)
        let right = CGRect(x: bounds.width / 2, y: 0, width: bounds.width / 2, height: bounds.height)
        switch layout {
        case .equality(let nitOnLeft):
            metalLayer.mask = Self.mask(nitOnLeft ? left : right)
            referencePatchLayer.mask = Self.mask(nitOnLeft ? right : left)
        case .tonality:
            metalLayer.mask = Self.mask(right)
            referencePatchLayer.mask = nil
        case .single, .blank:
            metalLayer.mask = nil
            referencePatchLayer.mask = nil
        }
    }

    private static func mask(_ rect: CGRect) -> CALayer {
        let m = CALayer()
        m.frame = rect
        m.backgroundColor = UIColor.black.cgColor
        return m
    }
}

struct VideoSurface: UIViewRepresentable {
    let view: VideoSurfaceView

    func makeUIView(context: Context) -> VideoSurfaceView { view }
    func updateUIView(_ uiView: VideoSurfaceView, context: Context) {}
}
