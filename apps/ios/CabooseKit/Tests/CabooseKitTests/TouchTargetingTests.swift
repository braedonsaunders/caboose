import Foundation
import Testing
@testable import CabooseKit

@Suite struct TouchTargetingTests {
    func target(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ kind: TouchTarget.Kind = .button,
                enabled: Bool = true) -> TouchTarget {
        TouchTarget(rect: CGRect(x: x, y: y, width: w, height: h), kind: kind, enabled: enabled)
    }

    @Test func wireFormCarriesKindAndDisabledBit() {
        #expect(TouchTarget(wire: [1, 2, 3, 4, 2]) == target(1, 2, 3, 4, .toggle))
        #expect(TouchTarget(wire: [1, 2, 3, 4, 0x83]) == target(1, 2, 3, 4, .link, enabled: false))
        #expect(TouchTarget(wire: [1, 2, 0, 4, 1]) == nil)
        #expect(TouchTarget(wire: [1, 2, 3]) == nil)
        #expect(TouchTarget(wire: [1, 2, 3, 4, 300]) == nil)
    }

    @Test func aTouchJustOffASmallButtonPressesItsMiddle() {
        let choice = TouchAim.choose(CGPoint(x: 112, y: 50), spread: 8, among: [target(90, 40, 16, 16)])
        #expect(choice?.index == 0)
        let point = try! #require(choice?.point)
        #expect(CGRect(x: 90, y: 40, width: 16, height: 16).insetBy(dx: 4, dy: 4).contains(point))
    }

    @Test func aTouchOnATargetStaysWhereItIs() {
        let choice = TouchAim.choose(CGPoint(x: 15, y: 12), spread: 8, among: [target(0, 0, 300, 24, .field)])
        #expect(choice == TouchAim.Choice(index: 0, point: CGPoint(x: 15, y: 12)))
    }

    @Test func farFromEveryTargetTheTouchIsLeftAlone() {
        #expect(TouchAim.choose(CGPoint(x: 200, y: 200), spread: 8, among: [target(0, 0, 16, 16)]) == nil)
        #expect(TouchAim.choose(CGPoint(x: 200, y: 200), spread: 8, among: []) == nil)
    }

    @Test func theNearerOfTwoEqualNeighboursWins() {
        let row = [target(0, 0, 20, 20), target(22, 0, 20, 20)]
        #expect(TouchAim.choose(CGPoint(x: 19, y: 10), spread: 10, among: row)?.index == 0)
        #expect(TouchAim.choose(CGPoint(x: 23, y: 10), spread: 10, among: row)?.index == 1)
    }

    @Test func aSmallControlBesideTheFingerBeatsTheRowItSitsIn() {
        let row = target(0, 0, 600, 24, .item)
        let check = target(4, 4, 16, 16, .toggle)
        #expect(TouchAim.choose(CGPoint(x: 24, y: 12), spread: 8, among: [row, check])?.index == 1)
        #expect(TouchAim.choose(CGPoint(x: 300, y: 12), spread: 8, among: [row, check])?.index == 0)
    }

    @Test func aDisabledControlKeepsItsTouchesWithoutTakingThem() {
        let pair = [target(0, 0, 20, 20, enabled: false), target(26, 0, 20, 20)]
        #expect(TouchAim.choose(CGPoint(x: 12, y: 10), spread: 8, among: pair) == nil)
        #expect(TouchAim.choose(CGPoint(x: 30, y: 10), spread: 8, among: pair)?.index == 1)
    }

    @Test func degenerateInputsPressWhereTheFingerIs() {
        let one = [target(0, 0, 20, 20)]
        #expect(TouchAim.choose(CGPoint(x: 10, y: 10), spread: 0, among: one) == nil)
        #expect(TouchAim.choose(CGPoint(x: CGFloat.nan, y: 10), spread: 8, among: one) == nil)
    }
}
