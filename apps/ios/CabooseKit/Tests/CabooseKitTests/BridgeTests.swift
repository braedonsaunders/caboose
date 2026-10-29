import Foundation
import Testing
import UniformTypeIdentifiers
@testable import CabooseKit

private func request(_ overrides: [String: Any] = [:]) throws -> BridgeRequest {
    var value: [String: Any] = [
        "id": "0123456789abcdef0123456789abcdef", "type": "file.open", "app": "org.libreoffice.LibreOffice", "title": "Open",
        "acceptLabel": "", "multiple": false, "directory": false,
        "filters": [["name": "Documents", "patterns": ["*.odt", "*.DOCX"], "mimeTypes": ["application/pdf"]]],
        "currentFilter": 0, "currentName": "", "currentFolder": "/home/caboose/Documents", "created": 1_793_161_915,
    ]
    for (key, item) in overrides { value[key] = item }
    return try JSONDecoder().decode(BridgeRequest.self, from: JSONSerialization.data(withJSONObject: value))
}

@Suite struct BridgeRequestTests {
    @Test func decodesTheContract() throws {
        let r = try request()
        #expect(r.type == .open)
        #expect(r.appName == "LibreOffice")
        #expect(r.filters[0].extensions == ["odt", "docx"])
        #expect(r.startFolder.relative == "Documents")
        let save = try request(["type": "file.save", "currentName": "Report.odt", "currentFilter": NSNull(), "currentFolder": ""])
        #expect(save.currentFilter == nil)
        #expect(save.startFolder.relative == "Documents")
    }

    @Test func rejectsMalformedRequests() {
        let bad: [[String: Any]] = [
            ["id": "XYZ"], ["type": "file.delete"], ["title": "a\u{7}"], ["app": String(repeating: "a", count: 201)],
            ["type": "file.save", "multiple": true], ["currentFilter": 1], ["currentName": "a.txt"],
            ["type": "file.save", "currentName": "a/b"], ["currentFolder": "/etc"], ["currentFolder": "/home/caboose/../x"],
            ["filters": [["name": "A", "patterns": [""], "mimeTypes": []]]], ["created": -1],
        ]
        for overrides in bad { #expect(throws: (any Error).self, "\(overrides)") { try request(overrides) } }
    }

    @Test func resolvesTypes() throws {
        let r = try request()
        let types = r.contentTypes
        #expect(types.contains(.pdf))
        #expect(types.contains { $0.preferredFilenameExtension == "docx" })
        let any = BridgeRequest.Filter(name: "All", patterns: ["*"], mimeTypes: ["*/*"])
        #expect(any.contentTypes.isEmpty)
        let images = BridgeRequest.Filter(name: "Images", patterns: [], mimeTypes: ["image/*"])
        #expect(images.contentTypes == [.image])
        let unknown = BridgeRequest.Filter(name: "X", patterns: ["*.qqqzzz"], mimeTypes: ["application/x-qqqzzz"])
        #expect(unknown.contentTypes.isEmpty)
    }
}

@Suite struct ComputerPathTests {
    @Test func convertsBetweenRelativeAndAbsolute() throws {
        let p = try #require(ComputerPath(absolute: "/home/caboose/Documents/Notes"))
        #expect(p.relative == "Documents/Notes")
        #expect(p.name == "Notes")
        #expect(p.parent?.absolute == "/home/caboose/Documents")
        #expect(p.ancestry.map(\.name) == ["Home", "Documents", "Notes"])
        #expect(ComputerPath(absolute: "/home/caboose") == .home)
        #expect(ComputerPath(relative: "")?.absolute == "/home/caboose")
        #expect(p.appending("a.txt")?.absolute == "/home/caboose/Documents/Notes/a.txt")
    }

    @Test func rejectsPathsOutsideTheHome() {
        for bad in ["/etc/passwd", "/home/caboosex", "/home/caboose/../root", "/home/caboose//a", "/home/caboose/./a", "/home/caboose/a\u{0}"] {
            #expect(ComputerPath(absolute: bad) == nil, "\(bad)")
        }
        #expect(ComputerPath.home.appending("a/b") == nil)
        #expect(ComputerPath.home.appending("..") == nil)
    }
}

@Suite struct BridgeAnswerTests {
    @Test func encodesTheContract() throws {
        let encode = { (answer: BridgeAnswer) throws -> [String: Any] in
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(answer)) as! [String: Any]
        }
        let path = try #require(ComputerPath(relative: "Documents/a.odt"))
        let ok = try encode(.chose([path], filter: 0))
        #expect(ok["response"] as? String == "ok")
        #expect(ok["paths"] as? [String] == ["/home/caboose/Documents/a.odt"])
        #expect(ok["filter"] as? Int == 0)
        #expect(try encode(.chose([path], filter: nil))["filter"] == nil)
        let cancel = try encode(.cancel), computer = try encode(.computer)
        #expect(cancel.count == 1 && cancel["response"] as? String == "cancel")
        #expect(computer.count == 1 && computer["response"] as? String == "computer")
    }
}

