import CabooseKit
import SwiftTerm
import UIKit

/// What the terminal view asks of whoever owns its session.
@MainActor
protocol CabooseTerminalViewOwner: AnyObject {
    func terminal(_ view: CabooseTerminalView, send bytes: Data)
    func terminal(_ view: CabooseTerminalView, resizedTo columns: Int, rows: Int)
    func terminal(_ view: CabooseTerminalView, titled title: String)
}

/// SwiftTerm's view in the Caboose look: SF Mono on translucent navy, an amber cursor and
/// selection, the key row above the keyboard, pinch to zoom, links that open in Safari, and
/// a haptic for the bell.
final class CabooseTerminalView: TerminalView, TerminalViewDelegate {
    weak var owner: CabooseTerminalViewOwner?
    private let keyRow = TerminalKeyRow()
    private let bellFeedback = UINotificationFeedbackGenerator()
    private var pinchStartSize: CGFloat = 0
    private var observers: [NSObjectProtocol] = []
    private let linkTapDelegate = LinkTapDelegate()
    private let readingTapDelegate = LinkTapDelegate()
    private static let fontSizeKey = "caboose.terminal.fontSize"

    private(set) var fontSize: CGFloat = {
        let saved = CGFloat(UserDefaults.standard.double(forKey: CabooseTerminalView.fontSizeKey))
        return TerminalTheme.fontSizes.contains(saved) ? saved : TerminalTheme.defaultFontSize
    }()

