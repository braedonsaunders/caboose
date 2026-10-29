import CoreGraphics
import Foundation
import Testing
@testable import CabooseKit

/// Writes are queued on the GPU without waiting; these check they land in order.
@Suite struct WindowSurfaceTests {
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let data = image.dataProvider!.data! as Data
        let offset = y * image.bytesPerRow + x * 4
        return Array(data[offset ..< offset + 4])
    }

    private func fill(_ surface: WindowSurface, x: Int, y: Int, width: Int, height: Int, bgra: [UInt8], rowPadding: Int = 0) {
        let rowBytes = width * 4 + rowPadding
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        for row in 0 ..< height { for column in 0 ..< width { bytes.replaceSubrange(row * rowBytes + column * 4 ..< row * rowBytes + column * 4 + 4, with: bgra) } }
        bytes.withUnsafeBytes { surface.upload(bgra: $0.baseAddress!, rowBytes: rowBytes, x: x, y: y, width: width, height: height) }
    }

    @Test func cpuUploadsLandInCommitOrder() throws {
        let surface = WindowSurface()
        surface.resize(width: 8, height: 8)
        fill(surface, x: 0, y: 0, width: 8, height: 8, bgra: [255, 0, 0, 255])
        fill(surface, x: 2, y: 2, width: 2, height: 2, bgra: [0, 255, 0, 255], rowPadding: 12)
        let image = try #require(surface.snapshot())
        #expect(pixel(image, 0, 0) == [255, 0, 0, 255])
        #expect(pixel(image, 3, 3) == [0, 255, 0, 255])
        #expect(pixel(image, 4, 4) == [255, 0, 0, 255])
    }

    @Test func uploadsAreClippedToTheWindow() throws {
        let surface = WindowSurface()
        surface.resize(width: 4, height: 4)
        fill(surface, x: 2, y: 2, width: 4, height: 4, bgra: [9, 9, 9, 255])
        let image = try #require(surface.snapshot())
        #expect(pixel(image, 3, 3) == [9, 9, 9, 255])
        #expect(pixel(image, 1, 1) == [0, 0, 0, 0])
    }

    @Test func resizeKeepsTheOverlapAndTheRestIsTransparent() throws {
        let surface = WindowSurface()
        surface.resize(width: 4, height: 4)
        fill(surface, x: 0, y: 0, width: 4, height: 4, bgra: [7, 7, 7, 255])
        surface.resize(width: 6, height: 2)
        let image = try #require(surface.snapshot())
        #expect(image.width == 6)
        #expect(pixel(image, 3, 1) == [7, 7, 7, 255])
        #expect(pixel(image, 5, 1) == [0, 0, 0, 0], "a popup's new area shows nothing until a tile lands")
    }

    @Test func aTileWithAlphaKeepsItsTransparency() throws {
        let surface = WindowSurface()
        surface.resize(width: 4, height: 4)
        // A 2x2 RGBA tile: an opaque red pixel beside a transparent one.
        var pixels = [UInt8](repeating: 0, count: 16)
        pixels.replaceSubrange(0 ..< 4, with: [255, 0, 0, 255])
        let data = Data(pixels)
        let provider = try #require(CGDataProvider(data: data as CFData))
        let tile = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        surface.upload(image: tile, x: 1, y: 1)
        let image = try #require(surface.snapshot())
        #expect(pixel(image, 1, 1) == [0, 0, 255, 255])
        #expect(pixel(image, 2, 1) == [0, 0, 0, 0], "a transparent tile pixel stays transparent")
        #expect(pixel(image, 0, 0) == [0, 0, 0, 0])
    }
}
