#if canImport(UIKit)
import UIKit
import QuartzCore

/// Explicitly owned by the phone's owner GPU session, one registry per seat: the owner's display
/// and the agent seat's (docs/gpu-live.md, "Seats"). A display session receives only its own
/// seat's registry. Display epoch and object identity come from the display stream;
/// the guest's grant cannot manufacture a visible UIKit owner.
///
/// Visibility never stalls the guest. While no view can show a bound window (another
/// tab, a hidden or off-screen view, a view reused for another window) its lease is
/// parked: the presentation layer leaves the view hierarchy but keeps its binding and
/// keeps receiving presents. When an eligible view shows the window again the layer
/// returns to it holding the latest frame. Only the session, the display epoch, the
/// window's identity or its server geometry end a lease.
///
/// A `child` window (docs/display.md, "Child windows") is a lease of its own, keyed by its
/// own id, hosted in the view showing its parent: inside the parent's picture at its
/// geometry, cut to its clip, above the parent's own layer and ordered among the parent's
/// children by `stack`. It takes no touches, and its presents never become the parent's
/// snapshot.
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
    /// The display's child windows, by id; each names its parent in `remoteWindows`.
    private var children: [UInt64: RemoteChildWindow] = [:]
    private var leases: [UInt64: LiveGPULayerLease] = [:]
    private let invalidated: @MainActor (LiveGPUSurfaceIdentity) -> Void
    private var stopped = false
    private let waiting = LiveGPUOwnerWaiter<LiveGPULayerLease>()

    init(invalidated: @escaping @MainActor (LiveGPUSurfaceIdentity) -> Void) { self.invalidated = invalidated }

    public func update(epoch: Data?, windows: [Int: RemoteWindow], children: [Int: RemoteChildWindow] = [:]) {
        guard !stopped else { return }
        self.children = Self.keyed(children)
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

    /// The display's child windows changed: one came, went, moved, was cut or restacked.
    func update(children: [Int: RemoteChildWindow]) {
        guard !stopped else { return }
        self.children = Self.keyed(children)
        for lease in leases.values { validate(lease) }
        waiting.retry()
    }

    private static func keyed(_ children: [Int: RemoteChildWindow]) -> [UInt64: RemoteChildWindow] {
        Dictionary(uniqueKeysWithValues: children.values.compactMap { $0.id > 0 ? (UInt64($0.id), $0) : nil })
    }

    private func parentWindow(of child: RemoteChildWindow) -> RemoteWindow? {
        UInt64(exactly: child.parent).flatMap { remoteWindows[$0]?.window }
    }

    /// The object a window id names now: a window's, or a child's.
    private func identity(of windowID: UInt64) -> ObjectIdentifier? {
        windows[windowID] ?? children[windowID].map(ObjectIdentifier.init)
    }

    /// Invalidates admission and detaches visible presentation layers immediately on main;
    /// native GPU work and backing layer ownership remain retained until the worker
    /// retirement/main detach barrier.
    /// Once a second while any window has a GPU layer: the notice over each window follows
    /// its GPU (lost, not responding, or nothing).
    private var healthTimer: Timer?
    private func watchHealth() {
        guard healthTimer == nil, !leases.isEmpty, !stopped else { return }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
    }
    private func checkHealth() {
        guard !leases.isEmpty, !stopped else {
            healthTimer?.invalidate(); healthTimer = nil
            return
        }
        for lease in leases.values where lease.isValid {
            let state = lease.healthState
            guard state != lease.shownHealth else { continue }
            lease.shownHealth = state
            (lease.content as? LiveGPULayerView)?.showHealth(state)
            print("CABOOSE_GPU_WINDOW_HEALTH window=\(lease.windowID) state=\(state)")
        }
    }

    public func revoke() {
        stopped = true; epoch = nil; windows.removeAll(); remoteWindows.removeAll(); children.removeAll()
        healthTimer?.invalidate(); healthTimer = nil
        waiting.cancel()
        for lease in leases.values {
            if lease.invalidate() {
                #if DEBUG && canImport(CabooseGPUMemoryAudit)
                LiveGPUMemoryAudit.ownerInvalidated(.session)
                #endif
            }
            lease.hosted?.removeFromSuperview()
            if lease.translucent { lease.view?.liveGPUTranslucencyChanged() }
        }
    }

    /// Whether the live GPU layer in `view` blends with what is behind the window. A child's
    /// layer blends with its parent's picture, not with what is behind the window.
    func presentsTranslucent(in view: RemoteWindowView) -> Bool {
        leases.values.contains { $0.isValid && !$0.isChild && $0.view === view && $0.translucent }
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
        guard !stopped, epoch == lease.identity.epoch, identity(of: lease.windowID) == lease.windowIdentity else {
            end(lease, stopped ? .session : .ownership)
            return
        }
        if let child = children[lease.windowID] { return validate(lease, child: child) }
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
        if lease.view !== view {
            let previous = lease.view
            lease.view = view
            if lease.translucent { previous?.liveGPUTranslucencyChanged(); view.liveGPUTranslucencyChanged() }
        }
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
        // the new extent via configurePresentationExtent, and a picture that keeps
        // another size is scaled to the window (LiveGPUDrawableGeometry.placement).
        (lease.content as? LiveGPULayerView)?.fit(in: view.bounds, fullscreen: window.isFullscreen)
        if !children.isEmpty { arrangeChildren(in: view) }
    }

    /// A child's lease follows the view showing its parent, and the child's own geometry.
    private func validate(_ lease: LiveGPULayerLease, child: RemoteChildWindow) {
        guard let parent = parentWindow(of: child),
              let view = host(showing: ObjectIdentifier(parent), preferring: lease.view) else {
            park(lease)
            return
        }
        guard let currentExtent = LiveGPUDrawableGeometry.extent(serverPixels: child.geometry.size,
                                                                 visibleBounds: view.bounds.size) else {
            end(lease, .geometry)
            return
        }
        if currentExtent != lease.extent { lease.updateExtent(currentExtent) }
        lease.view = view
        if let clip = lease.clip, clip.superview !== view { view.addSubview(clip) }
        if lease.parked {
            lease.parked = false
            #if DEBUG && canImport(CabooseGPUMemoryAudit)
            LiveGPUMemoryAudit.ownerParked(false)
            #endif
        }
        arrangeChildren(in: view)
    }

    /// Where a parent's picture shows in `view`: a child's geometry and clip, relative to
    /// the parent in display pixels, map through it as the parent's own layer is fitted.
    private func parentPicture(in view: RemoteWindowView, parent: RemoteWindow) -> CGRect {
        let main = leases.values.first { $0.isValid && !$0.isChild && $0.view === view && $0.content?.superview === view }
        let picture = (main?.content as? LiveGPULayerView)?.pixelExtent ?? parent.frame.size
        return LiveGPUDrawableGeometry.placement(picture: picture, in: view.bounds, fill: parent.isFullscreen)
    }

    /// Places the children hosted in `view` over the parent's picture, at their geometry and
    /// cut to their clips, and stacks them: directly above the parent's own layer, lowest
    /// `stack` first, below everything else the view shows.
    private func arrangeChildren(in view: RemoteWindowView) {
        guard let parent = view.remoteWindow else { return }
        let hosted = leases.values.filter { $0.isValid && $0.isChild && $0.view === view && $0.clip?.superview === view }
            .compactMap { lease in children[lease.windowID].map { (lease, $0) } }
            .sorted { $0.1.stack != $1.1.stack ? $0.1.stack < $1.1.stack : $0.1.id < $1.1.id }
        guard !hosted.isEmpty else { return }
        let placed = parentPicture(in: view, parent: parent)
        let frame = parent.frame.size
        let sx = frame.width > 0 ? placed.width / frame.width : 0
        let sy = frame.height > 0 ? placed.height / frame.height : 0
        func points(_ rect: CGRect) -> CGRect {
            CGRect(x: placed.minX + rect.minX * sx, y: placed.minY + rect.minY * sy,
                   width: rect.width * sx, height: rect.height * sy)
        }
        for (lease, child) in hosted {
            guard let clip = lease.clip else { continue }
            let cut = points(child.clip)
            if clip.frame != cut { clip.frame = cut }
            let shown = points(child.geometry).offsetBy(dx: -cut.minX, dy: -cut.minY)
            (lease.content as? LiveGPULayerView)?.fit(in: shown)
        }
        // Directly above the parent's own layer, or lowest of all without one.
        let main = leases.values.first { $0.isValid && !$0.isChild && $0.view === view && $0.content?.superview === view }?.content
        let wanted = (main.map { [$0] } ?? []) + hosted.compactMap { $0.0.clip }
        let start = main.flatMap { view.subviews.firstIndex(of: $0) } ?? 0
        let current = view.subviews.dropFirst(start).prefix(wanted.count)
        guard !current.elementsEqual(wanted, by: ===) else { return }
        var below = main
        for clip in wanted.dropFirst(main == nil ? 0 : 1) {
            if let below { view.insertSubview(clip, aboveSubview: below) } else { view.insertSubview(clip, at: 0) }
            below = clip
        }
    }
    /// The one eligible view showing the lease's window, preferring its current view.
    private func host(for lease: LiveGPULayerLease) -> RemoteWindowView? {
        host(showing: lease.windowIdentity, preferring: lease.view)
    }
    /// The one eligible view showing the window `identity`, preferring `current`.
    private func host(showing identity: ObjectIdentifier, preferring current: RemoteWindowView?) -> RemoteWindowView? {
        func shows(_ view: RemoteWindowView) -> Bool {
            view.remoteWindow.map(ObjectIdentifier.init) == identity && eligible(view)
        }
        if let view = current, shows(view) { return view }
        // A duplicated visible owner is not resolved by picking an arbitrary view.
        let candidates = views.values.compactMap(\.view).filter(shows)
        return candidates.count == 1 ? candidates[0] : nil
    }
    /// Takes the layer out of view while keeping the binding and its presents.
    private func park(_ lease: LiveGPULayerLease) {
        lease.hosted?.removeFromSuperview()
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
        lease.hosted?.removeFromSuperview()
        if lease.translucent { lease.view?.liveGPUTranslucencyChanged() }
        invalidated(lease.identity)
    }
    private func eligible(_ view: RemoteWindowView) -> Bool {
        guard view.remoteWindow?.game == nil,
              GamePresentation.hosts(interactive: view.isInteractive, desktop: view.hostsGame,
            contentEnabled: view.showsLiveContent, hasConnection: (view.session ?? view.pacer) != nil,
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
        if windows[windowID] == nil, let child = children[windowID] {
            guard leases[windowID] == nil else { throw unavailable(EBUSY) }
            return try claim(identity: identity, child: child)
        }
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
        // Until its first present the layer shows nothing, over a blank view: never a picture
        // from before.
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
            windowIdentity: object, extent: size, view: view, content: content, snapshot: window.snapshot)
        // A window with alpha (a menu's shadow) shows what is behind it from the start.
        lease.setTranslucent(window.hasAlpha)
        if view == nil {
            lease.parked = true
            #if DEBUG && canImport(CabooseGPUMemoryAudit)
            LiveGPUMemoryAudit.ownerParked(true)
            #endif
        }
        leases[windowID] = lease
        watchHealth()
        return lease
    }
    /// A child's surface: hosted in the one eligible view showing its parent, or parked, at
    /// the child's own size in display pixels.
    private func claim(identity: LiveGPUSurfaceIdentity, child: RemoteChildWindow) throws -> LiveGPULayerLease {
        let windowID = UInt64(child.id)
        guard let parent = parentWindow(of: child) else { throw unavailable(EAGAIN) }
        let candidates = views.values.compactMap(\.view).filter { $0.remoteWindow === parent && eligible($0) }
        guard candidates.count < 2 else { throw unavailable(EBUSY) }
        let view = candidates.first
        let bounds = view?.bounds.size ?? child.geometry.size
        guard let size = LiveGPUDrawableGeometry.extent(serverPixels: child.geometry.size, visibleBounds: bounds) else {
            throw unavailable(EAGAIN)
        }
        // Until its first present the child shows the parent's picture under it.
        let content = LiveGPULayerView(frame: CGRect(origin: .zero, size: child.geometry.size), pixelExtent: size)
        content.isUserInteractionEnabled = false
        content.isOpaque = false
        content.backgroundColor = .clear
        let layer = content.metal
        layer.contentsScale = 1
        layer.drawableSize = size
        layer.framebufferOnly = false
        layer.presentsWithTransaction = false
        // The clip: what of the child its parent shows. Touches pass through to the parent.
        let clip = UIView()
        clip.clipsToBounds = true
        clip.isUserInteractionEnabled = false
        clip.backgroundColor = .clear
        clip.isOpaque = false
        clip.addSubview(content)
        view?.addSubview(clip)
        // Its own snapshot, which nothing asks for: a child's presents never replace the parent's.
        let lease = LiveGPULayerLease(identity: identity, windowID: windowID, windowIdentity: ObjectIdentifier(child),
            extent: size, view: view, content: content, snapshot: WindowSnapshot(), clip: clip)
        if view == nil {
            lease.parked = true
            #if DEBUG && canImport(CabooseGPUMemoryAudit)
            LiveGPUMemoryAudit.ownerParked(true)
            #endif
        }
        leases[windowID] = lease
        if let view { arrangeChildren(in: view) }
        watchHealth()
        return lease
    }
    func release(_ lease: LiveGPULayerLease) {
        guard leases[lease.windowID] === lease else { return }
        lease.invalidate()
        lease.hosted?.removeFromSuperview()
        if lease.translucent { lease.view?.liveGPUTranslucencyChanged() }
        lease.content?.removeFromSuperview()
        lease.content = nil
        lease.clip = nil
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
    /// One line over the window while its GPU is lost or not responding; no controls.
    private let notice = UILabel()
    init(frame: CGRect, pixelExtent: CGSize) {
        self.pixelExtent = pixelExtent
        super.init(frame: frame)
        layer.addSublayer(metal)
        notice.font = .preferredFont(forTextStyle: .caption1)
        notice.textColor = .white
        notice.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        notice.textAlignment = .center
        notice.layer.cornerRadius = 6
        notice.layer.masksToBounds = true
        notice.isHidden = true
        addSubview(notice)
        applyDrawableExtent()
    }
    func showHealth(_ state: LiveGPUWindowHealth.State) {
        switch state {
        case .running: notice.isHidden = true
        case .stalled: notice.text = "GPU not responding"; notice.isHidden = false
        case .lost: notice.text = "GPU lost"; notice.isHidden = false
        }
        setNeedsLayout()
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
        guard !notice.isHidden else { return }
        let size = notice.sizeThatFits(CGSize(width: bounds.width - 16, height: 40))
        let width = min(bounds.width - 16, size.width + 16), height = size.height + 8
        notice.frame = CGRect(x: (bounds.width - width) / 2, y: 8, width: width, height: height)
    }
    /// Whether the window's pictures carry alpha: the layer then shows what is behind it
    /// instead of sitting on black.
    var translucent = false {
        didSet {
            guard translucent != oldValue else { return }
            isOpaque = !translucent
            backgroundColor = translucent ? .clear : .black
            metal.isOpaque = !translucent
        }
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
    /// A full-screen window's picture fills the view whatever its shape.
    private var fullscreen = false
    func fit(in target: CGRect, fullscreen: Bool = false) {
        frame = target
        self.fullscreen = fullscreen
        applyDrawableExtent()
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
        let shown = pixelExtent
        // A picture of another shape than the window (an application keeping its own
        // resolution) fits it, or fills a full-screen window; the layer's GPU sampling scales it.
        let placed = LiveGPUDrawableGeometry.placement(picture: shown, in: bounds, fill: fullscreen)
        let scale = CGAffineTransform(scaleX: placed.width / shown.width, y: placed.height / shown.height)
        metal.position = CGPoint(x: placed.midX, y: placed.midY)
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
    /// A child window's clip, which holds `content` and is what its parent's view hosts;
    /// nil for a window's own layer.
    @MainActor var clip: UIView?
    /// Whether this is a child window's layer (`RemoteChildWindow`).
    let isChild: Bool
    /// The view placed in the hosting `RemoteWindowView`.
    @MainActor var hosted: UIView? { clip ?? content }
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
    /// The window's current swapchain is premultiplied: its layer is not opaque, and shows
    /// what is behind the window.
    @MainActor private(set) var translucent = false
    @MainActor func setTranslucent(_ value: Bool) {
        guard isValid, translucent != value else { return }
        translucent = value
        (content as? LiveGPULayerView)?.translucent = value
        view?.liveGPUTranslucencyChanged()
    }
    /// The window's GPU for the notice over it: presents are noted from the presenting
    /// thread, read once a second on main (LiveGPUPresentationOwners).
    private let health = LiveGPUWindowHealthTracker()
    func trackSubmission(_ serial: UInt64, _ operation: () -> LiveGPUSurfaceSubmission) -> LiveGPUSurfaceSubmission {
        health.submit(serial, at: ProcessInfo.processInfo.systemUptime, operation)
    }
    func noteReleased(_ serial: UInt64) { health.released(serial) }
    func noteDeviceLost() { health.deviceLost() }
    var healthState: LiveGPUWindowHealth.State { health.state(at: ProcessInfo.processInfo.systemUptime) }
    /// The notice currently shown over the window.
    @MainActor var shownHealth = LiveGPUWindowHealth.State.running
    private let lock = NSLock()
    private var valid = true
    private var currentExtent: CGSize
    func updateExtent(_ newExtent: CGSize) { lock.withLock { currentExtent = newExtent } }
    var isValid: Bool { lock.withLock { valid } }
    @discardableResult func invalidate() -> Bool { lock.withLock { let old = valid; valid = false; return old } }
    /// Out of view, still bound and still presenting (LiveGPUPresentationOwners).
    @MainActor var parked = false
    /// The window's snapshot, which copies of this layer's presents replace.
    let snapshot: WindowSnapshot
    @MainActor init(identity: LiveGPUSurfaceIdentity, windowID: UInt64, windowIdentity: ObjectIdentifier,
                    extent: CGSize, view: RemoteWindowView?, content: UIView, snapshot: WindowSnapshot, clip: UIView? = nil) {
        self.identity = identity; self.windowID = windowID; self.windowIdentity = windowIdentity
        self.currentExtent = extent; self.view = view; self.content = content; self.snapshot = snapshot
        self.clip = clip; self.isChild = clip != nil
    }
}
#endif
