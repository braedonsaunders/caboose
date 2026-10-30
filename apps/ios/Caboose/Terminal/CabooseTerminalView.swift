import CabooseKit
import GhosttyKit
import UIKit

/// What the terminal view asks of whoever owns its session.
@MainActor
protocol CabooseTerminalViewOwner: AnyObject {
    func terminal(_ view: CabooseTerminalView, send bytes: Data)
    func terminal(_ view: CabooseTerminalView, resizedTo columns: Int, rows: Int)
    func terminal(_ view: CabooseTerminalView, titled title: String)
}

/// libghostty's surface in the Caboose look: SF Mono on translucent navy, an amber cursor and
/// selection, the key row above the keyboard, pinch to zoom, links that open in Safari, and
/// a haptic for the bell.
@MainActor
final class CabooseTerminalView: UIView, UITextInput, UIEditMenuInteractionDelegate {
    private static var runtimeInitialized = false
    private static let fontSizeKey = "caboose.terminal.fontSize"

    weak var owner: CabooseTerminalViewOwner?
    private let keyRow = TerminalKeyRow()
    weak var inlineKeyRow: TerminalKeyRow?
    var onKeyboardDismiss: (() -> Void)?

    private(set) var controlModifier = false
    private(set) var metaModifier = false

    private(set) var fontSize: CGFloat = {
        let saved = CGFloat(UserDefaults.standard.double(forKey: CabooseTerminalView.fontSizeKey))
        return TerminalTheme.fontSizes.contains(saved) ? saved : TerminalTheme.defaultFontSize
    }()

    private let bridge = GhosttyBridge()
    private let outputPipe = GhosttyOutputPipe()
    private var config: ghostty_config_t?
    private var configURL: URL?
    private var app: ghostty_app_t?
    private var surface: ghostty_surface_t?
    private var lastGridSize: (columns: Int, rows: Int) = (0, 0)

    private var displayLink: CADisplayLink?
    private var idleFrames = 0
    private var needsRender = true

    private var momentumLink: CADisplayLink?
    private var momentumVelocity: CGPoint = .zero
    private var dragSelecting = false

    private let bellFeedback = UINotificationFeedbackGenerator()
    private var pinchStartSize: CGFloat = 0
    private var nativeHeader = false
    private var hoveredLink: String?
    private var suppressNextInsertText = false

    private lazy var editMenuInteraction: UIEditMenuInteraction = {
        let interaction = UIEditMenuInteraction(delegate: self)
        addInteraction(interaction)
        return interaction
    }()

    // MARK: UITextInput state

