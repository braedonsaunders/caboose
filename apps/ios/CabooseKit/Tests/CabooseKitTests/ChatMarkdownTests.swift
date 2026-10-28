import XCTest
@testable import CabooseKit

final class ChatMarkdownTests: XCTestCase {
    func testRichAnswerKeepsCodeLiteralAndListsOrdered() {
        let input = "# Result\n\nRead **this** [file](https://example.com).\nNext line.\n\n1. First\n2) Second\n- Third\n> A quote\n---\n```swift\n# literal\n- code\n```"
        XCTAssertEqual(ChatMarkdown.blocks(input), [
            .heading(1, "Result"), .paragraph("Read **this** [file](https://example.com).\nNext line."),
            .list(marker: "1.", text: "First"), .list(marker: "2)", text: "Second"), .list(marker: "•", text: "Third"),
            .quote("A quote"), .divider, .code(language: "swift", text: "# literal\n- code")
        ])
    }

    func testStreamingFenceDoesNotReformatCodeAsProse() {
        XCTAssertEqual(ChatMarkdown.blocks("Working…\n\n```js\nconst x = 1\n"), [
            .paragraph("Working…"), .code(language: "js", text: "const x = 1\n")
        ])
        XCTAssertEqual(ChatMarkdown.blocks("~~~~\n```\n~~~~\nDone"), [.code(language: "", text: "```"), .paragraph("Done")])
    }
}
