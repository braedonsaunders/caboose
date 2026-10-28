import Foundation
import Testing
@testable import CabooseKit

/// Replays frames recorded from a real Xpra 6.5.5 client and server (docs/xpra-vectors).
@Suite struct VectorTests {
    struct Frame { var direction: String; var type: String; var data: Data }

    static func frames(_ file: String) throws -> [Frame] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../../../docs/xpra-vectors/\(file)").standardized
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return (json["packets"] as! [[String: Any]]).map { entry in
            Frame(direction: entry["direction"] as! String,
                  type: (entry["packet"] as! [Any])[0] as! String,
                  data: hex(entry["sanitized_frame_hex"] as! String))
        }
    }

    static func hex(_ string: String) -> Data {
        var data = Data(capacity: string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            data.append(UInt8(string[index ..< next], radix: 16)!)
            index = next
        }
        return data
    }

    @Test(arguments: ["session.json", "png-session.json", "video-session.json"])
    func parsesEveryRecordedFrame(file: String) throws {
        for frame in try Self.frames(file) {
            var parser = PacketParser()
            let packets = try parser.append(frame.data)
            #expect(packets.count == 1)
            #expect(packets.first?.type == frame.type)
        }
    }

    @Test func parsesFramesSplitAcrossMessages() throws {
        let all = try Self.frames("session.json").filter { $0.direction == "server" }
        let stream = all.reduce(Data()) { $0 + $1.data }
        var parser = PacketParser()
        var packets: [XpraPacket] = []
        var offset = 0
        while offset < stream.count {
            let end = min(stream.count, offset + 97)
            packets += try parser.append(stream.subdata(in: offset ..< end))
            offset = end
        }
        #expect(packets.map(\.type) == all.map(\.type))
    }

    @Test func reencodesClientPacketsByteForByte() throws {
        for frame in try Self.frames("session.json") where frame.direction == "client" {
            var parser = PacketParser()
            let packet = try #require(try parser.append(frame.data).first)
            #expect(PacketFraming.encode(packet) == frame.data, "\(frame.type)")
        }
    }

    @Test func legacyNamesNormalizeToModern() throws {
        for (legacy, modern) in [("new-window", "window-create"), ("draw", "window-draw"), ("window-draw", "window-draw")] {
            #expect(PacketNames.normalized(XpraPacket(legacy)).type == modern)
        }
    }

    @Test func h264DrawCarriesAnnexBBytes() throws {
        let frame = try #require(try Self.frames("video-session.json").first)
        var parser = PacketParser()
        let packet = try #require(try parser.append(frame.data).first)
        #expect(packet[5]?.string == "h264")
        guard case .bytes(let payload)? = packet[6] else { Issue.record("draw payload is not bytes"); return }
        #expect(payload.prefix(4) == Data([0, 0, 0, 1]))
    }
}

@Suite struct KeysymTests {
    @Test func plainAndShiftedCharacters() {
        #expect(Keysyms.stroke(for: "a")?.name == "a")
        #expect(Keysyms.stroke(for: "A")?.modifiers == ["shift"])
        #expect(Keysyms.stroke(for: "?")?.name == "question")
        #expect(Keysyms.stroke(for: "é")?.keyval == 0xE9)
        #expect(Keysyms.stroke(for: "→")?.keyval == 0x0100_2192)
    }

    @Test func multiScalarCharactersTypeEveryScalar() {
        let family: Character = "👩‍👩‍👧"
        #expect(Keysyms.strokes(for: family).count == family.unicodeScalars.count)
        let flag: Character = "🇨🇦"
        #expect(Keysyms.strokes(for: flag).map(\.keyval) == [0x0101_F1E8, 0x0101_F1E6])
        #expect(Keysyms.strokes(for: "e\u{301}").map(\.keyval) == [0x65, 0x0100_0301])
    }
}
