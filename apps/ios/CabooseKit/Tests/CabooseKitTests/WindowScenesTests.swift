import CoreGraphics
import Foundation
import Testing
@testable import CabooseKit

/// A Linux window in an iPadOS window of its own: how it is named across reconnects, which
/// windows the in-app desktop leaves to its scene, and the sizes the scene may take.
struct WindowScenesTests {
    private func ref(_ window: Int = 7, computer: String = "computer-a", epoch: String = "e1",
                     title: String = "") -> LinuxWindowRef {
        LinuxWindowRef(computer: computer, epoch: epoch, window: window, title: title)!
    }

    @Test func aWindowIsNamedOnlyWithAComputerAndAnEpoch() {
        #expect(LinuxWindowRef(computer: "computer-a", epoch: nil, window: 1) == nil)
        #expect(LinuxWindowRef(computer: nil, epoch: "e1", window: 1) == nil)
        #expect(LinuxWindowRef(computer: "", epoch: "e1", window: 1) == nil)
        #expect(LinuxWindowRef(computer: "computer-a", epoch: "", window: 1) == nil)
        #expect(LinuxWindowRef(computer: "computer-a", epoch: "e1", window: 1) != nil)
    }

    @Test func theTitleDoesNotChangeWhichWindowItIs() {
        let first = ref(title: "main.swift — Code")
        let renamed = ref(title: "README.md — Code")
        #expect(first == renamed)
        #expect(Set([first, renamed]).count == 1)
        #expect(ref(8) != first)
        #expect(ref(epoch: "e2") != first)
        #expect(ref(computer: "computer-b") != first)
        #expect(ref(title: "").name == "Window")
        #expect(LinuxWindowRef(computer: "c", epoch: "e", window: 1, app: "Code")!.name == "Code")
        #expect(first.name == "main.swift — Code")
    }

