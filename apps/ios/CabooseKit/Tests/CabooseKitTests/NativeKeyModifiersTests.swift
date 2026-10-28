import XCTest
@testable import CabooseKit

final class NativeKeyModifiersTests: XCTestCase {
    func testControlEditingChordsAreOneShot() {
        let cases: [(String, NativeKeyModifiers.TextAction)] = [
            ("a", .selectAll), ("C", .copy), ("x", .cut), ("v", .paste), ("z", .undo), ("y", .redo),
        ]
        for (key, expected) in cases {
            var state = NativeKeyModifiers()
            state.toggle("control")
            XCTAssertEqual(state.text(key, composing: false, secure: false), expected)
            XCTAssertTrue(state.active.isEmpty)
            XCTAssertEqual(state.text(key, composing: false, secure: false), .insert(key))
        }
    }
    func testSecureFieldsNeverExportThroughAccessoryChords() {
        for key in ["c", "x"] {
            var state = NativeKeyModifiers()
            state.toggle("control")
            XCTAssertEqual(state.text(key, composing: false, secure: true), .unsupported)
            XCTAssertTrue(state.active.isEmpty)
        }
    }
    func testNavigationConsumesAndToggleCanCancel() {
        var state = NativeKeyModifiers()
        state.toggle("mod1")
        XCTAssertEqual(state.consume(), ["mod1"])
        XCTAssertTrue(state.consume().isEmpty)
        state.toggle("control"); state.toggle("control")
        XCTAssertTrue(state.active.isEmpty)
    }
    func testUnsupportedChordsDoNotInsertPlainTextOrControlBytes() {
        for modifiers in [["control"], ["mod1"], ["control", "mod1"]] {
            var state = NativeKeyModifiers()
            for modifier in modifiers { state.toggle(modifier) }
            XCTAssertEqual(state.text("/", composing: false, secure: false), .unsupported)
            XCTAssertTrue(state.active.isEmpty)
        }
    }
    func testCompositionRemainsNativeAndConsumesModifier() {
        var state = NativeKeyModifiers()
        state.toggle("control")
        XCTAssertEqual(state.text("候補", composing: true, secure: false), .insert("候補"))
        XCTAssertTrue(state.active.isEmpty)
        XCTAssertEqual(state.text("hello\nworld", composing: false, secure: false), .insert("hello\nworld"))
    }
}
