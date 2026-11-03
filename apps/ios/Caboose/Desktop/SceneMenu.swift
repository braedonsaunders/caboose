import Observation
import SwiftUI

/// One row of a menu drawn in the scene.
struct SceneMenuItem {
    var title: String
    var systemImage: String
    var destructive = false
    var selected = false
    var dividerBefore = false
    var perform: @MainActor () -> Void
}

/// A context menu drawn in the scene itself rather than presented by UIKit: the desktop's
/// pointer hovers and clicks its rows (a popover would close at the first touch on the
/// trackpad, which to UIKit is a touch outside it), and a finger taps them. Every place the
/// shell offers a context menu for its own items uses one: the dock and taskbar, desktop
/// items, the Desktop menu, and the Desktop tab's dock.
///
/// It also asks the shell's questions there (`ask`): an alert, drawn as iOS draws one, in the
/// middle of the space, that the pointer and a finger both answer and nothing else can be
/// reached past until one does.
@MainActor @Observable
final class SceneMenu {
    struct Open {
        /// Where the menu hangs from, in the space it is drawn in.
        var anchor: CGPoint
        /// Grows up from the anchor (a dock's menu, above its icon) rather than down.
        var above: Bool
        var items: [SceneMenuItem]
        /// Set for a question rather than a menu.
        var prompt: Prompt?
    }

    /// A question's title and explanation; its answers are the open items.
    struct Prompt {
        var title: String
        var message: String
        /// What it asks about, so asking the same again changes nothing.
        var key: String
    }

    private(set) var open: Open?
    /// The row the pointer is over.
    var hovered: Int?
    /// Where the menu and its rows are, in the space it is drawn in.
    var frame: CGRect = .null
    var rows: [Int: CGRect] = [:]

    /// What closing a question without an answer does: its cancel.
    @ObservationIgnored private var unanswered: (@MainActor () -> Void)?

    var isOpen: Bool { open != nil }
    /// A question is open: only its answers can be reached.
    var isAsking: Bool { open?.prompt != nil }

    /// Opens at `anchor`; false when there is nothing to show, or a question is waiting.
    @discardableResult
    func show(_ items: [SceneMenuItem], at anchor: CGPoint, above: Bool = false) -> Bool {
        guard !items.isEmpty, !isAsking else { return false }
        present(Open(anchor: anchor, above: above, items: items))
        return true
    }

    /// Asks `title` about `key`: `cancelTitle`, which `cancel` answers, beside `answer`. A
    /// question about another key asked while one waits replaces it, cancelling it; asking
    /// about the same key again changes nothing.
    func ask(_ key: String, title: String, message: String, answer: SceneMenuItem,
             cancelTitle: String = "Cancel", cancel: @escaping @MainActor () -> Void) {
        let cancelItem = SceneMenuItem(title: cancelTitle, systemImage: "xmark", perform: cancel)
        put(Prompt(title: title, message: message, key: key), items: [cancelItem, answer], cancel: cancel)
    }

    /// Tells `title`, with a single OK, which `dismiss` answers.
    func tell(_ key: String, title: String, message: String, dismiss: @escaping @MainActor () -> Void) {
        put(Prompt(title: title, message: message, key: key),
            items: [SceneMenuItem(title: "OK", systemImage: "checkmark", perform: dismiss)], cancel: dismiss)
    }

    private func put(_ prompt: Prompt, items: [SceneMenuItem], cancel: @escaping @MainActor () -> Void) {
        guard open?.prompt?.key != prompt.key else { return }
        let dismissed = unanswered
        unanswered = nil
        dismissed?()
        present(Open(anchor: .zero, above: false, items: items, prompt: prompt))
        unanswered = cancel
    }

    /// Takes away a question whose key starts with `prefix` and is not `keeping`, without
    /// answering it: what it asked about is gone, or is asked elsewhere.
    func withdraw(_ prefix: String, keeping: String?) {
        guard let key = open?.prompt?.key, key.hasPrefix(prefix), key != keeping else { return }
        unanswered = nil
        close()
    }

    private func present(_ menu: Open) {
        rows = [:]
        frame = .null
        hovered = nil
        open = menu
    }

    /// Closes the menu, or the question, which counts as cancelling it.
    func close() {
        open = nil
        rows = [:]
        frame = .null
        hovered = nil
        let dismissed = unanswered
        unanswered = nil
        dismissed?()
    }

    /// Closes a menu; a question stays until it is answered.
    func closeMenu() {
        guard !isAsking else { return }
        close()
    }

    /// The row at `point`, or -1 for the menu outside its rows (and, for a question,
    /// everywhere else: nothing behind it answers), or nil outside the menu.
    func hit(_ point: CGPoint) -> Int? {
        guard let open else { return nil }
        if let row = rows.first(where: { $0.value.contains(point) }) { return row.key }
        return frame.contains(point) || open.prompt != nil ? -1 : nil
    }

    func choose(_ index: Int) {
        guard let items = open?.items, items.indices.contains(index) else { return }
        unanswered = nil
        close()
        items[index].perform()
    }
}

