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
public final class RemoteWindowView: UIView, UIKeyInput, UITextInputTraits, UIGestureRecognizerDelegate {
    public override static var layerClass: AnyClass { CAMetalLayer.self }

    public weak var session: XpraSession?
    public private(set) var remoteWindow: RemoteWindow?
    public var pixelsPerPoint: CGFloat = 2
    /// When false the view only displays (thumbnails, previews).
    public var isInteractive = true {
        didSet { gestureRecognizers?.forEach { $0.isEnabled = isInteractive } }
    }

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var displayLink: CADisplayLink?
    private var presentedGeneration: UInt64 = .max
    private var lastPointer = CGPoint.zero
    private var dragging = false
    private var longPressMoved = false
    private var scrollRemainder = CGPoint.zero
    private var momentum = CGPoint.zero
    private var momentumLink: CADisplayLink?

    /// Asks the host app to show or hide the software keyboard. Set it and a tap shows the
    /// keyboard only when it lands on editable text (the app switched to a text cursor) and
    /// hides it when it lands anywhere else; leave it nil and every tap shows the keyboard.
    public var onKeyboardWanted: ((Bool) -> Void)?
    private var focusCheck: (since: CFTimeInterval, serial: Int)?
    /// Ctrl/Alt from the key bar, applied to the next key and then released.
    private var stickyModifiers = Set<String>()
    private lazy var keyBar: KeyBar = {
        let bar = KeyBar()
        bar.onAction = { [weak self] action in self?.keyBarAction(action) }
        return bar
    }()

