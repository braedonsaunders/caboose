import XCTest
@testable import CabooseKit

final class ChatArtifactTests: XCTestCase {
    func testActualGeneratedFilesMapToAuthenticatedHomePaths() {
        let path = "Agents/f0868e2a-8127-44dc-8eeb-05f351c9c3b0/artifacts/xeqt-snapshot.pdf"
        for input in [path, "/home/caboose/" + path, "file:///home/caboose/" + path, "~/" + path] {
            XCTAssertEqual(ChatArtifactPolicy.guestPath(input), path)
        }
        XCTAssertEqual(ChatArtifactPolicy.guestPath("/home/caboose/My%20Files/report%23one.pdf"), "My Files/report#one.pdf")
        XCTAssertTrue(ChatArtifactPolicy.isImage("artifacts/chart.PNG"))
        XCTAssertFalse(ChatArtifactPolicy.isImage("artifacts/chart.svg"))
        XCTAssertTrue(ChatArtifactPolicy.canQuickLook("report.pdf"))
        XCTAssertFalse(ChatArtifactPolicy.canQuickLook("widget.html"))
        XCTAssertFalse(ChatArtifactPolicy.canQuickLook("script.js"))
        XCTAssertEqual(ChatMarkdown.blocks("![XEQT performance and fund snapshot](/home/caboose/Agents/task/artifacts/xeqt-snapshot.png)"), [
            .image(alt: "XEQT performance and fund snapshot", destination: "/home/caboose/Agents/task/artifacts/xeqt-snapshot.png")
        ])
    }

    func testUnsafePathsNeverBecomeLocalFilesOrServiceRequests() {
        for path in ["", "/etc/passwd", "/home/caboose-other/a", "file:///etc/passwd", "file://server/home/caboose/a", "https://example.com/a", "javascript:alert(1)", "//server/a", "../a", "./a", "a/../b", "a/%2e%2e/b", "a/%2Fb", "a\\b", "a/%00b", "a/%0Ab", "a//b", "a/", "a?token=x", "a#fragment", ".caboose-upload-secret"] {
            XCTAssertNil(ChatArtifactPolicy.guestPath(path), path)
        }
        XCTAssertNil(ChatArtifactPolicy.guestPath(String(repeating: "a", count: 8193)))
    }

    func testOnlyCompleteExplicitHTMLFencesExecute() {
        let html = "<button onclick='this.textContent=42'>Calculate</button>"
        for language in ["html", "inline-html", "HTML"] {
            XCTAssertEqual(ChatMarkdown.blocks("```\(language)\n\(html)\n```"), [.html(html)])
            XCTAssertEqual(ChatMarkdown.blocks("```\(language)\n\(html)"), [.code(language: language, text: html)])
        }
        XCTAssertEqual(ChatMarkdown.blocks("````html\n```\n````"), [.html("```")])
        XCTAssertEqual(ChatMarkdown.blocks("```js\nalert(1)\n```"), [.code(language: "js", text: "alert(1)")])
        let large = String(repeating: "é", count: ChatArtifactPolicy.maximumHTMLBytes / 2 + 1)
        XCTAssertEqual(ChatMarkdown.blocks("```html\n\(large)\n```"), [.code(language: "html", text: large)])
    }

    func testSandboxWrapEscapesAgentMarkupAndBoundsCompose() {
        let document = ChatArtifactPolicy.htmlDocument("</iframe><script>fetch('https://example.com')</script>")
        XCTAssertTrue(document.contains("sandbox=\"allow-scripts\""))
        XCTAssertFalse(document.contains("allow-same-origin"))
        XCTAssertTrue(document.contains("&lt;/iframe&gt;"))
        XCTAssertFalse(document.contains("</iframe><script>fetch"))
        XCTAssertTrue(document.contains("connect-src 'none'"))
        XCTAssertTrue(document.contains("form-action 'none'"))
        XCTAssertTrue(document.contains("navigator.userActivation.isActive"))
        XCTAssertNil(ChatArtifactPolicy.proposedMessage(" \n"))
        XCTAssertNil(ChatArtifactPolicy.proposedMessage(String(repeating: "x", count: 32_001)))
        XCTAssertEqual(ChatArtifactPolicy.proposedMessage("Explain this chart"), "Explain this chart")
    }
}
