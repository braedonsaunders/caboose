import Foundation
import Testing
@testable import CabooseKit

@Suite struct RencodeTests {
    @Test func encodesFixedForms() {
        #expect(Rencode.encode(1) == Data([0x01]))
        #expect(Rencode.encode(43) == Data([43]))
        #expect(Rencode.encode(-1) == Data([70]))
        #expect(Rencode.encode(-32) == Data([101]))
        #expect(Rencode.encode("abc") == Data([0x83]) + Data("abc".utf8))
        #expect(Rencode.encode([1, 2]) == Data([0xC2, 0x01, 0x02]))
        #expect(Rencode.encode(["a": 1]) == Data([103, 0x81, UInt8(ascii: "a"), 0x01]))
        #expect(Rencode.encode(true) == Data([67]))
        #expect(Rencode.encode(nil) == Data([69]))
    }

    @Test func encodesSizedIntegers() {
        #expect(Rencode.encode(100) == Data([62, 100]))
        #expect(Rencode.encode(-100) == Data([62, 0x9C]))
        #expect(Rencode.encode(1000) == Data([63, 0x03, 0xE8]))
        #expect(Rencode.encode(70000) == Data([64, 0x00, 0x01, 0x11, 0x70]))
        #expect(Rencode.encode(.int(1 << 40)) == Data([65, 0, 0, 1, 0, 0, 0, 0, 0]))
    }

    @Test func encodesLongStringsListsAndDicts() throws {
        let long = String(repeating: "x", count: 64)
        #expect(Rencode.encode(RValue(long)) == Data("64:".utf8) + Data(long.utf8))
        #expect(Rencode.encode(.bytes(Data([1, 2, 3]))) == Data("3/".utf8) + Data([1, 2, 3]))
        #expect(try Rencode.decode(Data("3/".utf8) + Data([1, 2, 3])) == .bytes(Data([1, 2, 3])))
        #expect(try Rencode.decode(Data([0x83]) + Data("abc".utf8)) == .string("abc"))
        let bigList = RValue.list((0 ..< 70).map { .int(Int64($0 % 40)) })
        let encodedList = Rencode.encode(bigList)
        #expect(encodedList.first == 59)
        #expect(encodedList.last == 127)
        let bigDict = RValue.dict((0 ..< 30).map { RPair(RValue("k\($0)"), .int(Int64($0))) })
        let encodedDict = Rencode.encode(bigDict)
        #expect(encodedDict.first == 60)
        #expect(try Rencode.decode(encodedList) == bigList)
        #expect(try Rencode.decode(encodedDict) == bigDict)
    }

    @Test func roundTripsMixedValues() throws {
        let value: RValue = [
            "hello",
            ["version": "6.3", "encodings": ["h264", "png"], "dpi": 192, "ratio": 1.5, "ok": true, "missing": nil],
            .bytes(Data((0 ..< 300).map { UInt8($0 % 256) })),
            -70000, .int(Int64.min), .int(Int64.max),
        ]
        #expect(try Rencode.decode(Rencode.encode(value)) == value)
    }

    @Test func decodesFloat32AndAsciiIntegers() throws {
        #expect(try Rencode.decode(Data([66, 0x3F, 0xC0, 0x00, 0x00])) == .float(1.5))
        #expect(try Rencode.decode(Data([61]) + Data("123456789012345678901234567890".utf8) + Data([127]))
            == .bigInt("123456789012345678901234567890"))
        #expect(try Rencode.decode(Data([61]) + Data("-42".utf8) + Data([127])) == .int(-42))
    }

    @Test func rejectsMalformedInput() {
        #expect(throws: RencodeError.truncated) { try Rencode.decode(Data([0x83, 0x61])) }
        #expect(throws: RencodeError.truncated) { try Rencode.decode(Data("5/ab".utf8)) }
        #expect(throws: RencodeError.trailingBytes(1)) { try Rencode.decode(Data([0x01, 0x02])) }
        #expect(throws: RencodeError.invalidTypeCode(45, offset: 0)) { try Rencode.decode(Data([45])) }
    }

    @Test func dictionaryHelpers() {
        let value: RValue = ["title": "Terminal", "size": [800, 600]]
        #expect(value["title"]?.string == "Terminal")
        #expect(value["size"]?[1]?.int == 600)
        #expect(value.stringKeyed.keys.sorted() == ["size", "title"])
    }
}

@Suite struct PacketFramingTests {
    @Test func roundTripsAPacket() throws {
        let packet = XpraPacket("ping", [.int(12345), "client"])
        var parser = PacketParser()
        #expect(try parser.append(PacketFraming.encode(packet)) == [packet])
    }

    @Test func handlesSplitAndCoalescedDelivery() throws {
        let a = PacketFraming.encode(XpraPacket("focus", [3, []]))
        let b = PacketFraming.encode(XpraPacket("bell", [1, 0, 50]))
        var stream = a + b
        var parser = PacketParser()
        var received: [XpraPacket] = []
        while !stream.isEmpty {
            let piece = stream.prefix(3)
            stream.removeFirst(piece.count)
            received += try parser.append(Data(piece))
        }
        #expect(received.map(\.type) == ["focus", "bell"])
    }

    @Test func substitutesRawChunks() throws {
        let pixels = Data(repeating: 0xAB, count: 1000)
        var raw = Data([UInt8(ascii: "P"), 0x10, 0, 7])
        Rencode.appendBigEndian(UInt32(pixels.count), into: &raw)
        raw.append(pixels)
        let main = PacketFraming.encode(XpraPacket("draw", [1, 0, 0, 10, 10, "png", "", 1, 0, [:]]))
        var parser = PacketParser()
        let packets = try parser.append(raw + main)
        #expect(packets.count == 1)
        #expect(packets[0][6]?.data == pixels)
    }

    @Test func rejectsCompressedPackets() {
        var data = PacketFraming.encode(XpraPacket("ping", [1]))
        data[2] = 0x11
        var parser = PacketParser()
        #expect(throws: PacketFramingError.compressed(level: 0x11)) { try parser.append(data) }
    }
}
