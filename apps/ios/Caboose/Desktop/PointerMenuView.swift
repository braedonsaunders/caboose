import SwiftUI

/// The menu a pointer opened (`DesktopModel.PointerMenu`), drawn in the space the cursor
/// moves in: its top-left corner at the click, moved left or up where it would leave that
/// space. The desktop hit-tests the rows, so the pointer highlights the one under it and a
/// click chooses it; a finger can tap a row too.
struct PointerMenuView: View {
    let desktop: DesktopModel
    /// The named coordinate space of the cursor, and its size.
    let space: String
    let bounds: CGSize
    @State private var size: CGSize = .zero

    var body: some View {
        if let menu = desktop.pointerMenu {
            let ui = desktop.ui
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(menu.items.enumerated()), id: \.offset) { index, item in
                    let hot = desktop.hovered == .menuItem(index)
                    Label(item.title, systemImage: item.systemImage)
                        .font(.system(size: 14 * ui))
                        .foregroundStyle(hot ? Color.white : item.destructive ? Color.red : Color.primary)
                        .padding(.horizontal, 10 * ui)
                        .padding(.vertical, 6 * ui)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(hot ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6 * ui))
                        .contentShape(Rectangle())
                        .onTapGesture { desktop.choosePointerMenuItem(index) }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: {
                            desktop.pointerMenuFrames[index] = $0
                        }
                        .accessibilityAddTraits(.isButton)
                }
            }
            .padding(5 * ui)
            .fixedSize()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10 * ui))
            .overlay { RoundedRectangle(cornerRadius: 10 * ui).strokeBorder(Color.primary.opacity(0.12)) }
            .shadow(color: .black.opacity(0.3), radius: 12 * ui, y: 6 * ui)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { desktop.pointerMenuFrame = $0 }
            .offset(origin(anchor: menu.anchor))
            .opacity(size == .zero ? 0 : 1)
            .transition(.opacity)
        }
    }

    /// Below and right of the click, as on a Mac, unless that runs off the space.
    private func origin(anchor: CGPoint) -> CGSize {
        var x = anchor.x, y = anchor.y
        if x + size.width > bounds.width { x = max(0, anchor.x - size.width) }
        if y + size.height > bounds.height { y = max(0, anchor.y - size.height) }
        return CGSize(width: x, height: y)
    }
}
