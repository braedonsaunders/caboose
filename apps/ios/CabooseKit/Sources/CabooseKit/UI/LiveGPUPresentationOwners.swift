#if canImport(UIKit)
import UIKit
import QuartzCore

/// Explicitly owned by the phone's owner session. Agent sessions never receive
/// this registry. Display epoch and object identity come from the display stream;
/// the guest's grant cannot manufacture a visible UIKit owner.
///
/// Visibility never stalls the guest. While no view can show a bound window (another
/// tab, a hidden or off-screen view, a view reused for another window) its lease is
/// parked: the presentation layer leaves the view hierarchy but keeps its binding and
/// keeps receiving presents. When an eligible view shows the window again the layer
/// returns to it holding the latest frame. Only the session, the display epoch, the
/// window's identity or its server geometry end a lease.
@MainActor
public final class LiveGPUPresentationOwners {
    private final class ViewRef {
        weak var view: RemoteWindowView?
        init(_ view: RemoteWindowView) { self.view = view }
    }
    private var epoch: Data?
    private var windows: [UInt64: ObjectIdentifier] = [:]
    private var remoteWindows: [UInt64: WindowRef] = [:]
    private final class WindowRef {
        weak var window: RemoteWindow?
        init(_ window: RemoteWindow) { self.window = window }
    }
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
        remoteWindows = Dictionary(uniqueKeysWithValues: windows.values.compactMap {
            $0.id > 0 ? (UInt64($0.id), WindowRef($0)) : nil
        })
        for window in windows.values { window.liveGPUPresentation = self }
        for lease in leases.values { validate(lease) }
        waiting.retry()
    }

    /// Invalidates admission and detaches visible presentation layers immediately on main;
    /// native GPU work and backing layer ownership remain retained until the worker
    /// retirement/main detach barrier.
    public func revoke() {
        stopped = true; epoch = nil; windows.removeAll(); remoteWindows.removeAll()
        waiting.cancel()
        for lease in leases.values {
            if lease.invalidate() {
                #if DEBUG && canImport(CabooseGPUMemoryAudit)
                LiveGPUMemoryAudit.ownerInvalidated(.session)
                #endif
            }
            lease.content?.removeFromSuperview()
        }
    }

    /// Whether a live GPU layer presents in `view`, over the picture the view draws itself.
    func presents(in view: RemoteWindowView) -> Bool {
        leases.values.contains { $0.isValid && $0.view === view }
    }

    /// For diagnosis: where `window`'s live GPU layer presents, if anywhere.
    func presenter(of window: RemoteWindow) -> (view: RemoteWindowView?, valid: Bool)? {
        guard window.id > 0, let lease = leases[UInt64(window.id)] else { return nil }
        return (lease.view, lease.isValid)
    }

    func observe(_ view: RemoteWindowView) {
        views = views.filter { $0.value.view != nil }
        views[ObjectIdentifier(view)] = ViewRef(view)
        // Any lease may move here: a parked one returns to the view now showing its window.
        for lease in leases.values { validate(lease) }
        waiting.retry()
    }
    /// The view no longer shows its window: its leases park until a view shows it again.
    func withdraw(_ view: RemoteWindowView) {
        views.removeValue(forKey: ObjectIdentifier(view))
        for lease in leases.values where lease.view === view {
            lease.view = nil
            validate(lease)
        }
    }
    private func validate(_ lease: LiveGPULayerLease) {
        guard lease.isValid else { return }
        guard !stopped, epoch == lease.identity.epoch, windows[lease.windowID] == lease.windowIdentity else {
            end(lease, stopped ? .session : .ownership)
            return
        }
        guard let view = host(for: lease) else {
            park(lease)
            return
        }
        guard let window = view.remoteWindow else { park(lease); return }
        // An eligible view has visible bounds: only the window's server geometry fails here.
        guard let currentExtent = extent(view) else {
            #if DEBUG && canImport(CabooseGPUMemoryAudit)
            let pending = ((view.session ?? view.pacer) as? CabooseDisplaySession)?.pendingPresentationSize(window)
            LiveGPUMemoryAudit.ownerGeometry(previous: lease.extent,
                server: window.frame.size, visible: view.bounds.size, pending: pending)
            #endif
            end(lease, .geometry)
            return
        }
        if currentExtent != lease.extent {
            #if DEBUG && canImport(CabooseGPUMemoryAudit)
            let pending = ((view.session ?? view.pacer) as? CabooseDisplaySession)?.pendingPresentationSize(window)
            LiveGPUMemoryAudit.ownerGeometry(previous: lease.extent,
                server: window.frame.size, visible: view.bounds.size,
                pending: pending)
            #endif
            lease.updateExtent(currentExtent)
        }
        lease.view = view
        if let content = lease.content, content.superview !== view {
            // The layer still holds the last frame presented while parked.
            view.insertSubview(content, at: 0)
        }
        if lease.parked {
            lease.parked = false
            #if DEBUG && canImport(CabooseGPUMemoryAudit)
            LiveGPUMemoryAudit.ownerParked(false)
            #endif
        }
        // Fitting the view slot scales the dedicated presentation layer without
        // invalidating the bound surface; the guest recreates its swapchain at
        // the new extent via configurePresentationExtent.
        (lease.content as? LiveGPULayerView)?.fit(in: view.bounds, viewport: window.frame.size, overscan: window.overscan)
    }
    /// The one eligible view showing the lease's window, preferring its current view.
    private func host(for lease: LiveGPULayerLease) -> RemoteWindowView? {
        func shows(_ view: RemoteWindowView) -> Bool {
            view.remoteWindow.map(ObjectIdentifier.init) == lease.windowIdentity && eligible(view)
        }
        if let view = lease.view, shows(view) { return view }
        // A duplicated visible owner is not resolved by picking an arbitrary view.
        let candidates = views.values.compactMap(\.view).filter(shows)
        return candidates.count == 1 ? candidates[0] : nil
    }
    /// Takes the layer out of view while keeping the binding and its presents.
    private func park(_ lease: LiveGPULayerLease) {
        lease.content?.removeFromSuperview()
        guard !lease.parked else { return }
        lease.parked = true
        #if DEBUG && canImport(CabooseGPUMemoryAudit)
        LiveGPUMemoryAudit.ownerParked(true)
        #endif
    }
    private func end(_ lease: LiveGPULayerLease, _ reason: EndReason) {
        guard lease.invalidate() else { return }
        #if DEBUG && canImport(CabooseGPUMemoryAudit)
        switch reason {
        case .session: LiveGPUMemoryAudit.ownerInvalidated(.session)
        case .ownership: LiveGPUMemoryAudit.ownerInvalidated(.ownership)
        case .geometry: LiveGPUMemoryAudit.ownerInvalidated(.geometry)
        }
        #endif
        lease.content?.removeFromSuperview()
        invalidated(lease.identity)
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
        let showing = views.values.compactMap(\.view).filter {
            guard let window = $0.remoteWindow else { return false }
            return ObjectIdentifier(window) == object
        }
        let candidates = showing.filter(eligible)
        // A duplicated visible owner is not resolved by picking an arbitrary view.
        guard candidates.count < 2 else { throw unavailable(EBUSY) }
        // With no view showing the window, the lease starts parked at the window's
        // server extent: binding never waits for the window to be on screen.
        let view = candidates.first
        guard let window = view?.remoteWindow ?? remoteWindows[windowID]?.window,
              ObjectIdentifier(window) == object else { throw unavailable(EAGAIN) }
        let display = ((view ?? showing.first).flatMap { $0.session ?? $0.pacer }) as? CabooseDisplaySession
        let bounds = view?.bounds.size ?? window.frame.size
        guard let size = LiveGPUDrawableGeometry.extent(serverPixels: window.frame.size,
            visibleBounds: bounds, requestedPixels: display?.pendingPresentationSize(window)) else {
            #if DEBUG && canImport(CabooseGPUMemoryAudit)
            LiveGPUMemoryAudit.ownerPending(server: window.frame.size,
                requested: display?.pendingPresentationSize(window))
            #endif
            throw unavailable(EAGAIN)
        }
        #if DEBUG && canImport(CabooseGPUMemoryAudit)
        LiveGPUMemoryAudit.ownerExtent(server: size, view: bounds)
        #endif
        let content = LiveGPULayerView(frame: CGRect(origin: .zero, size: bounds), pixelExtent: size)
        content.isUserInteractionEnabled = false
        content.isOpaque = true
        content.backgroundColor = .black
        let layer = content.metal
        layer.contentsScale = 1
        layer.drawableSize = size
        layer.framebufferOnly = false
        layer.presentsWithTransaction = false
        view?.insertSubview(content, at: 0)
        let lease = LiveGPULayerLease(identity: identity, windowID: windowID,
            windowIdentity: object, extent: size, view: view, content: content)
        if view == nil {
            lease.parked = true
            #if DEBUG && canImport(CabooseGPUMemoryAudit)
            LiveGPUMemoryAudit.ownerParked(true)
            #endif
        }
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
    private enum EndReason { case session, ownership, geometry }
    private func unavailable(_ code: Int32) -> LiveGPUBindingError { .native(operation: "visible owner", code: code) }
}

