import Foundation
import XCTest
@testable import CabooseKit

final class ComputerCommandTests: XCTestCase {
    private let id = "0123456789abcdef0123456789abcdef"

    private func command(_ fields: String) throws -> ComputerCommand {
        let json = #"{"id":"\#(id)","title":"ffmpeg","script":"ffmpeg -i in.mov out.mp4","cwd":null,"inputs":[],"timeout":3600,"#
            + #""stdout":"","stderr":"","truncated":{"stdout":false,"stderr":true},"createdAt":"2026-10-30T00:00:00.000Z","directory":"x","# + fields + "}"
        return try JSONDecoder().decode(ComputerCommand.self, from: Data(json.utf8))
    }

    func testDecodesAFinishedCommandAndItsFiles() throws {
        let finished = try command(#""status":"succeeded","exitCode":0,"signal":null,"error":null,"outputs":["clip.mp4","../escape","a/b"],"finishedAt":"2026-10-30T00:01:00.000Z""#)
        XCTAssertEqual(finished.status, .succeeded)
        XCTAssertFalse(finished.isRunning)
        XCTAssertEqual(finished.truncated.stderr, true)
        XCTAssertEqual(finished.outputs, ["clip.mp4"])
        XCTAssertEqual(finished.directory, ".caboose-jobs/cmd-\(id)")
        XCTAssertEqual(finished.outputPaths, [".caboose-jobs/cmd-\(id)/out/clip.mp4"])
        XCTAssertEqual(finished.link, URL(string: "caboose://command/\(id)"))
        XCTAssertEqual(finished.summary, "Finished")
    }

    func testSummarisesHowACommandEnded() throws {
        XCTAssertEqual(try command(#""status":"running","exitCode":null,"signal":null,"error":null,"outputs":[],"finishedAt":null"#).summary, "Running")
        XCTAssertEqual(try command(#""status":"failed","exitCode":2,"signal":null,"error":null,"outputs":[],"finishedAt":null"#).summary, "Exited with code 2")
        XCTAssertEqual(try command(#""status":"failed","exitCode":null,"signal":"SIGKILL","error":null,"outputs":[],"finishedAt":null"#).summary, "Stopped by SIGKILL")
        XCTAssertEqual(try command(#""status":"failed","exitCode":null,"signal":null,"error":"Stopped when the computer restarted.","outputs":[],"finishedAt":null"#).summary, "Stopped when the computer restarted.")
        XCTAssertEqual(try command(#""status":"timed-out","exitCode":null,"signal":"SIGTERM","error":null,"outputs":[],"finishedAt":null"#).status, .timedOut)
    }

    func testRefusesUnknownStatusesAndIds() {
        XCTAssertThrowsError(try command(#""status":"paused","exitCode":null,"signal":null,"error":null,"outputs":[],"finishedAt":null"#))
        let json = #"{"id":"../x","title":"t","script":"s","status":"running","stdout":"","stderr":"","truncated":{"stdout":false,"stderr":false},"outputs":[],"createdAt":"x"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ComputerCommand.self, from: Data(json.utf8)))
        XCTAssertTrue(ComputerCommand.isValidID(ComputerCommand.newID()))
        XCTAssertFalse(ComputerCommand.isValidID(id.uppercased()))
    }

    func testAssignsPlainDistinctInputNames() {
        XCTAssertEqual(CommandFileName.assign(["photo.jpg", "photo.jpg", "photo.jpg", "notes"]), ["photo.jpg", "photo (2).jpg", "photo (3).jpg", "notes"])
        XCTAssertEqual(CommandFileName.assign(["a/b.txt", "line\nbreak.txt", "", "..", ".caboose-upload-x"]), ["a-b.txt", "line break.txt", "file", "file (2)", "caboose-upload-x"])
        let long = String(repeating: "é", count: 200) + ".mov"
        let name = CommandFileName.assign([long])[0]
        XCTAssertLessThanOrEqual(name.utf8.count, 255)
        XCTAssertTrue(name.hasSuffix("é.mov"))
        XCTAssertTrue(CommandFileName.assign(["x", "y.tar.gz", "x"]).allSatisfy(CommandFileName.isPlain))
        XCTAssertFalse(CommandFileName.isPlain("a\u{7F}"))
        XCTAssertFalse(CommandFileName.isPlain(".caboose-upload-1"))
    }
}
