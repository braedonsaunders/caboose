import Foundation
import Testing
@testable import CabooseKit

@Suite struct ClipboardPolicyTests {
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])

    func entry(_ mime: String, _ data: Data) -> ClipboardEntry { ClipboardEntry(mime: mime, data: data) }

    @Test func textAndAnImageTogetherAreValid() {
        let copy = ClipboardContent([entry(ClipboardPolicy.text, Data("héllo".utf8)), entry(ClipboardPolicy.png, Self.png)])!
        #expect(ClipboardPolicy.validate(copy) == nil)
    }

    @Test func imagesMustCarryTheirSignature() {
        #expect(ClipboardPolicy.check(ClipboardPolicy.png, Data("GIF89a".utf8)) == .malformed)
        #expect(ClipboardPolicy.check(ClipboardPolicy.jpeg, Self.png) == .malformed)
        #expect(ClipboardPolicy.check(ClipboardPolicy.jpeg, Self.jpeg) == nil)
    }

    @Test func unknownRepeatedAndOversizedCopiesAreRefused() {
        #expect(ClipboardPolicy.validate(ClipboardContent([entry("text/html", Data("<b>".utf8))])!) == .unknownType)
        #expect(ClipboardPolicy.validate(ClipboardContent([entry(ClipboardPolicy.text, Data("a".utf8)),
                                                           entry(ClipboardPolicy.text, Data("b".utf8))])!) == .duplicate)
        var big = Self.png
        big.append(Data(count: ClipboardPolicy.maxBytes / 2))
        var bigJPEG = Self.jpeg
        bigJPEG.append(Data(count: ClipboardPolicy.maxBytes / 2))
        #expect(ClipboardPolicy.validate(ClipboardContent([entry(ClipboardPolicy.png, big), entry(ClipboardPolicy.jpeg, bigJPEG)])!) == .tooLarge)
        #expect(ClipboardPolicy.check(ClipboardPolicy.text, Data([0xFF, 0xFE])) == .malformed)
    }

    @Test func uriListsRoundTripThroughPercentEncoding() {
        let paths = ["/home/caboose/Report #1 (final).pdf", "/home/caboose/naïve.txt"]
        let list = ClipboardPolicy.uriList(paths)
        #expect(String(data: list, encoding: .utf8)
            == "file:///home/caboose/Report%20%231%20%28final%29.pdf\r\nfile:///home/caboose/na%C3%AFve.txt\r\n")
        #expect(ClipboardPolicy.filePaths(list) == paths)
        #expect(ClipboardPolicy.filePaths(Data("# c\r\nfile://localhost/tmp/x\r\n".utf8)) == ["/tmp/x"])
        for bad in ["https://example.com/\r\n", "file://server/x\r\n", "file:///a%00b\r\n", "file:///a%zz\r\n", "# none\r\n"] {
            #expect(ClipboardPolicy.filePaths(Data(bad.utf8)) == nil, "\(bad)")
        }
    }

    @Test func onlyHomeFilesAreFetched() {
        #expect(ClipboardPolicy.homeRelative("/home/caboose/Documents/a b.odt") == "Documents/a b.odt")
        #expect(ClipboardPolicy.homeRelative("/home/caboose/../etc/passwd") == nil)
        #expect(ClipboardPolicy.homeRelative("/home/caboose/a//b") == nil)
        #expect(ClipboardPolicy.homeRelative("/home/caboosex/a") == nil)
        #expect(ClipboardPolicy.homeRelative("/etc/hostname") == nil)
        #expect(ClipboardPolicy.homeRelative("/home/caboose") == nil)
    }

    @Test func thePhonesCopyTakesTheFirstImageThatFits() {
        var tooBig = Self.png
        tooBig.append(Data(count: ClipboardPolicy.maxBytes))
        let copy = ClipboardPolicy.content(text: "caption", images: [entry(ClipboardPolicy.png, tooBig), entry(ClipboardPolicy.jpeg, Self.jpeg)])
        #expect(copy?.entries.map(\.mime) == [ClipboardPolicy.text, ClipboardPolicy.jpeg])
        let files = ClipboardPolicy.content(text: nil, files: ["/home/caboose/.cache/caboose/transfers/x/a.txt"])
        #expect(files?.entries.map(\.mime) == [ClipboardPolicy.uriList])
        #expect(ClipboardPolicy.content(text: "", images: [entry(ClipboardPolicy.png, Data("not".utf8))]) == nil)
    }

    @Test func aCopyFromTheComputerKeepsWhatThisClientTakes() {
        let copy = ClipboardContent([entry(ClipboardPolicy.text, Data("a".utf8)), entry("image/bmp", Data([1])),
                                     entry(ClipboardPolicy.png, Data("bad".utf8)), entry(ClipboardPolicy.jpeg, Self.jpeg)])!
        #expect(ClipboardPolicy.accepted(copy)?.entries.map(\.mime) == [ClipboardPolicy.text, ClipboardPolicy.jpeg])
        #expect(ClipboardPolicy.accepted(ClipboardContent([entry("image/bmp", Data([1]))])!) == nil)
    }
}
