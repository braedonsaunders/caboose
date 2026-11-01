#if canImport(CabooseDraw)
import CabooseDraw
import Foundation
import Metal

/// Draws applications' draw lists (docs/draw.md) with Skia on Metal, on the shared surface
/// queue: what it hands out is drawn before anything committed to that queue afterwards.
/// Used from one queue at a time.
public final class DrawRenderer: @unchecked Sendable {
    private let renderer: OpaquePointer

    public init?(device: MTLDevice, queue: MTLCommandQueue, scale: Float = 1) {
        guard let renderer = caboose_draw_create(Unmanaged.passUnretained(device).toOpaque(),
                                                 Unmanaged.passUnretained(queue).toOpaque()) else { return nil }
        self.renderer = renderer
        caboose_draw_set_scale(renderer, scale)
    }

    deinit { caboose_draw_destroy(renderer) }

    /// Appends a `draw.ops` payload to its stream and draws what it completes. False when the
    /// stream was malformed and dropped.
    @discardableResult public func feed(stream: UInt32, ops: Data) -> Bool {
        ops.withUnsafeBytes { bytes in
            caboose_draw_feed(renderer, stream, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count) == 0
        }
    }

    public func end(stream: UInt32) { caboose_draw_end(renderer, stream) }

    /// A stream's surface as drawn so far, with the scale it was drawn at.
    public func texture(stream: UInt32, surface: UInt32) -> (texture: MTLTexture, scale: Float)? {
        var width: UInt32 = 0, height: UInt32 = 0, scale: Float = 1
        guard let pointer = caboose_draw_texture(renderer, stream, surface, &width, &height, &scale) else { return nil }
        return (Unmanaged<MTLTexture>.fromOpaque(pointer).takeUnretainedValue(), scale)
    }

    /// A surface read back as premultiplied RGBA8, waiting for the GPU (for checks).
    public func read(stream: UInt32, surface: UInt32) -> (rgba: Data, width: Int, height: Int)? {
        guard let (texture, _) = texture(stream: stream, surface: surface) else { return nil }
        var data = Data(count: texture.width * texture.height * 4)
        var width: UInt32 = 0, height: UInt32 = 0
        let written = data.withUnsafeMutableBytes { bytes in
            caboose_draw_read(renderer, stream, surface, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &width, &height)
        }
        return written > 0 ? (data, Int(width), Int(height)) : nil
    }

    public var stats: (drawn: UInt64, skipped: UInt64, dropped: UInt64) {
        var drawn: UInt64 = 0, skipped: UInt64 = 0, dropped: UInt64 = 0
        caboose_draw_stats(renderer, &drawn, &skipped, &dropped)
        return (drawn, skipped, dropped)
    }
}
#endif
