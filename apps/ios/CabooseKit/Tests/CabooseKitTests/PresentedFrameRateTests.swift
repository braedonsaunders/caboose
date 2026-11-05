import Testing
@testable import CabooseKit

struct PresentedFrameRateTests {
    @Test func rateCountsPresentsOverTheSpan() {
        let rates = PresentedFrameRate()
        for frame in 0..<120 { rates.note(window: 7, at: 100 + Double(frame) / 60) }
        let rate = rates.rate(window: 7, at: 102)
        #expect(rate.map { abs($0 - 60) <= 1 } == true)
        #expect(rates.rate(window: 8, at: 102) == nil)
    }

    @Test func aWindowThatStoppedHasNoRate() {
        let rates = PresentedFrameRate()
        rates.note(window: 3, at: 10)
        #expect(rates.rate(window: 3, at: 11) == 0.5)
        #expect(rates.rate(window: 3, at: 20) == nil)
    }

    @Test func frontmostSkipsWindowsThatDoNotPresent() {
        let rates = PresentedFrameRate()
        for frame in 0..<20 { rates.note(window: 2, at: 50 + Double(frame) / 10) }
        #expect(rates.frontmost([9, 2, 1], at: 52)?.window == 2)
        #expect(rates.frontmost([9], at: 52) == nil)
    }
}