    weak var inputDelegate: (any UITextInputDelegate)?
    lazy var tokenizer: any UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)
    var markedTextStyle: [NSAttributedString.Key: Any]?
    private var markedText: String?
    private var markedSelectedRange = NSRange(location: 0, length: 0)

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var keyboardType: UIKeyboardType = .default
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var inlinePredictionType: UITextInlinePredictionType = .no

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    init() {
        super.init(frame: .zero)
        Self.initializeRuntimeIfNeeded()
        bridge.view = self

        // TerminalScreen paints the navy field behind the transparent grid.
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = true
        layer.masksToBounds = true
        _ = editMenuInteraction

        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        keyRow.onAction = { [weak self] action in self?.keyRowAction(action) }

        setupGhosttyApp()
        setupGestures()
        setupLifecycleObservers()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        displayLink?.invalidate()
        momentumLink?.invalidate()
        outputPipe.detach(ticking: app)
        bridge.clearSurface()
        if let surface {
            ghostty_surface_free(surface)
        }
        if let app {
            ghostty_app_free(app)
        }
        if let config {
            ghostty_config_free(config)
        }
        if let configURL {
            try? FileManager.default.removeItem(at: configURL)
        }
    }

    // MARK: Ghostty lifecycle

    private static func initializeRuntimeIfNeeded() {
        guard !runtimeInitialized else { return }
        runtimeInitialized = true
        _ = ghostty_init(0, nil)
    }

    private func setupGhosttyApp() {
        guard let (cfg, url) = Self.loadConfig(fontSize: fontSize) else { return }
        config = cfg
        configURL = url

        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(bridge).toOpaque()
        runtimeConfig.supports_selection_clipboard = true
        runtimeConfig.wakeup_cb = ghosttyWakeupCallback
        runtimeConfig.action_cb = ghosttyActionCallback
        runtimeConfig.close_surface_cb = ghosttyCloseSurfaceCallback
        runtimeConfig.write_clipboard_cb = ghosttyWriteClipboardCallback
        runtimeConfig.read_clipboard_cb = ghosttyReadClipboardCallback
        runtimeConfig.confirm_read_clipboard_cb = ghosttyConfirmReadClipboardCallback

        if let created = ghostty_app_new(&runtimeConfig, cfg) {
            app = created
            ghostty_app_set_color_scheme(created, GHOSTTY_COLOR_SCHEME_DARK)
        }
    }

    private static func loadConfig(fontSize: CGFloat) -> (ghostty_config_t, URL)? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("caboose-ghostty", isDirectory: true)
        let url = dir.appendingPathComponent("ghostty-\(UUID().uuidString).conf")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try TerminalTheme.ghosttyConfig(fontSize: fontSize).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        guard let cfg = ghostty_config_new() else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        ghostty_config_load_file(cfg, url.path)
        ghostty_config_finalize(cfg)
        return (cfg, url)
    }

    private func ensureSurfaceIfNeeded() {
        guard surface == nil, let app, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        let scale = resolvedScale()
        let bridgePtr = Unmanaged.passUnretained(bridge).toOpaque()

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_IOS
        surfaceConfig.platform = ghostty_platform_u(
            ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(self).toOpaque())
        )
        surfaceConfig.userdata = bridgePtr
        surfaceConfig.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
        surfaceConfig.receive_userdata = bridgePtr
        surfaceConfig.receive_buffer = ghosttyReceiveBufferCallback
        surfaceConfig.receive_resize = ghosttyReceiveResizeCallback
        surfaceConfig.scale_factor = Double(scale)
        surfaceConfig.font_size = Float(fontSize)
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        let termKey = strdup("TERM"), termVal = strdup("xterm-256color")
        let colorKey = strdup("COLORTERM"), colorVal = strdup("truecolor")
        defer { free(termKey); free(termVal); free(colorKey); free(colorVal) }
        var envVars = [
            ghostty_env_var_s(key: termKey, value: termVal),
            ghostty_env_var_s(key: colorKey, value: colorVal),
        ]

        let created = envVars.withUnsafeMutableBufferPointer { buf -> ghostty_surface_t? in
            surfaceConfig.env_vars = buf.baseAddress
            surfaceConfig.env_var_count = buf.count
            return ghostty_surface_new(app, &surfaceConfig)
        }
        guard let created else { return }

        surface = created
        bridge.setSurface(created)
        outputPipe.attach(created)
        ghostty_surface_set_color_scheme(created, GHOSTTY_COLOR_SCHEME_DARK)
        ghostty_surface_set_occlusion(created, true)
        ghostty_surface_set_focus(created, isFirstResponder)
        applySurfaceFontSize(fontSize)
        syncSurfaceMetrics()
        requestRender()
    }

    // MARK: Layout & rendering

    private func resolvedScale() -> CGFloat {
        if let screen = window?.screen { return screen.nativeScale }
        if traitCollection.displayScale > 0 { return traitCollection.displayScale }
        return 3.0
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            ensureSurfaceIfNeeded()
            if let surface {
                ghostty_surface_set_occlusion(surface, true)
            }
            syncSurfaceMetrics()
            requestRender()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.ensureSurfaceIfNeeded()
                self.syncSurfaceMetrics()
                self.requestRender()
            }
        } else {
            stopMomentumScroll()
            displayLink?.isPaused = true
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let wide = (window?.bounds.width ?? bounds.width) >= 600
        if wide != nativeHeader {
            nativeHeader = wide
            if isFirstResponder { reloadInputViews() }
        }
        ensureSurfaceIfNeeded()
        syncSurfaceMetrics()
        requestRender()
    }

    override var inputAccessoryView: UIView? {
        keyRow.view.accessory(for: self)
    }

    private func syncSurfaceMetrics() {
        let scale = resolvedScale()
        contentScaleFactor = scale
        layer.contentsScale = scale
        updateSublayerFrames(scale: scale)

        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let pixelWidth = UInt32((bounds.width * scale).rounded(.down))
        let pixelHeight = UInt32((bounds.height * scale).rounded(.down))
        guard pixelWidth > 0, pixelHeight > 0 else { return }

        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
        ghostty_surface_set_size(surface, pixelWidth, pixelHeight)
        updateSublayerFrames(scale: scale)

        let sz = ghostty_surface_size(surface)
        reportGridSize(columns: Int(sz.columns), rows: Int(sz.rows))
    }

    private func updateSublayerFrames(scale: CGFloat) {
        guard let sublayers = layer.sublayers else { return }
        for sublayer in sublayers where !(sublayer.delegate is UIView) {
            if sublayer.frame != bounds { sublayer.frame = bounds }
            if sublayer.contentsScale != scale { sublayer.contentsScale = scale }
        }
    }

    fileprivate func reportGridSize(columns: Int, rows: Int) {
        guard columns > 1, rows > 1 else { return }
        guard columns != lastGridSize.columns || rows != lastGridSize.rows else { return }
        lastGridSize = (columns, rows)
        owner?.terminal(self, resizedTo: columns, rows: rows)
    }

    fileprivate func handleWakeup() {
        if let app {
            ghostty_app_tick(app)
        }
        requestRender()
    }

    fileprivate func requestRender() {
        needsRender = true
        idleFrames = 0
        guard window != nil else { return }
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(displayLinkFired(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard window != nil, let surface else {
            link.isPaused = true
            return
        }
        if let app {
            ghostty_app_tick(app)
        }
        if needsRender {
            needsRender = false
            idleFrames = 0
            ghostty_surface_draw(surface)
            updateSublayerFrames(scale: resolvedScale())
        } else {
            idleFrames += 1
            if idleFrames < 6 {
                ghostty_surface_draw(surface)
                updateSublayerFrames(scale: resolvedScale())
            } else if idleFrames >= 20 {
                link.isPaused = true
            }
        }
    }

    private func setupLifecycleObservers() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    @objc private func appDidBecomeActive() {
        if let surface { ghostty_surface_set_occlusion(surface, true) }
        requestRender()
    }

    @objc private func appDidEnterBackground() {
        stopMomentumScroll()
        if let surface { ghostty_surface_set_occlusion(surface, false) }
        displayLink?.isPaused = true
    }

    // MARK: Output feeding

    nonisolated func feed(byteArray: ArraySlice<UInt8>) {
        guard !byteArray.isEmpty else { return }
        outputPipe.enqueue(Data(byteArray), replay: false)
    }

    nonisolated func replay(byteArray: ArraySlice<UInt8>) {
        guard !byteArray.isEmpty else { return }
        outputPipe.enqueue(Data(byteArray), replay: true)
    }

    nonisolated func feed(text: String) {
        guard !text.isEmpty else { return }
        outputPipe.enqueue(Data(text.utf8), replay: false)
    }

    // MARK: First responder

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let surface {
            ghostty_surface_set_focus(surface, true)
            requestRender()
        }
        return ok
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if let surface {
            ghostty_surface_set_focus(surface, false)
            requestRender()
        }
        return ok
    }

    // MARK: Text size

    private func applySurfaceFontSize(_ size: CGFloat) {
        let formatted = Double(size).formatted(
            FloatingPointFormatStyle<Double>(locale: Locale(identifier: "en_US_POSIX"))
                .precision(.fractionLength(0 ... 2))
                .grouping(.never)
        )
        _ = performBindingAction("set_font_size:\(formatted)")
    }

    func setFontSize(_ size: CGFloat) {
        let clamped = min(max(size, TerminalTheme.fontSizes.lowerBound), TerminalTheme.fontSizes.upperBound)
        // Half-point steps: each change rebuilds the glyph cache and reflows the grid.
        let rounded = (clamped * 2).rounded() / 2
        guard rounded != fontSize else { return }
        fontSize = rounded
        UserDefaults.standard.set(Double(rounded), forKey: Self.fontSizeKey)
        applySurfaceFontSize(rounded)
        syncSurfaceMetrics()
        requestRender()
    }

    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began: pinchStartSize = fontSize
        case .changed: setFontSize(pinchStartSize * pinch.scale)
        case .ended: UISelectionFeedbackGenerator().selectionChanged()
        default: break
        }
    }

    // MARK: The key row

    func keyRowAction(_ action: TerminalKeyRow.Action) {
        switch action {
        case .control:
            controlModifier.toggle()
        case .alt:
            metaModifier.toggle()
        case .dismissKeyboard:
            _ = resignFirstResponder()
            onKeyboardDismiss?()
        case .key(let key):
            let control = controlModifier, alt = metaModifier
            if let bytes = TerminalKeys.bytes(for: key, control: control, alt: alt) {
                owner?.terminal(self, send: Data(bytes))
            } else {
                // Unmodified cursor keys: libghostty knows the application's cursor mode.
                switch key {
                case .up: sendMacKeyCode(0x7E)
                case .down: sendMacKeyCode(0x7D)
                case .left: sendMacKeyCode(0x7B)
                case .right: sendMacKeyCode(0x7C)
                case .home: sendMacKeyCode(0x73)
                case .end: sendMacKeyCode(0x77)
                default: break
                }
            }
            controlModifier = false
            metaModifier = false
        }
        showModifiers()
    }

    private func showModifiers() {
        keyRow.show(control: controlModifier, alt: metaModifier)
        inlineKeyRow?.show(control: controlModifier, alt: metaModifier)
    }

    private func sendMacKeyCode(
        _ keycode: UInt32,
        mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE,
        text: String? = nil
    ) {
        guard let surface else { return }
        var event = ghostty_input_key_s()
        event.action = GHOSTTY_ACTION_PRESS
        event.mods = mods
        event.consumed_mods = GHOSTTY_MODS_NONE
        event.keycode = keycode
        event.composing = false
        if let text {
            text.withCString { ptr in
                event.text = ptr
                _ = ghostty_surface_key(surface, event)
            }
        } else {
            _ = ghostty_surface_key(surface, event)
        }
        event.action = GHOSTTY_ACTION_RELEASE
        event.text = nil
        _ = ghostty_surface_key(surface, event)
        requestRender()
    }

    @discardableResult
    private func performBindingAction(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
        }
    }

    // MARK: UIKeyInput & UITextInput

    func insertText(_ text: String) {
        if suppressNextInsertText {
            suppressNextInsertText = false
            return
        }
        guard !text.isEmpty else { return }

        if markedText != nil {
            inputDelegate?.textWillChange(self)
            markedText = nil
            markedSelectedRange = NSRange(location: 0, length: 0)
            sendPreedit("")
            inputDelegate?.textDidChange(self)
        }

        if controlModifier || metaModifier {
            let control = controlModifier, alt = metaModifier
            controlModifier = false
            metaModifier = false
            showModifiers()
            if text == "\n" || text == "\r" {
                let bytes: [UInt8] = alt ? [0x1b, 0x0d] : [0x0d]
                owner?.terminal(self, send: Data(bytes))
                return
            }
            if let bytes = TerminalKeys.bytes(for: .text(text), control: control, alt: alt) {
                owner?.terminal(self, send: Data(bytes))
                return
            }
        }

        if text == "\n" || text == "\r" {
            sendMacKeyCode(0x24, text: "\r")
            return
        }

        guard let surface else {
            owner?.terminal(self, send: Data(text.utf8))
            return
        }

        if text.contains(where: \.isNewline) {
            text.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
            }
            requestRender()
            return
        }

        var event = ghostty_input_key_s()
        event.action = GHOSTTY_ACTION_PRESS
        event.mods = GHOSTTY_MODS_NONE
        event.consumed_mods = GHOSTTY_MODS_NONE
        event.keycode = 0x10000
        event.composing = false
        event.unshifted_codepoint = text.unicodeScalars.first?.value ?? 0
        text.withCString { ptr in
            event.text = ptr
            _ = ghostty_surface_key(surface, event)
        }
        requestRender()
    }

    func deleteBackward() {
        suppressNextInsertText = false
        if let current = markedText, !current.isEmpty {
            inputDelegate?.textWillChange(self)
            var updated = current
            _ = updated.popLast()
            if updated.isEmpty {
                markedText = nil
                markedSelectedRange = NSRange(location: 0, length: 0)
                sendPreedit("")
            } else {
                markedText = updated
                markedSelectedRange = NSRange(location: (updated as NSString).length, length: 0)
                sendPreedit(updated)
            }
            inputDelegate?.textDidChange(self)
            return
        }

        if controlModifier || metaModifier {
            let alt = metaModifier
            controlModifier = false
            metaModifier = false
            showModifiers()
            owner?.terminal(self, send: Data(alt ? [0x1b, 0x7f] : [0x7f]))
            return
        }

        sendMacKeyCode(0x33, text: "\u{7f}")
    }

    private func sendPreedit(_ text: String) {
        guard let surface else { return }
        text.withCString { ptr in
            ghostty_surface_preedit(surface, ptr, UInt(text.utf8.count))
        }
        requestRender()
    }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        inputDelegate?.textWillChange(self)
        inputDelegate?.selectionWillChange(self)
        if let markedText, !markedText.isEmpty {
            self.markedText = markedText
            self.markedSelectedRange = selectedRange
            sendPreedit(markedText)
        } else {
            self.markedText = nil
            self.markedSelectedRange = NSRange(location: 0, length: 0)
            sendPreedit("")
        }
        inputDelegate?.selectionDidChange(self)
        inputDelegate?.textDidChange(self)
    }

    func unmarkText() {
        let committed = markedText
        inputDelegate?.textWillChange(self)
        inputDelegate?.selectionWillChange(self)
        markedText = nil
        markedSelectedRange = NSRange(location: 0, length: 0)
        sendPreedit("")
        inputDelegate?.selectionDidChange(self)
        inputDelegate?.textDidChange(self)
        if let committed, !committed.isEmpty {
            insertText(committed)
        }
    }

    // A 1-character anchor keeps the caret off beginningOfDocument so iOS software keyboard
    // held-Delete continues repeating at an empty shell prompt.
    private var documentLength: Int { 1 + ((markedText as NSString?)?.length ?? 0) }

    var markedTextRange: UITextRange? {
        guard let markedText, !markedText.isEmpty else { return nil }
        return CabooseTextRange(start: 1, end: 1 + (markedText as NSString).length)
    }

    var selectedTextRange: UITextRange? {
        get {
            let start = 1 + markedSelectedRange.location
            return CabooseTextRange(start: start, end: start + markedSelectedRange.length)
        }
        set {
            guard let range = newValue as? CabooseTextRange else { return }
            let loc = max(0, range.startPos.index - 1)
            let len = max(0, range.endPos.index - range.startPos.index)
            markedSelectedRange = NSRange(location: loc, length: len)
        }
    }

    var beginningOfDocument: UITextPosition { CabooseTextPosition(0) }
    var endOfDocument: UITextPosition { CabooseTextPosition(documentLength) }

    func text(in range: UITextRange) -> String? {
        guard let range = range as? CabooseTextRange else { return nil }
        let full = (" " + (markedText ?? "")) as NSString
        let start = max(0, min(range.startPos.index, full.length))
        let end = max(start, min(range.endPos.index, full.length))
        return full.substring(with: NSRange(location: start, length: end - start))
    }

    func replace(_ range: UITextRange, withText text: String) {
        insertText(text)
    }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? CabooseTextPosition,
              let to = toPosition as? CabooseTextPosition else { return nil }
        return CabooseTextRange(start: from.index, end: to.index)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let pos = position as? CabooseTextPosition else { return nil }
        let next = pos.index + offset
        guard next >= 0, next <= documentLength else { return nil }
        return CabooseTextPosition(next)
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        self.position(from: position, offset: offset)
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let lhs = position as? CabooseTextPosition,
              let rhs = other as? CabooseTextPosition else { return .orderedSame }
        if lhs.index < rhs.index { return .orderedAscending }
        if lhs.index > rhs.index { return .orderedDescending }
        return .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let lhs = from as? CabooseTextPosition,
              let rhs = toPosition as? CabooseTextPosition else { return 0 }
        return rhs.index - lhs.index
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        switch direction {
        case .left, .up: return range.start
        case .right, .down: return range.end
        @unknown default: return range.start
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let pos = position as? CabooseTextPosition else { return nil }
        return CabooseTextRange(start: pos.index, end: pos.index)
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    func firstRect(for range: UITextRange) -> CGRect { caretRect(for: range.start) }

    func caretRect(for position: UITextPosition) -> CGRect {
        guard let surface else { return CGRect(x: 0, y: 0, width: 2, height: fontSize + 4) }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        return CGRect(x: x, y: y, width: max(w, 2), height: max(h, Double(fontSize + 4)))
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    func closestPosition(to point: CGPoint) -> UITextPosition? { CabooseTextPosition(documentLength) }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { CabooseTextPosition(documentLength) }
    func characterRange(at point: CGPoint) -> UITextRange? { CabooseTextRange(start: documentLength, end: documentLength) }

    // MARK: Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        suppressNextInsertText = false
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key else {
                unhandled.insert(press)
                continue
            }
            if markedText != nil {
                unhandled.insert(press)
                continue
            }
            if handleHardwareKey(key, action: GHOSTTY_ACTION_PRESS) {
                suppressNextInsertText = true
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty {
            UIApplication.shared.pressesBegan(unhandled, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        suppressNextInsertText = false
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, markedText == nil else {
                unhandled.insert(press)
                continue
            }
            if !handleHardwareKey(key, action: GHOSTTY_ACTION_RELEASE) {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty {
            UIApplication.shared.pressesEnded(unhandled, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        suppressNextInsertText = false
        UIApplication.shared.pressesCancelled(presses, with: event)
    }

    private func handleHardwareKey(_ key: UIKey, action: ghostty_input_action_e) -> Bool {
        guard let surface else { return false }
        let flags = key.modifierFlags

        if action == GHOSTTY_ACTION_PRESS, flags.contains(.command) {
            let chars = key.charactersIgnoringModifiers.lowercased()
            if chars == "c", ghostty_surface_has_selection(surface) {
                copy(nil)
                return true
            }
            if chars == "v" {
                paste(nil)
                return true
            }
            if chars == "a" {
                selectAll(nil)
                return true
            }
            if chars == "=" || chars == "+" {
                setFontSize(fontSize + 1)
                return true
            }
            if chars == "-" {
                setFontSize(fontSize - 1)
                return true
            }
            if chars == "0" {
                setFontSize(TerminalTheme.defaultFontSize)
                return true
            }
        }

        let usage = UInt16(key.keyCode.rawValue)
        let macKeyCode = Self.macKeyCode(forHIDUsage: usage)
        guard macKeyCode != 0x10000 || !key.characters.isEmpty else { return false }

        var rawMods: UInt32 = 0
        if flags.contains(.shift) { rawMods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) || flags.contains(.command) || controlModifier {
            rawMods |= GHOSTTY_MODS_CTRL.rawValue
        }
        if flags.contains(.alternate) || metaModifier {
            rawMods |= GHOSTTY_MODS_ALT.rawValue
        }
        if action == GHOSTTY_ACTION_PRESS, (controlModifier || metaModifier), !Self.isModifierUsage(usage) {
            controlModifier = false
            metaModifier = false
            showModifiers()
        }

        var event = ghostty_input_key_s()
        event.action = action
        event.mods = ghostty_input_mods_e(rawValue: rawMods)
        var consumed: UInt32 = 0
        if flags.contains(.shift) { consumed |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.alternate) { consumed |= GHOSTTY_MODS_ALT.rawValue }
        event.consumed_mods = ghostty_input_mods_e(rawValue: consumed)
        event.keycode = macKeyCode
        event.composing = false

        let ignoring = Self.filteredKeyText(key.charactersIgnoringModifiers)
        if let scalar = ignoring?.unicodeScalars.first {
            event.unshifted_codepoint = scalar.value
        }

        if action == GHOSTTY_ACTION_PRESS {
            var text = Self.filteredKeyText(key.characters)
            if (rawMods & GHOSTTY_MODS_CTRL.rawValue) != 0,
               let first = text?.unicodeScalars.first,
               text?.unicodeScalars.count == 1,
               first.value < 0x20
            {
                text = ignoring
            }
            if let text, let first = text.unicodeScalars.first, first.value >= 0x20, first.value != 0x7f {
                let handled = text.withCString { ptr -> Bool in
                    event.text = ptr
                    return ghostty_surface_key(surface, event)
                }
                requestRender()
                return handled
            }
        }

        let handled = ghostty_surface_key(surface, event)
        requestRender()
        return handled
    }

    private static func filteredKeyText(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        for scalar in text.unicodeScalars where (0xF700 ... 0xF8FF).contains(scalar.value) {
            return nil
        }
        return text
    }

    private static func isModifierUsage(_ usage: UInt16) -> Bool {
        (0xE0 ... 0xE7).contains(usage) || usage == 0x39
    }

    // MARK: Gestures, scrolling, selection & links

    private func setupGestures() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        addGestureRecognizer(longPress)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 2
        addGestureRecognizer(pan)

        let wheel = ScrollWheelGestureRecognizer(target: self, action: #selector(wheelScrolled(_:)))
        addGestureRecognizer(wheel)
    }

    @objc private func singleTapped(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended else { return }
        stopMomentumScroll()
        let point = tap.location(in: self)

        if let surface, ghostty_surface_has_selection(surface) {
            _ = performBindingAction("clear_selection")
            editMenuInteraction.dismissMenu()
            requestRender()
            return
        }

        if let url = link(at: point) {
            UIApplication.shared.open(url)
            return
        }

        if let surface, ghostty_surface_mouse_captured(surface) {
            ghostty_surface_mouse_pos(surface, Double(point.x), Double(point.y), GHOSTTY_MODS_NONE)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            requestRender()
            return
        }

        if isFirstResponder {
            if bounds.insetBy(dx: bounds.width * 0.2, dy: bounds.height * 0.2).contains(point) {
                _ = resignFirstResponder()
            }
        } else {
            _ = becomeFirstResponder()
        }
    }

    @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, let surface else { return }
        stopMomentumScroll()
        let point = tap.location(in: self)
        selectWord(at: point, on: surface)
        presentEditMenu(at: point)
    }

    @objc private func longPressed(_ press: UILongPressGestureRecognizer) {
        guard let surface else { return }
        let point = press.location(in: self)
        switch press.state {
        case .began:
            stopMomentumScroll()
            UISelectionFeedbackGenerator().selectionChanged()
            selectWord(at: point, on: surface)
            dragSelecting = true
            ghostty_surface_mouse_pos(surface, Double(point.x), Double(point.y), GHOSTTY_MODS_NONE)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            requestRender()
        case .changed:
            guard dragSelecting else { return }
            ghostty_surface_mouse_pos(surface, Double(point.x), Double(point.y), GHOSTTY_MODS_NONE)
            requestRender()
        case .ended, .cancelled:
            if dragSelecting {
                dragSelecting = false
                ghostty_surface_mouse_pos(surface, Double(point.x), Double(point.y), GHOSTTY_MODS_NONE)
                _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
                requestRender()
            }
            presentEditMenu(at: point)
        default:
            break
        }
    }

    private func selectWord(at point: CGPoint, on surface: ghostty_surface_t) {
        ghostty_surface_mouse_pos(surface, Double(point.x), Double(point.y), GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        requestRender()
    }

    private func presentEditMenu(at point: CGPoint) {
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: point)
        editMenuInteraction.presentEditMenu(with: config)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)):
            return surface.map { ghostty_surface_has_selection($0) } ?? false
        case #selector(paste(_:)):
            return UIPasteboard.general.hasStrings
        case #selector(selectAll(_:)):
            return surface != nil
        default:
            return false
        }
    }

    override func copy(_ sender: Any?) {
        guard let surface else { return }
        var out = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &out) else { return }
        defer { ghostty_surface_free_text(surface, &out) }
        guard let ptr = out.text, out.text_len > 0 else { return }
        let bytes = UnsafeBufferPointer(start: ptr, count: Int(out.text_len)).map { UInt8(bitPattern: $0) }
        UIPasteboard.general.string = String(decoding: bytes, as: UTF8.self)
        _ = performBindingAction("clear_selection")
        requestRender()
    }

    override func paste(_ sender: Any?) {
        guard let surface, let text = UIPasteboard.general.string, !text.isEmpty else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
        requestRender()
    }

    override func selectAll(_ sender: Any?) {
        _ = performBindingAction("select_all")
        requestRender()
        presentEditMenu(at: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    // MARK: Scrolling

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard !dragSelecting, let surface else { return }
        switch pan.state {
        case .began:
            stopMomentumScroll()
            editMenuInteraction.dismissMenu()
        case .changed:
            let delta = pan.translation(in: self)
            pan.setTranslation(.zero, in: self)
            let location = pan.location(in: self)
            ghostty_surface_mouse_pos(surface, Double(location.x), Double(location.y), GHOSTTY_MODS_NONE)
            sendScroll(dx: delta.x * 3, dy: delta.y * 3, momentum: 0)
        case .ended:
            let velocity = pan.velocity(in: self)
            if !ghostty_surface_mouse_captured(surface), (abs(velocity.x) > 50 || abs(velocity.y) > 50) {
                startMomentumScroll(velocity: velocity)
            }
        case .cancelled, .failed:
            stopMomentumScroll()
        default:
            break
        }
    }

    @objc private func wheelScrolled(_ wheel: UIPanGestureRecognizer) {
        guard let surface else { return }
        switch wheel.state {
        case .began:
            stopMomentumScroll()
        case .changed, .ended:
            let delta = wheel.translation(in: self)
            wheel.setTranslation(.zero, in: self)
            let location = wheel.location(in: self)
            ghostty_surface_mouse_pos(surface, Double(location.x), Double(location.y), GHOSTTY_MODS_NONE)
            sendScroll(dx: delta.x, dy: delta.y, momentum: 0)
        default:
            break
        }
    }

    private func sendScroll(dx: CGFloat, dy: CGFloat, momentum: Int32) {
        guard let surface else { return }
        let mods: ghostty_input_scroll_mods_t = 1 | (momentum << 1)
        ghostty_surface_mouse_scroll(surface, Double(dx), Double(dy), mods)
        requestRender()
    }

    private func startMomentumScroll(velocity: CGPoint) {
        momentumVelocity = velocity
        sendScroll(dx: 0, dy: 0, momentum: 1)
        let link = CADisplayLink(target: self, selector: #selector(momentumStep(_:)))
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    @objc private func momentumStep(_ link: CADisplayLink) {
        let dt = link.targetTimestamp - link.timestamp
        let decay = CGFloat(pow(0.92, dt * 60))
        momentumVelocity.x *= decay
        momentumVelocity.y *= decay
        if abs(momentumVelocity.x) < 50, abs(momentumVelocity.y) < 50 {
            stopMomentumScroll()
            return
        }
        sendScroll(dx: momentumVelocity.x * dt * 3, dy: momentumVelocity.y * dt * 3, momentum: 3)
    }

    private func stopMomentumScroll() {
        guard momentumLink != nil else { return }
        momentumLink?.invalidate()
        momentumLink = nil
        momentumVelocity = .zero
    }

    // MARK: Links

    /// Finds an OSC 8 link or plain URL in the output under `point`.
    private func link(at point: CGPoint) -> URL? {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return nil }

        hoveredLink = nil
        ghostty_surface_mouse_pos(surface, Double(point.x), Double(point.y), GHOSTTY_MODS_SUPER)
        if let app { ghostty_app_tick(app) }
        ghostty_surface_mouse_pos(surface, Double(point.x), Double(point.y), GHOSTTY_MODS_NONE)
        if let hoveredLink,
           let url = URL(string: hoveredLink),
           ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
        {
            return url
        }

        let sz = ghostty_surface_size(surface)
        let columns = max(Int(sz.columns), 1)
        let rows = max(Int(sz.rows), 1)
        let row = min(max(Int(point.y / (bounds.height / CGFloat(rows))), 0), rows - 1)
        let column = min(max(Int(point.x / (bounds.width / CGFloat(columns))), 0), columns - 1)

        // Read a window around the tapped row so URLs wrapped across lines stay whole.
        let startRow = max(0, row - 2)
        let endRow = min(rows - 1, row + 2)
        var rowStrings: [String] = []
        for r in startRow ... endRow {
            rowStrings.append(readViewportRow(r, columns: columns, on: surface))
        }
        let joined = rowStrings.joined()
        guard !joined.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }

        var offset = 0
        for i in 0 ..< (row - startRow) {
            offset += (rowStrings[i] as NSString).length
        }
        offset += min(column, max((rowStrings[row - startRow] as NSString).length - 1, 0))

        let nsJoined = joined as NSString
        for match in detector.matches(in: joined, range: NSRange(location: 0, length: nsJoined.length)) {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            if NSLocationInRange(offset, match.range) { return url }
        }
        return nil
    }

    private func readViewportRow(_ row: Int, columns: Int, on surface: ghostty_surface_t) -> String {
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: 0,
                y: UInt32(row)
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(max(columns - 1, 0)),
                y: UInt32(row)
            ),
            rectangle: false
        )
        var out = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &out) else { return "" }
        defer { ghostty_surface_free_text(surface, &out) }
        guard let ptr = out.text, out.text_len > 0 else { return "" }
        let bytes = UnsafeBufferPointer(start: ptr, count: Int(out.text_len)).map { UInt8(bitPattern: $0) }
        let str = String(decoding: bytes, as: UTF8.self)
        let pad = max(0, columns - (str as NSString).length)
        return str + String(repeating: " ", count: pad)
    }

    // MARK: Ghostty actions

    fileprivate func handleAction(_ action: ghostty_action_s) {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE:
            if let titlePtr = action.action.set_title.title {
                owner?.terminal(self, titled: String(cString: titlePtr))
            }
        case GHOSTTY_ACTION_RING_BELL:
            bellFeedback.notificationOccurred(.warning)
        case GHOSTTY_ACTION_OPEN_URL:
            let openURL = action.action.open_url
            guard let urlPtr = openURL.url, openURL.len > 0 else { return }
            let bytes = UnsafeBufferPointer(start: urlPtr, count: Int(openURL.len)).map { UInt8(bitPattern: $0) }
            let link = String(decoding: bytes, as: UTF8.self)
            if let url = URL(string: link), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
            }
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            let over = action.action.mouse_over_link
            if let urlPtr = over.url, over.len > 0 {
                let bytes = UnsafeBufferPointer(start: urlPtr, count: Int(over.len)).map { UInt8(bitPattern: $0) }
                hoveredLink = String(decoding: bytes, as: UTF8.self)
            } else {
                hoveredLink = nil
            }
        case GHOSTTY_ACTION_CELL_SIZE:
            syncSurfaceMetrics()
            requestRender()
        case GHOSTTY_ACTION_RENDER, GHOSTTY_ACTION_SELECTION_CHANGED, GHOSTTY_ACTION_SCROLLBAR:
            requestRender()
        default:
            break
        }
    }

    // MARK: HID usage -> macOS virtual keycode table

    private static func macKeyCode(forHIDUsage usage: UInt16) -> UInt32 {
        if let code = hidToMacKeyCode[usage] { return UInt32(code) }
        return 0x10000
    }

    private static let hidToMacKeyCode: [UInt16: UInt16] = [
        0x04: 0x00, 0x05: 0x0B, 0x06: 0x08, 0x07: 0x02, 0x08: 0x0E, 0x09: 0x03,
        0x0A: 0x05, 0x0B: 0x04, 0x0C: 0x22, 0x0D: 0x26, 0x0E: 0x28, 0x0F: 0x25,
        0x10: 0x2E, 0x11: 0x2D, 0x12: 0x1F, 0x13: 0x23, 0x14: 0x0C, 0x15: 0x0F,
        0x16: 0x01, 0x17: 0x11, 0x18: 0x20, 0x19: 0x09, 0x1A: 0x0D, 0x1B: 0x07,
        0x1C: 0x10, 0x1D: 0x06,
        0x1E: 0x12, 0x1F: 0x13, 0x20: 0x14, 0x21: 0x15, 0x22: 0x17, 0x23: 0x16,
        0x24: 0x1A, 0x25: 0x1C, 0x26: 0x19, 0x27: 0x1D,
        0x28: 0x24, 0x29: 0x35, 0x2A: 0x33, 0x2B: 0x30, 0x2C: 0x31, 0x2D: 0x1B,
        0x2E: 0x18, 0x2F: 0x21, 0x30: 0x1E, 0x31: 0x2A, 0x33: 0x29, 0x34: 0x27,
        0x35: 0x32, 0x36: 0x2B, 0x37: 0x2F, 0x38: 0x2C, 0x39: 0x39,
        0x3A: 0x7A, 0x3B: 0x78, 0x3C: 0x63, 0x3D: 0x76, 0x3E: 0x60, 0x3F: 0x61,
        0x40: 0x62, 0x41: 0x64, 0x42: 0x65, 0x43: 0x6D, 0x44: 0x67, 0x45: 0x6F,
        0x49: 0x72, 0x4A: 0x73, 0x4B: 0x74, 0x4C: 0x75, 0x4D: 0x77, 0x4E: 0x79,
        0x4F: 0x7C, 0x50: 0x7B, 0x51: 0x7D, 0x52: 0x7E,
        0xE0: 0x3B, 0xE1: 0x38, 0xE2: 0x3A, 0xE3: 0x37,
        0xE4: 0x3E, 0xE5: 0x3C, 0xE6: 0x3D, 0xE7: 0x36,
    ]
}

