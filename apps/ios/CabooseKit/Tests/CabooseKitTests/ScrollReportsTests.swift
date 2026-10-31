import CoreGraphics
import Foundation
import Testing
@testable import CabooseKit

struct ScrollReportsTests {
    static let tags: [(value: Int, blocks: String)] = {
        let url = DisplayVectorTests.directory.appendingPathComponent("scroll-tag/scroll-tag.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tags = json["tags"] as? [[String: Any]] else { return [] }
        return tags.compactMap { t in (t["value"] as? Int).flatMap { v in (t["blocks"] as? String).map { (v, $0) } } }
    }()

    static func luma(_ blocks: String) -> [Float] { blocks.map { $0 == "1" ? 235 : 16 } }

    @Test func decodesTheGoldenTags() {
        #expect(Self.tags.count == 5)
        for tag in Self.tags { #expect(ScrollTag.decode(Self.luma(tag.blocks)) == tag.value) }
    }

    @Test func rejectsWhatIsNotATag() {
        var flipped = Self.luma(Self.tags[2].blocks)
        flipped[12] = 251 - flipped[12]
        #expect(ScrollTag.decode(flipped) == nil)
        #expect(ScrollTag.decode([Float](repeating: 255, count: 32)) == nil)
        #expect(ScrollTag.decode([Float](repeating: 0, count: 31)) == nil)
    }

    static func tree(tag: Int, offset: CGFloat, applied: UInt64 = 0, epoch: UInt64 = 0) -> ScrollTree {
        ScrollTree(window: 7, tag: tag, tagRect: CGRect(x: 0, y: 2556, width: 384, height: 12), applied: applied, epoch: epoch,
                   scrollers: [ScrollTree.Scroller(id: 0, rect: CGRect(x: 0, y: 180, width: 1179, height: 4932),
                                                   offset: CGPoint(x: 0, y: offset), range: CGPoint(x: 0, y: 18_000),
                                                   fixed: [CGRect(x: 0, y: 180, width: 1179, height: 120), CGRect(x: 0, y: 2556, width: 384, height: 12)])])
    }

    static func blocks(_ value: Int) -> String {
        let check = (0 ..< 6).reduce(0) { $0 ^ ((value >> (4 * $1)) & 0xF) }
        let bits = (0 ..< 24).map { (value >> (23 - $0)) & 1 } + (0 ..< 4).map { (check >> (3 - $0)) & 1 }
        return "1010" + bits.map(String.init).joined()
    }

    @Test func placesAPictureByTheReportItsTagNames() throws {
        let reports = ScrollReports()
        reports.record(Self.tree(tag: 0x01_0001, offset: 1000))
        reports.record(Self.tree(tag: 0x01_0002, offset: 1037.25, epoch: 1))
        // A GPU picture at 0.55 of the window's pixels: 648 x 2808 for 1179 x 2556 shown + 2556 overscan.
        let picture = CGSize(width: 1179 * 0.55, height: 5112 * 0.55), shown = CGSize(width: 1179, height: 2556)
        let rect = try #require(reports.tagRect(picture: picture, shown: shown))
        #expect(abs(rect.minY - 2556 * 0.55) < 0.01 && abs(rect.width - 384 * 0.55) < 0.01)
        let older = try #require(reports.observation(luma: Self.luma(Self.blocks(0x01_0001)), picture: picture, shown: shown, axis: .vertical))
        guard case .reported(let offset, let region, let bounds, let stationary, let epoch) = older else { Issue.record("not reported"); return }
        #expect(abs(offset - 550) < 0.001 && epoch == 0)
        #expect(region.along == 99 ..< 2812 && region.across == 0 ..< 648)
        #expect(bounds == 0 ... 9900)
        #expect(stationary.count == 2)
        guard case .reported(let newer, _, _, _, let next)? = reports.observation(
            luma: Self.luma(Self.blocks(0x01_0002)), picture: picture, shown: shown, axis: .vertical) else { Issue.record("newer"); return }
        #expect(abs(newer - 1037.25 * 0.55) < 0.001 && next == 1)
        #expect(reports.observation(luma: Self.luma(Self.blocks(0x01_0009)), picture: picture, shown: shown, axis: .vertical) == nil)
        #expect(reports.observation(luma: nil, picture: picture, shown: shown, axis: .vertical) == nil)
    }

    @Test func predictsTheOffsetFromTargetsNotYetApplied() {
        let reports = ScrollReports()
        reports.record(Self.tree(tag: 1, offset: 500, applied: 3))
        reports.sent(seq: 4, delta: CGPoint(x: 0, y: 10))
        reports.sent(seq: 5, delta: CGPoint(x: 0, y: 12.5))
        #expect(reports.eventualOffset == CGPoint(x: 0, y: 522.5))
        // The picture that applied 4 already contains its 10 pixels: no double count.
        reports.record(Self.tree(tag: 2, offset: 510, applied: 4))
        #expect(reports.eventualOffset == CGPoint(x: 0, y: 522.5))
        reports.record(Self.tree(tag: 3, offset: 522.5, applied: 5))
        #expect(reports.eventualOffset == CGPoint(x: 0, y: 522.5) && reports.pending.isEmpty)
    }
}
