#if canImport(CabooseDraw)
import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
@testable import CabooseKit

/// The Skia renderer against cairo: a GTK 3 window recorded by guest/draw's cairo recorder
/// (Fixtures/draw/gtk3.cdl), drawn up to the commit of its window buffer 48, compared with what
/// guest/draw's caboose-draw-replay drew of that frame with cairo (surface-48-0000.png).
@Suite struct DrawRendererTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/draw")

    /// The capture's bytes through the `present` of `surface`.
    static func ops(through surface: UInt32) throws -> Data {
        let capture = try Data(contentsOf: fixtures.appendingPathComponent("gtk3.cdl"))
        var at = 0
        while at + 5 <= capture.count {
            let op = capture[at]
            let length = Int(capture[at + 1]) | Int(capture[at + 2]) << 8 | Int(capture[at + 3]) << 16 | Int(capture[at + 4]) << 24
            let end = at + 5 + length
            if op == 0x30, length >= 4 {
                let named = UInt32(capture[at + 5]) | UInt32(capture[at + 6]) << 8 | UInt32(capture[at + 7]) << 16 | UInt32(capture[at + 8]) << 24
                if named == surface { return capture.subdata(in: 0 ..< end) }
            }
            at = end
        }
        Issue.record("no present of surface \(surface)")
        return capture
    }

    static func referenceRGBA() throws -> (Data, Int, Int) {
        let source = CGImageSourceCreateWithURL(fixtures.appendingPathComponent("surface-48-0000.png") as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        var data = Data(count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (data, image.width, image.height)
    }

    @Test func drawsWhatCairoDrew() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let renderer = try #require(DrawRenderer(device: device, queue: queue))
        #expect(renderer.feed(stream: 1, ops: try Self.ops(through: 48)))
        let drawn = try #require(renderer.read(stream: 1, surface: 48))
        let (reference, width, height) = try Self.referenceRGBA()
        #expect(drawn.width == width && drawn.height == height)
        let a = [UInt8](drawn.rgba), b = [UInt8](reference)
        var squared = 0.0, differing = 0
        for pixel in 0 ..< width * height {
            var worst = 0
            for c in 0 ..< 4 {
                let index = pixel * 4 + c
                let d = abs(Int(a[index]) - Int(b[index]))
                squared += Double(d * d)
                worst = max(worst, d)
            }
            if worst > 8 { differing += 1 }
        }
        let psnr = 10 * log10(255.0 * 255.0 / max(squared / Double(width * height * 4), 1e-9))
        let share = Double(differing) / Double(width * height)
        print("skia vs cairo: \(width)x\(height), psnr \(String(format: "%.2f", psnr)) dB, \(String(format: "%.2f", share * 100))% pixels differ by more than 8, stats \(renderer.stats)")
        // Two rasterizers: glyph and path edges are anti-aliased differently, nothing else.
        #expect(psnr > 27)
        #expect(share < 0.06)
        #expect(renderer.stats.dropped == 0)
    }

    @Test func drawsAtThePhonesDensity() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let renderer = try #require(DrawRenderer(device: device, queue: queue, scale: 3))
        #expect(renderer.feed(stream: 7, ops: try Self.ops(through: 48)))
        let (texture, scale) = try #require(renderer.texture(stream: 7, surface: 48))
        let (_, width, height) = try Self.referenceRGBA()
        #expect(scale == 3 && texture.width == width * 3 && texture.height == height * 3)
        let drawn = try #require(renderer.read(stream: 7, surface: 48))
        let bytes = [UInt8](drawn.rgba)
        var opaque = 0
        for index in stride(from: 3, to: bytes.count, by: 4) where bytes[index] == 255 { opaque += 1 }
        #expect(opaque > width * height * 9 / 2, "the window is drawn, not blank")
        // CABOOSE_DRAW_TEST_PNG=PATH writes the 3x picture, to look at.
        if let path = ProcessInfo.processInfo.environment["CABOOSE_DRAW_TEST_PNG"] {
            let image = drawn.rgba.withUnsafeBytes { bytes in
                CGContext(data: UnsafeMutableRawPointer(mutating: bytes.baseAddress), width: drawn.width, height: drawn.height,
                          bitsPerComponent: 8, bytesPerRow: drawn.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
            }
            if let image, let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(out, image, nil)
                CGImageDestinationFinalize(out)
            }
        }
        renderer.end(stream: 7)
        #expect(renderer.texture(stream: 7, surface: 48) == nil)
    }
}
#endif
