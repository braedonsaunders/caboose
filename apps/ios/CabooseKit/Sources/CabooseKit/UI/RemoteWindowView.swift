#if canImport(UIKit)
import Metal
import QuartzCore
import UIKit

/// Shows one remote window and turns touch, trackpad and keyboard into its input.
///
/// The layer's drawable is the window's own pixel size and the view's bounds are that
/// size divided by `pixelsPerPoint`, so pixels land 1:1 on a scale that matches it.
/// Presentation copies the window texture into the drawable only when a draw changed it.
@MainActor
public final class RemoteWindowView: RemoteTextInputView, UIGestureRecognizerDelegate {
    public override static var layerClass: AnyClass { CAMetalLayer.self }

    public weak var session: (any DisplaySession)? {
        willSet { if session !== newValue { cancelTouches(); localScroll?.cancel() } }
        didSet { layoutLiveGPU() }
    }
    /// The session whose pictures this view shows, told of each refresh of the screen it is
    /// on so the server paces the window to it. Set it on display-only views too; it is
    /// `session` when nil.
    public weak var pacer: (any DisplaySession)?
    /// Explicit output for pacing, or nil for the session's primary output. Only an
    /// unselected bootstrap session resolves nil from the retained server hello.
    public var displayID: Int?
    /// Whether this view plays the window's videos. A video plays in one view at a time, so
    /// thumbnails leave it to the window's main view.
    public var showsVideo = true {
        didSet {
            guard showsVideo != oldValue else { return }
            laidOutVideos = nil
            if !showsVideo { releaseVideos() }
            layoutLiveGPU()
        }
    }
    private var laidOutVideos: (window: ObjectIdentifier, layout: Int, size: CGSize, bounds: CGRect)?
    private var hostedVideos: [CALayer] = []
    public private(set) var remoteWindow: RemoteWindow?
    public var pixelsPerPoint: CGFloat = 2
    /// The containing slot adopts the drawable's size before it is presented.
    public var onPictureSizeChanged: ((CGSize) -> Void)?
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
    #if canImport(CabooseGPUStream)
    /// The GPU stream this view shows over the window's picture (see `layoutGPUStream()`).
    private weak var gpuStreamView: GPUStreamView?
    #endif
    /// The window is a game: its input goes to the game, not to the computer.
    private var holdsGameInput = false

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var displayLink: CADisplayLink?
    private var presentedPictureSize: CGSize = .zero
    private var presentedGeneration: UInt64 = .max
    private var lastPointer = CGPoint.zero
    private var directDrag = DirectPointerDrag()
    private var holdingDirectDrag = false
    private let pointerClicks = PointerClickDriver()
    private let scrollDriver = ScrollDriver()
    private var scrollUsesDirectTouch = false
    /// Phone-owned scrolling of the window's picture (docs/display.md, "Phone-owned
    /// scrolling"); nil where Metal cannot run it.
    private lazy var localScroll: LocalScrollController? = {
        let made = LocalScrollController()
        made?.pictureOverscan = { [weak self] texture in
            self?.pictureOverscan(CGSize(width: texture.width, height: texture.height)) ?? .zero
        }
        return made
    }()
    /// The current pan scrolls through `localScroll` rather than `scrollDriver`.
    private var scrollIsLocal = false
    /// `localScroll` has been used: refreshes go through it.
    private var localScrollEngaged = false
    /// The touch that began now stopped a moving scroll, so its tap does not click.
    private var touchStoppedScroll = false
    /// The overscan this view asked for its window, and when it last scrolled locally.
    private var overscanAsked: (window: ObjectIdentifier, size: CGSize)?
    private var lastLocalScroll: CFTimeInterval = -.infinity
    /// A live GPU layer here sends its presented pictures for local scrolling.
    private var liveGPUCaptures = false
    private var liveGPUCaptureDropNoted = false
    /// Where local scrolling draws over a live GPU layer, shown only while it composes.
    private var scrollOverlay: CAMetalLayer?
    private var scrollOwnership = ScrollGestureOwnership<ObjectIdentifier>()
    private weak var secondaryTouchGesture: UITapGestureRecognizer?
    private weak var contextTouchGesture: UILongPressGestureRecognizer?
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
        metalLayer.device = SurfaceRenderer.shared.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = true
        metalLayer.contentsGravity = .resize
        metalLayer.presentsWithTransaction = false
        backgroundColor = .black
        isMultipleTouchEnabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(resignActive),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(releaseScrollMemory),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        installGestures()
        attach(window)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public func attach(_ window: RemoteWindow?) {
        if window !== remoteWindow {
            endOverscan()
            liveGPUOwners?.withdraw(self)
            liveGPUOwners = nil
            presentedPictureSize = .zero
            releaseVideos()
            focusCheck = nil
            resetTyping()
            cancelTouches()
            localScroll?.cancel()
            liveGPUCaptures = false
            laidOutVideos = nil
        }
        remoteWindow = window
        prefersProse = autocorrectChoice ?? !Self.isCodeApp(window)
        presentedGeneration = .max
        metalLayer.isOpaque = !(window?.hasAlpha ?? false)
        layoutGame()
        layoutLiveGPU()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        layoutLiveGPU()
        if self.window == nil {
            cancelTouches()
            endOverscan()
            localScroll?.cancel()
            focusCheck = nil
            releaseVideos()
        }
        displayLink?.invalidate()
        displayLink = nil
        guard self.window != nil, superview != nil else { return }
        // The link of the screen the view is on, a TV's included, so ticks are that screen's refreshes.
        let target = DisplayLinkTarget(self), tick = #selector(DisplayLinkTarget.tick(_:))
        let link = self.window?.windowScene?.screen.displayLink(withTarget: target, selector: tick)
            ?? CADisplayLink(target: target, selector: tick)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        laidOutVideos = nil
        metalLayer.contentsScale = pixelsPerPoint
        presentedGeneration = .max
        layoutGame()
        layoutGPUStream()
        layoutLiveGPU()
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
    /// an interactive or desktop view on screen with a connection that plays its media. Thumbnail
    /// views show the window's picture, which is the game's last snapshot. One web view runs
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
            interactive: isInteractive, desktop: hostsGame, contentEnabled: showsVideo,
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

    /// Lays the window's GPU stream over its picture in its interactive or desktop view. Touches
    /// pass through to this view: the application runs on the computer and takes its input there.
    func layoutGPUStream() {
        #if canImport(CabooseGPUStream)
        let hosts = GamePresentation.hosts(interactive: isInteractive, desktop: hostsGame,
            contentEnabled: showsVideo, hasConnection: (session ?? pacer) != nil, onScreen: window != nil)
        let shown = remoteWindow?.gpuStream.flatMap { hosts ? $0.view : nil }
        if let current = gpuStreamView, current !== shown {
            if current.superview === self { current.removeFromSuperview() }
            gpuStreamView = nil
        }
        guard let shown else { return }
        if gpuStreamView == nil {
            if shown.superview != nil, shown.superview !== self, shown.window != nil { return }
            shown.isUserInteractionEnabled = false
            insertSubview(shown, at: 0)
            gpuStreamView = shown
        }
        if shown.frame != bounds { shown.frame = bounds }
        #endif
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

    /// Puts each of the window's videos over its picture: the stream's layer at its `rect`,
    /// inside a container cut to its `clip`, in `z` order. Runs only when one of them changed.
    func layoutVideos() {
        let window = showsVideo ? remoteWindow : nil
        let key = window.map { (ObjectIdentifier($0), $0.videoLayout, $0.surface.pixelSize, bounds) }
        if let key, let laid = laidOutVideos, laid == key { return }
        if key == nil, hostedVideos.isEmpty { return }
        laidOutVideos = key
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let videos = window?.videos ?? []
        // An ended video stays over its region until this view has shown the window picture
        // that repaints it; until then the layout is looked at again every refresh.
        var retiring: [CALayer] = []
        for container in hostedVideos where container.superlayer === layer && !videos.contains(where: { $0.container === container }) {
            if let repaint = window?.retiringVideos[ObjectIdentifier(container)],
               presentedGeneration == .max || presentedGeneration < repaint {
                retiring.append(container)
            } else {
                container.removeFromSuperlayer()
            }
        }
        if !retiring.isEmpty { laidOutVideos = nil }
        for (index, video) in videos.enumerated() {
            let geometry = VideoLayerGeometry(rect: video.rect, clip: video.clip,
                                              surfaceSize: window?.surface.pixelSize ?? .zero, bounds: bounds)
            if video.container.superlayer !== layer { layer.addSublayer(video.container) }
            video.container.isHidden = geometry == nil
            if let geometry {
                video.container.frame = geometry.container
                video.layer.frame = geometry.picture
            }
            // Negative protocol z values still play above the window's own picture.
            video.container.zPosition = CGFloat(index + 1)
        }
        hostedVideos = videos.map(\.container) + retiring
        CATransaction.commit()
    }

    private func releaseVideos() {
        for container in hostedVideos where container.superlayer === layer {
            container.removeFromSuperlayer()
        }
        hostedVideos.removeAll()
        laidOutVideos = nil
    }

    /// One display refresh of the window's picture: the phone's own composition while it
    /// owns the scroll, the app's picture otherwise.
    fileprivate func refreshPicture(at targetTime: CFTimeInterval) {
        let liveGPU = liveGPUOwners?.presents(in: self) ?? false
        if (localScrollEngaged || liveGPU), let localScroll, let window = remoteWindow {
            // A live GPU layer presents itself; local scrolling draws over it.
            let target = liveGPU ? overlay() : metalLayer
            let composed = localScroll.refresh(at: targetTime, surface: liveGPU ? nil : window.surface, layer: target)
            followLocalScroll()
            showOverlay(liveGPU && composed)
            if composed {
                // When the app's picture returns it is drawn afresh.
                if !liveGPU { presentedGeneration = .max }
                return
            }
        } else {
            showOverlay(false)
        }
        present()
    }

    private func overlay() -> CAMetalLayer {
        if let scrollOverlay, scrollOverlay.superlayer === layer {
            if scrollOverlay.frame != bounds { scrollOverlay.frame = bounds }
            return scrollOverlay
        }
        let made = CAMetalLayer()
        made.device = SurfaceRenderer.shared.device
        made.framebufferOnly = true
        made.isOpaque = true
        made.contentsGravity = .resize
        made.presentsWithTransaction = false
        made.isHidden = true
        made.frame = bounds
        // Above the live GPU layer, below the videos laid over the picture.
        made.zPosition = 0.5
        layer.addSublayer(made)
        scrollOverlay = made
        return made
    }

    private func showOverlay(_ shown: Bool) {
        guard let scrollOverlay, scrollOverlay.isHidden == shown else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollOverlay.isHidden = !shown
        // A hidden overlay keeps no stale composition to show when it next appears.
        if !shown { scrollOverlay.contents = nil }
        CATransaction.commit()
    }

    /// A live GPU layer in this view presented `texture` (its own copy, read only until
    /// `release`), for local scrolling to start from and measure.
    func liveGPUPictureCaptured(_ texture: MTLTexture, serial: UInt64, release: @escaping @Sendable () -> Void) {
        guard isInteractive, window != nil, let localScroll, liveGPUOwners?.presents(in: self) ?? false else {
            if !liveGPUCaptureDropNoted {
                liveGPUCaptureDropNoted = true
                LocalScrollProfile.note("gpu capture dropped window=\(remoteWindow?.id ?? 0) interactive=\(isInteractive) onScreen=\(window != nil) renderer=\(localScroll != nil) presentsHere=\(liveGPUOwners?.presents(in: self) ?? false)")
            }
            release()
            return
        }
        if !liveGPUCaptures {
            LocalScrollProfile.note("gpu captures arriving window=\(remoteWindow?.id ?? 0) \(texture.width)x\(texture.height) format=\(texture.pixelFormat.rawValue)")
        }
        liveGPUCaptures = true
        localScroll.offer(texture, serial: serial, done: release)
    }

    /// Video layers over the picture move with the content the phone is scrolling.
    private func followLocalScroll() {
        let shift = localScroll?.contentShift ?? .zero
        guard let window = remoteWindow, window.frame.width > 0, window.frame.height > 0 else { return }
        let liveGPU = liveGPUOwners?.presents(in: self) ?? false
        let picture = (liveGPU ? localScroll?.pictureSize : nil) ?? window.presentationSize
        let offset = CGPoint(x: shift.x * bounds.width / max(1, picture.width), y: shift.y * bounds.height / max(1, picture.height))
        let transform = offset == .zero ? CATransform3DIdentity : CATransform3DMakeTranslation(offset.x, offset.y, 0)
        guard hostedVideos.contains(where: { !CATransform3DEqualToTransform($0.transform, transform) }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for container in hostedVideos { container.transform = transform }
        CATransaction.commit()
    }

    fileprivate func present() {
        guard let picture = remoteWindow?.surface.presentation() else { return }
        let texture = picture.texture, generation = picture.generation
        guard generation != presentedGeneration else { return }
        // An overscan picture shows its viewport.
        let overscan = pictureOverscan(CGSize(width: texture.width, height: texture.height))
        let size = CGSize(width: CGFloat(texture.width) - overscan.width.rounded(), height: CGFloat(texture.height) - overscan.height.rounded())
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
        guard let drawable = metalLayer.nextDrawable(),
              let commands = SurfaceRenderer.shared.queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { return }
        adoptPictureSize(size)
        let target = drawable.texture
        let width = min(texture.width, target.width, Int(size.width)), height = min(texture.height, target.height, Int(size.height))
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: target, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        commands.present(drawable)
        commands.commit()
        presentedGeneration = generation
    }

    /// Called after acquiring a drawable. Adoption belongs to the attached window,
    /// even when its first picture has the same dimensions as the preceding window.
    func adoptPictureSize(_ size: CGSize) {
        guard presentedPictureSize != size else { return }
        presentedPictureSize = size
        remoteWindow?.adoptPictureSize(size)
        // Guest picture replacement is atomic; slot geometry keeps its animation.
        UIView.performWithoutAnimation { onPictureSizeChanged?(size) }
    }

    // MARK: Pointer mapping

    func pixelPoint(_ point: CGPoint) -> CGPoint {
        guard let remoteWindow, bounds.width > 0, bounds.height > 0 else { return .zero }
        var mapped = CGPoint(x: point.x * remoteWindow.frame.width / bounds.width,
                             y: point.y * remoteWindow.frame.height / bounds.height)
        // With an overscan, what the viewport shows after the scrolling region (a footer)
        // is the picture's end, the overscan further on in the window.
        if let anchored = localScroll?.anchoredFrom {
            let vertical = anchored.axis == .vertical
            let along = (vertical ? point.y / bounds.height : point.x / bounds.width) * CGFloat(anchored.viewport)
            if along >= CGFloat(anchored.start) {
                if vertical { mapped.y += remoteWindow.overscan.height } else { mapped.x += remoteWindow.overscan.width }
            }
        }
        return mapped
    }

    /// How many of `picture`'s pixels lie past the viewport, right and below: the window's
    /// overscan once its pictures are of the enlarged window (by their shape), none before.
    func pictureOverscan(_ picture: CGSize) -> CGSize {
        guard croppingOverscan, let window = remoteWindow, picture.width > 0, picture.height > 0,
              window.frame.width > 0, window.frame.height > 0 else { return .zero }
        // By shape alone: the picture may still be of the enlarged window after the overscan
        // was announced over, or already before its announcement settles.
        let tall = picture.height - picture.width * window.frame.height / window.frame.width
        let wide = picture.width - picture.height * window.frame.width / window.frame.height
        if tall > 2 { return CGSize(width: 0, height: tall.rounded()) }
        if wide > 2 { return CGSize(width: wide.rounded(), height: 0) }
        return .zero
    }

    /// The window was asked for, or still shows, an overscan: pictures longer than the
    /// viewport's shape are its enlarged pictures and show their viewport, never scaled.
    var croppingOverscan: Bool {
        overscanAsked != nil || remoteWindow?.overscan != .zero || CACurrentMediaTime() < overscanLingersUntil
    }
    /// Pictures of an ended overscan may still arrive until the app has resized.
    private var overscanLingersUntil: CFTimeInterval = 0
    /// When this window's scrolling region was last known, kept so a reset of the scroll
    /// model (a resize, a lost run) does not flap the overscan off and on.
    private var regionKnownAt: CFTimeInterval = -.infinity

    private func move(to point: CGPoint) {
        guard let window = remoteWindow, let session else { return }
        lastPointer = pixelPoint(point)
        session.pointerMove(in: window, to: lastPointer)
    }

    private func click(at point: CGPoint, button: Int = 1) {
        guard let window = remoteWindow, let session else { return }
        // A click can move focus or the caret, so iOS must not edit text from before it.
        resetTyping()
        caretAnchor = point
        move(to: point)
        session.focus(window)
        pointerClicks.click(in: window, session: session, at: lastPointer, button: button)
        if button == 3 { showSecondaryClick(at: point) }
    }

    /// A right-click from a finger (two fingers tapped, or a long press) has no cursor to show
    /// where it went: a ring blooms there for a moment, with a tick, so the menu that opens is
    /// plainly the press's.
    private func showSecondaryClick(at point: CGPoint) {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.7)
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
        longPress.minimumPressDuration = 0.5
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
        if gesture === contextTouchGesture {
            holdUsesPointerDrag = touch.type == .direct && remoteWindow?.acceptsTouch == false
            holdWindow = remoteWindow
            holdSession = session
        }
        return gesture === secondaryTouchGesture || gesture === contextTouchGesture || !routesNatively(touch)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // As in any iOS scroll view, a tap on moving content only stops it.
        if touchStoppedScroll { touchStoppedScroll = false; return }
        stopMomentum()
        localScroll?.interrupt()
        click(at: gesture.location(in: self))
        tapped()
    }

    @objc private func handlePointerClick(_ gesture: UITapGestureRecognizer) {
        stopMomentum()
        click(at: gesture.location(in: self))
        tapped()
    }

    private func tapped() {
        prefersProse = autocorrectChoice ?? !Self.isCodeApp(remoteWindow)
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
        // The app says what the field takes: no autocorrect in a terminal or a password.
        if isText, autocorrectChoice == nil, let purpose = session.textPurpose {
            prefersProse = !["terminal", "password", "pin", "url", "email", "number", "digits", "phone", "date", "time", "datetime"]
                .contains(purpose)
        }
        onKeyboardWanted(isText)
        focusCheck = nil
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
        click(at: gesture.location(in: self), button: 3)
    }

    public override func resignFirstResponder() -> Bool {
        focusCheck = nil
        return super.resignFirstResponder()
    }

    /// Native touch and Pencil retain context holds. A mouse-only finger hold grabs
    /// content instead; two-finger tap still opens its context menu.
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            guard let window = holdWindow, let session = holdSession,
                  remoteWindow === window, self.session === session,
                  isInteractive, self.window != nil, session.state == .ready,
                  session.windows[window.id] === window else { return }
            let drag = holdUsesPointerDrag
            cancelTouches()
            stopMomentum()
            if drag {
                holdingDirectDrag = true
                focusCheck = nil
                session.focus(window)
                sendDirectDrag(directDrag.begin(at: point, translation: .zero))
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } else {
                click(at: point, button: 3)
            }
        case .changed:
            if holdingDirectDrag { sendDirectDrag(directDrag.move(to: point)) }
        case .ended:
            if holdingDirectDrag { sendDirectDrag(directDrag.end(at: point)) }
            holdingDirectDrag = false
        case .cancelled, .failed:
            if holdingDirectDrag { sendDirectDrag(directDrag.cancel()) }
            holdingDirectDrag = false
        default: break
        }
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
        default:
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
        // A second contact belongs to the current recognizer. Its topology check
        // cancels the whole gesture; do not silently strand an active driver here.
        if !scrollOwnership.isActive {
            touchStoppedScroll = localScroll?.isMoving ?? false
            stopMomentum()
        }
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
            let point = pixelPoint(touch.location(in: self))
            let force = touch.maximumPossibleForce > 0 ? Double(touch.force / touch.maximumPossibleForce) : nil
            points.append(TouchPoint(slot: slot, phase: phase, x: Double(point.x), y: Double(point.y), force: force,
                                     radius: Double(touch.majorRadius * window.frame.width / max(1, bounds.width))))
            if phase == .up || phase == .cancel {
                touchSlots.release(key)
                activeTouches[key] = nil
            } else {
                activeTouches[key] = (slot, point)
            }
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
        endOverscan()
        localScroll?.cancel()
    }