// MARK: - UITextInput positions & ranges

private final class CabooseTextPosition: UITextPosition {
    let index: Int
    init(_ index: Int) { self.index = index }
}

private final class CabooseTextRange: UITextRange {
    let startPos: CabooseTextPosition
    let endPos: CabooseTextPosition
    init(start: Int, end: Int) {
        startPos = CabooseTextPosition(min(start, end))
        endPos = CabooseTextPosition(max(start, end))
    }
    override var start: UITextPosition { startPos }
    override var end: UITextPosition { endPos }
    override var isEmpty: Bool { startPos.index == endPos.index }
}

// MARK: - Trackpad / wheel scroll gesture recognizer

private final class ScrollWheelGestureRecognizer: UIPanGestureRecognizer {
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedScrollTypesMask = [.continuous, .discrete]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func shouldReceive(_ event: UIEvent) -> Bool {
        event.type == .scroll
    }
}

// MARK: - Thread-safe output pipe for host-managed surface

private final class GhosttyOutputPipe: @unchecked Sendable {
    private static let maxBufferedBytes = 1 << 20
    private let condition = NSCondition()
    private let queue = DispatchQueue(label: "caboose.terminal.ghostty-output", qos: .userInitiated)
    private var surface: ghostty_surface_t?
    private var activeWrites = 0
    private var draining = false
    private var pending: [(data: Data, replay: Bool)] = []
    private var pendingBytes = 0

