import CoreGraphics
import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import CabooseKit

/// Real pictures through the hardware decoders and into a window surface: the compositor's
/// H.264 and HEVC keyframe vectors, and an AV1 stream where the Mac has an AV1 decoder.
@Suite(.serialized) struct DisplayDecodeTests {
    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [ClientMessage] = []
        func append(_ message: ClientMessage) { lock.lock(); messages.append(message); lock.unlock() }
        var acks: [Int] {
            lock.lock(); defer { lock.unlock() }
            return messages.compactMap { if case .ack(_, _, let decoded) = $0 { decoded } else { nil } }
        }
    }

    private func frame(_ vector: String) throws -> EncodedFrame {
        var parser = DisplayFrameParser()
        let wire = try DisplayVectorTests.vector(vector).wire
        guard case .frame(let frame)? = try parser.append(wire).first.map(ServerMessage.init) else {
            throw CancellationError()
        }
        return frame
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let data = image.dataProvider!.data! as Data
        let offset = y * image.bytesPerRow + x * 4
        return Array(data[offset ..< offset + 4])
    }

    /// The fraction of pixels in a region that are not black: a decoded test picture fills it.
    private func painted(_ image: CGImage, width: Int, height: Int) -> Double {
        var count = 0
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) where pixel(image, x, y)[0 ..< 3].contains(where: { $0 > 16 }) { count += 1 }
        }
        return Double(count) / Double((width / 2) * (height / 2))
    }

    @Test func h264KeyframeDecodesIntoTheWindow() throws {
        let frame = try frame("frame-h264-keyframe")
        let sent = Sent()
        let pipeline = FramePipeline(windowID: frame.window, width: 64, height: 64) { sent.append($0) }
        pipeline.frame(frame)
        pipeline.flush()
        #expect(sent.acks.count == 1 && sent.acks[0] >= 0)
        let image = try #require(pipeline.surface.snapshot())
        #expect(painted(image, width: 64, height: 64) > 0.5)
    }

    /// A 62x60 picture in a 64x64 coded frame, shown at twice its size: crop, then scale.
    @Test func hevcKeyframeIsCroppedAndScaled() throws {
        let frame = try frame("frame-hevc-keyframe-scaled")
        let sent = Sent()
        let pipeline = FramePipeline(windowID: frame.window, width: 130, height: 126) { sent.append($0) }
        pipeline.frame(frame)
        pipeline.flush()
        #expect(sent.acks == [sent.acks.first ?? -1] && (sent.acks.first ?? -1) >= 0)
        let image = try #require(pipeline.surface.snapshot())
        #expect(painted(image, width: 124, height: 120) > 0.5)
        // Nothing lands outside `rect`.
        #expect(pixel(image, 127, 60) == [0, 0, 0, 0])
        #expect(pixel(image, 60, 123) == [0, 0, 0, 0])
    }

    @Test func av1SequenceHeaderAndConfigurationRecord() throws {
        let units = try AV1OBU.units(in: try Self.av1TemporalUnits()[0])
        #expect(units.first?.type == AV1OBU.temporalDelimiter)
        let header = try #require(units.first { $0.type == AV1OBU.sequenceHeader })
        let sequence = try AV1SequenceHeader(header.payload)
        #expect(sequence.profile == 0 && sequence.maxWidth == 64 && sequence.maxHeight == 64)
        #expect(!sequence.highBitDepth && !sequence.monochrome && sequence.subsamplingX && sequence.subsamplingY)
        let record = sequence.configurationRecord(sequenceHeader: header.sized)
        #expect(record[0] == 0x81 && record[1] >> 5 == 0 && record[2] & 0x0C == 0x0C)
    }

    @Test func obuSizesRoundTrip() throws {
        #expect(AV1OBU.leb128(0) == Data([0]))
        #expect(AV1OBU.leb128(300) == Data([0xAC, 0x02]))
        // A unit without a size field runs to the end; sized, it reads back the same.
        let bare = Data([0x30, 1, 2, 3])
        let unit = try #require(try AV1OBU.units(in: bare).first)
        #expect(unit.type == 6 && unit.payload == Data([1, 2, 3]))
        #expect(try AV1OBU.units(in: unit.sized) == [AV1OBU.Unit(type: 6, header: Data([0x32]), payload: Data([1, 2, 3]))])
        #expect(throws: AV1OBU.Failure.self) { try AV1OBU.units(in: Data([0x32, 9, 1])) }
    }

    @Test(.enabled(if: AV1Decoder.isSupported)) func av1DecodesInHardware() throws {
        let sent = Sent()
        let pipeline = FramePipeline(windowID: 1, width: 64, height: 64) { sent.append($0) }
        for (index, unit) in try Self.av1TemporalUnits().enumerated() {
            pipeline.frame(EncodedFrame(window: 1, codec: .av1, keyframe: index == 0, ptsMicros: UInt64(index) * 33_333,
                                        rect: CGRect(x: 0, y: 0, width: 64, height: 64), crop: CGRect(x: 0, y: 0, width: 64, height: 64),
                                        data: unit))
        }
        pipeline.flush()
        #expect(sent.acks.count == 3 && sent.acks.allSatisfy { $0 >= 0 }, "\(sent.acks)")
        let image = try #require(pipeline.surface.snapshot())
        #expect(painted(image, width: 64, height: 64) > 0.5)
    }

    @Test func decodersOfferAV1OnlyWhereTheDeviceHasIt() {
        #expect(CabooseDisplaySession.hardwareDecoders.contains(.av1) == AV1Decoder.isSupported)
        #expect(CabooseDisplaySession.hardwareDecoders.first == .hevc)
    }

    /// The fixture's temporal units, split at each temporal delimiter.
    static func av1TemporalUnits() throws -> [Data] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/av1-64x64.obu")
        let stream = try Data(contentsOf: url)
        var units: [Data] = []
        var current = Data()
        for unit in try AV1OBU.units(in: stream) {
            if unit.type == AV1OBU.temporalDelimiter, !current.isEmpty {
                units.append(current)
                current = Data()
            }
            current.append(unit.sized)
        }
        if !current.isEmpty { units.append(current) }
        return units
    }

    /// Wraps raw uncompressed bytes in a valid LZ4 literal-only block with 4-byte LE size header.
    private static func lz4LiteralPrependSize(_ uncompressed: Data) -> Data {
        var out = Data()
        let len = UInt32(uncompressed.count)
        out.append(UInt8(len & 0xFF))
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8((len >> 16) & 0xFF))
        out.append(UInt8((len >> 24) & 0xFF))
        guard !uncompressed.isEmpty else { return out }
        if uncompressed.count < 15 {
            out.append(UInt8(uncompressed.count << 4))
        } else {
            out.append(0xF0)
            var rem = uncompressed.count - 15
            while rem >= 255 {
                out.append(255)
                rem -= 255
            }
            out.append(UInt8(rem))
        }
        out.append(uncompressed)
        return out
    }

    @Test func xxh64MatchesCanonicalVectors() {
        #expect(SurfaceAtlasCodec.xxh64(Data()) == 0xEF46_DB37_51D8_E999)
        #expect(SurfaceAtlasCodec.xxh64(Data("abc".utf8)) == 0x44BC_2CF5_AD77_0999)
        let sixtyFour = Data((0 ..< 64).map { UInt8($0) })
        let h1 = SurfaceAtlasCodec.xxh64(sixtyFour)
        let h2 = SurfaceAtlasCodec.xxh64(sixtyFour)
        #expect(h1 == h2 && h1 != 0)
    }

    @Test func surfaceAtlasDecodeTileFormats() throws {
        // 1. pal2-lz4 on a 4x2 tile (8 pixels -> 1 byte bitmask: 0b1010_0101 = 0xA5)
        var pal2Raw = Data([
            0x10, 0x20, 0x30, 0xFF, // color 0
            0xE0, 0xF0, 0x40, 0xFF, // color 1
            0xA5,                   // bits: 1,0,1,0,0,1,0,1
        ])
        let pal2Tile = SurfaceTile(
            rect: CGRect(x: 0, y: 0, width: 4, height: 2),
            format: .pal2Lz4,
            data: Self.lz4LiteralPrependSize(pal2Raw)
        )
        let pal2Decoded = try #require(SurfaceAtlasCodec.decodeTile(pal2Tile))
        #expect(pal2Decoded.count == 4 * 2 * 4)
        #expect(Array(pal2Decoded[0 ..< 4]) == [0xE0, 0xF0, 0x40, 0xFF]) // bit 0 = 1
        #expect(Array(pal2Decoded[4 ..< 8]) == [0x10, 0x20, 0x30, 0xFF]) // bit 1 = 0
        #expect(Array(pal2Decoded[8 ..< 12]) == [0xE0, 0xF0, 0x40, 0xFF]) // bit 2 = 1

        // 2. pal16-lz4 on a 2x2 tile (4 pixels -> 3 colors, 2 packed bytes)
        pal2Raw.removeAll()
        let pal16Raw = Data([
            3,                      // 3 palette entries
            0x11, 0x22, 0x33, 0xFF, // idx 0
            0x44, 0x55, 0x66, 0xFF, // idx 1
            0x77, 0x88, 0x99, 0xFF, // idx 2
            0x10,                   // pixel 0 = 0, pixel 1 = 1
            0x02,                   // pixel 2 = 2, pixel 3 = 0
        ])
        let pal16Tile = SurfaceTile(
            rect: CGRect(x: 0, y: 0, width: 2, height: 2),
            format: .pal16Lz4,
            data: Self.lz4LiteralPrependSize(pal16Raw)
        )
        let pal16Decoded = try #require(SurfaceAtlasCodec.decodeTile(pal16Tile))
        #expect(Array(pal16Decoded[0 ..< 4]) == [0x11, 0x22, 0x33, 0xFF])
        #expect(Array(pal16Decoded[4 ..< 8]) == [0x44, 0x55, 0x66, 0xFF])
        #expect(Array(pal16Decoded[8 ..< 12]) == [0x77, 0x88, 0x99, 0xFF])
        #expect(Array(pal16Decoded[12 ..< 16]) == [0x11, 0x22, 0x33, 0xFF])

        // 3. rgba-lz4 on a 2x1 tile
        let rgbaRaw = Data([1, 2, 3, 255, 9, 8, 7, 255])
        let rgbaTile = SurfaceTile(
            rect: CGRect(x: 0, y: 0, width: 2, height: 1),
            format: .rgbaLz4,
            data: Self.lz4LiteralPrependSize(rgbaRaw)
        )
        #expect(SurfaceAtlasCodec.decodeTile(rgbaTile) == rgbaRaw)
    }

    @Test func surfaceAtlasRendererAppliesFillsCopiesTilesAndRefsBitExact() throws {
        let cache = TileAtlasCache(capacity: 16)
        let renderer = SurfaceAtlasRenderer()

        // Create a 64x64 solid tile of 0xAA, 0xBB, 0xCC, 0xFF
        var tilePixels = Data(capacity: 64 * 64 * 4)
        for _ in 0 ..< (64 * 64) {
            tilePixels.append(contentsOf: [0xAA, 0xBB, 0xCC, 0xFF])
        }
        let tileHash = SurfaceAtlasCodec.xxh64(tilePixels)
        let tile = SurfaceTile(
            rect: CGRect(x: 0, y: 0, width: 64, height: 64),
            hash: tileHash,
            format: .rgbaLz4,
            data: Self.lz4LiteralPrependSize(tilePixels)
        )

        // Batch 1: 128x64 keyframe with fill on right half and 64x64 tile on left half
        let batch1 = SurfaceBatch(
            window: 7,
            seq: 1,
            ptsMicros: 1000,
            size: CGSize(width: 128, height: 64),
            rect: CGRect(x: 0, y: 0, width: 128, height: 64),
            keyframe: true,
            fills: [SurfaceFill(rect: CGRect(x: 64, y: 0, width: 64, height: 64), rgba: 0x1234_56FF)],
            tiles: [tile]
        )
        let img1 = try #require(renderer.apply(batch1, cache: cache))
        #expect(pixel(img1, 0, 0) == [0xAA, 0xBB, 0xCC, 0xFF])
        #expect(pixel(img1, 64, 0) == [0x12, 0x34, 0x56, 0xFF])
        #expect(cache.get(hash: tileHash) == tilePixels)

        // Batch 2: copy left 64x64 to (32, 0) via dx=+32, and ref the cached tile at (64, 0)
        let batch2 = SurfaceBatch(
            window: 7,
            seq: 2,
            ptsMicros: 2000,
            size: CGSize(width: 128, height: 64),
            rect: CGRect(x: 32, y: 0, width: 96, height: 64),
            keyframe: false,
            copies: [SurfaceCopy(dx: 32, dy: 0, rect: CGRect(x: 32, y: 0, width: 64, height: 64))],
            refs: [SurfaceTileRef(x: 64, y: 0, hash: tileHash)]
        )
        let img2 = try #require(renderer.apply(batch2, cache: cache))
        #expect(pixel(img2, 40, 10) == [0xAA, 0xBB, 0xCC, 0xFF])
        #expect(pixel(img2, 100, 10) == [0xAA, 0xBB, 0xCC, 0xFF])
        let rawBytes = try #require(renderer.rgbaBytes(forWindow: 7))
        #expect(rawBytes.count == 128 * 64 * 4)
    }

    @Test func sceneGraphUnpacksGlyphsAndRendersRetainedTree() throws {
        var glyphBytes = Data()
        let gId: UInt16 = 42
        let gx: Float = 12.5
        let gy: Float = 28.0
        glyphBytes.append(UInt8(gId & 0xFF))
        glyphBytes.append(UInt8(gId >> 8))
        var xBits = gx.bitPattern.littleEndian
        var yBits = gy.bitPattern.littleEndian
        withUnsafeBytes(of: &xBits) { glyphBytes.append(contentsOf: $0) }
        withUnsafeBytes(of: &yBits) { glyphBytes.append(contentsOf: $0) }

        let unpacked = PositionedGlyph.unpack(glyphBytes)
        #expect(unpacked == [PositionedGlyph(glyphID: 42, x: 12.5, y: 28.0)])

        let fontCache = SceneFontCache()
        fontCache.register(SceneFontDescriptor(font: 99, index: 0, family: "Helvetica", data: Data([0, 1, 0, 0])))

        let scene = WindowSceneState(windowID: 7)
        let commit = SceneCommit(
            window: 7,
            seq: 1,
            ptsMicros: 1000,
            root: 1,
            reset: true,
            nodes: [
                SceneNode(id: 1, kind: .rclip, rect: CGRect(x: 0, y: 0, width: 64, height: 64), radius: [8, 8, 8, 8], children: [2]),
                SceneNode(id: 2, kind: .scroll, rect: CGRect(x: 0, y: 0, width: 64, height: 64), scroll: CGRect(x: 0, y: 0, width: 64, height: 200), children: [3, 4]),
                SceneNode(id: 3, kind: .rect, rect: CGRect(x: 0, y: 0, width: 64, height: 64), color: 0x2040_80FF),
                SceneNode(id: 4, kind: .glyphs, rect: CGRect(x: 4, y: 4, width: 56, height: 24), color: 0xFFFF_FFFF, font: 99, size: 14, glyphs: glyphBytes),
            ]
        )
        scene.apply(commit)
        let image = try #require(scene.render(size: CGSize(width: 64, height: 64), scale: 2.0, fontCache: fontCache))
        #expect(image.width == 128 && image.height == 128)
        #expect(pixel(image, 64, 64) == [0x20, 0x40, 0x80, 0xFF])

        let scrollMsg = scene.userScrolled(nodeID: 2, offset: CGPoint(x: 0, y: 120))
        if case .sceneScroll(let w, let n, let sx, let sy) = scrollMsg {
            #expect(w == 7 && n == 2 && sx == 0 && sy == 120)
        } else {
            Issue.record("expected sceneScroll")
        }
    }
}
