import CabooseKit
import SwiftUI

/// A local pointer for a trackpad aimed at one tiled window or full-screen card.
/// It never identifies a window across display sessions or keeps a remote window alive.
@MainActor @Observable
final class LaptopPointer {
    static let shared = LaptopPointer()
    private(set) var point: CGPoint?
    private weak var window: RemoteWindow?
    private weak var session: (any DisplaySession)?
    private weak var owner: AnyObject?

    func show(in window: RemoteWindow, session: any DisplaySession, at point: CGPoint, owner: AnyObject) {
        self.window = window; self.session = session; self.point = point; self.owner = owner
    }
    func point(in window: RemoteWindow, session: (any DisplaySession)?) -> CGPoint? {
        guard self.window === window, self.session === session, session?.state == .ready else { return nil }
        return point
    }
    func clear(owner: AnyObject? = nil) {
        if let owner, self.owner !== owner { return }
        point = nil; window = nil; session = nil; self.owner = nil
    }
}