@MainActor
private final class LiveGPULayerView: UIView {
    private(set) var pixelExtent: CGSize
    private var configuringExtent = false
    private var extentQuarantined = false
    let metal = CAMetalLayer()
    init(frame: CGRect, pixelExtent: CGSize) {
        self.pixelExtent = pixelExtent
        super.init(frame: frame)
        layer.addSublayer(metal)
        applyDrawableExtent()
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
    func configurePresentationExtent(_ size: CGSize, configure: (CAMetalLayer) -> Int32) -> Int32 {
        guard !configuringExtent, !extentQuarantined else { return EBUSY }
        // A native transaction commit may synchronously invoke UIKit layout.
        // Keep that layout from restoring the previous buffer extent mid-mutation.
        configuringExtent = true
        let code = configure(metal)
        if code == 0 { pixelExtent = size }
        else if code == EIO { extentQuarantined = true }
        configuringExtent = false
        if code == 0 { applyDrawableExtent() }
        return code
    }
    /// The window's viewport and overscan in server pixels: a picture of the enlarged
    /// window (an overscan window) shows its viewport, top-left aligned, the rest clipped.
    private var viewport: CGSize = .zero, overscan: CGSize = .zero
    func fit(in target: CGRect, viewport: CGSize = .zero, overscan: CGSize = .zero) {
        frame = target
        clipsToBounds = overscan != .zero
        self.viewport = viewport; self.overscan = overscan
        applyDrawableExtent()
    }
    /// The part of the drawable the view shows.
    private var shownExtent: CGSize {
        guard overscan != .zero, viewport.width > 0, viewport.height > 0 else { return pixelExtent }
        let full = CGSize(width: viewport.width + overscan.width, height: viewport.height + overscan.height)
        let shape = pixelExtent.height / max(1, pixelExtent.width)
        guard abs(shape - full.height / full.width) < abs(shape - viewport.height / viewport.width) else { return pixelExtent }
        return CGSize(width: pixelExtent.width * viewport.width / full.width, height: pixelExtent.height * viewport.height / full.height)
    }
    func applyDrawableExtent() {
        guard !configuringExtent, !extentQuarantined else { return }
        // A separate layer avoids UIKit rescaling a view's backing Metal layer.
        // MoltenVK observes these real bounds * contentsScale as its natural extent.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metal.bounds = CGRect(origin: .zero, size: pixelExtent)
        metal.contentsScale = 1
        metal.drawableSize = pixelExtent
        let shown = shownExtent
        let scale = CGAffineTransform(scaleX: bounds.width / shown.width, y: bounds.height / shown.height)
        // Centred on the shown part, so a full drawable fills the bounds exactly as before.
        metal.position = CGPoint(x: bounds.minX + pixelExtent.width * scale.a / 2, y: bounds.minY + pixelExtent.height * scale.d / 2)
        metal.setAffineTransform(scale)
        CATransaction.commit()
    }
}

/// Layer and view are touched only in main-dispatched stages. The registry keeps
/// this object alive on failure, so worker ARC never tears down a quarantined view.
final class LiveGPULayerLease: @unchecked Sendable {
    let identity: LiveGPUSurfaceIdentity
    let windowID: UInt64
    let windowIdentity: ObjectIdentifier
    /// Display placement; read off the main actor by the native bind path.
    var extent: CGSize { lock.withLock { currentExtent } }
    @MainActor weak var view: RemoteWindowView?
    @MainActor var content: UIView?
    @MainActor var layer: CAMetalLayer? {
        guard isValid, let content = content as? LiveGPULayerView else { return nil }
        content.layoutIfNeeded()
        content.applyDrawableExtent()
        return content.metal
    }
    /// Main-only, after native verifies there are no live swapchain resources.
    /// Display placement remains `extent`; only the independently owned buffer changes.
    @MainActor func configurePresentationExtent(_ size: CGSize, configure: (CAMetalLayer) -> Int32) -> Int32 {
        guard isValid, let content = content as? LiveGPULayerView else { return ECANCELED }
        guard LiveGPUDrawableGeometry.extent(serverPixels: size, visibleBounds: content.bounds.size) != nil else { return EINVAL }
        return content.configurePresentationExtent(size, configure: configure)
    }
    private let lock = NSLock()
    private var valid = true
    private var currentExtent: CGSize
    func updateExtent(_ newExtent: CGSize) { lock.withLock { currentExtent = newExtent } }
    var isValid: Bool { lock.withLock { valid } }
    @discardableResult func invalidate() -> Bool { lock.withLock { let old = valid; valid = false; return old } }
    /// Out of view, still bound and still presenting (LiveGPUPresentationOwners).
    @MainActor var parked = false
    @MainActor init(identity: LiveGPUSurfaceIdentity, windowID: UInt64, windowIdentity: ObjectIdentifier,
                    extent: CGSize, view: RemoteWindowView?, content: UIView) {
        self.identity = identity; self.windowID = windowID; self.windowIdentity = windowIdentity
        self.currentExtent = extent; self.view = view; self.content = content
    }
}
#endif