@Suite struct SaveNameTests {
    let odt = BridgeRequest.Filter(name: "ODF Text", patterns: ["*.odt"], mimeTypes: [])
    @Test func appliesTheFilterExtension() {
        #expect(SaveName.applying(odt, to: "Report.odt") == "Report.odt")
        #expect(SaveName.applying(odt, to: "Report.docx") == "Report.odt")
        #expect(SaveName.applying(odt, to: "Report") == "Report.odt")
        #expect(SaveName.applying(nil, to: "Report.docx") == "Report.docx")
        #expect(SaveName.applying(.init(name: "All", patterns: ["*"], mimeTypes: []), to: "a.b") == "a.b")
    }

    @Test func validatesNames() {
        #expect(SaveName.valid("Report.odt"))
        for bad in ["", " ", " a", "a/b", ".", "..", "a\u{1}"] { #expect(!SaveName.valid(bad), "\(bad)") }
    }

    @Test func selectsTheBaseName() {
        let name = "Report.final.odt"
        #expect(String(name[SaveName.baseRange(of: name)]) == "Report.final")
        #expect(String("Makefile"[SaveName.baseRange(of: "Makefile")]) == "Makefile")
        #expect(String(".bashrc"[SaveName.baseRange(of: ".bashrc")]) == ".bashrc")
    }
}

@Suite struct BridgeAppearanceTests {
    @Test func encodesThePhonesAppearance() throws {
        let look = BridgeAppearance(dark: true, accent: 0.039, 0.518, 1, highContrast: false, reducedMotion: true, contentSize: "UICTContentSizeCategoryXXL")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(look)) as! [String: Any]
        #expect(json["colorScheme"] as? String == "dark")
        #expect(json["accent"] as? String == "#0A84FF")
        #expect(json["contrast"] as? String == "normal")
        #expect(json["reducedMotion"] as? Bool == true)
        #expect(json["textScale"] as? Double == 1.2)
        #expect(BridgeAppearance.hex(2, -1, .nan) == "#FF0000")
        #expect(BridgeAppearance.textScale(contentSize: "unknown") == 1)
    }
}

@Suite struct BridgeNowPlayingTests {
    let base: [String: Any] = [
        "id": "a1b2c3-0", "player": "Spotify", "title": "Teardrop", "artist": "Massive Attack", "album": "Mezzanine",
        "artwork": "https://i.scdn.co/image/1", "position": 30, "duration": 330, "paused": false, "rate": 1,
        "canPlay": true, "canPause": true, "canNext": true, "canPrevious": true, "canSeek": true, "updatedAt": 1_000_000,
    ]
    func decode(_ overrides: [String: Any] = [:]) throws -> BridgeNowPlaying {
        var value = base
        for (key, item) in overrides { value[key] = item }
        return try JSONDecoder().decode(BridgeNowPlaying.self, from: JSONSerialization.data(withJSONObject: value))
    }

    @Test func extrapolatesWhilePlaying() throws {
        let track = try decode(["rate": 2])
        #expect(track.position(at: 1_000_500) == 31)
        #expect(track.position(at: 9_000_000) == 330)
        #expect(try decode(["paused": true]).position(at: 2_000_000) == 30)
        #expect(try decode(["paused": true]).playbackRate == 0)
        #expect(try decode(["duration": NSNull(), "artwork": NSNull()]).duration == nil)
        #expect(try decode(["artwork": "http://insecure/a.png"]).artwork == nil)
    }

    @Test func rejectsMalformedState() {
        let bad: [[String: Any]] = [["id": "a/b"], ["id": ""], ["position": -1], ["rate": 17], ["paused": "no"]]
        for bad in bad {
            #expect(throws: (any Error).self, "\(bad)") { try decode(bad) }
        }
    }
}

private func admit(_ throttle: inout LocationThrottle, _ fix: LocationThrottle.Fix, at now: Double) -> Bool {
    throttle.admit(fix, at: now)
}

@Suite struct LocationThrottleTests {
    @Test func admitsAtMostEveryFiveSecondsAndOnlyMeaningfulMoves() {
        var throttle = LocationThrottle()
        let here = LocationThrottle.Fix(latitude: 43.6532, longitude: -79.3832, accuracy: 20)
        let near = LocationThrottle.Fix(latitude: 43.65321, longitude: -79.3832, accuracy: 20)
        let far = LocationThrottle.Fix(latitude: 43.6600, longitude: -79.3832, accuracy: 20)
        #expect(admit(&throttle, here, at: 0) == true)
        #expect(admit(&throttle, far, at: 3) == false)
        #expect(admit(&throttle, near, at: 10) == false)
        #expect(admit(&throttle, far, at: 10) == true)
        #expect(admit(&throttle, far, at: 71) == true)
        #expect(admit(&throttle, .init(latitude: 91, longitude: 0, accuracy: 1), at: 200) == false)
        throttle.reset()
        #expect(admit(&throttle, here, at: 72) == true)
        #expect(abs(LocationThrottle.distance(here, far) - 753) < 5)
    }
}
