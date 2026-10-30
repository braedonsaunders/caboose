#if canImport(UIKit)
import UIKit
import QuartzCore

/// Explicitly owned by the phone's owner session. Agent sessions never receive
/// this registry. Display epoch and object identity come from the display stream;
/// the guest's grant cannot manufacture a visible UIKit owner.
@MainActor
public final class LiveGPUPresentationOwners {
    private final class ViewRef {
        weak var view: RemoteWindowView?
        init(_ view: RemoteWindowView) { self.view = view }
    }
    private var epoch: Data?
    private var windows: [UInt64: ObjectIdentifier] = [:]
    private var views: [ObjectIdentifier: ViewRef] = [:]
    private var leases: [UInt64: LiveGPULayerLease] = [:]
    private let invalidated: @MainActor (LiveGPUSurfaceIdentity) -> Void
    private var stopped = false
    private let waiting = LiveGPUOwnerWaiter<LiveGPULayerLease>()

    init(invalidated: @escaping @MainActor (LiveGPUSurfaceIdentity) -> Void) { self.invalidated = invalidated }

    public func update(epoch: Data?, windows: [Int: RemoteWindow]) {
        guard !stopped else { return }
        let validEpoch = epoch.flatMap { $0.count == 16 && $0.contains(where: { $0 != 0 }) ? $0 : nil }
        self.epoch = validEpoch
        self.windows = Dictionary(uniqueKeysWithValues: windows.values.compactMap {
            $0.id > 0 ? (UInt64($0.id), ObjectIdentifier($0)) : nil
        })
        for window in windows.values { window.liveGPUPresentation = self }
        for lease in leases.values { validate(lease) }
        waiting.retry()
    }

    /// Invalidates admission immediately on main; native GPU work and UIKit
    /// ownership remain retained until the worker retirement/main detach barrier.
    public func revoke() {
        stopped = true; epoch = nil; windows.removeAll()
        waiting.cancel()
        for lease in leases.values { lease.invalidate() }
    }

    func observe(_ view: RemoteWindowView) {
        views = views.filter { $0.value.view != nil }
        views[ObjectIdentifier(view)] = ViewRef(view)
        for lease in leases.values where lease.view === view { validate(lease) }
        waiting.retry()
    }
    func withdraw(_ view: RemoteWindowView) {
        views.removeValue(forKey: ObjectIdentifier(view))
        for lease in leases.values where lease.view === view {
            if lease.invalidate() { invalidated(lease.identity) }
        }
    }
    private func validate(_ lease: LiveGPULayerLease) {
        guard lease.isValid else { return }
        guard !stopped, epoch == lease.identity.epoch,
              windows[lease.windowID] == lease.windowIdentity,
              let view = lease.view, let window = view.remoteWindow,
              ObjectIdentifier(window) == lease.windowIdentity, eligible(view),
              extent(view) == lease.extent else {
            if lease.invalidate() { invalidated(lease.identity) }
            return
        }
    }
    private func eligible(_ view: RemoteWindowView) -> Bool {
        guard view.remoteWindow?.game == nil, view.remoteWindow?.gpuStream == nil,
              GamePresentation.hosts(interactive: view.isInteractive, desktop: view.hostsGame,
            contentEnabled: view.showsVideo, hasConnection: (view.session ?? view.pacer) != nil,
            onScreen: view.window != nil), let window = view.window, view.superview != nil else { return false }
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha <= 0 { return false }
            ancestor = current.superview
        }
        return !view.convert(view.bounds, to: window).intersection(window.bounds).isEmpty
    }
    private func extent(_ view: RemoteWindowView) -> CGSize? {
        let scale = view.window?.windowScene?.screen.scale ?? view.contentScaleFactor
        let width = (view.bounds.width * scale).rounded(), height = (view.bounds.height * scale).rounded()
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width <= CGFloat(UInt32.max), height <= CGFloat(UInt32.max) else { return nil }
        return CGSize(width: width, height: height)
    }

    func requestClaim(identity: LiveGPUSurfaceIdentity, windowID: UInt64,
                      complete: @escaping @MainActor (Result<LiveGPULayerLease, Error>) -> Void) {
        waiting.request(resolve: { [self] in try claim(identity: identity, windowID: windowID) }, complete: complete)
    }
    private func claim(identity: LiveGPUSurfaceIdentity, windowID: UInt64) throws -> LiveGPULayerLease {
        guard !stopped else { throw unavailable(ECANCELED) }
        guard let epoch else { throw unavailable(EAGAIN) }
        guard epoch == identity.epoch else { throw unavailable(ESTALE) }
        guard let object = windows[windowID] else { throw unavailable(EAGAIN) }
        guard leases[windowID] == nil else { throw unavailable(EBUSY) }
        let candidates = views.values.compactMap(\.view).filter {
            guard let window = $0.remoteWindow else { return false }
            return ObjectIdentifier(window) == object && eligible($0)
        }
        // A duplicated visible owner is not resolved by picking an arbitrary view.
        guard candidates.count < 2 else { throw unavailable(EBUSY) }
        guard let view = candidates.first, let size = extent(view) else {
            throw unavailable(EAGAIN)
        }
        let content = LiveGPULayerView(frame: view.bounds)
        content.isUserInteractionEnabled = false
        content.isOpaque = true
        content.backgroundColor = .black
        let layer = content.layer as! CAMetalLayer
        layer.contentsScale = view.window?.windowScene?.screen.scale ?? view.contentScaleFactor
        layer.drawableSize = size
        layer.framebufferOnly = false
        layer.presentsWithTransaction = false
        view.insertSubview(content, at: 0)
        let lease = LiveGPULayerLease(identity: identity, windowID: windowID,
            windowIdentity: object, extent: size, view: view, content: content)
        leases[windowID] = lease
        return lease
    }
    func release(_ lease: LiveGPULayerLease) {
        guard leases[lease.windowID] === lease else { return }
        lease.invalidate()
        lease.content?.removeFromSuperview()
        lease.content = nil
        leases.removeValue(forKey: lease.windowID)
    }
    private func unavailable(_ code: Int32) -> LiveGPUBindingError { .native(operation: "visible owner", code: code) }
}

@MainActor
private final class LiveGPULayerView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
}

/// Layer and view are touched only in main-dispatched stages. The registry keeps
/// this object alive on failure, so worker ARC never tears down a quarantined view.
final class LiveGPULayerLease: @unchecked Sendable {
    let identity: LiveGPUSurfaceIdentity
    let windowID: UInt64
    let windowIdentity: ObjectIdentifier
    let extent: CGSize
    @MainActor weak var view: RemoteWindowView?
    @MainActor var content: UIView?
    @MainActor var layer: CAMetalLayer? { content?.layer as? CAMetalLayer }
    private let lock = NSLock()
    private var valid = true
    var isValid: Bool { lock.withLock { valid } }
    @discardableResult func invalidate() -> Bool { lock.withLock { let old = valid; valid = false; return old } }
    @MainActor init(identity: LiveGPUSurfaceIdentity, windowID: UInt64, windowIdentity: ObjectIdentifier,
                    extent: CGSize, view: RemoteWindowView, content: UIView) {
        self.identity = identity; self.windowID = windowID; self.windowIdentity = windowIdentity
        self.extent = extent; self.view = view; self.content = content
    }
}
#endif
