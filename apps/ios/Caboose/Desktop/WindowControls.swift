import CabooseKit
import SwiftUI

/// A window's close, minimize and zoom controls, as a Mac draws them: small coloured
/// circles at the title bar's leading edge, at the places `WindowTitleBar` gives them.
///
/// With `action`, each is a button across its whole slice of the bar. Without it they are
/// only drawn, for a desktop that hit-tests the same `WindowTitleBar` itself. Their symbols
/// show on hover, as on a Mac, and always under a finger, which cannot hover.
struct WindowControls: View {
    let bar: WindowTitleBar
    var hovered: WindowTitleBar.Control?
    var showsSymbols = false
    var title = "Window"
    var action: ((WindowTitleBar.Control) -> Void)?
    @State private var diagnosticCloseFrame: CGRect?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(bar.controls, id: \.self) { control in
                if let frame = bar.hitFrame(of: control), let centre = bar.centre(of: control) {
                    // As on a Mac, pointing at any of them shows every symbol.
                    let light = Light(control: control, diameter: bar.diameter, symbol: showsSymbols || hovered != nil)
                        .position(x: centre - frame.minX, y: frame.height / 2)
                        .frame(width: frame.width, height: frame.height)
                    Group {
                        if let action {
                            Button {
                                CloseDiagnostics.withControlFrame(control == .close ? diagnosticCloseFrame : nil) { action(control) }
                            } label: { light.contentShape(Rectangle()) }
                                .onGeometryChange(for: CGRect.self) { proxy in
                                    proxy.frame(in: .global)
                                } action: { frame in
                                    if control == .close, CloseDiagnostics.enabled { diagnosticCloseFrame = frame }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Self.label(control, title: title))
                        } else {
                            light.accessibilityHidden(true)
                        }
                    }
                    .offset(x: frame.minX)
                }
            }
        }
        .frame(width: bar.controlsWidth, height: bar.height, alignment: .topLeading)
    }

    static func label(_ control: WindowTitleBar.Control, title: String) -> String {
        switch control {
        case .close: "Close \(title)"
        case .minimize: "Minimize \(title)"
        case .zoom: "Full Screen \(title)"
        }
    }

    private struct Light: View {
        let control: WindowTitleBar.Control
        let diameter: CGFloat
        let symbol: Bool

        var body: some View {
            Circle()
                .fill(colour.gradient)
                .overlay(Circle().strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
                .frame(width: diameter, height: diameter)
                .overlay {
                    if symbol {
                        Image(systemName: name)
                            .font(.system(size: diameter * 0.58, weight: .black))
                            .foregroundStyle(.black.opacity(0.6))
                    }
                }
        }

        private var colour: Color {
            switch control {
            case .close: Color(red: 1, green: 0.37, blue: 0.34)
            case .minimize: Color(red: 1, green: 0.74, blue: 0.18)
            case .zoom: Color(red: 0.16, green: 0.79, blue: 0.25)
            }
        }

        private var name: String {
            switch control {
            case .close: "xmark"
            case .minimize: "minus"
            case .zoom: "arrow.up.left.and.arrow.down.right"
            }
        }
    }
}