    func attach(_ surface: ghostty_surface_t) {
        condition.lock()
        self.surface = surface
        if !pending.isEmpty, !draining {
            draining = true
            queue.async { [weak self] in self?.drain() }
        }
        condition.unlock()
    }

    func detach(ticking app: ghostty_app_t?) {
        condition.lock()
        surface = nil
        while activeWrites > 0 {
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.01))
            if activeWrites > 0, let app {
                condition.unlock()
                ghostty_app_tick(app)
                condition.lock()
            }
        }
        condition.unlock()
    }

    func enqueue(_ data: Data, replay: Bool) {
        condition.lock()
        pending.append((data, replay))
        pendingBytes += data.count
        if surface == nil, pendingBytes > Self.maxBufferedBytes {
            while pendingBytes > Self.maxBufferedBytes, !pending.isEmpty {
                let removed = pending.removeFirst()
                pendingBytes -= removed.data.count
            }
        }
        if surface != nil, !draining {
            draining = true
            queue.async { [weak self] in self?.drain() }
        }
        condition.unlock()
    }

    private func drain() {
        while true {
            condition.lock()
            guard let currentSurface = surface, !pending.isEmpty else {
                draining = false
                condition.unlock()
                return
            }
            let item = pending.removeFirst()
            pendingBytes -= item.data.count
            activeWrites += 1
            condition.unlock()

            item.data.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                if item.replay {
                    ghostty_surface_write_buffer_replay(currentSurface, base, UInt(item.data.count))
                } else {
                    ghostty_surface_write_buffer(currentSurface, base, UInt(item.data.count))
                }
            }

            condition.lock()
            activeWrites -= 1
            if activeWrites == 0 {
                condition.broadcast()
            }
            condition.unlock()
        }
    }
}

