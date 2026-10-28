import Testing
@testable import CabooseKit

@Test func directoryMovesAndDeletesPreserveUnrelatedNames() {
    let original = ["Docs": "dir", "Docs/a": "file", "Docs/a/b": "nested", "Docs2/a": "other"]
    let moved = FilePathIndex.moving(original, from: "Docs", to: "Archive")
    #expect(moved == ["Archive": "dir", "Archive/a": "file", "Archive/a/b": "nested", "Docs2/a": "other"])
    let deleted = FilePathIndex.removing(moved, path: "Archive")
    #expect(deleted.remaining == ["Docs2/a": "other"])
    #expect(Set(deleted.removed) == Set(["dir", "file", "nested"]))
}