/// A `SceneMenu`, drawn in the named coordinate space it hit-tests in: below and right of
/// its anchor (above it for a dock), moved left or up to stay inside `bounds`, the part of
/// that space the pointer can reach. A tap outside it closes it.
struct SceneMenuView: View {
    let menu: SceneMenu
    let space: String
    let bounds: CGRect
    var ui: CGFloat = 1
    @State private var size: CGSize = .zero

    /// Whether questions are drawn here: one space draws each question once.
    var showsPrompts = true

    var body: some View {
        if let open = menu.open, let prompt = open.prompt {
            if showsPrompts { promptView(prompt, items: open.items) }
        } else if let open = menu.open {
            let dense = open.items.count > 8
            let rowVerticalPadding: CGFloat = (dense ? 4.5 : 6) * ui
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .frame(width: bounds.maxX, height: bounds.maxY)
                    .onTapGesture { menu.close() }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(open.items.enumerated()), id: \.offset) { index, item in
                        if item.dividerBefore && index > 0 {
                            Divider()
                                .padding(.vertical, 3 * ui)
                                .padding(.horizontal, 6 * ui)
                        }
                        let hot = menu.hovered == index
                        HStack(spacing: 8 * ui) {
                            Label(item.title, systemImage: item.systemImage)
                                .font(.system(size: (dense ? 13 : 14) * ui, weight: item.selected ? .semibold : .regular))
                            Spacer(minLength: 10 * ui)
                            if item.selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11 * ui, weight: .bold))
                            }
                        }
                        .foregroundStyle(hot ? Color.white : item.destructive ? Color.red : Color.primary)
                        .padding(.horizontal, 10 * ui)
                        .padding(.vertical, rowVerticalPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(hot ? Color.accentColor : (item.selected ? Color.primary.opacity(0.08) : .clear),
                                    in: RoundedRectangle(cornerRadius: 6 * ui))
                        .contentShape(Rectangle())
                        .onTapGesture { menu.choose(index) }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { menu.rows[index] = $0 }
                        .accessibilityAddTraits(item.selected ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(5 * ui)
                .fixedSize()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10 * ui))
                .overlay { RoundedRectangle(cornerRadius: 10 * ui).strokeBorder(Color.primary.opacity(0.12)) }
                .shadow(color: .black.opacity(0.3), radius: 12 * ui, y: 6 * ui)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { menu.frame = $0 }
                .offset(origin(open))
                .opacity(size == .zero ? 0 : 1)
            }
            .transition(.opacity)
        }
    }

    /// The question as iOS draws an alert: a glass card in the middle of `bounds`, its title
    /// and message above Cancel and the answer, over a dimmed space that takes every touch.
    private func promptView(_ prompt: SceneMenu.Prompt, items: [SceneMenuItem]) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.18)
                .frame(width: bounds.maxX, height: bounds.maxY)
                .contentShape(Rectangle())
                .onTapGesture {}
                .accessibilityHidden(true)
            VStack(spacing: 16 * ui) {
                VStack(spacing: 6 * ui) {
                    Text(prompt.title)
                        .font(.system(size: 17 * ui, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(prompt.message)
                        .font(.system(size: 14 * ui))
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10 * ui) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        promptButton(item, index: index)
                    }
                }
            }
            .padding(20 * ui)
            .frame(width: max(1, min(320 * ui, bounds.width - 24)))
            .glassEffect(.regular, in: .rect(cornerRadius: 28 * ui))
            .shadow(color: .black.opacity(0.25), radius: 18 * ui, y: 8 * ui)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { menu.frame = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .position(x: bounds.midX, y: bounds.midY)
        }
        .frame(width: bounds.maxX, height: bounds.maxY, alignment: .topLeading)
        .transition(.opacity.combined(with: .scale(scale: 1.06)))
    }

    @ViewBuilder private func promptButton(_ item: SceneMenuItem, index: Int) -> some View {
        let hot = menu.hovered == index
        let button = Button(role: item.destructive ? .destructive : (index == 0 ? .cancel : nil)) { menu.choose(index) } label: {
            Text(item.title)
                .font(.system(size: 15 * ui, weight: item.destructive ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 30 * ui)
        }
        .controlSize(.large)
        .overlay { if hot { Capsule().fill(Color.white.opacity(0.18)).allowsHitTesting(false) } }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { menu.rows[index] = $0 }
        if item.destructive {
            button.buttonStyle(.glassProminent).tint(.red)
        } else {
            button.buttonStyle(.glass)
        }
    }

    /// Hangs from the anchor, then is moved back inside `bounds`.
    private func origin(_ open: SceneMenu.Open) -> CGSize {
        var x = open.anchor.x, y = open.above ? open.anchor.y - size.height : open.anchor.y
        if x + size.width > bounds.maxX - 6 { x = open.anchor.x - size.width }
        if y + size.height > bounds.maxY - 6 { y = open.anchor.y - size.height }
        if y < bounds.minY + 6 { y = bounds.minY + 6 }
        x = min(max(bounds.minX + 6, x), max(bounds.minX + 6, bounds.maxX - size.width - 6))
        y = min(max(bounds.minY + 6, y), max(bounds.minY + 6, bounds.maxY - size.height - 6))
        return CGSize(width: x, height: y)
    }
}
