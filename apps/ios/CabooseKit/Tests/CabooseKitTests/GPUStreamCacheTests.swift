import Foundation
import Testing
@testable import CabooseKit

/// The device's copy of GPU streams (docs/gpu-stream.md, "The device's copy"): keyed by server
/// epoch, stream id and nonce, trusted only as far as its record says, bounded per stream and in
/// total with the least recently used streams removed first, and cleared.
@Suite struct GPUStreamCacheTests {
    func makeCache(budget: UInt64 = 1 << 20, streamLimit: UInt64 = 1 << 20, commitInterval: UInt64 = 1) -> GPUStreamCache {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GPUStreamCacheTests-\(UUID().uuidString)")
        return GPUStreamCache(directory: directory, budget: budget, streamLimit: streamLimit, commitInterval: commitInterval)
    }

    func bytes(_ count: Int, from start: Int = 0) -> Data {
        Data((start ..< start + count).map { UInt8(truncatingIfNeeded: $0) })
    }

    func exists(_ cache: GPUStreamCache, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: cache.directory.appendingPathComponent(path).path)
    }

    @Test func aStreamIsKeptUnderItsEpochAndIdForTheSameStreamOnly() throws {
        let cache = makeCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let stream = try #require(cache.open(epoch: "5f3a9c01d2e4b678", id: 1, nonce: "8c41d07e2b9fa365"))
        #expect(stream.cached == 0)
        stream.write(bytes(10), at: 0)
        stream.close()
        #expect(exists(cache, "5f3a9c01d2e4b678/1") && exists(cache, "5f3a9c01d2e4b678/1.json"))
        let again = try #require(cache.open(epoch: "5f3a9c01d2e4b678", id: 1, nonce: "8c41d07e2b9fa365"))
        #expect(again.cached == 10)
        #expect(try Data(contentsOf: again.dataURL) == bytes(10))
        again.close()
        // The same id for another stream (a relaunched application) finds nothing, and the old
        // copy goes.
        let other = try #require(cache.open(epoch: "5f3a9c01d2e4b678", id: 1, nonce: "0123456789abcdef"))
        #expect(other.cached == 0)
        other.close()
        let first = try #require(cache.open(epoch: "5f3a9c01d2e4b678", id: 1, nonce: "8c41d07e2b9fa365"))
        #expect(first.cached == 0)
        first.close()
        // Another server process's stream of that id is another stream.
        let elsewhere = try #require(cache.open(epoch: "0000000000000001", id: 1, nonce: "8c41d07e2b9fa365"))
        #expect(elsewhere.cached == 0)
        elsewhere.close()
        // An epoch that is not a plain name is not cached.
        #expect(cache.open(epoch: "../x", id: 1, nonce: "8c41d07e2b9fa365") == nil)
        #expect(cache.open(epoch: "", id: 1, nonce: "8c41d07e2b9fa365") == nil)
    }

    /// Bytes written past the record (the app stopped before recording them) are not used, and a
    /// record that claims more than the data holds discards the stream.
    @Test func onlyRecordedBytesAreTrusted() throws {
        let cache = makeCache(commitInterval: 1 << 20)
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let stream = try #require(cache.open(epoch: "e1", id: 3, nonce: "n3"))
        stream.write(bytes(100), at: 0)
        // Not yet recorded: a new open would find nothing.
        #expect(stream.recordedLength == 0)
        stream.close()
        let data = cache.directory.appendingPathComponent("e1/3")
        let handle = try FileHandle(forWritingTo: data)
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes(50, from: 100))
        try handle.close()
        let reopened = try #require(cache.open(epoch: "e1", id: 3, nonce: "n3"))
        #expect(reopened.cached == 100)
        #expect(try Data(contentsOf: data) == bytes(100))
        reopened.close()
        let shrink = try FileHandle(forWritingTo: data)
        try shrink.truncate(atOffset: 40)
        try shrink.close()
        let short = try #require(cache.open(epoch: "e1", id: 3, nonce: "n3"))
        #expect(short.cached == 0)
        short.close()
    }

    /// A stream stops being kept at its limit, or at a gap, with what it recorded kept.
    @Test func aStreamStopsAtItsLimitOrAGap() throws {
        let cache = makeCache(streamLimit: 64)
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let stream = try #require(cache.open(epoch: "e1", id: 1, nonce: "n1"))
        stream.write(bytes(40), at: 0)
        // Bytes already kept are the same bytes again.
        stream.write(bytes(20, from: 20), at: 20)
        #expect(stream.isKeeping && stream.recordedLength == 40)
        stream.write(bytes(40, from: 40), at: 40)
        #expect(!stream.isKeeping)
        stream.close()
        let again = try #require(cache.open(epoch: "e1", id: 1, nonce: "n1"))
        #expect(again.cached == 40)
        again.write(bytes(4, from: 50), at: 50)
        #expect(!again.isKeeping)
        again.close()
        #expect(try #require(cache.open(epoch: "e1", id: 1, nonce: "n1")).cached == 40)
    }

    /// Over the budget, the least recently used streams go first; an open stream is never taken
    /// for another, which then stops being kept instead.
    @Test func theLeastRecentlyUsedStreamsMakeRoom() throws {
        let cache = makeCache(budget: 100)
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let old = try #require(cache.open(epoch: "e1", id: 1, nonce: "n1"))
        old.write(bytes(60), at: 0)
        old.close()
        let recent = try #require(cache.open(epoch: "e1", id: 2, nonce: "n2"))
        recent.write(bytes(30), at: 0)
        recent.close()
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)],
                                              ofItemAtPath: cache.directory.appendingPathComponent("e1/1").path)
        let new = try #require(cache.open(epoch: "e1", id: 3, nonce: "n3"))
        new.write(bytes(30), at: 0)
        #expect(new.isKeeping)
        #expect(!exists(cache, "e1/1") && exists(cache, "e1/2"))
        #expect(cache.usedBytes == 60)
        // Room for another stream comes from closed streams only.
        let more = try #require(cache.open(epoch: "e1", id: 4, nonce: "n4"))
        more.write(bytes(60), at: 0)
        #expect(more.isKeeping && !exists(cache, "e1/2"))
        // `new` and `more` are open: nothing can make room for a third.
        let last = try #require(cache.open(epoch: "e1", id: 5, nonce: "n5"))
        last.write(bytes(60), at: 0)
        #expect(!last.isKeeping)
        #expect(exists(cache, "e1/3") && exists(cache, "e1/4"))
        last.close()
        more.close()
        new.close()
    }

    /// Another epoch's streams go once a server hello names this one; clearing takes everything,
    /// and an open stream records nothing more.
    @Test func otherEpochsAndClearingRemoveStreams() throws {
        let cache = makeCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        for epoch in ["e1", "e2"] {
            let stream = try #require(cache.open(epoch: epoch, id: 1, nonce: "n1"))
            stream.write(bytes(10), at: 0)
            stream.close()
        }
        cache.retain(epoch: "e2")
        #expect(!exists(cache, "e1") && exists(cache, "e2/1"))
        cache.retain(epoch: nil)
        #expect(!exists(cache, "e2"))
        let open = try #require(cache.open(epoch: "e3", id: 1, nonce: "n1"))
        open.write(bytes(10), at: 0)
        cache.removeAll()
        #expect(!exists(cache, ""))
        open.write(bytes(10, from: 10), at: 10)
        #expect(!open.isKeeping)
        open.close()
        #expect(!exists(cache, "") && cache.usedBytes == 0)
    }

    /// A record that cannot be written stops the keeping and discards the stream; the stream
    /// itself goes on without it.
    @Test func aFailedWriteStopsKeeping() throws {
        let cache = makeCache()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cache.directory.appendingPathComponent("e1").path)
            try? FileManager.default.removeItem(at: cache.directory)
        }
        let stream = try #require(cache.open(epoch: "e1", id: 1, nonce: "n1"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: cache.directory.appendingPathComponent("e1").path)
        stream.write(bytes(10), at: 0)
        #expect(!stream.isKeeping)
        stream.write(bytes(10, from: 10), at: 10)
        stream.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cache.directory.appendingPathComponent("e1").path)
        #expect(try #require(cache.open(epoch: "e1", id: 1, nonce: "n1")).cached == 0)
    }

    @Test func clearingFencesOldWritersFromNewAccountingAndOwnership() throws {
        let cache = makeCache(budget: 100, commitInterval: 1000)
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let old = try #require(cache.open(epoch: "e1", id: 1, nonce: "old"))
        old.write(bytes(80), at: 0) // Not yet committed.
        cache.removeAll()
        let current = try #require(cache.open(epoch: "e1", id: 1, nonce: "new"))
        current.write(bytes(60), at: 0)
        old.write(bytes(1), at: 80) // Settling an old inode must not reduce the new total.
        old.close() // Nor can it release the current stream's eviction protection.
        #expect(cache.usedBytes == 60)
        let other = try #require(cache.open(epoch: "e1", id: 2, nonce: "other"))
        other.write(bytes(50), at: 0)
        #expect(!other.isKeeping)
        #expect(current.isKeeping && exists(cache, "e1/1"))
        other.close()
        current.close()
    }

    @Test func aSecondWriterCannotTruncateAnOpenStream() throws {
        let cache = makeCache(commitInterval: 1000)
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let first = try #require(cache.open(epoch: "e1", id: 1, nonce: "first"))
        first.write(bytes(80), at: 0)
        #expect(cache.open(epoch: "e1", id: 1, nonce: "first") == nil)
        #expect(cache.open(epoch: "e1", id: 1, nonce: "other") == nil)
        #expect(try Data(contentsOf: first.dataURL) == bytes(80))
        first.close()
        let reopened = try #require(cache.open(epoch: "e1", id: 1, nonce: "first"))
        #expect(reopened.cached == 80)
        reopened.close()
    }
    /// Requested growth is accounted before I/O; neither zero nor partial progress can leak
    /// that reservation or subtract bytes belonging to an independent open stream.
    @Test func failedAndPartialWritesReleaseExactlyTheirReservation() throws {
        for partial in [0, 7, 39] {
            let cache = makeCache(budget: 100, commitInterval: 1000)
            defer { try? FileManager.default.removeItem(at: cache.directory) }
            let other = try #require(cache.open(epoch: "e1", id: 2, nonce: "other"))
            other.write(bytes(60), at: 0)
            let failed = try #require(cache.open(epoch: "e1", id: 1, nonce: "failed"))
            cache.writeData = { handle, data in
                try handle.write(contentsOf: data.prefix(partial))
                throw CocoaError(.fileWriteOutOfSpace)
            }
            failed.write(bytes(40), at: 0)
            #expect(!failed.isKeeping)
            #expect(!exists(cache, "e1/1"))
            #expect(cache.usedBytes == 60)
            failed.discard() // Cleanup must not release the same reservation twice.
            #expect(cache.usedBytes == 60)
            cache.writeData = { try $0.write(contentsOf: $1) }
            let replacement = try #require(cache.open(epoch: "e1", id: 1, nonce: "new"))
            replacement.write(bytes(40), at: 0)
            #expect(replacement.isKeeping && cache.usedBytes == 100)
            #expect(try Data(contentsOf: other.dataURL) == bytes(60))
            replacement.close()
            other.close()
        }
    }

    @Test func removalInvalidatesTheWriterBeforeItsReplacementOpens() throws {
        let cache = makeCache(budget: 100, commitInterval: 1000)
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let old = try #require(cache.open(epoch: "e1", id: 1, nonce: "old"))
        old.write(bytes(80), at: 0)
        cache.remove(epoch: "e1", id: 1)
        let current = try #require(cache.open(epoch: "e1", id: 1, nonce: "new"))
        current.write(bytes(60), at: 0)
        old.commit()
        old.discard()
        #expect(cache.usedBytes == 60)
        #expect(try Data(contentsOf: current.dataURL) == bytes(60))
        current.close()
        let reopened = try #require(cache.open(epoch: "e1", id: 1, nonce: "new"))
        #expect(reopened.cached == 60)
        reopened.close()
    }

    @Test func releasingAStreamClosesItsWriter() throws {
        let cache = makeCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        var stream: GPUStreamCache.Stream? = try #require(cache.open(epoch: "e1", id: 1, nonce: "n"))
        stream?.write(bytes(10), at: 0)
        stream = nil
        let reopened = try #require(cache.open(epoch: "e1", id: 1, nonce: "n"))
        #expect(reopened.cached == 10)
        reopened.close()
    }

}
