import XCTest
@testable import CabooseKit

final class FileExportTests: XCTestCase {
    func testExportContract() throws {
        for app in FileExportApplication.allCases {
            for format in app.formats {
                try app.validate(format: format, count: app.inputCount.lowerBound)
                try app.validate(format: format, count: app.inputCount.upperBound)
            }
            XCTAssertThrowsError(try app.validate(format: app.formats[0], count: 0))
            XCTAssertThrowsError(try app.validate(format: app.formats[0], count: app.inputCount.upperBound + 1))
            XCTAssertThrowsError(try app.validate(format: "pdf", count: 1))
        }
        XCTAssertThrowsError(try FileExportApplication.photocraft.validate(format: "mp4", count: 1))
        XCTAssertThrowsError(try FileExportApplication.filmcraft.validate(format: "png", count: 1))
        XCTAssertEqual(FileExportApplication.filmcraft.rawValue, "filmcraft")
        XCTAssertEqual(FileExportApplication.filmcraft.formats, ["mp4", "mov"])
    }
}
