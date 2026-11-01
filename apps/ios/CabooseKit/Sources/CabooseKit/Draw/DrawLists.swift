import Foundation
import Metal

/// The session's draw lists (docs/draw.md): each stream drawn as it arrives, on one queue, and
/// each `draw.present` handed to its window as the picture drawn on the phone.
///
/// Always on in a build linked with CabooseDraw.xcframework (apps/ios/scripts/build-draw.sh).
/// The computer sends a window's frame either as a draw list or as an atlas batch, never both,
/// and the first atlas batch after draw lists is a keyframe; surfaces are drawn at their own
/// pixels, the window picture's size, so either lands on the same picture.
final class DrawLists: @unchecked Sendable {
    #if canImport(CabooseDraw)
    private let queue = DispatchQueue(label: "caboose.draw-lists", qos: .userInteractive)
    private let renderer: DrawRenderer
    #endif

    /// Whether this build draws draw lists (`draw` in the hello).
    static var enabled: Bool {
        #if canImport(CabooseDraw)
        true
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

    /// Shows the stream's surface as `pipeline`'s window once everything before it is drawn,
    /// acknowledging picture `ptsMicros`. Waits for the ops before it to be encoded (the GPU
    /// draws them later, in order), so the picture reaches the pipeline before any batch that
    /// arrives after it.
    func present(stream: UInt32, surface: UInt32, ptsMicros: UInt64, on pipeline: FramePipeline?) {
        #if canImport(CabooseDraw)
        let texture = queue.sync { [renderer] in renderer.texture(stream: stream, surface: surface)?.texture }
        pipeline?.drawn(texture, ptsMicros: ptsMicros)
        #endif
    }

    func end(stream: UInt32) {
        #if canImport(CabooseDraw)
        queue.async { [renderer] in renderer.end(stream: stream) }
        #endif
    }
}