    public init(session: XpraSession?, window: RemoteWindow?) {
        self.session = session
        super.init(frame: .zero)
        metalLayer.device = SurfaceRenderer.shared.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = true
        metalLayer.contentsGravity = .topLeft
        metalLayer.presentsWithTransaction = false
        backgroundColor = .black
        isMultipleTouchEnabled = true
        installGestures()
        attach(window)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public func attach(_ window: RemoteWindow?) {
        remoteWindow = window
        presentedGeneration = .max
        metalLayer.isOpaque = !(window?.hasAlpha ?? false)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard self.window != nil, superview != nil else { return }
        let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        metalLayer.contentsScale = pixelsPerPoint
        presentedGeneration = .max
    }

    fileprivate func present() {
        guard let surface = remoteWindow?.surface, let texture = surface.texture else { return }
        let generation = surface.generation
        guard generation != presentedGeneration else { return }
        let size = CGSize(width: texture.width, height: texture.height)
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
        guard let drawable = metalLayer.nextDrawable(),
              let commands = SurfaceRenderer.shared.queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { return }
        let target = drawable.texture
        let width = min(texture.width, target.width), height = min(texture.height, target.height)
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: target, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        commands.present(drawable)
        commands.commit()
        presentedGeneration = generation
    }

    // MARK: Pointer mapping

    private func pixelPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * pixelsPerPoint, y: point.y * pixelsPerPoint)
    }

    private func move(to point: CGPoint) {
        guard let window = remoteWindow, let session else { return }
        lastPointer = pixelPoint(point)
        session.pointerMove(in: window, to: lastPointer)
    }

    private func click(at point: CGPoint, button: Int = 1) {
        guard let window = remoteWindow, let session else { return }
        move(to: point)
        session.focus(window)
        session.pointerButton(in: window, button: button, pressed: true, at: lastPointer)
        session.pointerButton(in: window, button: button, pressed: false, at: lastPointer)
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

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        tap.require(toFail: doubleTap)

        // Two fingers tapped together right-click, as on a Mac trackpad. A single tap
        // waits for it to fail, which it does the moment one finger lifts alone.
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryClick(_:)))
        twoFingerTap.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        twoFingerTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoFingerTap)
        tap.require(toFail: twoFingerTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.allowableMovement = .greatestFiniteMagnitude
        longPress.delegate = self
        addGestureRecognizer(longPress)

        let pointerDrag = UIPanGestureRecognizer(target: self, action: #selector(handlePointerDrag(_:)))
        pointerDrag.allowedTouchTypes = [UITouch.TouchType.indirectPointer.rawValue as NSNumber]
        pointerDrag.allowedScrollTypesMask = []
        addGestureRecognizer(pointerDrag)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        scroll.allowedScrollTypesMask = .all
        scroll.maximumNumberOfTouches = 2
        scroll.delegate = self
        addGestureRecognizer(scroll)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
    }

    public func gestureRecognizer(_ gesture: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    public override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        if gesture is UIPanGestureRecognizer, dragging { return false }
        return true
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        stopMomentum()
        click(at: gesture.location(in: self))
        tapped()
    }

    @objc private func handlePointerClick(_ gesture: UITapGestureRecognizer) {
        click(at: gesture.location(in: self))
        tapped()
    }

    private func tapped() {
        guard onKeyboardWanted != nil, let session else {
            if !isFirstResponder { becomeFirstResponder() }
            return
        }
        focusCheck = (CACurrentMediaTime(), session.cursorSerial)
    }

    /// The app answers a tap by redrawing the cursor: a text cursor means a text field took
    /// focus. Waits briefly for a fresh cursor; an unchanged one is still the answer, and a
    /// server that names no cursors falls back to showing the keyboard.
    fileprivate func checkFocus() {
        guard let check = focusCheck, let session, let onKeyboardWanted else { return }
        let elapsed = CACurrentMediaTime() - check.since
        let fresh = session.cursorSerial != check.serial
        guard fresh || elapsed > 0.35 else { return }
        if let isText = session.cursorIsText {
            onKeyboardWanted(isText)
            focusCheck = nil
        } else if elapsed > 1.2 {
            onKeyboardWanted(true)
            focusCheck = nil
        }
    }

    @objc private func handleSecondaryClick(_ gesture: UITapGestureRecognizer) {
        click(at: gesture.location(in: self), button: 3)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        click(at: point)
        click(at: point)
    }

    /// Long press opens a context menu; long press then move drags with the primary button.
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let window = remoteWindow, let session else { return }
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            longPressMoved = false
            move(to: point)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .changed:
            if !longPressMoved {
                longPressMoved = true
                dragging = true
                session.focus(window)
                session.pointerButton(in: window, button: 1, pressed: true, at: lastPointer)
            }
            move(to: point)
        case .ended, .cancelled:
            if longPressMoved {
                session.pointerButton(in: window, button: 1, pressed: false, at: pixelPoint(point))
            } else {
                click(at: point, button: 3)
            }
            dragging = false
        default:
            break
        }
    }

    @objc private func handlePointerDrag(_ gesture: UIPanGestureRecognizer) {
        guard let window = remoteWindow, let session else { return }
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            move(to: point)
            session.pointerButton(in: window, button: 1, pressed: true, at: lastPointer)
        case .changed:
            move(to: point)
        default:
            session.pointerButton(in: window, button: 1, pressed: false, at: pixelPoint(point))
        }
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed else { return }
        move(to: gesture.location(in: self))
    }

    /// Swiping scrolls, like any iOS app: content follows the finger, with momentum after release.
    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopMomentum()
            scrollRemainder = .zero
            session?.resetScroll()
            move(to: gesture.location(in: self))
        case .changed:
            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            scrollBy(CGPoint(x: -translation.x, y: -translation.y))
        case .ended:
            let velocity = gesture.velocity(in: self)
            startMomentum(CGPoint(x: -velocity.x, y: -velocity.y))
        default:
            break
        }
    }

    private func scrollBy(_ points: CGPoint) {
        guard let window = remoteWindow, let session else { return }
        let delta = CGPoint(x: points.x * pixelsPerPoint + scrollRemainder.x, y: points.y * pixelsPerPoint + scrollRemainder.y)
        // Send whole pixels and carry the fraction, so slow drags still scroll.
        let whole = CGPoint(x: delta.x.rounded(.towardZero), y: delta.y.rounded(.towardZero))
        scrollRemainder = CGPoint(x: delta.x - whole.x, y: delta.y - whole.y)
        if whole != .zero { session.scroll(in: window, dx: whole.x, dy: whole.y, at: lastPointer) }
    }

    private func startMomentum(_ velocity: CGPoint) {
        guard hypot(velocity.x, velocity.y) > 120 else { return }
        momentum = velocity
        let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.momentumTick(_:)))
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    fileprivate func momentumStep(_ duration: CFTimeInterval) {
        let dt = CGFloat(min(duration, 1.0 / 30))
        scrollBy(CGPoint(x: momentum.x * dt, y: momentum.y * dt))
        let decay = pow(0.135, dt) // UIScrollView's normal deceleration, per second
        momentum = CGPoint(x: momentum.x * decay, y: momentum.y * decay)
        if hypot(momentum.x, momentum.y) < 20 { stopMomentum() }
    }

    private func stopMomentum() {
        momentumLink?.invalidate()
        momentumLink = nil
        momentum = .zero
    }

    // MARK: Keyboard — software keyboard through UIKeyInput, hardware keys through presses.

    public override var canBecomeFirstResponder: Bool { isInteractive }
    public var hasText: Bool { true }
    public var autocorrectionType: UITextAutocorrectionType = .no
    public var autocapitalizationType: UITextAutocapitalizationType = .none
    public var spellCheckingType: UITextSpellCheckingType = .no
    public var smartQuotesType: UITextSmartQuotesType = .no
    public var smartDashesType: UITextSmartDashesType = .no
    public var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    public var keyboardType: UIKeyboardType = .asciiCapable
    public var keyboardAppearance: UIKeyboardAppearance = .dark
    public var returnKeyType: UIReturnKeyType = .default

    public override var inputAccessoryView: UIView? { isInteractive ? keyBar : nil }

    public func insertText(_ text: String) {
        guard !stickyModifiers.isEmpty else {
            session?.type(text, in: remoteWindow)
            return
        }
        for character in text {
            guard let stroke = Keysyms.stroke(for: Character(character.lowercased())) else { continue }
            pressAndRelease(stroke, modifiers: Array(stickyModifiers))
        }
        releaseSticky()
    }

    private func keyBarAction(_ action: KeyBar.Action) {
        switch action {
        case .modifier(let name):
            if stickyModifiers.contains(name) { stickyModifiers.remove(name) } else { stickyModifiers.insert(name) }
            keyBar.show(activeModifiers: stickyModifiers)
        case .key(let name):
            guard let stroke = Keysyms.special[name] else { return }
            pressAndRelease(stroke, modifiers: Array(stickyModifiers))
            releaseSticky()
        case .text(let text):
            insertText(text)
        }
    }

    private func pressAndRelease(_ stroke: KeyStroke, modifiers: [String]) {
        session?.key(stroke, pressed: true, in: remoteWindow, extraModifiers: modifiers)
        session?.key(stroke, pressed: false, in: remoteWindow, extraModifiers: modifiers)
    }

    private func releaseSticky() {
        guard !stickyModifiers.isEmpty else { return }
        stickyModifiers.removeAll()
        keyBar.show(activeModifiers: stickyModifiers)
    }

    public func deleteBackward() {
        guard let stroke = Keysyms.special["BackSpace"] else { return }
        pressAndRelease(stroke, modifiers: Array(stickyModifiers))
        releaseSticky()
    }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
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

    @MainActor @objc func tick() {
        guard let view else { return }
        view.checkFocus()
        view.present()
    }

    @MainActor @objc func momentumTick(_ link: CADisplayLink) {
        guard let view else { link.invalidate(); return }
        view.momentumStep(link.targetTimestamp - link.timestamp)
    }
}
#endif
