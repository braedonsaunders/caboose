import CoreGraphics
import Foundation
import Testing
@testable import CabooseKit

/// Home's Today: what came in while the owner was away, what Ask finds, tile shapes and
/// where the tabs sit.
struct HomeTodayTests {
    private let left = Date(timeIntervalSince1970: 1_000_000)

    private func task(_ id: String, _ status: String, after seconds: TimeInterval?, summary: String? = nil) -> HomeToday.AgentTask {
        HomeToday.AgentTask(id: id, title: "Task \(id)", agent: "Codex", status: status,
                            finishedAt: seconds.map { left.addingTimeInterval($0) }, summary: summary)
    }

    private func file(_ path: String, after seconds: TimeInterval) -> RecentFile {
        RecentFile(path: path, mtime: (left.timeIntervalSince1970 + seconds) * 1000)
    }

    @Test func onlyTurnsThatEndedAfterLeavingArrive() {
        let arrivals = HomeToday.arrivals(tasks: [
            task("a", "succeeded", after: 60),
            task("b", "succeeded", after: -60),
            task("c", "running", after: nil),
            task("d", "cancelled", after: 120),
            task("e", "failed", after: 30, summary: "\n  Ran out of disk  \nmore"),
        ], files: [], since: left, limit: 10)
        #expect(arrivals.map(\.id) == ["a", "e"])
        #expect(arrivals.map(\.kind) == [.agentSucceeded, .agentFailed])
        // The summary's first line, else the agent.
        #expect(arrivals.map(\.detail) == ["Codex", "Ran out of disk"])
    }

    @Test func filesArriveNewestFirstWithoutHiddenOnesAndAreCapped() {
        // As scanned: newest first.
        let files = [
            file(".config/app/state.json", after: 50),
            file("Downloads/report.pdf", after: 40),
            file("notes.md", after: 30),
            file("Documents/a.txt", after: 20),
            file("Documents/b.txt", after: 10),
            file("old.txt", after: -10),
        ]
        let arrivals = HomeToday.arrivals(tasks: [task("t", "succeeded", after: 35)], files: files,
                                          since: left, limit: 10, fileLimit: 3)
        #expect(arrivals.map(\.id) == ["Downloads/report.pdf", "t", "notes.md", "Documents/a.txt"])
        #expect(arrivals[0].title == "report.pdf" && arrivals[0].detail == "Downloads")
        #expect(arrivals[2].detail == "Home")
        #expect(HomeToday.arrivals(tasks: [], files: files, since: left, limit: 2).count == 2)
    }

    @Test func askMatchesWordStartsIgnoringCaseAndAccents() {
        let candidates = [
            HomeToday.Candidate(kind: .file, key: "Documents/Q3 Budget.ods", title: "Q3 Budget.ods", subtitle: "Documents"),
            HomeToday.Candidate(kind: .app, key: "libreoffice-calc", title: "LibreOffice Calc", subtitle: "Spreadsheet"),
            HomeToday.Candidate(kind: .window, key: "7", title: "Budget — Calc", subtitle: "LibreOffice Calc"),
            HomeToday.Candidate(kind: .app, key: "chromium", title: "Chromium", subtitle: "Web Browser"),
            HomeToday.Candidate(kind: .file, key: "Café.txt", title: "Café.txt", subtitle: "Home"),
        ]
        // A title starting with the query first; then all words in the title, windows first.
        #expect(HomeToday.find("budg", in: candidates, limit: 5).map(\.key) == ["7", "Documents/Q3 Budget.ods"])
        #expect(HomeToday.find("calc", in: candidates, limit: 5).map(\.key) == ["7", "libreoffice-calc"])
        // Words may come from the subtitle; all of them must match.
        #expect(HomeToday.find("web chr", in: candidates, limit: 5).map(\.key) == ["chromium"])
        #expect(HomeToday.find("web firefox", in: candidates, limit: 5).isEmpty)
        // Within a word is not a match; accents fold.
        #expect(HomeToday.find("udget", in: candidates, limit: 5).isEmpty)
        #expect(HomeToday.find("CAFE", in: candidates, limit: 5).map(\.key) == ["Café.txt"])
        #expect(HomeToday.find("  ", in: candidates, limit: 5).isEmpty)
        #expect(HomeToday.find("c", in: candidates, limit: 2).count == 2)
    }

    @Test func tilesKeepTheWindowsShapeWithinBounds() {
        #expect(HomeToday.tileSize(window: CGSize(width: 800, height: 600), height: 150) == CGSize(width: 200, height: 150))
        #expect(HomeToday.tileSize(window: CGSize(width: 3000, height: 600), height: 150).width == 225)
        #expect(HomeToday.tileSize(window: CGSize(width: 300, height: 1200), height: 150).width == 93)
        #expect(HomeToday.tileSize(window: .zero, height: 160) == CGSize(width: 120, height: 160))
    }

    @Test func tabsSitAtTheBottomRightWhereBarsAreHorizontal() {
        // An iPhone held upright, then on its side or a Duo opened out.
        #expect(HomeToday.tabPlacement(isPhone: true, hasVerticalBar: false, width: 402) == .cluster)
        #expect(HomeToday.tabPlacement(isPhone: true, hasVerticalBar: false, width: 760) == .sidebar)
        // The system's vertical bar already has them on the side; iPad keeps its own.
        #expect(HomeToday.tabPlacement(isPhone: true, hasVerticalBar: true, width: 760) == .system)
        #expect(HomeToday.tabPlacement(isPhone: false, hasVerticalBar: false, width: 1024) == .system)
    }
}
