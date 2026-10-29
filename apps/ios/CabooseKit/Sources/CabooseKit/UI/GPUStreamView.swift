#if canImport(UIKit) && canImport(CabooseGPUStream)
import QuartzCore
import UIKit

/// Shows a window whose GPU stream replays on this device: a `CAMetalLayer` that a
/// `GPUStreamPlayer` presents into. The drawables are the size of the captured swapchain
/// (the remote window's pixels) and are scaled to the view's bounds.
@MainActor
public final class GPUStreamView: UIView {
    public override static var layerClass: AnyClass { CAMetalLayer.self }

    public var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    /// The player presenting into this view, from the last `play`.
    public private(set) var player: GPUStreamPlayer?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        metalLayer.isOpaque = true
        metalLayer.contentsGravity = .resize
        metalLayer.presentsWithTransaction = false
        backgroundColor = .black
        isOpaque = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Starts a new stream in this view, stopping the one it was showing. Events arrive on the
    /// main queue.
    @discardableResult
    public func play(onEvent: @escaping @Sendable (GPUStreamPlayer.Event) -> Void = { _ in }) -> GPUStreamPlayer {
        player?.stop()
        let player = GPUStreamPlayer(layer: metalLayer, queue: .main, onEvent: onEvent)
        self.player = player
        return player
    }

    /// Stops the stream this view shows. Its last frame stays on screen.
    public func stop() {
        player?.stop()
        player = nil
    }
}
#endif
