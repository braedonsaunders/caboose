import Foundation
import Testing
@testable import CabooseKit

@Suite struct TypingBufferTests {
    @Test func typingSendsOnlyTheNewText() {
        var buffer = TypingBuffer()
        #expect(buffer.insert("h") == [.type("h")])
        #expect(buffer.insert("i") == [.type("i")])
        #expect(buffer.text == "hi")
        #expect(buffer.selection == NSRange(location: 2, length: 0))
    }

    @Test func autocorrectReplacesTheWordWithBackspacesFromWhereItDiffers() {
        var buffer = TypingBuffer()
        _ = buffer.insert("teh ")
        // iOS replaces "teh" with "the" while the caret sits after the space.
        #expect(buffer.replace(NSRange(location: 0, length: 3), with: "the") == [.backspace(3), .type("he ")])
        #expect(buffer.text == "the ")
        #expect(buffer.selection == NSRange(location: 3, length: 0))
    }

    @Test func swipeTypingInsertsWholeWords() {
        var buffer = TypingBuffer()
        #expect(buffer.insert("hello") == [.type("hello")])
        #expect(buffer.insert(" ") == [.type(" ")])
        #expect(buffer.insert("world") == [.type("world")])
        // Picking a different candidate for the last swipe replaces just that word.
        #expect(buffer.replace(NSRange(location: 6, length: 5), with: "would") == [.backspace(3), .type("uld")])
    }

    @Test func markedTextIsTypedLiveAndRecomposedByDifference() {
        var buffer = TypingBuffer()
        #expect(buffer.setMarked("n", selectedRange: NSRange(location: 1, length: 0)) == [.type("n")])
        #expect(buffer.setMarked("ni", selectedRange: NSRange(location: 2, length: 0)) == [.type("i")])
        #expect(buffer.marked == NSRange(location: 0, length: 2))
        // Choosing the candidate replaces the pinyin with the characters.
        #expect(buffer.insert("你") == [.backspace(2), .type("你")])
        #expect(buffer.marked == nil)
        #expect(buffer.text == "你")
    }

    @Test func unmarkCommitsWhatIsAlreadyTyped() {
        var buffer = TypingBuffer()
        _ = buffer.setMarked("かな", selectedRange: NSRange(location: 2, length: 0))
        buffer.unmark()
        #expect(buffer.marked == nil)
        #expect(buffer.text == "かな")
        #expect(buffer.insert("!") == [.type("!")])
    }

    @Test func clearingMarkedTextDeletesIt() {
        var buffer = TypingBuffer()
        _ = buffer.insert("a")
        _ = buffer.setMarked("ka", selectedRange: NSRange(location: 2, length: 0))
        #expect(buffer.setMarked("", selectedRange: NSRange(location: 0, length: 0)) == [.backspace(2)])
        #expect(buffer.marked == nil)
        #expect(buffer.text == "a")
    }

    @Test func deleteRemovesWholeCharactersAndKeepsDeletingPastTheBuffer() {
        var buffer = TypingBuffer()
        _ = buffer.insert("a👍🏽")
        #expect(buffer.deleteBackward() == [.backspace(1)])
        #expect(buffer.text == "a")
        #expect(buffer.deleteBackward() == [.backspace(1)])
        #expect(buffer.deleteBackward() == [.backspace(1)])
        #expect(buffer.text == "")
    }

    @Test func deletingBeforeTheBufferRetypesIt() {
        var buffer = TypingBuffer()
        _ = buffer.insert("ab")
        buffer.select(NSRange(location: 0, length: 0))
        #expect(buffer.deleteBackward() == [.backspace(3), .type("ab")])
        #expect(buffer.text == "ab")
    }

    @Test func insertingInTheMiddleRetypesTheTail() {
        var buffer = TypingBuffer()
        _ = buffer.insert("ac")
        buffer.select(NSRange(location: 1, length: 0))
        #expect(buffer.insert("b") == [.backspace(1), .type("bc")])
        #expect(buffer.selection == NSRange(location: 2, length: 0))
    }

    @Test func returnEndsTheEditableText() {
        var buffer = TypingBuffer()
        _ = buffer.insert("ls")
        #expect(buffer.insert("\n") == [.type("\n")])
        #expect(buffer.text == "")
        #expect(buffer.deleteBackward() == [.backspace(1)])
    }

    @Test func longTextForgetsItsOldestCharacters() {
        var buffer = TypingBuffer()
        _ = buffer.insert(String(repeating: "x", count: TypingBuffer.limit + 10))
        #expect((buffer.text as NSString).length == TypingBuffer.limit)
        #expect(buffer.selection.location == TypingBuffer.limit)
    }

    @Test func outOfRangeEditsAreClamped() {
        var buffer = TypingBuffer()
        _ = buffer.insert("ab")
        #expect(buffer.replace(NSRange(location: 5, length: 9), with: "c") == [.type("c")])
        #expect(buffer.text == "abc")
    }
}

@Suite struct TypingBufferPreeditTests {
    @Test func markedTextStaysLocalAndIsTypedOnCommit() {
        var buffer = TypingBuffer(marksAsPreedit: true)
        _ = buffer.insert("a")
        #expect(buffer.setMarked("ni", selectedRange: NSRange(location: 2, length: 0)) == [])
        #expect(buffer.preedit == "ni")
        #expect(buffer.insert("你") == [.type("你")])
        #expect(buffer.preedit == nil)
        #expect(buffer.text == "a你")
    }

    @Test func unmarkCommitsThePreedit() {
        var buffer = TypingBuffer(marksAsPreedit: true)
        _ = buffer.setMarked("かな", selectedRange: NSRange(location: 2, length: 0))
        #expect(buffer.unmark() == [.type("かな")])
        #expect(buffer.unmark() == [])
    }

    @Test func cancellingThePreeditSendsNothing() {
        var buffer = TypingBuffer(marksAsPreedit: true)
        _ = buffer.insert("x")
        _ = buffer.setMarked("ka", selectedRange: NSRange(location: 2, length: 0))
        #expect(buffer.setMarked("", selectedRange: NSRange(location: 0, length: 0)) == [])
        #expect(buffer.text == "x")
    }

    @Test func markingOverCommittedTextDeletesItRemotely() {
        var buffer = TypingBuffer(marksAsPreedit: true)
        _ = buffer.insert("abc")
        buffer.select(NSRange(location: 1, length: 2))
        #expect(buffer.setMarked("z", selectedRange: NSRange(location: 1, length: 0)) == [.backspace(2)])
        #expect(buffer.unmark() == [.type("z")])
    }
}
