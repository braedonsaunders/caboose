import Foundation
import Testing
@testable import CabooseKit

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