// MARK: - C callback bridge

private final class GhosttyBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var wakeupPending = false
    private var rawSurface: ghostty_surface_t?
    @MainActor weak var view: CabooseTerminalView?

    func setSurface(_ surface: ghostty_surface_t) {
        lock.lock()
        rawSurface = surface
        lock.unlock()
    }

    func clearSurface() {
        lock.lock()
        rawSurface = nil
        lock.unlock()
    }

    func currentSurface() -> ghostty_surface_t? {
        lock.lock()
        defer { lock.unlock() }
        return rawSurface
    }

    func claimWakeup() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !wakeupPending else { return false }
        wakeupPending = true
        return true
    }

    func releaseWakeup() {
        lock.lock()
        wakeupPending = false
        lock.unlock()
    }
}

private let ghosttyWakeupCallback: ghostty_runtime_wakeup_cb = { userdata in
    guard let userdata else { return }
    let bridge = Unmanaged<GhosttyBridge>.fromOpaque(userdata).takeUnretainedValue()
    if Thread.isMainThread {
        MainActor.assumeIsolated { bridge.view?.handleWakeup() }
        return
    }
    guard bridge.claimWakeup() else { return }
    DispatchQueue.main.async {
        bridge.releaseWakeup()
        MainActor.assumeIsolated { bridge.view?.handleWakeup() }
    }
}

