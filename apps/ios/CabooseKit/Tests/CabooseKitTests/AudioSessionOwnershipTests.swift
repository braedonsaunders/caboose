import Testing
@testable import CabooseKit

struct AudioSessionOwnershipTests {
    @Test func olderReleasePreservesNewOwner() {
        var session = AudioSessionOwnership("playback")
        let mic = session.acquire("mic")
        let dictation = session.acquire("dictation")
        let changed = session.release(mic)
        #expect(!changed)
        #expect(session.current == "dictation")
        let restored = session.release(dictation)
        #expect(restored)
        #expect(session.current == "playback")
    }
    @Test func identicalConfigurationStillRetiresOldLease() {
        var session = AudioSessionOwnership("playback")
        let mic = session.acquire("mic")
        session.replace("mic")
        #expect(!session.contains(mic))
        let changed = session.release(mic)
        #expect(!changed)
        #expect(session.current == "mic")
    }
    @Test func newestReleaseRestoresRemainingOwner() {
        var session = AudioSessionOwnership("playback")
        let mic = session.acquire("mic")
        let dictation = session.acquire("dictation")
        #expect(!session.contains(mic))
        let restored = session.release(dictation)
        #expect(restored)
        #expect(session.contains(mic))
        #expect(session.current == "mic")
    }
}