    /// Overscan windows (docs/display.md, "Overscan"): while this window has been scrolled
    /// locally within the last 30 seconds and its scrolling region is measured, the app is
    /// laid out one viewport longer along the scroll axis, so the content a flick reveals is
    /// already drawn. Asked for and ended only at rest, never mid-scroll.
    fileprivate func followOverscanPolicy(at now: CFTimeInterval) {
        guard let localScroll, let session, let window = remoteWindow, isInteractive, self.window != nil,
              !localScroll.isActive else { return }
        if localScroll.model.region != nil { regionKnownAt = now }
        let scrolling = now - lastLocalScroll < 30 && now - regionKnownAt < 30 && !window.isFullscreen
        var wanted = CGSize.zero
        if scrolling {
            // About one viewport, in steps of 64 pixels so a viewport a pixel off does not
            // ask again, and the whole picture within 4096 pixels per axis.
            func step(_ extent: CGFloat) -> CGFloat { max(0, min((extent / 64).rounded() * 64, 4096 - extent)) }
            if localScroll.model.axis == .vertical { wanted.height = step(window.frame.height) }
            else { wanted.width = step(window.frame.width) }
        }
        let key = ObjectIdentifier(window)
        let asked = overscanAsked?.window == key ? overscanAsked!.size : .zero
        guard wanted != asked else { return }
        LocalScrollProfile.note("overscan request window=\(window.id) \(Int(wanted.width))x\(Int(wanted.height))")
        session.requestOverscan(window, wanted)
        if wanted == .zero, overscanAsked != nil { overscanLingersUntil = now + 3 }
        overscanAsked = wanted == .zero ? nil : (key, wanted)
    }

