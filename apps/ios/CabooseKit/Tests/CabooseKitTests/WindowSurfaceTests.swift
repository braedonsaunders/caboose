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

    @Test @MainActor func presentationRetainsPictureAcrossEarlyGeometry() throws {
        let surface = WindowSurface()
        surface.resize(width: 80, height: 50)
        let window = RemoteWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 80, height: 50),
                                  overrideRedirect: false, surface: surface)
        let before = try #require(surface.presentation())
        window.frame.size = CGSize(width: 80, height: 26)
        #expect(window.presentationSize == CGSize(width: 80, height: 50))
        surface.resize(width: 80, height: 26)
        let after = try #require(surface.presentation())
        #expect(before.texture.height == 50)
        #expect(after.texture.height == 26)
        #expect(after.generation > before.generation)
        #expect(window.presentationSize.height == 50)
        window.adoptPictureSize(CGSize(width: after.texture.width, height: after.texture.height))
        #expect(window.presentationSize == CGSize(width: 80, height: 26))
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

    @Test func reducedSnapshotScalesOnTheGPUWithoutBlocking() async throws {
        let surface = WindowSurface()
        surface.resize(width: 64, height: 32)
        fill(surface, x: 0, y: 0, width: 64, height: 32, bgra: [0, 0, 255, 255])
        fill(surface, x: 32, y: 0, width: 32, height: 32, bgra: [0, 255, 0, 255])
        let image = try #require(await surface.snapshot(longEdgeAtMost: 16))
        #expect(image.width == 16)
        #expect(image.height == 8)
        #expect(pixel(image, 2, 4) == [0, 0, 255, 255])
        #expect(pixel(image, 13, 4) == [0, 255, 0, 255])
    }

    @Test func reducedSnapshotNeverScalesUp() async throws {
        let surface = WindowSurface()
        surface.resize(width: 6, height: 4)
        fill(surface, x: 0, y: 0, width: 6, height: 4, bgra: [1, 2, 3, 255])
        let image = try #require(await surface.snapshot(longEdgeAtMost: 1024))
        #expect(image.width == 6)
        #expect(image.height == 4)
        #expect(pixel(image, 5, 3) == [1, 2, 3, 255])
    }

    @Test func gatheredSnapshotsLeaveOutEmptyWindows() async throws {
        let painted = WindowSurface()
        painted.resize(width: 8, height: 8)
        fill(painted, x: 0, y: 0, width: 8, height: 8, bgra: [4, 4, 4, 255])
        let empty = WindowSurface()
        let images = await withCheckedContinuation { continuation in
            WindowSurface.snapshots(of: [1: painted, 2: empty], longEdgeAtMost: 4) { continuation.resume(returning: $0) }
        }
        #expect(images.keys.sorted() == [1])
        #expect(images[1]?.width == 4)
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

    @Test func atlasGpuCopyRectPreservesChromeAndUploadsExposedPixels() throws {
        let cache = TileAtlasCache(capacity: 16)
        let renderer = SurfaceAtlasRenderer()
        let surface = WindowSurface()

        // Batch 1: 128x128 keyframe with top chrome (y: 0..<32 = red) and content viewport (y: 32..<128 = blue)
        let batch1 = SurfaceBatch(
            window: 9,
            seq: 1,
            ptsMicros: 1000,
            size: CGSize(width: 128, height: 128),
            rect: CGRect(x: 0, y: 0, width: 128, height: 128),
            keyframe: true,
            fills: [
                SurfaceFill(rect: CGRect(x: 0, y: 0, width: 128, height: 32), rgba: 0xFF00_00FF),
                SurfaceFill(rect: CGRect(x: 0, y: 32, width: 128, height: 64), rgba: 0x00FF_00FF),
                SurfaceFill(rect: CGRect(x: 0, y: 96, width: 128, height: 32), rgba: 0x0000_FFFF),
            ]
        )
        #expect(renderer.applyAndUpload(batch1, cache: cache, to: surface))

        // Batch 2: scroll content viewport (y: 32..<128) up by 16 px (dy = -16), update a top-right scrollbar thumb
        // at (x: 120..<128, y: 32..<48), and fill exposed bottom strip (y: 112..<128)
        let batch2 = SurfaceBatch(
            window: 9,
            seq: 2,
            ptsMicros: 2000,
            size: CGSize(width: 128, height: 128),
            rect: CGRect(x: 0, y: 0, width: 128, height: 128),
            keyframe: false,
            copies: [SurfaceCopy(dx: 0, dy: -16, rect: CGRect(x: 0, y: 32, width: 128, height: 96))],
            fills: [
                SurfaceFill(rect: CGRect(x: 120, y: 32, width: 8, height: 16), rgba: 0x8080_80FF),
                SurfaceFill(rect: CGRect(x: 0, y: 112, width: 128, height: 16), rgba: 0xFFFF_00FF),
            ]
        )
        #expect(renderer.applyAndUpload(batch2, cache: cache, to: surface))
        let img = try #require(surface.snapshot())
        // Top header chrome (y=10) stayed red (BGRA: [0, 0, 255, 255])
        #expect(pixel(img, 10, 10) == [0, 0, 255, 255])
        // Top-right scrollbar thumb at (124, 40) is gray (BGRA: [128, 128, 128, 255])
        #expect(pixel(img, 124, 40) == [128, 128, 128, 255])
        // Shifted blue band moved from y=96..<128 to y=80..<112 (BGRA: [255, 0, 0, 255] at y=88)
        #expect(pixel(img, 10, 88) == [255, 0, 0, 255])
        // Newly exposed bottom strip y=112..<128 is yellow (RGBA 0xFFFF00FF -> BGRA [0, 255, 255, 255])
        #expect(pixel(img, 10, 120) == [0, 255, 255, 255])
    }
    @Test func atlasAllocationFailureRejectsWholeBatchWithoutAdvancingPixelsOrHistory() throws {
        for resource in [WindowSurface.AtlasResource.scratch, .staging, .commandBuffer, .blitEncoder, .backing] {
            var denied: WindowSurface.AtlasResource?
            let surface = WindowSurface(allowsResource: { $0 != denied })
            let cache = TileAtlasCache(capacity: 16)
            let renderer = SurfaceAtlasRenderer()
            let initial = SurfaceBatch(window: 1, seq: 1, ptsMicros: 1,
                size: CGSize(width: 16, height: 16), rect: CGRect(x: 0, y: 0, width: 16, height: 16),
                keyframe: true, fills: [SurfaceFill(rect: CGRect(x: 0, y: 0, width: 16, height: 16), rgba: 0xFF00_00FF)])
            #expect(renderer.applyAndUpload(initial, cache: cache, to: surface))
            let oldGeneration = surface.generation
            let oldBytes = renderer.rgbaBytes(forWindow: 1)
            denied = resource
            let side = resource == .backing ? 32 : 16
            let delta = SurfaceBatch(window: 1, seq: 2, ptsMicros: 2,
                size: CGSize(width: side, height: side), rect: CGRect(x: 0, y: 0, width: side, height: side),
                keyframe: resource == .backing,
                copies: [SurfaceCopy(dx: 0, dy: -4, rect: CGRect(x: 0, y: 0, width: 16, height: 12))],
                fills: [SurfaceFill(rect: CGRect(x: 0, y: 12, width: 16, height: 4), rgba: 0x0000_FFFF)])
            #expect(!renderer.applyAndUpload(delta, cache: cache, to: surface))
            #expect(surface.generation == oldGeneration)
            #expect(renderer.rgbaBytes(forWindow: 1) == oldBytes)
            let image = try #require(surface.snapshot())
            #expect(pixel(image, 4, 14) == [0, 0, 255, 255])
            denied = nil
            #expect(renderer.applyAndUpload(delta, cache: cache, to: surface))
            let recovered = try #require(surface.snapshot())
            #expect(pixel(recovered, 4, 14) == [255, 0, 0, 255])
        }
    }

}
