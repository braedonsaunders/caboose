import SwiftUI
#if canImport(SwiftTerm)
import SwiftTerm
#endif

/// Where the native terminal (`Caboose/Terminal/`, built on SwiftTerm) joins the shell. It is
/// part of the build exactly when the app links SwiftTerm; until then the Terminal tab and
/// the shell's terminal actions are absent. The terminal supplies its session items
/// and draws its grid translucent; the shell adds the wallpaper behind it and its own trailing
/// pair, as on every tab.
@MainActor
enum TerminalSlot {
    #if canImport(SwiftTerm)
    static let isFilled = true
    static func screen() -> some View {
        NavigationStack { TerminalScreen().toolbar { ComputerToolbar() }.background { ShellBackground() } }
    }
    #else
    static let isFilled = false
    static func screen() -> some View { EmptyView() }
    #endif
}