    private func endOverscan() {
        guard let asked = overscanAsked, let window = remoteWindow, ObjectIdentifier(window) == asked.window else { return }
        session?.requestOverscan(window, .zero)
        overscanAsked = nil
    }

    /// Captured pictures are the scroll's largest memory: under pressure they go, and the
    /// next gesture starts from a fresh picture.
    @objc private func releaseScrollMemory() {
        guard !(localScroll?.isActive ?? false) else { return }
        localScroll?.cancel()
        LocalScrollRenderer.shared?.drain()
    }

    /// Lifts every finger the app still thinks is down, e.g. when the view leaves the screen.
    @objc private func cancelTouches() {
        pointerClicks.cancel()
        stopMomentum()
        sendDirectDrag(directDrag.cancel())
        holdingDirectDrag = false
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
            let directContent = scrollUsesDirectTouch
            let anchor = lastPointer
            let scale = pixelsPerPoint
            let geometry = bounds
            let size = remoteWindow.frame.size
            let epoch = session.epoch
            let connection = (session as? CabooseDisplaySession)?.connections
            scrollOwnership.begin(owner, contacts: gesture.numberOfTouches)
            if directContent, beginLocalScroll(at: now - 1.0 / 120, location: gesture.location(in: self),
                                                 translation: gesture.translation(in: self)) {
                // As in UIScrollView, the content starts with the finger from here: the
                // recognizer's slop before it began is not a jump.
                gesture.setTranslation(.zero, in: self)
                return
            }
            if directContent { LocalScrollProfile.note("pan window=\(remoteWindow.id) local=no \(localScrollState(remoteWindow))") }
            scrollIsLocal = false
            scrollDriver.begin(at: now - 1.0 / 120) { [weak self, weak session, weak remoteWindow] delta in
                guard let self, let session, let remoteWindow, self.isInteractive,
                      self.window != nil, self.session === session, self.remoteWindow === remoteWindow,
                      session.state == .ready, session.windows[remoteWindow.id] === remoteWindow,
                      session.epoch == epoch, (session as? CabooseDisplaySession)?.connections == connection,
                      self.pixelsPerPoint == scale, self.bounds == geometry, remoteWindow.frame.size == size
                else { return false }
                let mapped = CGPoint(x: delta.x * size.width / max(1, geometry.width),
                                     y: delta.y * size.height / max(1, geometry.height))
                let precise = DirectScrollCalibration.preciseDelta(mapped, directContent: directContent)
                session.scroll(in: remoteWindow, dx: precise.x, dy: precise.y, at: anchor)
                return true
            }
            appendScroll(gesture, at: now)
        case .changed:
            guard scrollOwnership.update(owner, contacts: gesture.numberOfTouches) else {
                if !scrollOwnership.isActive { scrollDriver.cancel(); if scrollIsLocal { localScroll?.halt(at: now) } }
                return
            }
            appendScroll(gesture, at: now)
        case .ended:
            guard scrollOwnership.end(owner) else { return }
            appendScroll(gesture, at: now)
            let velocity = gesture.velocity(in: self)
            if scrollIsLocal {
                localScroll?.release(at: now, velocity: CGPoint(x: -velocity.x, y: -velocity.y), coast: true)
                return
            }
            // Indirect hardware scrolling already includes OS momentum.
            scrollDriver.end(at: now, velocity: CGPoint(x: -velocity.x, y: -velocity.y), coast: scrollUsesDirectTouch)
        case .cancelled, .failed:
            if scrollOwnership.end(owner) {
                scrollDriver.cancel()
                if scrollIsLocal { localScroll?.halt(at: now) }
            }
        default: break
        }
    }

    private func appendScroll(_ gesture: UIPanGestureRecognizer, at time: TimeInterval) {
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        guard translation != .zero else { return }
        let delta = CGPoint(x: -translation.x, y: -translation.y)
        if scrollIsLocal { localScroll?.track(delta, at: time) } else { scrollDriver.append(delta, at: time) }
    }

    private func stopMomentum() {
        scrollOwnership.cancel()
        scrollDriver.cancel()
        localScroll?.halt(at: CACurrentMediaTime())
    }

    /// Starts a phone-owned scroll of a finger at `location` whose pan has moved
    /// `translation` so far, when this window can scroll locally. The pointer is already at
    /// `location`. The scroll forwards to the app only while the session, window, connection
    /// and mapping it began with stay current.
    private func beginLocalScroll(at time: TimeInterval, location: CGPoint, translation: CGPoint) -> Bool {
        guard let localScroll, let session, let remoteWindow, canScrollLocally(remoteWindow) else { return false }
        let anchor = lastPointer, scale = pixelsPerPoint, geometry = bounds, size = remoteWindow.frame.size
        let epoch = session.epoch, connection = (session as? CabooseDisplaySession)?.connections
        let liveGPU = liveGPUOwners?.presents(in: self) ?? false
        guard let whole = liveGPU ? localScroll.pictureSize : remoteWindow.surface.presentation().map({ CGSize(width: $0.texture.width, height: $0.texture.height) }) ?? remoteWindow.presentationSize,
              whole.width > 0, whole.height > 0 else { return false }
        // The viewport's share of the picture: an overscan picture is longer than it shows.
        let extra = pictureOverscan(whole)
        let picture = CGSize(width: whole.width - extra.width, height: whole.height - extra.height)
        let toPicture = CGSize(width: picture.width / max(1, geometry.width), height: picture.height / max(1, geometry.height))
        let toFrame = CGSize(width: size.width / max(1, picture.width), height: size.height / max(1, picture.height))
        scrollIsLocal = true
        localScrollEngaged = true
        lastLocalScroll = CACurrentMediaTime()
        LocalScrollProfile.note("pan window=\(remoteWindow.id) local=yes path=\(liveGPU ? "gpu" : "video") picture=\(Int(picture.width))x\(Int(picture.height)) \(localScrollState(remoteWindow))")
        localScroll.begin(at: time, delta: CGPoint(x: -translation.x, y: -translation.y),
                          anchor: CGPoint(x: location.x * toPicture.width, y: location.y * toPicture.height), scale: toPicture) {
            [weak self, weak session, weak remoteWindow] delta, _ in
            guard let self, let session, let remoteWindow, self.isInteractive,
                  self.window != nil, self.session === session, self.remoteWindow === remoteWindow,
                  session.state == .ready, session.windows[remoteWindow.id] === remoteWindow,
                  session.epoch == epoch, (session as? CabooseDisplaySession)?.connections == connection,
                  self.pixelsPerPoint == scale, self.bounds == geometry, remoteWindow.frame.size == size
            else { return false }
            let mapped = CGPoint(x: delta.x * toFrame.width, y: delta.y * toFrame.height)
            let precise = DirectScrollCalibration.preciseDelta(mapped, directContent: true)
            session.scroll(in: remoteWindow, dx: precise.x, dy: precise.y, at: anchor)
            return true
        }
        return true
    }

    // MARK: Synthetic replay

    private var replay: LocalScrollReplay?

    /// `CABOOSE_SCROLL_REPLAY=1`: once this interactive window has been on screen for three
    /// seconds, the standard flick script plays through the same local scroll path as a
    /// finger, for `LocalScrollProfile` to measure on the device.
    fileprivate func driveReplay(at time: CFTimeInterval) {
        guard LocalScrollReplay.enabled, isInteractive, window != nil, let session, session.state == .ready,
              let remoteWindow, canScrollLocally(remoteWindow) else { replay = nil; return }
        if replay == nil { replay = LocalScrollReplay(start: time + 3) }
        guard let events = replay?.events(until: time), !events.isEmpty else { return }
        let location = CGPoint(x: bounds.midX, y: bounds.midY)
        for event in events {
            switch event {
            case .begin(let label, let at, let delta):
                localScroll?.profile.label(label)
                stopMomentum()
                move(to: location)
                if !beginLocalScroll(at: at, location: location, translation: CGPoint(x: -delta.x, y: -delta.y)) { replay = nil; return }
                localScroll?.track(delta, at: at)
            case .move(let at, let delta):
                localScroll?.track(delta, at: at)
            case .release(let at, let velocity):
                localScroll?.release(at: at, velocity: velocity, coast: true)
            }
        }
    }

    /// For diagnosis: what decides whether this window scrolls locally.
    private func localScrollState(_ window: RemoteWindow) -> String {
        let presenter = liveGPUOwners?.presenter(of: window)
        let lease = presenter.map { ($0.view === self ? "here" : $0.view == nil ? "gone" : "other-view") + ($0.valid ? "" : "-invalid") } ?? "none"
        return "renderer=\(localScroll != nil) game=\(window.game != nil) gpuStream=\(window.gpuStream != nil) owners=\(liveGPUOwners != nil) gpuLease=\(lease) gpuCaptures=\(liveGPUCaptures) interactive=\(isInteractive)"
    }

    /// Phone-owned scrolling covers windows whose picture this view draws, and live GPU
    /// windows whose presented pictures arrive here; not games or GPU streams.
    private func canScrollLocally(_ window: RemoteWindow) -> Bool {
        window.game == nil && window.gpuStream == nil && (liveGPUCaptures || !(liveGPUOwners?.presents(in: self) ?? false))
    }

    // MARK: Keyboard — the software keyboard through UITextInput, hardware keys through presses.

    public override var canBecomeFirstResponder: Bool { isInteractive }
    public override var inputAccessoryView: UIView? { isInteractive ? super.inputAccessoryView : nil }

    /// Terminals and code editors, where autocorrect and automatic capitals get in the way.
    public static func isCodeApp(_ window: RemoteWindow?) -> Bool {
        guard let app = window?.appClass else { return false }
        let name = "\(app.instance) \(app.name)".lowercased()
        return ["term", "xterm", "kitty", "alacritty", "konsole", "foot", "tilix", "wezterm", "ghostty",
                "code", "codium", "cursor", "zed", "vim", "emacs", "mousepad", "gedit", "kate", "sublime"]
            .contains { name.contains($0) }
    }

    public override func send(_ edits: [TypingBuffer.Edit]) {
        guard !holdsGameInput else { return }
        localScroll?.interrupt()
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

    public override func sendKey(_ stroke: KeyStroke, modifiers: [String]) {
        guard !holdsGameInput else { return }
        localScroll?.interrupt()
        session?.key(stroke, pressed: true, in: remoteWindow, extraModifiers: modifiers)
        session?.key(stroke, pressed: false, in: remoteWindow, extraModifiers: modifiers)
    }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Keys the game's page left unhandled travel on up the responder chain, not to the computer.
        guard !holdsGameInput else { return super.pressesBegan(presses, with: event) }
        resetTyping()
        localScroll?.interrupt()
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
        if let name = specialKeys[key.keyCode], let stroke = Keysyms.special[name] { return (stroke, modifiers) }
        guard let character = key.charactersIgnoringModifiers.first,
              let stroke = Keysyms.stroke(for: modifiers.contains("shift") ? Character(String(character).uppercased()) : character)
        else { return nil }
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
        view.adoptSurroundingText()
        view.layoutGame()
        view.layoutGPUStream()
        view.layoutLiveGPU()
        view.driveReplay(at: CACurrentMediaTime())
        view.refreshPicture(at: link.targetTimestamp)
        view.followOverscanPolicy(at: CACurrentMediaTime())
        view.layoutVideos()
    }
}
#endif
