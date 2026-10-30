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
        for lease in leases.values {
            if lease.invalidate() {
                #if DEBUG && canImport(CabooseGPUMemoryAudit)
                LiveGPUMemoryAudit.ownerInvalidated(.session)
                #endif
            }
        }
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
            if lease.invalidate() {
                #if DEBUG && canImport(CabooseGPUMemoryAudit)
                LiveGPUMemoryAudit.ownerInvalidated(.withdrawn)
                #endif
                invalidated(lease.identity)
            }
        }
    }
    private func validate(_ lease: LiveGPULayerLease) {
        guard lease.isValid else { return }
        guard !stopped, epoch == lease.identity.epoch,
              windows[lease.windowID] == lease.windowIdentity,
              let view = lease.view, let window = view.remoteWindow,
              ObjectIdentifier(window) == lease.windowIdentity, eligible(view),
              extent(view) == lease.extent else {
            if lease.invalidate() {
                #if DEBUG && canImport(CabooseGPUMemoryAudit)
                let reason: LiveGPUMemoryAudit.OwnerInvalidation
                if stopped { reason = .session }
                else if epoch != lease.identity.epoch || windows[lease.windowID] != lease.windowIdentity { reason = .ownership }
                else if let view = lease.view, eligible(view) {
                    reason = extent(view) == lease.extent ? .ownership : .geometry
                } else { reason = .visibility }
                LiveGPUMemoryAudit.ownerInvalidated(reason)
                #endif
                invalidated(lease.identity)
            }
            return
        }
        // Fitting the same server pixels to a new UIKit slot does not resize Vulkan.
        if let view = lease.view { (lease.content as? LiveGPULayerView)?.fit(in: view.bounds) }
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
        guard let window = view.remoteWindow else { return nil }
        return LiveGPUDrawableGeometry.extent(serverPixels: window.frame.size,
                                             visibleBounds: view.bounds.size)
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
        #if DEBUG && canImport(CabooseGPUMemoryAudit)
        LiveGPUMemoryAudit.ownerExtent(server: size, view: view.bounds.size)
        #endif
        let content = LiveGPULayerView(frame: view.bounds, pixelExtent: size)
        content.isUserInteractionEnabled = false
        content.isOpaque = true
        content.backgroundColor = .black
        let layer = content.layer as! CAMetalLayer
        layer.contentsScale = 1
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
    let pixelExtent: CGSize
    override class var layerClass: AnyClass { CAMetalLayer.self }
    init(frame: CGRect, pixelExtent: CGSize) {
        self.pixelExtent = pixelExtent
        super.init(frame: .zero)
        fit(in: frame)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyDrawableExtent()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        applyDrawableExtent()
    }
    func fit(in target: CGRect) {
        // MoltenVK reports bounds * contentsScale as its natural surface extent.
        // Keep those in server pixels; only the view transform fits the UIKit slot.
        bounds = CGRect(origin: .zero, size: pixelExtent)
        transform = CGAffineTransform(scaleX: target.width / pixelExtent.width,
                                      y: target.height / pixelExtent.height)
        center = CGPoint(x: target.midX, y: target.midY)
        applyDrawableExtent()
    }
    func applyDrawableExtent() {
        contentScaleFactor = 1
        let metal = layer as! CAMetalLayer
        metal.contentsScale = 1
        metal.drawableSize = pixelExtent
    }
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
    @MainActor var layer: CAMetalLayer? {
        guard let content = content as? LiveGPULayerView else { return nil }
        content.layoutIfNeeded()
        content.applyDrawableExtent()
        return content.layer as? CAMetalLayer
    }
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
