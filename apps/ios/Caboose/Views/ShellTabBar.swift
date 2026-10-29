import CabooseKit
import SwiftUI

/// Portrait Desktop uses one compact bottom control regardless of the system's tab
/// placement. Other tabs retain the shell cluster or sidebar, and landscape Desktop
/// retains its native bar where available. Laptop and covering windows own their controls.
struct ShellTabChrome: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.portraitDesktopChrome) private var portraitDesktop
    let placement: HomeToday.TabPlacement
    let tab: ShellTab
    private var keyboard = SoftwareKeyboard.shared

    init(placement: HomeToday.TabPlacement, tab: ShellTab) {
        self.placement = placement
        self.tab = tab
    }

    @ViewBuilder func body(content: Content) -> some View {
        if tab == .desktop && portraitDesktop {
            content
                .toolbarVisibility(.hidden, for: .tabBar)
                .overlay(alignment: .bottomTrailing) {
                    // A ready local desktop owns this button in its dock.
                    if !immersive && (model.phase != .ready || model.externalDisplayActive) {
                        DesktopPanelButton().padding(12)
                    }
                }
        } else {
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
                GeometryReader { proxy in
                    // A real content column, not a safe-area overlay on a NavigationStack:
                    // child scroll views, composers and terminal grids get this exact width.
                    HStack(spacing: 0) {
                        content
                            .frame(width: max(0, proxy.size.width - (immersive ? 0 : ShellTabButtons.sidebarWidth + 8)),
                                   height: proxy.size.height)
                        if !immersive {
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                ScrollView(.vertical) {
                                    VStack(spacing: 8) {
                                        if tab == .desktop { DesktopRailControls() }
                                        ShellTabButtons(axis: .vertical)
                                    }
                                    .padding(.vertical, 8)
                                    .frame(width: ShellTabButtons.sidebarWidth)
                                }
                                .scrollIndicators(.hidden)
                                .scrollBounceBehavior(.basedOnSize)
                                .frame(width: ShellTabButtons.sidebarWidth,
                                       height: min(max(0, proxy.size.height - 16), railHeight))
                                .glassEffect(.regular, in: .rect(cornerRadius: 26))
                            }
                            .padding(.trailing, 8)
                            .padding(.bottom, 8)
                        }
                    }
                }
                .toolbarVisibility(.hidden, for: .tabBar)
                .animation(.snappy, value: immersive)
            }
        }
    }

    private var railHeight: CGFloat {
        let tabs = TerminalSlot.isFilled ? 5 : 4
        return CGFloat(tabs * 54 + (tabs - 1) * 4 + 16) + (tab == .desktop ? 184 : 0)
    }

    /// Under the keyboard, as the system's tab bar is, and out of the way of a window that
    /// covers the Desktop.
    private var hidden: Bool { keyboard.visible || immersive }

    /// The same test the Desktop uses to hide its own bars.
    private var immersive: Bool {
        tab == .desktop && (model.laptopDesktopActive || (model.yardActive && !model.externalDisplayActive && model.yard.coverWindow != nil))
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
    var showsTitles = false
    var iconsOnly = false

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
                if !iconsOnly && (axis == .vertical || showsTitles) {
                    Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .foregroundStyle(selected ? Brand.amber : .white.opacity(0.72))
            .frame(width: axis == .horizontal ? 44 : 56, height: iconsOnly ? 44 : (axis == .horizontal && !showsTitles ? 42 : 54))
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

/// Whether the software keyboard covers part of the shell's own window, so the cluster can go
/// under it as the system's tab bar does. The shell's window is the one `ShellWindowProbe`
/// sits in, never whichever window is key, which may be the external display's desktop. The
/// keyboard's frame is taken in its screen's coordinates and measured against that window; a
/// keyboard on another screen, or a hardware keyboard's short shortcuts bar, does not count.
@MainActor @Observable
final class SoftwareKeyboard {
    static let shared = SoftwareKeyboard()
    private(set) var visible = false
    @ObservationIgnored weak var window: UIWindow?

    private init() {
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                let hiding = note.name == UIResponder.keyboardWillHideNotification
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                let screen = note.object as? UIScreen
                MainActor.assumeIsolated {
                    let keyboard = SoftwareKeyboard.shared
                    keyboard.visible = !hiding && keyboard.covered(by: frame, on: screen) > 120
                }
            }
        }
    }

    /// How many points of the shell's window the keyboard's `frame` on `screen` covers.
    private func covered(by frame: CGRect?, on screen: UIScreen?) -> CGFloat {
        guard let frame, !frame.isEmpty, let window else { return 0 }
        if let screen, screen !== window.screen { return 0 }
        let local = window.convert(frame, from: window.screen.coordinateSpace)
        let overlap = local.intersection(window.bounds)
        return overlap.isNull ? 0 : overlap.height
    }
}

/// Tells `SoftwareKeyboard` which window is the shell's: the one this invisible view is in.
struct ShellWindowProbe: UIViewRepresentable {
    var sizeChanged: (CGSize) -> Void = { _ in }
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.sizeChanged = sizeChanged
        return view
    }
    func updateUIView(_ view: Probe, context: Context) { view.sizeChanged = sizeChanged }

    final class Probe: UIView {
        var sizeChanged: (CGSize) -> Void = { _ in }
        private var lastSize: CGSize = .zero

        override func layoutSubviews() {
            super.layoutSubviews()
            reportSize()
        }

        private func reportSize() {
            guard let size = window?.bounds.size, size != lastSize else { return }
            lastSize = size
            // Window bounds do not change when keyboard or system bars appear.
            DispatchQueue.main.async { [weak self] in self?.sizeChanged(size) }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            isUserInteractionEnabled = false
            if let window { SoftwareKeyboard.shared.window = window }
            reportSize()
        }
    }
}

extension EnvironmentValues {
    /// The Desktop-only override, measured from the shell window before keyboard insets.
    @Entry var portraitDesktopChrome = false
    /// Where the shell's tabs sit, so a tab can place its own bottom control beside them.
    @Entry var shellTabPlacement: HomeToday.TabPlacement = .system
}
