import CoreGraphics
import Foundation
import Metal
import QuartzCore
import Testing
@testable import CabooseKit

/// A window's snapshot: when a present is copied, what a copy holds, and how it is read.
@Suite struct WindowSnapshotTests {
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let data = image.dataProvider!.data! as Data
        let offset = y * image.bytesPerRow + x * 4
        return Array(data[offset ..< offset + 4])
    }

    /// An opaque image of `width` × `height`, its left half `left` and right half `right` (RGB).
    private func image(width: Int, height: Int, left: [UInt8], right: [UInt8]) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let colour = x < width / 2 ? left : right
                bytes.replaceSubrange((y * width + x) * 4 ..< (y * width + x) * 4 + 3, with: colour)
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// A presented frame as the GPU executor lends it: a private-to-the-device texture.
    private func frame(width: Int, height: Int, format: MTLPixelFormat, bytes: [UInt8]) throws -> MTLTexture {
        let device = SharedMetal.shared.device
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        return texture
    }

    @Test func theFirstPresentIsCopiedThenEveryFiveSecondsUnlessSomethingShowsIt() {
        let snapshot = WindowSnapshot()
        #expect(snapshot.capturesPresent(at: 100))
        snapshot.store(image: image(width: 2, height: 2, left: [1, 2, 3], right: [1, 2, 3]))
        // Stored now (a real clock); time here is measured from that store.
        let stored = CACurrentMediaTime()
        #expect(!snapshot.capturesPresent(at: stored + 1))
        #expect(!snapshot.capturesPresent(at: stored + 4.9))
        #expect(snapshot.capturesPresent(at: stored + 5.1))
        // Something shows the snapshot: a second apart while it was wanted lately.
        snapshot.want(at: stored + 0.5)
        #expect(!snapshot.capturesPresent(at: stored + 0.9))
        #expect(snapshot.capturesPresent(at: stored + 1.1))
        #expect(!snapshot.capturesPresent(at: stored + 3))
    }

    @Test func aPresentedFrameIsCopiedAndBumpsTheGeneration() throws {
        let snapshot = WindowSnapshot()
        #expect(snapshot.presentation() == nil && snapshot.pixelSize == .zero)
        let red: [UInt8] = [0, 0, 255, 255], green: [UInt8] = [0, 255, 0, 255]
        let source = try frame(width: 4, height: 2, format: .bgra8Unorm,
                               bytes: Array([red, red, green, green, red, red, green, green].joined()))
        #expect(snapshot.store(copyOf: source))
        let first = try #require(snapshot.presentation())
        #expect(snapshot.pixelSize == CGSize(width: 4, height: 2))
        let image = try #require(snapshot.snapshot())
        #expect(pixel(image, 0, 0) == red && pixel(image, 3, 1) == green)
        // A later frame replaces the copy; the earlier texture is never written again.
        #expect(snapshot.store(copyOf: try frame(width: 4, height: 2, format: .bgra8Unorm, bytes: Array(repeating: 9, count: 32))))
        let second = try #require(snapshot.presentation())
        #expect(second.generation > first.generation && second.texture !== first.texture)
    }

    @Test func anRGBAFrameIsCopiedAsBGRA() throws {
        let snapshot = WindowSnapshot()
        let source = try frame(width: 2, height: 1, format: .rgba8Unorm, bytes: [255, 0, 0, 255, 0, 0, 255, 255])
        #expect(snapshot.store(copyOf: source))
        let region = try #require(snapshot.pixels(x: 0, y: 0, width: 2, height: 1))
        #expect(region.bytes == [0, 0, 255, 255, 255, 0, 0, 255])
    }

    @Test func pixelsAreClampedToThePicture() throws {
        let snapshot = WindowSnapshot()
        snapshot.store(image: image(width: 4, height: 4, left: [10, 20, 30], right: [40, 50, 60]))
        let region = try #require(snapshot.pixels(x: 2, y: -2, width: 8, height: 4))
        #expect(region.x == 2 && region.y == 0 && region.width == 2 && region.height == 2)
        #expect(Array(region.bytes[0 ..< 4]) == [60, 50, 40, 255])
        #expect(snapshot.pixels(x: 4, y: 0, width: 2, height: 2) == nil)
    }

    @Test func reducedSnapshotScalesOnTheGPU() async throws {
        let snapshot = WindowSnapshot()
        snapshot.store(image: image(width: 64, height: 32, left: [255, 0, 0], right: [0, 255, 0]))
        let reduced = try #require(await snapshot.snapshot(longEdgeAtMost: 16))
        #expect(reduced.width == 16 && reduced.height == 8)
        #expect(pixel(reduced, 2, 4) == [0, 0, 255, 255])
        #expect(pixel(reduced, 13, 4) == [0, 255, 0, 255])
    }

    @Test func reducedSnapshotNeverScalesUp() async throws {
        let snapshot = WindowSnapshot()
        snapshot.store(image: image(width: 6, height: 4, left: [3, 2, 1], right: [3, 2, 1]))
        let reduced = try #require(await snapshot.snapshot(longEdgeAtMost: 1024))
        #expect(reduced.width == 6 && reduced.height == 4)
        #expect(pixel(reduced, 5, 3) == [1, 2, 3, 255])
    }

    @Test func gatheredSnapshotsLeaveOutWindowsWithNoPicture() async throws {
        let shown = WindowSnapshot()
        shown.store(image: image(width: 8, height: 8, left: [4, 4, 4], right: [4, 4, 4]))
        let images = await withCheckedContinuation { continuation in
            WindowSnapshot.snapshots(of: [1: shown, 2: WindowSnapshot()], longEdgeAtMost: 4) { continuation.resume(returning: $0) }
        }
        #expect(images.keys.sorted() == [1])
        #expect(images[1]?.width == 4)
    }

}
