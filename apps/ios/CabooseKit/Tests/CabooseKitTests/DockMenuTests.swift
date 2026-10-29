import Testing
@testable import CabooseKit

/// A held dock app always offers something real to do.
struct DockMenuTests {
    @Test func anAppThatIsNotRunningOpensAndPins() {
        #expect(DockMenu.actions(appName: "Firefox", pinned: false, windows: []) == [.open, .pin])
        #expect(DockMenu.actions(appName: "Firefox", pinned: true, windows: []) == [.open, .unpin])
    }

    @Test func eachRunningWindowCanBeClosedByName() {
        let actions = DockMenu.actions(appName: "Terminal", pinned: true, windows: [
            .init(id: 4, title: "~/src — bash"), .init(id: 9, title: ""),
        ])
        #expect(actions == [.open, .unpin, .close(window: 4, title: "~/src — bash"), .close(window: 9, title: "Terminal")])
        #expect(actions.map(\.title) == ["Open", "Unpin", "Close ~/src — bash", "Close Terminal"])
    }
}
