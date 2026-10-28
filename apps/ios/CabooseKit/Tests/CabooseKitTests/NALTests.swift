import Foundation
import Testing
@testable import CabooseKit

@Suite struct NALTests {
    @Test func classifiesHEVCUnits() {
        // Two-byte HEVC NAL headers: type is bits 1–6 of the first byte.
        #expect(AnnexB.hevcType(of: Data([0x40, 0x01])) == 32) // VPS
        #expect(AnnexB.hevcType(of: Data([0x42, 0x01])) == 33) // SPS
        #expect(AnnexB.hevcType(of: Data([0x44, 0x01])) == 34) // PPS
        #expect(AnnexB.hevcType(of: Data([0x26, 0x01])) == 19) // IDR_W_RADL
        #expect(AnnexB.hevcType(of: Data([0x02, 0x01])) == 1)  // TRAIL_R
    }

    @Test func splitsAnnexBWithThreeAndFourByteStartCodes() {
        let stream = Data([0, 0, 0, 1, 0x40, 0x01, 0xAA, 0, 0, 1, 0x42, 0x01, 0xBB])
        #expect(AnnexB.nalUnits(in: stream) == [Data([0x40, 0x01, 0xAA]), Data([0x42, 0x01, 0xBB])])
    }
}
