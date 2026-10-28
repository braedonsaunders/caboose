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
}
