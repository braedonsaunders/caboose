import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing
@testable import CabooseKit

/// Lossless tiles are in picture pixels (the space of `frame.crop`) and are shown where that
/// part of the picture is shown, through the window's last crop → rect mapping.
@Suite(.serialized) struct TileTests {
    @Test func picturePixelsMapThroughTheLastFrame() {
        let tile = CGRect(x: 10, y: 10, width: 16, height: 16)
        #expect(FramePipeline.window(tile, placement: nil) == tile) // 1:1 before any frame
        // An X11 window at buffer scale 1 shown at 2x.
        #expect(FramePipeline.window(tile, placement: (CGRect(x: 0, y: 0, width: 604, height: 524), CGRect(x: 0, y: 0, width: 1208, height: 1048)))
            == CGRect(x: 20, y: 20, width: 32, height: 32))
        // A picture cropped from an offset and placed at an offset.
        #expect(FramePipeline.window(tile, placement: (CGRect(x: 8, y: 8, width: 100, height: 100), CGRect(x: 50, y: 50, width: 100, height: 100)))
            == CGRect(x: 52, y: 52, width: 16, height: 16))
    }

    /// A PNG of exact RGB values, like the server's (8-bit RGB, no alpha).
    static func png(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) throws -> Data {
        let bytes = Data((0 ..< width * height).flatMap { _ in [red, green, blue] })
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let data = image.dataProvider!.data! as Data
        let offset = y * image.bytesPerRow + x * 4
        return Array(data[offset ..< offset + 4]) // BGRA
    }

    /// A scroll arrives as a frame.copy and the tiles that complete it: the copy moves what the
    /// window shows, and the tile after it lands on top of the moved pixels.
    @Test func aCopyMovesThePictureAndItsTilesLandAfterIt() throws {
        let pipeline = FramePipeline(windowID: 7, width: 8, height: 8, makeDecoder: { _ in FakeDecoder() }) { _ in }
        // Row y shows blue y * 10.
        for y in 0 ..< 8 {
            let row: [UInt8] = (0 ..< 8).flatMap { _ in [UInt8(y * 10), 0, 0, 255] }
            row.withUnsafeBytes { pipeline.surface.upload(bgra: $0.baseAddress!, rowBytes: 32, x: 0, y: y, width: 8, height: 1) }
        }
        var parser = DisplayFrameParser()
        let red = try Self.png(width: 8, height: 2, red: 255, green: 0, blue: 0)
        let messages = try parser.append(
            DisplayFraming.encode(DisplayFrame(type: DisplayProtocol.ServerType.frameCopy.rawValue, body: [
                "id": 7, "src": [0, 2, 8, 6], "dst": [0, 0],
            ]))
            + DisplayFraming.encode(DisplayFrame(type: DisplayProtocol.ServerType.tile.rawValue, body: [
                "id": 7, "rect": [0, 6, 8, 2], "format": "png", "data": .bytes(red),
            ]))
        ).map(ServerMessage.init)
        guard messages.count == 2, case .frameCopy(let copy) = messages[0], case .tile(let tile) = messages[1] else {
            Issue.record("\(messages)"); return
        }
        pipeline.copy(copy)
        pipeline.tile(tile)
        pipeline.flush()
        let painted = try #require(pipeline.surface.snapshot())
        for y in 0 ..< 6 { #expect(pixel(painted, 5, y) == [UInt8((y + 2) * 10), 0, 0, 255], "row \(y) moved up two rows") }
        #expect(pixel(painted, 5, 6) == [0, 0, 255, 255] && pixel(painted, 5, 7) == [0, 0, 255, 255], "the exposed rows are the tile's")
    }

    @Test func aTileOnAScaledWindowLandsWhereItsPixelsAreShownAndAFrameRepaintsIt() throws {
        let decoder = FakeDecoder()
        let pipeline = FramePipeline(windowID: 7, width: 16, height: 16, makeDecoder: { _ in decoder }) { _ in }
        let frame = EncodedFrame(window: 7, codec: .hevc, keyframe: true, ptsMicros: 1, rect: CGRect(x: 0, y: 0, width: 16, height: 16),
                                 crop: CGRect(x: 0, y: 0, width: 8, height: 8), data: Data([0, 0, 1]))
        pipeline.frame(frame)
        let red = try Self.png(width: 2, height: 2, red: 255, green: 0, blue: 0)
        var parser = DisplayFrameParser()
        let message = try #require(try parser.append(DisplayFraming.encode(DisplayFrame(type: DisplayProtocol.ServerType.tile.rawValue, body: [
            "id": 7, "rect": [2, 2, 2, 2], "format": "png", "data": .bytes(red),
        ]))).first.map(ServerMessage.init))
        guard case .tile(let tile) = message else { Issue.record("tile"); return }
        pipeline.tile(tile)
        pipeline.flush()
        let painted = try #require(pipeline.surface.snapshot())
        #expect(pixel(painted, 4, 4) == [0, 0, 255, 255] && pixel(painted, 7, 7) == [0, 0, 255, 255], "picture (2,2)-(3,3) is window (4,4)-(7,7)")
        #expect(pixel(painted, 3, 3) != [0, 0, 255, 255] && pixel(painted, 8, 8) != [0, 0, 255, 255])

        pipeline.frame(EncodedFrame(window: 7, codec: .hevc, keyframe: false, ptsMicros: 2, rect: frame.rect, crop: frame.crop, data: Data([0, 0, 1])))
        pipeline.flush()
        let repainted = try #require(pipeline.surface.snapshot())
        #expect(pixel(repainted, 5, 5) != [0, 0, 255, 255], "a later frame repaints the tile")
    }
}
