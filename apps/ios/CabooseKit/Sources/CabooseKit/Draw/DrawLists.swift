import Foundation
import Metal

/// The session's draw lists (docs/draw.md): each stream drawn as it arrives, on one queue, and
/// each `draw.present` handed to its window as the picture drawn on the phone.
///
/// Opt-in while the renderer is new: `CABOOSE_DRAW=1` in the environment, in a build linked
/// with CabooseDraw.xcframework (apps/ios/scripts/build-draw.sh). Surfaces are drawn at their
/// own pixels, the window picture's size, so the atlas batches that still arrive for the same
/// window keep applying to the same picture.
final class DrawLists: @unchecked Sendable {
    #if canImport(CabooseDraw)
    private let queue = DispatchQueue(label: "caboose.draw-lists", qos: .userInteractive)
    private let renderer: DrawRenderer
    #endif

    /// Whether draw lists are on and this build can draw them (`draw` in the hello).
    static var enabled: Bool {
        #if canImport(CabooseDraw)
        ProcessInfo.processInfo.environment["CABOOSE_DRAW"] == "1"
        #else
        false
        #endif
    }

    /// Draw lists for one connection, or nil when they are off or cannot be drawn here.
    static func make() -> DrawLists? { enabled ? DrawLists() : nil }

    private init?() {
        #if canImport(CabooseDraw)
        let shared = SurfaceRenderer.shared
        guard let renderer = DrawRenderer(device: shared.device, queue: shared.queue) else { return nil }
        self.renderer = renderer
        #else
        return nil
        #endif
    }

    func ops(stream: UInt32, _ ops: Data) {
        #if canImport(CabooseDraw)
        queue.async { [renderer] in renderer.feed(stream: stream, ops: ops) }
        #endif
    }

    /// Shows the stream's surface as `pipeline`'s window once everything before it is drawn.
    func present(stream: UInt32, surface: UInt32, on pipeline: FramePipeline?) {
        #if canImport(CabooseDraw)
        queue.async { [renderer] in
            guard let pipeline, let drawn = renderer.texture(stream: stream, surface: surface) else { return }
            pipeline.drawn(drawn.texture)
        }
        #endif
    }

    func end(stream: UInt32) {
        #if canImport(CabooseDraw)
        queue.async { [renderer] in renderer.end(stream: stream) }
        #endif
    }
}
