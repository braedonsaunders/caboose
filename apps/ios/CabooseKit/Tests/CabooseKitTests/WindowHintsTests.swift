import Foundation
import Testing
@testable import CabooseKit

@MainActor @Suite struct WindowHintsTests {
    @Test func contentTypePicksARefreshRangeThatSuitsIt() {
        let ranges = Dictionary(uniqueKeysWithValues: [WindowContentType.none, .photo, .video, .game].map { ($0, FrameRatePolicy.range(for: $0)) })
        #expect(ranges[.none] == FrameRatePolicy.Range(minimum: 30, maximum: 120, preferred: 120))
        // A game is never held below 60, a video never above 60, a photo needs little.
        #expect(ranges[.game]!.minimum >= 60 && ranges[.game]!.preferred == 120)
        #expect(ranges[.video]!.maximum == 60 && ranges[.video]!.minimum <= 24)
        #expect(ranges[.photo]!.maximum <= 30)
        for range in ranges.values { #expect(range.minimum <= range.preferred && range.preferred <= range.maximum) }
    }

    @Test func theScreenStaysAwakeWhileAnyShownWindowInhibitsIdle() {
        var applied: [Bool] = []
        let inhibition = IdleInhibition { applied.append($0) }
        let a = NSObject(), b = NSObject()
        inhibition.set(a, inhibiting: false)
        #expect(applied.isEmpty)
        inhibition.set(a, inhibiting: true)
        inhibition.set(a, inhibiting: true)
        inhibition.set(b, inhibiting: true)
        #expect(applied == [true])
        inhibition.set(a, inhibiting: false)
        #expect(applied == [true])
        inhibition.set(b, inhibiting: false)
        #expect(applied == [true, false])
    }
}
