import CabooseKit
import SwiftUI

/// The shell's tabs where an iPhone's bars are horizontal: at the bottom right rather than
/// the system's bar across the bottom (`HomeToday.tabPlacement`). Held upright, they are a
/// short glass cluster at the bottom right, with the tab's own control (Home's Ask) to its
/// left; on a wide screen, a sidebar down the trailing edge with the tabs at its foot, like
/// the system's vertical bar on iPhone Duo. Where the system draws that vertical bar, its own
/// tab bar is used and this draws nothing.
struct ShellTabChrome: ViewModifier {
    @Environment(AppModel.self) private var model
    let placement: HomeToday.TabPlacement
    let tab: ShellTab
    private var keyboard = SoftwareKeyboard.shared

    init(placement: HomeToday.TabPlacement, tab: ShellTab) {
        self.placement = placement
        self.tab = tab
    }

    @ViewBuilder func body(content: Content) -> some View {
        switch placement {
        case .system:
            content
        case .cluster:
            content
                .toolbarVisibility(.hidden, for: .tabBar)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !hidden {
                        HStack(alignment: .bottom, spacing: 10) {
                            if tab == .home { HomeAskField().frame(maxWidth: .infinity) } else { Spacer(minLength: 0) }
                            ShellTabButtons(axis: .horizontal)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: hidden)
        case .sidebar:
            content
                .toolbarVisibility(.hidden, for: .tabBar)
                .safeAreaInset(edge: .trailing, spacing: 0) {
                    if !immersive {
                        ShellTabButtons(axis: .vertical)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 6)
                            .frame(width: ShellTabButtons.sidebarWidth)
                            .glassEffect(.regular, in: .rect(cornerRadius: 26))
                            .padding(.vertical, 8)
                            .padding(.trailing, 8)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: immersive)
        }
    }

    /// Under the keyboard, as the system's tab bar is, and out of the way of a window that
    /// covers the Desktop.
    private var hidden: Bool { keyboard.visible || immersive }

    /// The same test the Desktop uses to hide its own bars.
    private var immersive: Bool {
        tab == .desktop && model.yardActive && !model.externalDisplayActive && model.yard.coverWindow != nil
    }
}

/// The tabs as buttons: icons in a row for the cluster, icons over their names in a column
/// for the sidebar. The selected tab is lit amber on a plate that slides between them, and
/// Agents carries the number of approvals waiting, as the system's tab bar would.
struct ShellTabButtons: View {
    static let sidebarWidth: CGFloat = 68
    @Environment(AppModel.self) private var model
    @Namespace private var plate
    let axis: Axis

    private var tabs: [(tab: ShellTab, title: String, symbol: String)] {
        var tabs: [(tab: ShellTab, title: String, symbol: String)] = [
            (.home, "Home", "house"),
            (.desktop, "Desktop", "macwindow.on.rectangle"),
            (.agents, "Agents", "sparkles"),
            (.apps, "Apps", "square.grid.2x2"),
        ]
        if TerminalSlot.isFilled { tabs.append((tab: .terminal, title: "Terminal", symbol: "apple.terminal")) }
        return tabs
    }

    var body: some View {
        let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: 4))
        layout {
            ForEach(tabs, id: \.tab) { item in
                button(item.tab, item.title, item.symbol)
            }
        }
        .padding(axis == .horizontal ? 4 : 0)
        .modifier(ClusterGlass(active: axis == .horizontal))
        .animation(.snappy(duration: 0.3), value: model.selectedTab)
        .sensoryFeedback(.selection, trigger: model.selectedTab)
    }

    private func button(_ tab: ShellTab, _ title: String, _ symbol: String) -> some View {
        let selected = model.selectedTab == tab
        let badge = tab == .agents ? model.agents.awaitingApproval.count : 0
        return Button { model.selectedTab = tab } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: selected ? .semibold : .regular))
                    .symbolVariant(selected ? .fill : .none)
                    .frame(height: 24)
                if axis == .vertical {
                    Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .foregroundStyle(selected ? Brand.amber : .white.opacity(0.72))
            .frame(width: axis == .horizontal ? 44 : 56, height: axis == .horizontal ? 42 : 54)
            .background {
                if selected {
                    Capsule().fill(.white.opacity(0.12)).matchedGeometryEffect(id: "plate", in: plate)
                }
            }
            .overlay(alignment: .topTrailing) {
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(Brand.amber, in: .capsule)
                        .offset(x: 2, y: -2)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(badge > 0 ? "\(badge) waiting" : "")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

private struct ClusterGlass: ViewModifier {
    let active: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if active { content.glassEffect(.regular.interactive(), in: .capsule) } else { content }
    }
}

/// Whether the software keyboard is on screen, so the tabs can go under it as the system's do.
/// A hardware keyboard's short shortcuts bar does not count.
@MainActor @Observable
final class SoftwareKeyboard {
    static let shared = SoftwareKeyboard()
    private(set) var visible = false

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            let screen = (note.object as? UIScreen)?.bounds ?? frame
            MainActor.assumeIsolated {
                SoftwareKeyboard.shared.visible = frame.height > 120 && frame.minY < screen.maxY
            }
        }
        center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SoftwareKeyboard.shared.visible = false }
        }
    }
}

extension EnvironmentValues {
    /// Where the shell's tabs sit, so a tab can place its own bottom control beside them.
    @Entry var shellTabPlacement: HomeToday.TabPlacement = .system
}
