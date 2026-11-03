#if canImport(UIKit)
import GameController
import Metal
import QuartzCore
import UIKit

/// Shows one remote window and turns touch, trackpad and keyboard into its input.
///
/// The window's picture is its GPU layer, which `LiveGPUPresentationOwners` places in the
/// one live view showing the window, fitted to its bounds; popups and override-redirect
/// windows are windows of their own, each with its own layer in its own view. Until the
/// layer's first present the view is blank: black, or clear for a window with alpha.
/// A view that never hosts the layer (a thumbnail, a preview) shows the window's snapshot
/// (`WindowSnapshot`) instead, copied into its own drawable when a new one arrives.
@MainActor
public final class RemoteWindowView: RemoteTextInputView, UIGestureRecognizerDelegate {
    public override static var layerClass: AnyClass { CAMetalLayer.self }

    public weak var session: (any DisplaySession)? {
        willSet { if session !== newValue { cancelTouches() } }
        didSet { layoutLiveGPU() }
    }
    /// The session whose windows this view shows, told of each refresh of the screen it is
    /// on so the server paces the window to it. Set it on display-only views too; it is
    /// `session` when nil.
    public weak var pacer: (any DisplaySession)?
    /// Explicit output for pacing, or nil for the session's primary output. Only an
    /// unselected bootstrap session resolves nil from the retained server hello.
    public var displayID: Int?
    /// Whether this view may run the window's live content: its GPU layer and its game. Each
    /// runs in one view at a time, so thumbnails leave it to the window's main view.
    public var showsLiveContent = true {
        didSet {
            guard showsLiveContent != oldValue else { return }
            layoutGame()
            layoutLiveGPU()
        }
    }
    /// Covers the window controls the application draws itself (`RemoteWindow.drawnControls`).
    private let drawnCover = DrawnControlsCover()
    private var laidOutDrawnControls: (controls: [CGRect], frame: CGSize, bounds: CGSize)?
    public private(set) var remoteWindow: RemoteWindow?
    public var pixelsPerPoint: CGFloat = 2
    /// When false the view only displays (thumbnails, previews).
    public var isInteractive = true {
        didSet {
            if !isInteractive { cancelTouches() }
            updateGestures()
            layoutLiveGPU()
        }
    }
    /// The game this view runs over the window's picture, when the window has one and this is
    /// its main view (see `layoutGame()`).
    private weak var gameSurface: GameSurfaceView?
    /// The desktop routes input separately but owns live game/GPU content, unlike a thumbnail.
    public var hostsGame = false { didSet { layoutLiveGPU() } }
    private weak var liveGPUOwners: LiveGPUPresentationOwners?
    /// The window is a game: its input goes to the game, not to the computer.
    private var holdsGameInput = false
    /// The content type the display link's frame rate range was set for.
    private var followedContent: WindowContentType = .none

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var displayLink: CADisplayLink?
    private var presentedGeneration: UInt64 = .max
    private var lastPointer = CGPoint.zero
    private var directDrag = DirectPointerDrag()
    private let pointerClicks = PointerClickDriver()
    private let scrollDriver = ScrollDriver()
    private var scrollUsesDirectTouch = false
    private var scrollOwnership = ScrollGestureOwnership<ObjectIdentifier>()
    private weak var secondaryTouchGesture: UITapGestureRecognizer?
    private weak var scrollTouchGesture: UIPanGestureRecognizer?
    private weak var contextTouchGesture: UILongPressGestureRecognizer?
    private weak var tapGesture: UITapGestureRecognizer?
    /// The tap being recognized is a finger's, which is aimed; a Pencil's is exact.
    private var tapIsFinger = false
    private var holdUsesPointerDrag = false
    private weak var holdWindow: RemoteWindow?
    private weak var holdSession: (any DisplaySession)?

