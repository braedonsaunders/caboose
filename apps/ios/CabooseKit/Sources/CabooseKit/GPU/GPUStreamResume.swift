import Foundation

/// The decisions behind continuing a GPU stream's replay across a reconnect
/// (docs/gpu-stream.md, "Resuming"), apart from the player that carries them out.
///
/// A replay kept through a lost connection is claimed in the next hello's `gpu_resume` with the
/// offset it has accepted, only for the server epoch it came from. The server answers in the
/// stream's `gpu.create`: `resume` at exactly that offset continues the kept replay; anything
/// else means the stream starts again from its first byte, and the kept replay is discarded.
enum GPUStreamResume {
    /// A window's stream as the client holds it when the stream is announced.
    struct Kept: Equatable {
        var id: Int
        var nonce: String?
        /// The stream ended on this device (a failed replay, or the computer ended it).
        var ended: Bool
        /// Kept through a lost connection: the offset its replay accepted, once that is
        /// settled, while the replay still runs. Nil for a stream live on the connection, or a
        /// kept one that cannot continue.
        var resumable: UInt64?
        /// Kept through a lost connection (resumable or not).
        var suspended: Bool
    }

    enum Plan: Equatable {
        /// The window's stream is already this connection's, or ended here: nothing changes.
        case keep
        /// The kept replay continues on this connection at `offset`.
        case continueKept(offset: UInt64)
        /// A new replay from the stream's first byte; a kept one is discarded.
        case fresh
        /// The computer continues the stream for a replay this device no longer has.
        case unplayable
    }

    /// What `gpu.create { id, nonce, resume }` does to the window's stream `kept`.
    static func plan(id: Int, nonce: String?, resume: UInt64?, kept: Kept?) -> Plan {
        guard let kept, kept.id == id else { return resume == nil ? .fresh : .unplayable }
        if kept.ended || !kept.suspended { return .keep }
        if let resume, let offset = kept.resumable, offset == resume, let nonce, nonce == kept.nonce {
            return .continueKept(offset: offset)
        }
        return resume == nil ? .fresh : .unplayable
    }

    /// The hello's `gpu_resume`: the kept replays that can continue, for the server `epoch` they
    /// came from. Nil without an epoch, which proves nothing, or without such a replay.
    static func claims(epoch: String?, streams: [(id: Int, nonce: String?, offset: UInt64?)]) -> GPUResume? {
        guard let epoch else { return nil }
        let claimed = streams.compactMap { stream -> GPUResume.Stream? in
            guard let nonce = stream.nonce, let offset = stream.offset else { return nil }
            return GPUResume.Stream(id: stream.id, nonce: nonce, offset: offset)
        }
        return claimed.isEmpty ? nil : GPUResume(epoch: epoch, streams: claimed.sorted { $0.id < $1.id })
    }
}
