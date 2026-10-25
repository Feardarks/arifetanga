import AVFoundation
import SwiftUI
import UIKit

/// İki katmanlı video yüzeyi (03-tasarim §9.6):
/// altta `AVPlayerLayer` (Referans: sistemin HDR işleyişi), üstte `CAMetalLayer` (Nit Çekirdeği, EDR).
final class VideoSurfaceView: UIView {
    let playerLayer = AVPlayerLayer()
    let metalLayer = CAMetalLayer()

    /// Pencereye eklendiğinde ve boyut değiştiğinde çağrılır.
    var onLayout: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(playerLayer)
        layer.addSublayer(metalLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) desteklenmiyor") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        metalLayer.frame = bounds
        let scale = window?.screen.nativeScale ?? traitCollection.displayScale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        CATransaction.commit()
        onLayout?()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
        onLayout?()
    }

    /// Mod geçişi: yalnızca katman görünürlüğü değişir, oynatma ve ses kesilmez (K6).
    func show(_ mode: RenderMode) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.isHidden = mode != .nit
        playerLayer.isHidden = mode != .reference
        CATransaction.commit()
    }
}

struct VideoSurface: UIViewRepresentable {
    let view: VideoSurfaceView

    func makeUIView(context: Context) -> VideoSurfaceView { view }
    func updateUIView(_ uiView: VideoSurfaceView, context: Context) {}
}