    init() {
        // A 1×1 start makes the first layout report the real size, whatever it is.
        let options = TerminalOptions(cols: 1, rows: 1, scrollback: 10_000)
        super.init(frame: .zero, font: nil, options: options)
        terminalDelegate = self
        applyFont()
        // SwiftTerm's Metal renderer also clears with this color. Keep both the
        // render surface and its layer transparent; TerminalScreen paints one navy field.
        nativeBackgroundColor = .clear
        nativeForegroundColor = TerminalTheme.foreground
        backgroundOpacity = 0
        isOpaque = false
        backgroundColor = .clear
        installColors(TerminalTheme.ansi)
        caretColor = TerminalTheme.amber
        caretTextColor = TerminalTheme.background
        selectedTextBackgroundColor = TerminalTheme.selection
        selectionHandleColor = TerminalTheme.amber
        linkColor = TerminalTheme.palette[12].uiColor
        linkHighlightMode = .always
        bellStyle = .soundAndVisual
        optionAsMetaKey = true
        keyboardAppearance = .dark
        indicatorStyle = .white
        inputAccessoryView = keyRow
        keyRow.onAction = { [weak self] action in self?.keyRowAction(action) }

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        addGestureRecognizer(pinch)
        let linkTap = UITapGestureRecognizer(target: self, action: #selector(tappedLink(_:)))
        linkTapDelegate.shouldBegin = { [weak self] point in self?.link(at: point) != nil }
        linkTap.delegate = linkTapDelegate
        addGestureRecognizer(linkTap)
        // SwiftTerm's own tap (focus, clicks, menus) waits only when a link is under the finger.
        for recognizer in gestureRecognizers ?? [] {
            if let tap = recognizer as? UITapGestureRecognizer, tap !== linkTap, tap.numberOfTapsRequired == 1 {
                tap.require(toFail: linkTap)
            }
        }
        let readingTap = UITapGestureRecognizer(target: self, action: #selector(hideKeyboardForReading(_:)))
        readingTapDelegate.shouldBegin = { [weak self] point in
            guard let self, self.isFirstResponder else { return false }
            return self.bounds.insetBy(dx: self.bounds.width * 0.2, dy: self.bounds.height * 0.2).contains(point)
                && self.link(at: point) == nil
        }
        readingTap.delegate = readingTapDelegate
        addGestureRecognizer(readingTap)
        for recognizer in gestureRecognizers ?? [] {
            guard let tap = recognizer as? UITapGestureRecognizer, tap !== readingTap, tap !== linkTap else { continue }
            if tap.numberOfTapsRequired > 1 { readingTap.require(toFail: tap) }
            else { tap.require(toFail: readingTap) }
        }
        let center = NotificationCenter.default
        for name in [Notification.Name.terminalViewControlModifierReset, .terminalViewMetaModifierReset] {
            observers.append(center.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.showModifiers() }
            })
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The GPU renderer draws the same picture with less CPU; the view falls back to Core
        // Graphics on a device without Metal.
        if window != nil { try? setUseMetal(true) }
    }

    @objc private func hideKeyboardForReading(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended else { return }
        _ = resignFirstResponder()
    }

    // MARK: Text size

    private func applyFont() {
        let fonts = TerminalTheme.fonts(size: fontSize)
        setFonts(normal: fonts.normal, bold: fonts.bold, italic: fonts.italic, boldItalic: fonts.boldItalic)
    }

    func setFontSize(_ size: CGFloat) {
        let clamped = min(max(size, TerminalTheme.fontSizes.lowerBound), TerminalTheme.fontSizes.upperBound)
        // Half-point steps: each change rebuilds the glyph cache and reflows the grid.
        let rounded = (clamped * 2).rounded() / 2
        guard rounded != fontSize else { return }
        fontSize = rounded
        applyFont()
        UserDefaults.standard.set(Double(rounded), forKey: Self.fontSizeKey)
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

    private func keyRowAction(_ action: TerminalKeyRow.Action) {
        switch action {
        case .control:
            controlModifier.toggle()
        case .alt:
            metaModifier.toggle()
        case .dismissKeyboard:
            _ = resignFirstResponder()
        case .key(let key):
            let control = controlModifier, alt = metaModifier
            if let bytes = TerminalKeys.bytes(for: key, control: control, alt: alt) {
                send(bytes)
            } else {
                // Unmodified cursor keys: the terminal knows the application's cursor mode.
                switch key {
                case .up: sendKeyUp()
                case .down: sendKeyDown()
                case .left: sendKeyLeft()
                case .right: sendKeyRight()
                case .home: sendKeyHome()
                case .end: sendKeyEnd()
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
    }

    // MARK: Links

    /// A plain URL in the output under `point`, found in the line's text as the terminal reads it.
    private func link(at point: CGPoint) -> URL? {
        let line = accessibilityLineNumber(for: point)
        guard let text = accessibilityContent(forLineNumber: line), !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        // A long URL wraps over several rows, which all read as the same logical line.
        var first = line
        while first > 0, accessibilityContent(forLineNumber: first - 1) == text { first -= 1 }
        let columns = max(terminalDimensions.cols, 1)
        let cellWidth = bounds.width / CGFloat(columns)
        let column = min(Int(point.x / max(cellWidth, 1)), columns - 1)
        let index = (line - first) * columns + column
        let string = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            if NSLocationInRange(index, match.range) { return url }
        }
        return nil
    }

    @objc private func tappedLink(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, let url = link(at: tap.location(in: self)) else { return }
        UIApplication.shared.open(url)
    }


    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        owner?.terminal(self, send: Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        owner?.terminal(self, resizedTo: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        owner?.terminal(self, titled: title)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        UIApplication.shared.open(url)
    }

    func bell(source: TerminalView) {
        bellFeedback.notificationOccurred(.warning)
    }

    /// OSC 52: a program in the shell (vim, tmux) copies to the phone's clipboard. Reading
    /// the clipboard back stays denied.
    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Lets the link tap begin only over a link, so every other tap stays SwiftTerm's.
private final class LinkTapDelegate: NSObject, UIGestureRecognizerDelegate {
    var shouldBegin: ((CGPoint) -> Bool)?

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        shouldBegin?(gestureRecognizer.location(in: gestureRecognizer.view)) ?? false
    }
}

private extension UInt32 {
    var uiColor: UIColor {
        UIColor(red: CGFloat(self >> 16 & 0xFF) / 255, green: CGFloat(self >> 8 & 0xFF) / 255, blue: CGFloat(self & 0xFF) / 255, alpha: 1)
    }
}