    /// Asks the host app to show or hide the software keyboard. Set it and a tap shows the
    /// keyboard only when it lands on editable text (the app switched to a text cursor) and
    /// hides it when it lands anywhere else; leave it nil and every tap shows the keyboard.
    public var onKeyboardWanted: ((Bool) -> Void)?
    private var focusCheck: TapTextFocus?
    public init(session: (any DisplaySession)?, window: RemoteWindow?) {
        self.session = session
        super.init(frame: .zero)
        metalLayer.device = SharedMetal.shared.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = true
        metalLayer.contentsGravity = .resize
        metalLayer.presentsWithTransaction = false
        backgroundColor = .black
        isMultipleTouchEnabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(resignActive),
            name: UIApplication.willResignActiveNotification, object: nil)
        installGestures()
        attach(window)
    }

    /// Whether the view shows through where the window's picture is transparent (a popup's
    /// rounded corners and shadow); an opaque window sits on black.
    public private(set) var showsThrough = false

    /// Matches the layer and background to the window's alpha, which `window.update` can change,
    /// or to a translucent live GPU layer presenting here.
    /// The refresh range the window's content type asks for, and the idle inhibitor its
    /// application holds, while this view shows the window.
    private func followHints() {
        let shown = window != nil && !isHidden && alpha > 0.01
        IdleInhibition.shared.set(self, inhibiting: shown && (remoteWindow?.inhibitsIdle ?? false))
        let content = remoteWindow?.contentType ?? .none
        guard content != followedContent, let link = displayLink else { return }
        followedContent = content
        let range = FrameRatePolicy.range(for: content)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: range.minimum, maximum: range.maximum, preferred: range.preferred)
    }

    private func followAlpha() {
        let alpha = (remoteWindow?.hasAlpha ?? false) || (liveGPUOwners?.presentsTranslucent(in: self) ?? false)
        guard alpha != showsThrough || metalLayer.isOpaque == alpha else { return }
        showsThrough = alpha
        metalLayer.isOpaque = !alpha
        backgroundColor = alpha ? .clear : .black
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public func attach(_ window: RemoteWindow?) {
        if window !== remoteWindow {
            liveGPUOwners?.withdraw(self)
            liveGPUOwners = nil
            focusCheck = nil
            resetTyping()
            cancelTouches()
            drawnCover.removeAll()
            laidOutDrawnControls = nil
        }
        remoteWindow = window
        followField(purpose: session?.textPurpose, isCode: Self.isCodeApp(window))
        presentedGeneration = .max
        followAlpha()
        layoutGame()
        layoutLiveGPU()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        layoutLiveGPU()
        if self.window == nil {
            cancelTouches()
            focusCheck = nil
            IdleInhibition.shared.set(self, inhibiting: false)
        }
        displayLink?.invalidate()
        displayLink = nil
        guard self.window != nil, superview != nil else { return }
        // The link of the screen the view is on, a TV's included, so ticks are that screen's refreshes.
        let target = DisplayLinkTarget(self), tick = #selector(DisplayLinkTarget.tick(_:))
        let link = self.window?.windowScene?.screen.displayLink(withTarget: target, selector: tick)
            ?? CADisplayLink(target: target, selector: tick)
        let range = FrameRatePolicy.range(for: remoteWindow?.contentType ?? .none)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: range.minimum, maximum: range.maximum, preferred: range.preferred)
        followedContent = remoteWindow?.contentType ?? .none
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        metalLayer.contentsScale = pixelsPerPoint
        presentedGeneration = .max
        layoutGame()
        layoutLiveGPU()
        layoutDrawnControls()
    }

    /// Lays the covers over the application's own window controls when they, the window's
    /// size or this view's size changed (or `force`, once a cover's colour is known).
    private func layoutDrawnControls(force: Bool = false) {
        guard let window = remoteWindow else { return }
        let now = (controls: window.drawnControls, frame: window.frame.size, bounds: bounds.size)
        if !force, let laid = laidOutDrawnControls, laid.controls == now.controls, laid.frame == now.frame, laid.bounds == now.bounds { return }
        laidOutDrawnControls = now
        drawnCover.layout(in: layer, controls: now.controls, frame: now.frame)
    }

    /// Reads the colour beside the application's own window controls from the window's snapshot.
    private func sampleDrawnControls(_ texture: MTLTexture) {
        guard let window = remoteWindow, !window.drawnControls.isEmpty else { return }
        drawnCover.sample(texture, frame: window.frame.size) { [weak self] in self?.layoutDrawnControls(force: true) }
    }

    func layoutLiveGPU() {
        let owners = remoteWindow?.liveGPUPresentation
        if liveGPUOwners !== owners {
            liveGPUOwners?.withdraw(self)
            liveGPUOwners = owners
        }
        owners?.observe(self)
    }

    // MARK: Games

    /// Lays the window's game (`RemoteWindow.game`) over its picture when this view runs it:
    /// an interactive or desktop view on screen with a connection that runs live content.
    /// Thumbnail views show the window's snapshot, which is the game's last. One web view runs
    /// each game, so a view takes it only from a view that is not on screen. Touch, the pointer
    /// and keys of a game window never go to the computer.
    func layoutGame() {
        let game = remoteWindow?.game
        if (game != nil) != holdsGameInput {
            holdsGameInput = game != nil
            if holdsGameInput {
                cancelTouches()
                stopMomentum()
                resetTyping()
            }
            updateGestures()
        }
        let runs = game.map { !$0.isEnded } == true && GamePresentation.hosts(
            interactive: isInteractive, desktop: hostsGame, contentEnabled: showsLiveContent,
            hasConnection: (session ?? pacer) != nil, onScreen: window != nil)
        if let surface = gameSurface, !runs || surface.game !== game || surface.superview !== self {
            if surface.superview === self { surface.removeFromSuperview() }
            gameSurface = nil
        }
        guard runs, let game else { return }
        if gameSurface == nil {
            let surface = GameSurfaceView.surface(for: game)
            if surface.superview != nil, surface.superview !== self, surface.window != nil { return }
            let focused = isFirstResponder
            insertSubview(surface, at: 0)
            gameSurface = surface
            if focused { surface.focus() }
        }
        if let surface = gameSurface, surface.frame != bounds { surface.frame = bounds }
    }

    private func updateGestures() {
        let enabled = isInteractive && !holdsGameInput
        gestureRecognizers?.forEach { $0.isEnabled = enabled }
    }

    /// The keyboard of a game window is the game's.
    @discardableResult
    public override func becomeFirstResponder() -> Bool {
        if let gameSurface, gameSurface.superview === self { return gameSurface.focus() }
        return super.becomeFirstResponder()
    }

    /// Whether this view shows the window's snapshot: it is not a live view, so the window's
    /// GPU layer and game run elsewhere.
    var showsSnapshot: Bool { !((isInteractive || hostsGame) && showsLiveContent) }

    /// One display refresh. A live view draws nothing of its own: the GPU layer is the picture,
    /// and until it presents the view stays blank. A snapshot view shows the window's newest
    /// snapshot when it changed, and asks for fresh ones while it shows them.
    fileprivate func present() {
        followAlpha()
        followHints()
        layoutDrawnControls()
        guard let window = remoteWindow else { return }
        // Covers read their colour, and aiming its shapes, from the snapshot.
        if !window.drawnControls.isEmpty || (isInteractive && window.touchTargets.isEmpty) { window.snapshot.want() }
        if let texture = window.snapshot.texture { sampleDrawnControls(texture) }
        guard showsSnapshot else {
            if presentedGeneration != Self.cleared, clearPicture() { presentedGeneration = Self.cleared }
            return
        }
        window.snapshot.want()
        guard let picture = window.snapshot.presentation() else {
            if presentedGeneration != Self.cleared, clearPicture() { presentedGeneration = Self.cleared }
            return
        }
        let texture = picture.texture, generation = picture.generation
        guard generation != presentedGeneration else { return }
        let size = CGSize(width: texture.width, height: texture.height)
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
        // A stalled GPU returns no drawable for a second at a time: never ask for one then.
        guard !SharedMetal.shared.isStalled, let commands = SharedMetal.shared.makeCommandBuffer(),
              let drawable = metalLayer.nextDrawable(),
              let blit = commands.makeBlitCommandEncoder() else { return }
        let target = drawable.texture
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: min(texture.width, target.width), height: min(texture.height, target.height), depth: 1),
                  to: target, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        commands.present(drawable)
        commands.commit()
        presentedGeneration = generation
    }

    /// `presentedGeneration` once the view's own drawable is cleared.
    private static let cleared: UInt64 = .max - 1

    private func clearPicture() -> Bool {
        let pass = MTLRenderPassDescriptor()
        guard !SharedMetal.shared.isStalled, let commands = SharedMetal.shared.makeCommandBuffer(),
              let drawable = metalLayer.nextDrawable() else { return false }
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
        return true
    }

    /// A live GPU layer in this view turned translucent or opaque, arrived or left.
    func liveGPUTranslucencyChanged() { present() }

    // MARK: Pointer mapping

    func pixelPoint(_ point: CGPoint) -> CGPoint {
        guard let remoteWindow, bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGPoint(x: point.x * remoteWindow.frame.width / bounds.width,
                       y: point.y * remoteWindow.frame.height / bounds.height)
    }

    private func move(to point: CGPoint) {
        guard let window = remoteWindow, let session else { return }
        lastPointer = pixelPoint(point)
        session.pointerMove(in: window, to: lastPointer)
    }

    /// A finger's landing error, in millimetres (`TouchAim`), and points per millimetre.
    private static let fingerSpread: CGFloat = 1.2
    private static let pointsPerMillimetre: CGFloat = 160 / 25.4

    /// Where a finger at view `point` meant to press, in window pixels: the control it most
    /// likely meant among the window's targets, or the point itself. With `picture`, a
    /// window whose tree lists none is aimed among the shapes in its picture; a touch that may
    /// start a stroke (native touch) is not.
    func aimedPixel(_ point: CGPoint, picture: Bool = true) -> CGPoint {
        let pixel = pixelPoint(point)
        guard let window = remoteWindow, bounds.width > 0 else { return pixel }
        let spread = Self.fingerSpread * Self.pointsPerMillimetre * window.frame.width / bounds.width
        let targets = window.touchTargets.isEmpty && picture ? pictureTargets(around: pixel, spread: spread) : window.touchTargets
        return TouchAim.choose(pixel, spread: spread, among: targets)?.point ?? pixel
    }

    /// For a window whose accessibility tree lists nothing: the shapes in its snapshot
    /// around `pixel` (`PictureTargets`), in window pixels.
    private func pictureTargets(around pixel: CGPoint, spread: CGFloat) -> [TouchTarget] {
        guard let window = remoteWindow, window.frame.width > 0, window.frame.height > 0 else { return [] }
        let size = window.snapshot.pixelSize
        guard size.width > 0, size.height > 0 else { return [] }
        let sx = size.width / window.frame.width, sy = size.height / window.frame.height
        let radius = Int((3 * spread + 4) * max(sx, sy))
        let center = CGPoint(x: pixel.x * sx, y: pixel.y * sy)
        guard let region = window.snapshot.pixels(x: Int(center.x) - radius, y: Int(center.y) - radius,
                                                 width: 2 * radius, height: 2 * radius) else { return [] }
        let found = region.bytes.withUnsafeBytes {
            PictureTargets.find(in: $0, width: region.width, height: region.height, bytesPerRow: region.width * 4,
                                around: CGPoint(x: center.x - CGFloat(region.x), y: center.y - CGFloat(region.y)), radius: radius)
        }
        return found.map { target in
            var target = target
            let r = target.rect.offsetBy(dx: CGFloat(region.x), dy: CGFloat(region.y))
            target.rect = CGRect(x: r.minX / sx, y: r.minY / sy, width: r.width / sx, height: r.height / sy)
            return target
        }
    }

    private func click(at point: CGPoint, button: Int = 1, aimed: Bool = false) {
        guard let window = remoteWindow, let session else { return }
        // The application's own window controls are covered; Caboose's are the ones to use.
        if window.isOnDrawnControl(pixelPoint(point)) { return }
        // A click can move focus or the caret, so iOS must not edit text from before it.
        resetTyping()
        caretAnchor = point
        if aimed {
            lastPointer = aimedPixel(point)
            session.pointerMove(in: window, to: lastPointer)
        } else {
            move(to: point)
        }
        session.focus(window)
        pointerClicks.click(in: window, session: session, at: lastPointer, button: button)
        if button == 3 { showSecondaryClick(at: point) }
    }

    /// A right-click from a finger (two fingers tapped, or a long press) has no cursor to show
    /// where it went: a ring blooms there for a moment, with a tick, so the menu that opens is
    /// plainly the press's.
    private func showSecondaryClick(at point: CGPoint) {
        TrackpadFeedback.play(.secondaryClick)
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let ring = CAShapeLayer()
        let radius: CGFloat = 22
        ring.path = UIBezierPath(ovalIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius)).cgPath
        ring.position = point
        ring.fillColor = UIColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 0.18).cgColor
        ring.strokeColor = UIColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 0.9).cgColor
        ring.lineWidth = 1.5
        ring.opacity = 0
        layer.addSublayer(ring)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.35
        scale.toValue = 1
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0]
        fade.keyTimes = [0, 0.25, 1]
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.42
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "bloom")
        CATransaction.commit()
    }

    // MARK: Gestures

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber, UITouch.TouchType.pencil.rawValue as NSNumber]
        tapGesture = tap
        addGestureRecognizer(tap)

        let pointerClick = UITapGestureRecognizer(target: self, action: #selector(handlePointerClick(_:)))
        pointerClick.allowedTouchTypes = [UITouch.TouchType.indirectPointer.rawValue as NSNumber]
        pointerClick.buttonMaskRequired = .primary
        addGestureRecognizer(pointerClick)

        let secondaryClick = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryClick(_:)))
        secondaryClick.allowedTouchTypes = [UITouch.TouchType.indirectPointer.rawValue as NSNumber]
        secondaryClick.buttonMaskRequired = .secondary
        addGestureRecognizer(secondaryClick)

        // Every tap sends its own click immediately. Waiting for a double-tap recognizer
        // used to deliver both clicks together, losing the user's timing.
        // Two fingers tapped together right-click, as on a Mac trackpad. A single tap
        // waits for it to fail, which it does the moment one finger lifts alone.
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryClick(_:)))
        secondaryTouchGesture = twoFingerTap
        twoFingerTap.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        twoFingerTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoFingerTap)
        tap.require(toFail: twoFingerTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        contextTouchGesture = longPress
        longPress.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber, UITouch.TouchType.pencil.rawValue as NSNumber]
        longPress.minimumPressDuration = Self.contextHold
        longPress.allowableMovement = 10
        longPress.delegate = self
        addGestureRecognizer(longPress)

        // Mouse-only windows: a finger pans content; hold before moving to drag.
        // Pencil strokes retain direct drawing/selection.
        let touchDrag = UIPanGestureRecognizer(target: self, action: #selector(handleTouchDrag(_:)))
        touchDrag.allowedTouchTypes = [UITouch.TouchType.pencil.rawValue as NSNumber]
        touchDrag.maximumNumberOfTouches = 1
        touchDrag.allowedScrollTypesMask = []
        touchDrag.delegate = self
        addGestureRecognizer(touchDrag)

        let pointerDrag = UIPanGestureRecognizer(target: self, action: #selector(handlePointerDrag(_:)))
        pointerDrag.allowedTouchTypes = [UITouch.TouchType.indirectPointer.rawValue as NSNumber]
        pointerDrag.allowedScrollTypesMask = []
        addGestureRecognizer(pointerDrag)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        scroll.allowedScrollTypesMask = []
        scroll.minimumNumberOfTouches = 1
        scroll.maximumNumberOfTouches = 2
        scroll.delegate = self
        scrollTouchGesture = scroll
        addGestureRecognizer(scroll)
        // Movement fails the stationary hold and immediately releases the pan. Once
        // the hold wins it owns the contact through lift, so it cannot also scroll.
        scroll.require(toFail: longPress)
        tap.require(toFail: longPress)

        // Hardware wheel/trackpad events do not have direct finger contacts.
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        wheel.allowedTouchTypes = []
        wheel.allowedScrollTypesMask = .all
        wheel.delegate = self
        addGestureRecognizer(wheel)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)

        // Native touch stays with the app, except the two-finger secondary tap. Its
        // recognition cancels the native sequence; movement fails it, preserving pinches.
        for recognizer in [tap, pointerClick, secondaryClick, twoFingerTap, pointerDrag] { recognizer.delegate = self }
    }

    public func gestureRecognizer(_ gesture: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    public func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gesture === contextTouchGesture, let hold = gesture as? UILongPressGestureRecognizer {
            holdUsesPointerDrag = touch.type == .direct && remoteWindow?.acceptsTouch == false
            // A finger on a mouse-only window aims after a short hold; elsewhere a hold is a
            // context press.
            hold.minimumPressDuration = holdUsesPointerDrag ? Self.aimHold : Self.contextHold
            holdWindow = remoteWindow
            holdSession = session
        }
        if gesture === tapGesture { tapIsFinger = touch.type == .direct }
        return gesture === secondaryTouchGesture || gesture === contextTouchGesture || !routesNatively(touch)
    }

    public override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        return super.gestureRecognizerShouldBegin(gesture)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        stopMomentum()
        click(at: gesture.location(in: self), aimed: tapIsFinger)
        tapped()
    }

    @objc private func handlePointerClick(_ gesture: UITapGestureRecognizer) {
        stopMomentum()
        click(at: gesture.location(in: self))
        tapped()
    }

    private func tapped() {
        followField(purpose: session?.textPurpose, isCode: Self.isCodeApp(remoteWindow))
        guard onKeyboardWanted != nil, let session else {
            if !isFirstResponder { becomeFirstResponder() }
            return
        }
        focusCheck = TapTextFocus(since: CACurrentMediaTime(), serial: session.cursorSerial)
    }

    /// The app answers a tap by redrawing the cursor: a text cursor means a text field took
    /// focus. Waits briefly for a fresh cursor; an unchanged one is still the answer, and a
    /// server that names no cursors needs the owner's explicit keyboard control.
    fileprivate func checkFocus() {
        guard let check = focusCheck, let session, let onKeyboardWanted else { return }
        guard let isText = check.keyboardWanted(at: CACurrentMediaTime(), serial: session.cursorSerial,
                                               isText: session.cursorIsText, keyboardVisible: isFirstResponder) else { return }
        // The app says what the field takes: its keyboard, AutoFill and whether it is prose.
        if isText { followField(purpose: session.textPurpose, isCode: Self.isCodeApp(remoteWindow)) }
        onKeyboardWanted(isText)
        focusCheck = nil
    }

    /// When this view last hid the keyboard for a field its window left.
    private var fieldLeftHandled: TimeInterval = 0
    /// How long a left field may stay left before the keyboard goes: focus moving to the next
    /// field turns text input off and on again within it.
    private static let fieldExitGrace: TimeInterval = 0.3

    /// The keyboard goes when the window's field loses focus for good, as iOS's does: after
    /// Return in a search box or an address bar, or a click that leaves the field. A
    /// hardware keyboard keeps the view first responder: it shows no keyboard to hide.
    fileprivate func followFieldExit() {
        guard isFirstResponder, GCKeyboard.coalesced == nil, let window = remoteWindow, let left = session?.textFieldLeft,
              left.window == window.id, left.at != fieldLeftHandled,
              ProcessInfo.processInfo.systemUptime - left.at >= Self.fieldExitGrace else { return }
        fieldLeftHandled = left.at
        focusCheck = nil
        if let onKeyboardWanted { onKeyboardWanted(false) } else { _ = resignFirstResponder() }
    }

    /// Focus moving between fields with the keyboard up (Tab from a username to its
    /// password) changes the keyboard with it.
    fileprivate func followFieldPurpose() {
        guard isFirstResponder, let session, session.textPurpose != fieldPurpose else { return }
        followField(purpose: session.textPurpose, isCode: Self.isCodeApp(remoteWindow))
    }

    private var adoptedSurrounding = 0

    /// The focused field's real text before its caret, where its app reports it, becomes
    /// what the keyboard edits. A selection in the app is left to the keystroke path.
    fileprivate func adoptSurroundingText() {
        guard isFirstResponder, let window = remoteWindow, let report = session?.surroundingText,
              report.window == window.id, report.serial != adoptedSurrounding else { return }
        adoptedSurrounding = report.serial
        guard !report.text.hasSelection else { return }
        adoptRemoteText(beforeCaret: report.text.beforeCaret)
    }

    @objc private func handleSecondaryClick(_ gesture: UITapGestureRecognizer) {
        stopMomentum()
        if gesture === secondaryTouchGesture { cancelTouches() }
        click(at: gesture.location(in: self), button: 3, aimed: gesture === secondaryTouchGesture)
    }

    public override func resignFirstResponder() -> Bool {
        focusCheck = nil
        return super.resignFirstResponder()
    }

    private static let contextHold: TimeInterval = 0.65
    private static let aimHold: TimeInterval = 0.3

    /// Native touch and Pencil retain context holds. A mouse-only finger hold aims the
    /// pointer (`PointerAim`); two-finger tap still opens its context menu.
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        if aim.phase != .idle || (gesture.state == .began && holdUsesPointerDrag) {
            return followAim(gesture.state, at: point)
        }
        guard gesture.state == .began, let window = holdWindow, let session = holdSession,
              remoteWindow === window, self.session === session,
              isInteractive, self.window != nil, session.state == .ready,
              session.windows[window.id] === window else { return }
        // Defer secondary click by one run-loop turn so a queued touch-up from a quick tap
        // during a main-thread stall drains before the long-press timer can cancel it.
        let hadNativeTouch = !activeTouches.isEmpty || pencilPoint != nil
        DispatchQueue.main.async { [weak self, weak gesture, weak window, weak session] in
            guard let self, let gesture, let window, let session,
                  gesture.state == .began || gesture.state == .changed,
                  self.remoteWindow === window, self.session === session,
                  self.isInteractive, self.window != nil, session.state == .ready,
                  session.windows[window.id] === window,
                  !hadNativeTouch || !self.activeTouches.isEmpty || self.pencilPoint != nil
            else { return }
            self.cancelTouches()
            self.stopMomentum()
            self.click(at: point, button: 3)
        }
    }

    // MARK: Aiming

    private var aim = PointerAim()
    private var aimLoupe: UITextLoupeSession?
    private var aimMark: CAShapeLayer?
    /// The target the aim is on, by index into the window's targets, for its tick.
    private var aimTarget: Int?
    /// Where the press went down, against where the finger aimed then, while dragging.
    private var aimDragOffset = CGPoint.zero
    private var aimTimer: DispatchWorkItem?
    private let aimTick = UISelectionFeedbackGenerator()

    private func followAim(_ state: UIGestureRecognizer.State, at point: CGPoint) {
        let now = CACurrentMediaTime()
        switch state {
        case .began:
            guard let window = holdWindow, let session = holdSession, remoteWindow === window, self.session === session,
                  isInteractive, self.window != nil, session.state == .ready, session.windows[window.id] === window else { return }
            cancelTouches()
            stopMomentum()
            focusCheck = nil
            session.focus(window)
            aim.begin(at: point, time: now)
            aimTarget = nil
            aimLoupe = UITextLoupeSession.begin(at: point, fromSelectionWidgetView: nil, in: self)
            aimTick.prepare()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showAim()
            scheduleAimPress()
        case .changed:
            aim.move(to: point, time: now)
            showAim()
            if aim.phase == .aiming { scheduleAimPress() }
            if aim.phase == .dragging { session?.trackDragOut(at: convert(point, to: nil)) }
        case .ended:
            let (pixel, _) = aimedPoint()
            switch aim.end() {
            case .aiming:
                if let window = remoteWindow, let session {
                    resetTyping()
                    caretAnchor = viewPoint(pixel)
                    lastPointer = pixel
                    session.pointerMove(in: window, to: pixel)
                    pointerClicks.click(in: window, session: session, at: pixel, button: 1)
                    TrackpadFeedback.play(.click)
                    tapped()
                }
            case .dragging:
                session?.takeDragIfOver(convert(point, to: nil))
                if let window = remoteWindow { session?.pointerButton(in: window, button: 1, pressed: false, at: pixel) }
                TrackpadFeedback.play(.dragEnded)
            case .idle: break
            }
            endAim()
        default:
            if aim.end() == .dragging, let window = remoteWindow {
                session?.pointerButton(in: window, button: 1, pressed: false, at: aimedPoint().pixel)
            }
            endAim()
        }
    }

    /// Where the aim presses, in window pixels, and the target it snapped to: while aiming,
    /// the target nearest the pointer by a third of a finger's spread (the owner sees exactly
    /// where it is); while dragging, the finger's path from where the press went down.
    private func aimedPoint() -> (pixel: CGPoint, target: (index: Int, rect: CGRect)?) {
        let pixel = pixelPoint(aim.point)
        if aim.phase == .dragging {
            return (CGPoint(x: pixel.x + aimDragOffset.x, y: pixel.y + aimDragOffset.y), nil)
        }
        guard let window = remoteWindow, !window.touchTargets.isEmpty, bounds.width > 0 else { return (pixel, nil) }
        let spread = Self.fingerSpread / 3 * Self.pointsPerMillimetre * window.frame.width / bounds.width
        guard let choice = TouchAim.choose(pixel, spread: spread, among: window.touchTargets) else { return (pixel, nil) }
        return (choice.point, (choice.index, window.touchTargets[choice.index].rect))
    }

    /// A window pixel in this view's points.
    private func viewPoint(_ pixel: CGPoint) -> CGPoint {
        guard let window = remoteWindow, window.frame.width > 0, window.frame.height > 0 else { return pixel }
        return CGPoint(x: pixel.x * bounds.width / window.frame.width, y: pixel.y * bounds.height / window.frame.height)
    }

    private func viewRect(_ pixels: CGRect) -> CGRect {
        let origin = viewPoint(pixels.origin), end = viewPoint(CGPoint(x: pixels.maxX, y: pixels.maxY))
        return CGRect(x: origin.x, y: origin.y, width: end.x - origin.x, height: end.y - origin.y)
    }

    /// Hovers the pointer where it aims, outlines the target it would press, moves the loupe,
    /// and ticks when the target changes.
    private func showAim() {
        guard let window = remoteWindow, let session else { return }
        let (pixel, target) = aimedPoint()
        lastPointer = pixel
        session.pointerMove(in: window, to: pixel)
        if target?.index != aimTarget {
            aimTarget = target?.index
            if target != nil { aimTick.selectionChanged() }
        }
        let point = viewPoint(pixel)
        let mark = aimMark ?? {
            let layer = CAShapeLayer()
            layer.fillColor = UIColor.clear.cgColor
            layer.strokeColor = UIColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 0.95).cgColor
            layer.lineWidth = 2
            layer.zPosition = 10
            self.layer.addSublayer(layer)
            aimMark = layer
            return layer
        }()
        let path = UIBezierPath(ovalIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
        if let rect = target?.rect {
            path.append(UIBezierPath(roundedRect: viewRect(rect).insetBy(dx: -2, dy: -2), cornerRadius: 4))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.path = path.cgPath
        CATransaction.commit()
        let caret = target.map { viewRect($0.rect) } ?? CGRect(x: point.x - 1, y: point.y - 8, width: 2, height: 16)
        aimLoupe?.move(to: point, withCaretRect: caret, trackingCaret: false)
    }

    /// Presses the button once the finger has held still long enough while aiming.
    private func scheduleAimPress() {
        aimTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.aimPressIfDue() }
        aimTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, aim.dragTime - CACurrentMediaTime()), execute: item)
    }

    private func aimPressIfDue() {
        guard aim.phase == .aiming else { return }
        guard aim.dragDue(at: CACurrentMediaTime()) else { return scheduleAimPress() }
        guard let window = remoteWindow, let session, session.state == .ready else { return }
        let (pixel, _) = aimedPoint()
        let raw = pixelPoint(aim.point)
        aimDragOffset = CGPoint(x: pixel.x - raw.x, y: pixel.y - raw.y)
        aim.startDrag()
        session.pointerMove(in: window, to: pixel)
        session.pointerButton(in: window, button: 1, pressed: true, at: pixel)
        TrackpadFeedback.play(.dragBegan)
        showAim()
    }

    private func endAim() {
        aimTimer?.cancel()
        aimTimer = nil
        aimLoupe?.invalidate()
        aimLoupe = nil
        aimMark?.removeFromSuperlayer()
        aimMark = nil
        aimTarget = nil
    }

    @objc private func handleTouchDrag(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            pointerClicks.cancel()
            stopMomentum()
            focusCheck = nil
            if let window = remoteWindow { session?.focus(window) }
            sendDirectDrag(directDrag.begin(at: point, translation: gesture.translation(in: self)))
        case .changed:
            sendDirectDrag(directDrag.move(to: point))
        case .ended:
            sendDirectDrag(directDrag.end(at: point))
        case .cancelled, .failed:
            sendDirectDrag(directDrag.cancel())
        default: break
        }
    }

    private func sendDirectDrag(_ actions: [DirectPointerDrag.Action]) {
        guard let window = remoteWindow, let session else { return }
        for action in actions {
            switch action {
            case .move(let point): move(to: point)
            case .button(let point, let pressed):
                session.pointerButton(in: window, button: 1, pressed: pressed, at: pixelPoint(point))
            }
        }
    }

    @objc private func handlePointerDrag(_ gesture: UIPanGestureRecognizer) {
        guard let window = remoteWindow, let session else { return }
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            pointerClicks.cancel()
            stopMomentum()
            move(to: point)
            session.pointerButton(in: window, button: 1, pressed: true, at: lastPointer)
        case .changed:
            move(to: point)
            session.trackDragOut(at: convert(point, to: nil))
        default:
            if gesture.state == .ended { session.takeDragIfOver(convert(point, to: nil)) }
            session.pointerButton(in: window, button: 1, pressed: false, at: pixelPoint(point))
        }
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        // A Pencil hovering above an iPad (zOffset above zero) is in a tablet's proximity.
        if gesture.zOffset > 0, let window = remoteWindow, window.acceptsPencil, let session {
            let point = pixelPoint(gesture.location(in: self))
            let hovering = gesture.state == .began || gesture.state == .changed
            let azimuth = Double(gesture.azimuthAngle(in: self))
            session.pencil(PencilSample(phase: hovering ? .hover : .leave, x: Double(point.x), y: Double(point.y), pressure: 0,
                                        tilt: PencilSample.tilt(altitude: Double(gesture.altitudeAngle), azimuth: azimuth),
                                        azimuth: Self.degrees(azimuth)), in: window)
            return
        }
        guard gesture.state == .began || gesture.state == .changed else { return }
        move(to: gesture.location(in: self))
    }

    // MARK: Native touch and Pencil

    /// Fingers down on a window that takes touch: their slots and last positions, so a
    /// view that goes away mid-touch can cancel them.
    private var touchSlots = TouchSlots<ObjectIdentifier>()
    private var activeTouches: [ObjectIdentifier: (slot: Int, point: CGPoint)] = [:]
    /// How far a lone finger's touch-down was aimed (`aimedPixel`), in window pixels; the
    /// rest of its contact keeps the same offset, so a drag from it is unchanged.
    private var touchAim: (finger: ObjectIdentifier, offset: CGPoint)?
    /// The first finger of a native touch sequence, to tell a tap (which may focus a text
    /// field, so the keyboard question is asked) from a drag.
    private var tapCandidate: (finger: ObjectIdentifier, at: CFTimeInterval, location: CGPoint)?
    /// Every finger and Pencil that went down to the app. The rest of a touch goes wherever
    /// it began, even if the window's touch support changes meanwhile.
    private var nativeTouches = Set<ObjectIdentifier>()

    /// Where a Pencil that is down on the app last was, so it can be cancelled.
    private var pencilPoint: CGPoint?

    private func isNative(_ touch: UITouch) -> Bool { nativeTouches.contains(ObjectIdentifier(touch)) }

    private func routesNatively(_ touch: UITouch) -> Bool {
        guard isInteractive, session != nil, let window = remoteWindow, window.game == nil else { return false }
        switch touch.type {
        case .direct: return window.acceptsTouch
        case .pencil: return window.acceptsPencil
        default: return false
        }
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // A finger down stops content the computer is coasting, as on a touchpad.
        if touches.contains(where: { $0.type == .direct }) { session?.holdScroll() }
        // A second contact belongs to the current recognizer. Its topology check
        // cancels the whole gesture; do not silently strand an active driver here.
        if !scrollOwnership.isActive { stopMomentum() }
        let native = touches.filter(routesNatively)
        nativeTouches.formUnion(native.map(ObjectIdentifier.init))
        if !native.isEmpty {
            stopMomentum()
            if let first = native.first, activeTouches.isEmpty, native.count == 1, first.type == .direct {
                tapCandidate = (ObjectIdentifier(first), first.timestamp, first.location(in: self))
            } else {
                tapCandidate = nil
            }
            deliver(native, .down, event)
        }
        let rest = touches.subtracting(native)
        if !rest.isEmpty { super.touchesBegan(rest, with: event) }
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let native = touches.filter(isNative)
        if let candidate = tapCandidate, let touch = native.first(where: { ObjectIdentifier($0) == candidate.finger }) {
            let location = touch.location(in: self)
            if hypot(location.x - candidate.location.x, location.y - candidate.location.y) > 10 { tapCandidate = nil }
        }
        deliver(native, .motion, event)
        let rest = touches.subtracting(native)
        if !rest.isEmpty { super.touchesMoved(rest, with: event) }
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let native = touches.filter(isNative)
        nativeTouches.subtract(native.map(ObjectIdentifier.init))
        deliver(native, .up, event)
        if let candidate = tapCandidate, let touch = native.first(where: { ObjectIdentifier($0) == candidate.finger }) {
            tapCandidate = nil
            if touch.timestamp - candidate.at < 0.35, activeTouches.isEmpty {
                // The app takes the tap itself; ask afterwards whether it focused a text field.
                resetTyping()
                caretAnchor = touch.location(in: self)
                tapped()
            }
        }
        let rest = touches.subtracting(native)
        if !rest.isEmpty { super.touchesEnded(rest, with: event) }
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        let native = touches.filter(isNative)
        nativeTouches.subtract(native.map(ObjectIdentifier.init))
        tapCandidate = nil
        deliver(native, .cancel, event)
        let rest = touches.subtracting(native)
        if !rest.isEmpty { super.touchesCancelled(rest, with: event) }
    }

    /// One `touch` message per UIKit event is one wl_touch.frame: every finger that changed, together.
    private func deliver(_ touches: Set<UITouch>, _ phase: TouchPhase, _ event: UIEvent?) {
        guard !touches.isEmpty, let window = remoteWindow, let session else { return }
        var points: [TouchPoint] = []
        for touch in touches {
            if touch.type == .pencil {
                deliverPencil(touch, phase, event, window, session)
                continue
            }
            let key = ObjectIdentifier(touch)
            let slot = touchSlots.slot(for: key)
            var point = pixelPoint(touch.location(in: self))
            if phase == .down {
                touchAim = nil
                if touches.count == 1, activeTouches.isEmpty {
                    let aimed = aimedPixel(touch.location(in: self), picture: false)
                    if aimed != point { touchAim = (key, CGPoint(x: aimed.x - point.x, y: aimed.y - point.y)) }
                }
            }
            if let aim = touchAim, aim.finger == key { point.x += aim.offset.x; point.y += aim.offset.y }
            let force = touch.maximumPossibleForce > 0 ? Double(touch.force / touch.maximumPossibleForce) : nil
            points.append(TouchPoint(slot: slot, phase: phase, x: Double(point.x), y: Double(point.y), force: force,
                                     radius: Double(touch.majorRadius * window.frame.width / max(1, bounds.width))))
            if phase == .up || phase == .cancel {
                touchSlots.release(key)
                activeTouches[key] = nil
                if touchAim?.finger == key { touchAim = nil }
            } else {
                activeTouches[key] = (slot, point)
            }
        }
        // A computer drag follows the finger to the phone's own target; lifted there, it is
        // the phone's, taken before the lift reaches the computer.
        if session.computerDrag != nil, let finger = touches.first(where: { $0.type != .pencil }) {
            let location = convert(finger.location(in: self), to: nil)
            if phase == .motion { session.trackDragOut(at: location) }
            if phase == .up { session.takeDragIfOver(location) }
        }
        if !points.isEmpty { session.touch(points, in: window) }
    }

    /// Pencil samples arrive at up to 240 Hz, coalesced into each 120 Hz event; all of them go,
    /// so strokes keep their shape.
    private func deliverPencil(_ touch: UITouch, _ phase: TouchPhase, _ event: UIEvent?, _ window: RemoteWindow, _ session: any DisplaySession) {
        if phase == .down { resetTyping() }
        let samples = phase == .motion ? (event?.coalescedTouches(for: touch) ?? [touch]) : [touch]
        let pencilPhase = PencilPhase(rawValue: phase.rawValue) ?? .motion
        for sample in samples {
            let point = pixelPoint(sample.location(in: self))
            let pressure = phase == .up || phase == .cancel ? 0
                : sample.maximumPossibleForce > 0 ? min(1, Double(sample.force / sample.maximumPossibleForce)) : 0.5
            let azimuth = Double(sample.azimuthAngle(in: self))
            pencilPoint = phase == .up || phase == .cancel ? nil : point
            session.pencil(PencilSample(phase: pencilPhase, x: Double(point.x), y: Double(point.y), pressure: pressure,
                                        tilt: PencilSample.tilt(altitude: Double(sample.altitudeAngle), azimuth: azimuth),
                                        azimuth: Self.degrees(azimuth)), in: window)
        }
    }

    @objc private func resignActive() {
        cancelTouches()
    }

    /// Lifts every finger the app still thinks is down, e.g. when the view leaves the screen.
    @objc private func cancelTouches() {
        pointerClicks.cancel()
        stopMomentum()
        sendDirectDrag(directDrag.cancel())
        if aim.phase != .idle {
            if aim.end() == .dragging, let window = remoteWindow {
                session?.pointerButton(in: window, button: 1, pressed: false, at: lastPointer)
            }
            endAim()
        }
        if let window = remoteWindow, let session {
            if !activeTouches.isEmpty {
                session.touch(activeTouches.values.map { TouchPoint(slot: $0.slot, phase: .cancel, x: Double($0.point.x), y: Double($0.point.y)) },
                              in: window)
            }
            if let point = pencilPoint {
                session.pencil(PencilSample(phase: .cancel, x: Double(point.x), y: Double(point.y), pressure: 0, tilt: (0, 0), azimuth: 0), in: window)
            }
        }
        pencilPoint = nil
        activeTouches.removeAll()
        touchSlots.removeAll()
        nativeTouches.removeAll()
        tapCandidate = nil
    }

    /// Radians as compass degrees, 0 ≤ d < 360.
    static func degrees(_ radians: Double) -> Double {
        let degrees = radians * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Native touch retains the application's own gestures and fling. Emulated pans
    /// send precise deltas once per display frame, followed by client-side inertia.
    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        let now = CACurrentMediaTime()
        let owner = ObjectIdentifier(gesture)
        switch gesture.state {
        case .began:
            stopMomentum()
            pointerClicks.cancel()
            focusCheck = nil
            guard let session, let remoteWindow else { return }
            session.resetScroll()
            move(to: gesture.location(in: self))
            scrollUsesDirectTouch = gesture.numberOfTouches > 0
            let anchor = lastPointer
            let scale = pixelsPerPoint
            let geometry = bounds
            let size = remoteWindow.frame.size
            let epoch = session.epoch
            let connection = (session as? CabooseDisplaySession)?.connections
            scrollOwnership.begin(owner, contacts: gesture.numberOfTouches)
            scrollDriver.begin(at: now - 1.0 / 120) { [weak self, weak session, weak remoteWindow] delta, lift in
                guard let self, let session, let remoteWindow, self.isInteractive,
                      self.window != nil, self.session === session, self.remoteWindow === remoteWindow,
                      session.state == .ready, session.windows[remoteWindow.id] === remoteWindow,
                      session.epoch == epoch, (session as? CabooseDisplaySession)?.connections == connection,
                      self.pixelsPerPoint == scale, self.bounds == geometry, remoteWindow.frame.size == size
                else { return false }
                func mapped(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: p.x * size.width / max(1, geometry.width), y: p.y * size.height / max(1, geometry.height))
                }
                // The finger's distance in window pixels: the computer scrolls content exactly that far,
                // and on from the lift as its input system coasts.
                let delta = mapped(delta)
                session.scroll(in: remoteWindow, dx: delta.x, dy: delta.y, at: anchor, lift: lift.map(mapped))
                return true
            }
            appendScroll(gesture, at: now)
        case .changed:
            guard scrollOwnership.update(owner, contacts: gesture.numberOfTouches) else {
                if !scrollOwnership.isActive { scrollDriver.cancel() }
                return
            }
            appendScroll(gesture, at: now)
        case .ended:
            guard scrollOwnership.end(owner) else { return }
            appendScroll(gesture, at: now)
            let velocity = gesture.velocity(in: self)
            // Indirect hardware scrolling already includes OS momentum.
            scrollDriver.end(at: now, velocity: CGPoint(x: -velocity.x, y: -velocity.y), coast: scrollUsesDirectTouch)
        case .cancelled, .failed:
            if scrollOwnership.end(owner) { scrollDriver.cancel() }
        default: break
        }
    }

    private func appendScroll(_ gesture: UIPanGestureRecognizer, at time: TimeInterval) {
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        guard translation != .zero else { return }
        let delta = CGPoint(x: -translation.x, y: -translation.y)
        scrollDriver.append(delta, at: time)
    }

    private func stopMomentum() {
        scrollOwnership.cancel()
        scrollDriver.cancel()
    }

    // MARK: Keyboard — the software keyboard through UITextInput, hardware keys through presses.

    public override var canBecomeFirstResponder: Bool { isInteractive }
    public override var inputAccessoryView: UIView? { isInteractive ? super.inputAccessoryView : nil }

    /// The freedesktop categories of a window's desktop entry, as the app's list of the
    /// computer's apps knows them; empty when no entry is known. Set by the app.
    public static var windowCategories: @MainActor (RemoteWindow) -> [String] = { _ in [] }

    /// A window whose app types code, by its desktop entry's categories
    /// (`TextPurposeTraits.typesCode`): autocorrect and automatic capitals get in the way.
    public static func isCodeApp(_ window: RemoteWindow?) -> Bool {
        guard let window else { return false }
        return TextPurposeTraits.typesCode(categories: windowCategories(window))
    }

    public override func send(_ edits: [TypingBuffer.Edit]) {
        guard !holdsGameInput else { return }
        session?.edit(edits, in: remoteWindow)
    }

    /// Caboose Display composes IME text in the app itself (text-input-v3 preedit).
    public override var sendsMarkedTextAsPreedit: Bool { session?.composesText ?? false }

    public override func sendPreedit(_ text: String, selection: NSRange) {
        guard !holdsGameInput else { return }
        session?.compose(text, selection: selection, in: remoteWindow)
    }

    public override func insertText(_ text: String) {
        let modified = hasStickyModifiers
        super.insertText(text)
        if !modified, (text == "\n" || text == "\r" || text == "\r\n"), !Self.isCodeApp(remoteWindow) {
            dismissKeyboard()
        }
    }

    public override func dismissKeyboard() {
        focusCheck = nil
        onKeyboardWanted?(false)
        super.dismissKeyboard()
    }

    /// The session puts the images and files on the computer's clipboard, then Control-V
    /// pastes them into this window, if it is still the one shown.
    public override func pasteItems() -> Bool {
        guard let session, let window = remoteWindow, let take = session.onPasteItems else { return false }
        return take { [weak self, weak session, weak window] in
            guard let self, let session, let window, self.session === session, self.remoteWindow === window,
                  let stroke = Keysyms.stroke(for: "v") else { return }
            self.sendKey(stroke, modifiers: ["control"])
        }
    }

    public override func sendKey(_ stroke: KeyStroke, modifiers: [String]) {
        guard !holdsGameInput else { return }
        session?.key(stroke, pressed: true, in: remoteWindow, extraModifiers: modifiers)
        session?.key(stroke, pressed: false, in: remoteWindow, extraModifiers: modifiers)
    }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Keys the game's page left unhandled travel on up the responder chain, not to the computer.
        guard !holdsGameInput else { return super.pressesBegan(presses, with: event) }
        resetTyping()
        var unhandled = Set<UIPress>()
        for press in presses {
            if let (stroke, modifiers) = Self.stroke(for: press) {
                session?.key(stroke, pressed: true, in: remoteWindow, extraModifiers: modifiers)
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard !holdsGameInput else { return super.pressesEnded(presses, with: event) }
        var unhandled = Set<UIPress>()
        for press in presses {
            if let (stroke, modifiers) = Self.stroke(for: press) {
                session?.key(stroke, pressed: false, in: remoteWindow, extraModifiers: modifiers)
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }

    private static let specialKeys: [UIKeyboardHIDUsage: String] = [
        .keyboardReturnOrEnter: "Return", .keyboardDeleteOrBackspace: "BackSpace", .keyboardTab: "Tab",
        .keyboardEscape: "Escape", .keyboardDeleteForward: "Delete", .keyboardLeftArrow: "Left",
        .keyboardRightArrow: "Right", .keyboardUpArrow: "Up", .keyboardDownArrow: "Down",
        .keyboardHome: "Home", .keyboardEnd: "End", .keyboardPageUp: "Page_Up", .keyboardPageDown: "Page_Down",
        .keyboardF1: "F1", .keyboardF2: "F2", .keyboardF3: "F3", .keyboardF4: "F4", .keyboardF5: "F5",
        .keyboardF6: "F6", .keyboardF7: "F7", .keyboardF8: "F8", .keyboardF9: "F9", .keyboardF10: "F10",
        .keyboardF11: "F11", .keyboardF12: "F12",
    ]

    /// A hardware key as an X keystroke plus held modifiers. ⌘ maps to Control so the
    /// Mac shortcuts people already know (⌘C, ⌘V, ⌘T) do the same thing in Linux apps.
    static func stroke(for press: UIPress) -> (KeyStroke, [String])? {
        guard let key = press.key else { return nil }
        var modifiers: [String] = []
        if key.modifierFlags.contains(.shift) { modifiers.append("shift") }
        if key.modifierFlags.contains(.control) || key.modifierFlags.contains(.command) { modifiers.append("control") }
        if key.modifierFlags.contains(.alternate) { modifiers.append("mod1") }
        if let name = specialKeys[key.keyCode], var stroke = Keysyms.special[name] {
            stroke.physicalCode = Int(key.keyCode.rawValue)
            return (stroke, modifiers)
        }
        guard let character = key.charactersIgnoringModifiers.first,
              var stroke = Keysyms.stroke(for: modifiers.contains("shift") ? Character(String(character).uppercased()) : character)
        else { return nil }
        stroke.physicalCode = Int(key.keyCode.rawValue)
        stroke.modifiers = []
        return (stroke, modifiers)
    }
}

/// Breaks the CADisplayLink → view retain cycle.
private final class DisplayLinkTarget: NSObject {
    weak var view: RemoteWindowView?
    init(_ view: RemoteWindowView) { self.view = view }

    @MainActor @objc func tick(_ link: CADisplayLink) {
        guard let view else { link.invalidate(); return }
        // A window shown is a window paced: the server releases its frames on these ticks,
        // at the screen's own rate (120 Hz on ProMotion).
        if let pacer = view.pacer ?? view.session, view.remoteWindow != nil {
            pacer.displayWillRefresh(view.displayID, targetTimestamp: link.targetTimestamp)
        }
        view.checkFocus()
        view.followFieldExit()
        view.followFieldPurpose()
        view.adoptSurroundingText()
        view.layoutGame()
        view.layoutLiveGPU()
        view.present()
    }
}
#endif
