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
@MainActor @Observable
final class SceneMenu {
    struct Open {
        /// Where the menu hangs from, in the space it is drawn in.
        var anchor: CGPoint
        /// Grows up from the anchor (a dock's menu, above its icon) rather than down.
        var above: Bool
        var items: [SceneMenuItem]
    }

    private(set) var open: Open?
    /// The row the pointer is over.
    var hovered: Int?
    /// Where the menu and its rows are, in the space it is drawn in.
    var frame: CGRect = .null
    var rows: [Int: CGRect] = [:]

    var isOpen: Bool { open != nil }

    /// Opens at `anchor`; false when there is nothing to show.
    @discardableResult
    func show(_ items: [SceneMenuItem], at anchor: CGPoint, above: Bool = false) -> Bool {
        guard !items.isEmpty else { return false }
        rows = [:]
        frame = .null
        hovered = nil
        open = Open(anchor: anchor, above: above, items: items)
        return true
    }

    func close() {
        open = nil
        rows = [:]
        frame = .null
        hovered = nil
    }

    /// The row at `point`, or -1 for the menu outside its rows, or nil outside the menu.
    func hit(_ point: CGPoint) -> Int? {
        guard open != nil else { return nil }
        if let row = rows.first(where: { $0.value.contains(point) }) { return row.key }
        return frame.contains(point) ? -1 : nil
    }

    func choose(_ index: Int) {
        guard let items = open?.items, items.indices.contains(index) else { return }
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

    var body: some View {
        if let open = menu.open {
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