private let ghosttyActionCallback: ghostty_runtime_action_cb = { _, target, action in
    guard target.tag == GHOSTTY_TARGET_SURFACE,
          let surfacePtr = target.target.surface,
          let userdata = ghostty_surface_userdata(surfacePtr)
    else { return false }
    let bridge = Unmanaged<GhosttyBridge>.fromOpaque(userdata).takeUnretainedValue()
    if Thread.isMainThread {
        MainActor.assumeIsolated { bridge.view?.handleAction(action) }
        return action.tag == GHOSTTY_ACTION_OPEN_URL
    }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { bridge.view?.handleAction(action) }
    }
    return false
}

private let ghosttyCloseSurfaceCallback: ghostty_runtime_close_surface_cb = { _, _ in }

/// OSC 52 and copy bindings: a program in the shell (vim, tmux) copies to the phone's clipboard.
private let ghosttyWriteClipboardCallback: ghostty_runtime_write_clipboard_cb = { _, clipboard, contents, len, _ in
    guard clipboard == GHOSTTY_CLIPBOARD_STANDARD, let contents, len > 0 else { return }
    let buffer = UnsafeBufferPointer(start: contents, count: len)
    for item in buffer {
        guard let dataPtr = item.data, item.len > 0 else { continue }
        let data = Data(bytes: UnsafeRawPointer(dataPtr), count: item.len)
        if let text = String(data: data, encoding: .utf8) {
            DispatchQueue.main.async {
                UIPasteboard.general.string = text
            }
            return
        }
    }
}

