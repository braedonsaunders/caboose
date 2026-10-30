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

    /// Rows of distinct colours: row `y` is `[y * 10, 0, 0, 255]`.
    private func rows(_ surface: WindowSurface, width: Int, height: Int) {
        for y in 0 ..< height { fill(surface, x: 0, y: y, width: width, height: 1, bgra: [UInt8(y * 10), 0, 0, 255]) }
    }

    /// A scroll's copy overlaps itself; it lands as if read from the picture before it, in both
    /// directions, and leaves the rows it does not reach alone.
    @Test func anOverlappingCopyMovesPixelsAsIfFromASnapshot() throws {
        let surface = WindowSurface()
        surface.resize(width: 8, height: 8)
        rows(surface, width: 8, height: 8)
        // Up by two rows: rows 2...7 land on 0...5; rows 6 and 7 stay.
        surface.copy(source: CGRect(x: 0, y: 2, width: 8, height: 6), to: CGPoint(x: 0, y: 0))
        let up = try #require(surface.snapshot())
        for y in 0 ..< 6 { #expect(pixel(up, 3, y) == [UInt8((y + 2) * 10), 0, 0, 255], "row \(y)") }
        #expect(pixel(up, 3, 6) == [60, 0, 0, 255] && pixel(up, 3, 7) == [70, 0, 0, 255])

        rows(surface, width: 8, height: 8)
        // Down by three rows and right by one column.
        surface.copy(source: CGRect(x: 0, y: 0, width: 7, height: 5), to: CGPoint(x: 1, y: 3))
        let down = try #require(surface.snapshot())
        for y in 3 ..< 8 { #expect(pixel(down, 4, y) == [UInt8((y - 3) * 10), 0, 0, 255], "row \(y)") }
        for y in 0 ..< 3 { #expect(pixel(down, 4, y) == [UInt8(y * 10), 0, 0, 255], "row \(y)") }
        #expect(pixel(down, 0, 5) == [50, 0, 0, 255], "column 0 is outside the destination")
    }

    /// Copies, uploads and copies again land in the order they were made, through one
    /// scratch texture.
    @Test func copiesAndUploadsLandInOrder() throws {
        let surface = WindowSurface()
        surface.resize(width: 4, height: 8)
        rows(surface, width: 4, height: 8)
        surface.copy(source: CGRect(x: 0, y: 1, width: 4, height: 7), to: .zero)
        fill(surface, x: 0, y: 7, width: 4, height: 1, bgra: [200, 0, 0, 255])
        surface.copy(source: CGRect(x: 0, y: 1, width: 4, height: 7), to: .zero)
        let image = try #require(surface.snapshot())
        #expect(pixel(image, 0, 0) == [20, 0, 0, 255])
        #expect(pixel(image, 0, 5) == [70, 0, 0, 255])
        #expect(pixel(image, 0, 6) == [200, 0, 0, 255], "the row uploaded between the copies moved with the second")
        #expect(pixel(image, 0, 7) == [200, 0, 0, 255])
    }

    /// Both rectangles of a copy lose the same rows and columns at the texture's edges.
    @Test func copiesAreClippedToTheTexture() {
        typealias Region = WindowSurface.CopyRegion
        func region(_ source: CGRect, to destination: CGPoint) -> Region? {
            Region(source: source, destination: destination, textureWidth: 100, textureHeight: 100)
        }
        #expect(region(CGRect(x: 0, y: 18, width: 100, height: 82), to: .zero)
            == Region(sourceX: 0, sourceY: 18, destinationX: 0, destinationY: 0, width: 100, height: 82))
        // A destination above the texture: the rows that would land outside it are not read.
        #expect(region(CGRect(x: 0, y: 10, width: 50, height: 40), to: CGPoint(x: 0, y: -5))
            == Region(sourceX: 0, sourceY: 15, destinationX: 0, destinationY: 0, width: 50, height: 35))
        // A source past the right edge, and a source left of the texture.
        #expect(region(CGRect(x: 90, y: 0, width: 20, height: 10), to: CGPoint(x: 70, y: 0))
            == Region(sourceX: 90, sourceY: 0, destinationX: 70, destinationY: 0, width: 10, height: 10))
        #expect(region(CGRect(x: -4, y: 0, width: 20, height: 10), to: CGPoint(x: 10, y: 0))
            == Region(sourceX: 0, sourceY: 0, destinationX: 14, destinationY: 0, width: 16, height: 10))
        #expect(region(CGRect(x: 0, y: 0, width: 10, height: 10), to: CGPoint(x: 100, y: 0)) == nil)
        #expect(region(.zero, to: .zero) == nil)
    }

    @Test func resizeKeepsTheOverlap() throws {
        let surface = WindowSurface()
        surface.resize(width: 4, height: 4)
        fill(surface, x: 0, y: 0, width: 4, height: 4, bgra: [7, 7, 7, 255])
        surface.resize(width: 6, height: 2)
        let image = try #require(surface.snapshot())
        #expect(image.width == 6)
        #expect(pixel(image, 3, 1) == [7, 7, 7, 255])
        #expect(pixel(image, 5, 1) == [0, 0, 0, 0])
    }

    @Test func aNewSurfaceIsTransparentBeforeItsFirstPicture() throws {
        let surface = WindowSurface()
        surface.resize(width: 16, height: 16)
        let image = try #require(surface.snapshot())
        for y in 0 ..< 16 { for x in 0 ..< 16 {
            #expect(pixel(image, x, y) == [0, 0, 0, 0])
        } }
    }

    @Test func growingAfterAShrinkDoesNotRestoreDiscardedPixels() throws {
        let surface = WindowSurface()
        surface.resize(width: 8, height: 8)
        fill(surface, x: 0, y: 0, width: 8, height: 8, bgra: [17, 39, 61, 255])
        surface.resize(width: 12, height: 10)
        var image = try #require(surface.snapshot())
        #expect(pixel(image, 7, 7) == [17, 39, 61, 255])
        #expect(pixel(image, 8, 7) == [0, 0, 0, 0])
        #expect(pixel(image, 7, 8) == [0, 0, 0, 0])
        surface.resize(width: 4, height: 3)
        surface.resize(width: 8, height: 8)
        image = try #require(surface.snapshot())
        for y in 0 ..< 8 { for x in 0 ..< 8 {
            let expected: [UInt8] = x < 4 && y < 3 ? [17, 39, 61, 255] : [0, 0, 0, 0]
            #expect(pixel(image, x, y) == expected)
        } }
    }
}