    @Test func itSurvivesStateRestorationAndADrag() throws {
        let original = ref(title: "Notes")
        let restored = try JSONDecoder().decode(LinuxWindowRef.self, from: JSONEncoder().encode(original))
        #expect(restored == original)
        #expect(restored.title == "Notes")
        let dropped = LinuxWindowRef(activityUserInfo: original.activityUserInfo)
        #expect(dropped == original)
        #expect(dropped?.title == "Notes")
        #expect(LinuxWindowRef(activityUserInfo: nil) == nil)
        #expect(LinuxWindowRef(activityUserInfo: ["window": Data("{}".utf8)]) == nil)
        let blankEpoch = Data(#"{"computer":"c","epoch":"","window":1,"title":"","app":""}"#.utf8)
        #expect(LinuxWindowRef(activityUserInfo: ["window": blankEpoch]) == nil)
    }

    @Test func theWindowIsPresentInItsOwnEpochEvenWhileReconnecting() {
        let window = ref()
        #expect(window.presence(computer: "computer-a", epoch: "e1", ready: true, announced: true, windowExists: true) == .present)
        // Kept through a lost connection: the same window, still shown.
        #expect(window.presence(computer: "computer-a", epoch: "e1", ready: false, announced: true, windowExists: true) == .present)
        // The same id in another server lifetime is another window.
        #expect(window.presence(computer: "computer-a", epoch: "e2", ready: true, announced: true, windowExists: true) == .gone)
    }

    @Test func absenceCountsOnlyOnceTheServerHasAnnouncedEverything() {
        let window = ref()
        // In the background, parked, waking, or a new connection still announcing.
        #expect(window.presence(computer: "computer-a", epoch: nil, ready: false, announced: false, windowExists: false) == .waiting)
        #expect(window.presence(computer: "computer-a", epoch: "e1", ready: false, announced: true, windowExists: false) == .waiting)
        #expect(window.presence(computer: "computer-a", epoch: "e1", ready: true, announced: false, windowExists: false) == .waiting)
        // Closed on the computer, or gone with a restart.
        #expect(window.presence(computer: "computer-a", epoch: "e1", ready: true, announced: true, windowExists: false) == .gone)
        #expect(window.presence(computer: "computer-a", epoch: "e2", ready: true, announced: false, windowExists: false) == .gone)
        #expect(window.presence(computer: "computer-a", epoch: nil, ready: true, announced: false, windowExists: false) == .gone)
    }

    @Test func anotherComputerOrSigningOutEndsIt() {
        let window = ref()
        #expect(window.presence(computer: "computer-b", epoch: "e1", ready: true, announced: true, windowExists: true) == .otherComputer)
        #expect(window.presence(computer: nil, epoch: nil, ready: false, announced: false, windowExists: false) == .otherComputer)
    }

    @Test func oneSceneShowsAWindowAndReleasingReturnsIt() {
        var detached = DetachedWindows()
        #expect(detached.claim(ref(7), scene: "s1") == nil)
        // A second scene for the same window leaves it with the first.
        #expect(detached.claim(ref(7, title: "renamed"), scene: "s2") == "s1")
        #expect(detached.claims["s2"] == nil)
        // Claiming again from the same scene is not a conflict.
        #expect(detached.claim(ref(7), scene: "s1") == nil)
        #expect(detached.claim(ref(9), scene: "s2") == nil)
        #expect(detached.windows(computer: "computer-a", epoch: "e1") == [7, 9])
        #expect(detached.scene(showing: 9, computer: "computer-a", epoch: "e1") == "s2")
        detached.release(scene: "s1")
        #expect(detached.windows(computer: "computer-a", epoch: "e1") == [9])
        #expect(detached.scene(showing: 7, computer: "computer-a", epoch: "e1") == nil)
        #expect(detached.claim(ref(7), scene: "s3") == nil)
    }

    @Test func heldWindowsAreScopedToTheirComputerAndEpoch() {
        var detached = DetachedWindows()
        detached.claim(ref(7), scene: "s1")
        detached.claim(ref(7, epoch: "e0"), scene: "restored")
        detached.claim(ref(3, computer: "computer-b"), scene: "other")
        #expect(detached.windows(computer: "computer-a", epoch: "e1") == [7])
        #expect(detached.windows(computer: "computer-a", epoch: "e2").isEmpty)
        #expect(detached.windows(computer: nil, epoch: nil).isEmpty)
        #expect(detached.scene(showing: 7, computer: "computer-a", epoch: "e1") == "s1")
        #expect(detached.scene(showing: 3, computer: "computer-a", epoch: "e1") == nil)
    }

    @Test func menusAndDialogsGoWithTheirWindow() {
        // 7 is held; 20 is its dialog, 21 a menu of that dialog, 30 another window's menu,
        // 40 a popup without a parent, and 50/51 a transient cycle that must not hang.
        let parents = [20: 7, 21: 20, 30: 8, 50: 51, 51: 50]
        #expect(DetachedWindows.withDescendants([7], parents: parents) == [7, 20, 21])
        #expect(DetachedWindows.withDescendants([], parents: parents).isEmpty)
        #expect(DetachedWindows.withDescendants([7, 8], parents: parents) == [7, 8, 20, 21, 30])
    }

    @Test func linuxSizeHintsBecomeTheWindowsSizeRestrictions() {
        let chrome = CGSize(width: 0, height: 50)
        let limits = SceneSizeLimits.limits(minimum: CGSize(width: 801, height: 600), maximum: CGSize(width: 2001, height: 1600),
                                            pixelsPerPoint: 2, chrome: chrome)
        #expect(limits.minimum == CGSize(width: 401, height: 350))
        #expect(limits.maximum == CGSize(width: 1000, height: 850))
    }

    @Test func missingOrZeroSidesAreNoLimit() {
        let none = SceneSizeLimits.limits(minimum: nil, maximum: nil, pixelsPerPoint: 2, chrome: CGSize(width: 0, height: 50))
        #expect(none.minimum == .zero)
        #expect(none.maximum == CGSize(width: SceneSizeLimits.unbounded, height: SceneSizeLimits.unbounded))
        let widthOnly = SceneSizeLimits.limits(minimum: CGSize(width: 400, height: 0), maximum: CGSize(width: 0, height: 900),
                                               pixelsPerPoint: 2, chrome: .zero)
        #expect(widthOnly.minimum == CGSize(width: 200, height: 0))
        #expect(widthOnly.maximum == CGSize(width: SceneSizeLimits.unbounded, height: 450))
    }

    @Test func aMaximumBelowTheMinimumIsRaisedToIt() {
        let fixed = SceneSizeLimits.limits(minimum: CGSize(width: 900, height: 700), maximum: CGSize(width: 600, height: 700),
                                           pixelsPerPoint: 2, chrome: CGSize(width: 0, height: 40))
        #expect(fixed.minimum == CGSize(width: 450, height: 390))
        #expect(fixed.maximum == CGSize(width: 450, height: 390))
        let invalid = SceneSizeLimits.limits(minimum: CGSize(width: 100, height: 100), maximum: nil, pixelsPerPoint: 0, chrome: .zero)
        #expect(invalid.minimum == .zero)
    }
}