private let ghosttyReadClipboardCallback: ghostty_runtime_read_clipboard_cb = { _, _, _, _, _, _ in
    GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
}

/// Reading the phone's clipboard back from shell programs (OSC 52 / Kitty) stays denied.
private let ghosttyConfirmReadClipboardCallback: ghostty_runtime_confirm_read_clipboard_cb = { userdata, _, statePtr, _ in
    guard let userdata, let statePtr else { return }
    let bridge = Unmanaged<GhosttyBridge>.fromOpaque(userdata).takeUnretainedValue()
    let stateAddress = UInt(bitPattern: statePtr)
    DispatchQueue.main.async {
        guard let surface = bridge.currentSurface(),
              let ptr = UnsafeMutableRawPointer(bitPattern: stateAddress)
        else { return }
        ghostty_surface_deny_clipboard_request(surface, ptr)
    }
}

private let ghosttyReceiveBufferCallback: ghostty_surface_receive_buffer_cb = { userdata, ptr, len in
    guard let userdata, let ptr, len > 0 else { return }
    let bridge = Unmanaged<GhosttyBridge>.fromOpaque(userdata).takeUnretainedValue()
    let data = Data(bytes: ptr, count: len)
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            guard let view = bridge.view else { return }
            view.owner?.terminal(view, send: data)
        }
    } else {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let view = bridge.view else { return }
                view.owner?.terminal(view, send: data)
            }
        }
    }
}

private let ghosttyReceiveResizeCallback: ghostty_surface_receive_resize_cb = { userdata, cols, rows, _, _ in
    guard let userdata else { return }
    let bridge = Unmanaged<GhosttyBridge>.fromOpaque(userdata).takeUnretainedValue()
    let columns = Int(cols), rowCount = Int(rows)
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            bridge.view?.reportGridSize(columns: columns, rows: rowCount)
        }
    } else {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                bridge.view?.reportGridSize(columns: columns, rows: rowCount)
            }
        }
    }
}
