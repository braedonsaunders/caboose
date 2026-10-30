import Foundation
import XCTest
@testable import CabooseKit

final class DesktopNoticeTests: XCTestCase {
    private let id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    func testDecodesTheControlEventWithActionsAndReply() throws {
        let event = #"{"type":"notification","id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","app":"Signal","summary":"Ada","body":"Lunch?","created":1,"desktopEntry":"org.signal.Signal","actions":[{"key":"read","label":"Mark as Read"}],"defaultAction":true,"reply":{"label":"Reply","placeholder":"Message Ada"}}"#
        let notice = try DesktopNotice(event: Data(event.utf8))
        XCTAssertEqual(notice, DesktopNotice(id: id, app: "Signal", summary: "Ada", body: "Lunch?", desktopEntry: "org.signal.Signal",
                                             actions: [.init(key: "read", label: "Mark as Read")], defaultAction: true,
                                             reply: .init(label: "Reply", placeholder: "Message Ada")))
        XCTAssertEqual(notice.title, "Ada")
        XCTAssertEqual(notice.userInfo["notificationId"] as? String, id)
        XCTAssertEqual(notice.userInfo["desktopEntry"] as? String, "org.signal.Signal")
        XCTAssertEqual(notice.userInfo["defaultAction"] as? Bool, true)
    }

    func testOlderEventsHaveNoActionsAndInvalidIDsAreRejected() throws {
        let notice = try DesktopNotice(event: Data(#"{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","app":"Editor","summary":"","body":"Saved","desktopEntry":null,"reply":null}"#.utf8))
        XCTAssertEqual(notice, DesktopNotice(id: id, app: "Editor", summary: "", body: "Saved"))
        XCTAssertEqual(notice.title, "Editor")
        XCTAssertNil(notice.category)
        XCTAssertEqual(notice.userInfo.count, 1)
        XCTAssertThrowsError(try DesktopNotice(event: Data(#"{"id":"../x","app":"","summary":"","body":""}"#.utf8)))
        XCTAssertThrowsError(try DesktopNotice(event: Data(#"{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","defaultAction":"yes"}"#.utf8)))
    }

    func testKeepsAtMostFourLabelledButtons() throws {
        let actions = (0 ..< 6).map { n -> String in
            let label = n == 1 ? "" : "L\(n)"
            return "{\"key\":\"k\(n)\",\"label\":\"\(label)\"}"
        }
        let event = "{\"id\":\"\(id)\",\"actions\":[" + actions.joined(separator: ",") + "]}"
        let notice = try DesktopNotice(event: Data(event.utf8))
        XCTAssertEqual(notice.actions.map(\.key), ["k0", "k2", "k3", "k4"])
    }

    func testCategoriesAreStableAndDistinguishKeysLabelsAndReplies() {
        let read = DesktopNotificationCategory(actions: [.init(key: "read", label: "Read")], reply: nil)
        XCTAssertEqual(read.identifier, DesktopNotificationCategory(actions: [.init(key: "read", label: "Read")], reply: nil).identifier)
        XCTAssertTrue(read.identifier.hasPrefix("DESKTOP."))
        XCTAssertEqual(read.identifier.count, "DESKTOP.".count + 16)
        let identifiers: Set<String> = [
            read.identifier,
            DesktopNotificationCategory(actions: [.init(key: "0", label: "Read")], reply: nil).identifier,
            DesktopNotificationCategory(actions: [.init(key: "read", label: "Mark")], reply: nil).identifier,
            DesktopNotificationCategory(actions: [.init(key: "read", label: "Read")], reply: .init(label: "", placeholder: "")).identifier,
            DesktopNotificationCategory(actions: [], reply: .init(label: "", placeholder: "Message")).identifier,
        ]
        XCTAssertEqual(identifiers.count, 5)
        XCTAssertEqual(DesktopNotificationCategory(actions: [], reply: .init(label: "", placeholder: "")).replyTitle, "Reply")
        XCTAssertEqual(DesktopNotificationCategory(actions: [], reply: .init(label: "Answer", placeholder: "")).replyTitle, "Answer")
    }

    func testRecentCategoriesAreBoundedAndReportOnlyNewOnes() {
        var recent = DesktopNotificationCategories()
        let categories = (0 ..< 4).map { DesktopNotificationCategory(actions: [.init(key: "k\($0)", label: "L")], reply: nil) }
        XCTAssertTrue(recent.use(categories[0], limit: 3))
        XCTAssertTrue(recent.use(categories[1], limit: 3))
        XCTAssertFalse(recent.use(categories[0], limit: 3))
        XCTAssertEqual(recent.recent, [categories[1], categories[0]])
        XCTAssertTrue(recent.use(categories[2], limit: 3))
        XCTAssertTrue(recent.use(categories[3], limit: 3))
        XCTAssertEqual(recent.recent, [categories[0], categories[2], categories[3]])
        let saved = try? JSONDecoder().decode(DesktopNotificationCategories.self, from: JSONEncoder().encode(recent))
        XCTAssertEqual(saved, recent)
    }

    func testAnswersFromResponses() {
        let open = "com.apple.UNNotificationDefaultActionIdentifier"
        XCTAssertEqual(DesktopNotificationAnswer(actionIdentifier: open, userText: nil, openIdentifier: open), .open)
        XCTAssertEqual(DesktopNotificationAnswer(actionIdentifier: "ACTION:read", userText: nil, openIdentifier: open), .action("read"))
        XCTAssertEqual(DesktopNotificationAnswer(actionIdentifier: "REPLY", userText: "  On my way\n", openIdentifier: open), .reply("On my way"))
        XCTAssertNil(DesktopNotificationAnswer(actionIdentifier: "REPLY", userText: " ", openIdentifier: open))
        XCTAssertNil(DesktopNotificationAnswer(actionIdentifier: "ACTION:", userText: nil, openIdentifier: open))
        XCTAssertNil(DesktopNotificationAnswer(actionIdentifier: "com.apple.UNNotificationDismissActionIdentifier", userText: nil, openIdentifier: open))
        XCTAssertNil(DesktopNotificationAnswer(actionIdentifier: "ALLOW", userText: nil, openIdentifier: open))
        let requests = [DesktopNotificationAnswer.open, .action("read"), .reply("Hi")].map { [$0.request.field, $0.request.value] }
        XCTAssertEqual(requests, [["action", "default"], ["action", "read"], ["reply", "Hi"]])
    }

    func testDesktopEntryMatchesAnInstalledAppByID() {
        let ids = ["firefox-esr.desktop", "org.signal.Signal.desktop", "thunderbird.desktop"]
        XCTAssertEqual(DesktopEntryMatch.appID(for: "org.signal.Signal", among: ids), "org.signal.Signal.desktop")
        XCTAssertEqual(DesktopEntryMatch.appID(for: "Thunderbird.desktop", among: ids), "thunderbird.desktop")
        XCTAssertNil(DesktopEntryMatch.appID(for: "signal", among: ids))
        XCTAssertNil(DesktopEntryMatch.appID(for: "", among: ids))
    }

    func testDesktopPushRoutingFields() throws {
        let data = Data(#"{"aps":{"alert":{"title":"Ada"},"category":"DESKTOP_REPLY"},"notificationId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","desktopEntry":"org.signal.Signal","defaultAction":true}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PushPayload.self, from: data),
                       PushPayload(notificationId: id, desktopEntry: "org.signal.Signal", defaultAction: true))
    }
}
