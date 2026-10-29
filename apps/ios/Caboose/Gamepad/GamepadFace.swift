import CabooseKit
import SwiftUI

/// The controller drawn from its state: every control of a layout in its type's own look. A
/// floating stick is drawn where its thumb landed while held, and at its place otherwise.
struct GamepadFace: View {
    let layout: OnScreenGamepad.Layout
    let state: GameGamepadState
    let centers: [OnScreenGamepad.Control: CGPoint]
    let settings: OnScreenGamepad.Settings

    var body: some View {
        let theme = GamepadTheme(style: layout.style, labels: settings.labels)
        ZStack(alignment: .topLeading) {
            ForEach(Array(plates(theme).enumerated()), id: \.offset) { _, plate in
                RoundedRectangle(cornerRadius: plate.height * theme.plateRounding, style: .continuous)
                    .fill(theme.plate)
                    .overlay(RoundedRectangle(cornerRadius: plate.height * theme.plateRounding, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.black.opacity(0.35), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1.5))
                    .frame(width: plate.width, height: plate.height)
                    .position(x: plate.midX, y: plate.midY)
            }
            ForEach(layout.items, id: \.control) { item in
                let frame = frame(of: item)
                control(item, theme: theme)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    // A stick that floated under its thumb is drawn over whatever it landed near.
                    .zIndex(centers[item.control] == nil ? 0 : 1)
            }
        }
    }

    /// Where a control is drawn: a held floating stick under its thumb.
    private func frame(of item: OnScreenGamepad.Item) -> CGRect {
        guard let center = centers[item.control] else { return item.frame }
        return CGRect(x: center.x - item.frame.width / 2, y: center.y - item.frame.height / 2, width: item.frame.width, height: item.frame.height)
    }

    /// The recessed wells some types set their d-pad and buttons into.
    private func plates(_ theme: GamepadTheme) -> [CGRect] {
        guard theme.hasPlates else { return [] }
        let clusters: [OnScreenGamepad.Cluster] = [.dpad, .face]
        return clusters.compactMap { cluster in
            let union = layout.items(in: cluster).map(\.frame).reduce(CGRect.null) { $0.union($1) }
            guard !union.isNull else { return nil }
            let inset = -min(union.width, union.height) * 0.09
            return union.insetBy(dx: inset, dy: inset)
        }
    }

    @ViewBuilder private func control(_ item: OnScreenGamepad.Item, theme: GamepadTheme) -> some View {
        switch item.control {
        case .dpad:
            let pressed = Set([GameGamepadState.Button.up, .down, .left, .right].filter { state[$0] > 0.5 })
            if layout.style == .arcade {
                ArcadeLever(directions: pressed, ball: theme.lever)
            } else {
                DirectionPad(directions: pressed, fill: theme.dpad, square: layout.style == .retro)
            }
        case .leftStick, .rightStick:
            let left = item.control == .leftStick
            ThumbStick(x: state[left ? .leftX : .rightX], y: state[left ? .leftY : .rightY],
                       clicked: state[left ? .leftStick : .rightStick] > 0.5,
                       held: centers[item.control] != nil,
                       floating: settings.sticks == .floating, accent: theme.accent)
        case .button(let button):
            let label = OnScreenGamepad.label(button, style: layout.style, labels: settings.labels)
            let value = state[button]
            if item.shape == .circle {
                DomeButton(label: label, fill: theme.fill(button), ink: theme.ink(button),
                           pressed: value > 0.1, printedBelow: layout.style == .retro)
            } else {
                PillButton(label: label, fill: theme.fill(button), ink: theme.ink(button), value: value,
                           analog: button == .leftTrigger || button == .rightTrigger,
                           slant: layout.style == .classic && (button == .select || button == .start) ? -22 : 0,
                           accent: theme.accent)
            }
        }
    }
}

/// The surface behind the controls.
struct GamepadBackdrop: View {
    let style: OnScreenGamepad.Style
    var body: some View {
        let colors: [Color] = switch style {
        case .modern: [Color(white: 0.13), Color(white: 0.06)]
        case .classic: [Color(red: 0.17, green: 0.17, blue: 0.21), Color(red: 0.09, green: 0.09, blue: 0.12)]
        case .retro: [Color(white: 0.17), Color(white: 0.1)]
        case .arcade: [Color(red: 0.1, green: 0.07, blue: 0.15), Color(white: 0.03)]
        }
        LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }
}

/// A type's colours.
struct GamepadTheme {
    let style: OnScreenGamepad.Style
    let labels: OnScreenGamepad.Labels

    var hasPlates: Bool { style == .classic || style == .retro }
    var plateRounding: CGFloat { style == .classic ? 0.5 : 0.18 }
    var plate: Color {
        style == .classic ? Color(red: 0.22, green: 0.21, blue: 0.29) : Color(white: 0.07)
    }
    var dpad: Color {
        switch style {
        case .classic: Color(red: 0.22, green: 0.22, blue: 0.25)
        case .retro: Color(white: 0.1)
        default: Color(white: 0.2)
        }
    }
    var lever: Color { Color(red: 0.86, green: 0.13, blue: 0.16) }
    var accent: Color {
        switch style {
        case .modern: labels == .xbox ? Color(red: 0.42, green: 0.75, blue: 0.27) : Color(red: 0.3, green: 0.55, blue: 1)
        case .classic: Color(red: 0.55, green: 0.5, blue: 0.85)
        case .retro: Color(red: 0.85, green: 0.15, blue: 0.2)
        case .arcade: Color(red: 0.99, green: 0.85, blue: 0.21)
        }
    }

    func fill(_ button: GameGamepadState.Button) -> Color {
        switch style {
        case .modern:
            return Color(white: [.south, .east, .west, .north].contains(button) ? 0.17 : 0.22)
        case .classic:
            switch button {
            case .east: return Color(red: 0.85, green: 0.19, blue: 0.18)
            case .south: return Color(red: 0.95, green: 0.75, blue: 0.12)
            case .north: return Color(red: 0.18, green: 0.37, blue: 0.85)
            case .west: return Color(red: 0.18, green: 0.62, blue: 0.31)
            case .leftShoulder, .rightShoulder: return Color(red: 0.6, green: 0.6, blue: 0.66)
            default: return Color(red: 0.3, green: 0.3, blue: 0.34)
            }
        case .retro:
            return [.south, .east].contains(button) ? Color(red: 0.8, green: 0.07, blue: 0.15) : Color(white: 0.12)
        case .arcade:
            switch button {
            case .west, .south: return Color(red: 0.9, green: 0.22, blue: 0.21)
            case .north, .east: return Color(red: 0.99, green: 0.83, blue: 0.2)
            case .rightShoulder, .rightTrigger: return Color(red: 0.26, green: 0.63, blue: 0.28)
            case .leftShoulder, .leftTrigger: return Color(red: 0.12, green: 0.53, blue: 0.9)
            default: return Color(white: 0.18)
            }
        }
    }

    func ink(_ button: GameGamepadState.Button) -> Color {
        switch style {
        case .modern:
            guard [.south, .east, .west, .north].contains(button) else { return .white.opacity(0.85) }
            switch (labels, button) {
            case (.xbox, .south): return Color(red: 0.42, green: 0.75, blue: 0.27)
            case (.xbox, .east): return Color(red: 0.89, green: 0.28, blue: 0.24)
            case (.xbox, .west): return Color(red: 0.24, green: 0.56, blue: 0.88)
            case (.xbox, _): return Color(red: 0.95, green: 0.76, blue: 0.19)
            case (.playstation, .south): return Color(red: 0.49, green: 0.71, blue: 1)
            case (.playstation, .east): return Color(red: 1, green: 0.42, blue: 0.42)
            case (.playstation, .west): return Color(red: 0.94, green: 0.55, blue: 0.78)
            case (.playstation, _): return Color(red: 0.25, green: 0.82, blue: 0.69)
            }
        case .classic:
            switch button {
            case .south: return Color(red: 0.3, green: 0.22, blue: 0.02)
            case .leftShoulder, .rightShoulder: return Color(white: 0.2)
            default: return .white.opacity(0.92)
            }
        case .retro:
            return Color(red: 0.9, green: 0.2, blue: 0.24)
        case .arcade:
            return [.north, .east].contains(button) ? Color(red: 0.3, green: 0.22, blue: 0.02) : .white.opacity(0.92)
        }
    }
}

/// A button's name, or the symbol drawn for it.
private struct ButtonMark: View {
    let label: OnScreenGamepad.Label
    let size: CGFloat
    var body: some View {
        if let symbol = label.symbol {
            Image(systemName: symbol).font(.system(size: size * 0.82, weight: .heavy))
        } else {
            Text(label.name.count > 2 ? label.name.uppercased() : label.name)
                .font(.system(size: label.name.count > 2 ? size * 0.5 : size, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
    }
}

/// A round button: a lit dome that sinks and glows while pressed.
private struct DomeButton: View {
    let label: OnScreenGamepad.Label
    let fill: Color
    let ink: Color
    let pressed: Bool
    /// The name printed on the body below the button rather than on it.
    var printedBelow = false

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle().fill(fill).blur(radius: side * 0.2).scaleEffect(1.2).opacity(pressed ? 0.6 : 0)
                Circle()
                    .fill(RadialGradient(colors: [fill.mix(with: .white, by: 0.3), fill, fill.mix(with: .black, by: 0.4)],
                                         center: UnitPoint(x: 0.4, y: 0.32), startRadius: 0, endRadius: side * 0.66))
                    .shadow(color: .black.opacity(pressed ? 0.3 : 0.6), radius: pressed ? side * 0.02 : side * 0.07, y: pressed ? 1 : side * 0.06)
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom),
                                      lineWidth: max(1, side * 0.03))
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .frame(width: side * 0.6, height: side * 0.32)
                    .offset(y: -side * 0.22)
                    .opacity(pressed ? 0.2 : 1)
                if !printedBelow {
                    ButtonMark(label: label, size: side * 0.42)
                        .foregroundStyle(ink)
                        .shadow(color: .black.opacity(0.35), radius: 0.5, y: 0.5)
                }
            }
            .frame(width: side, height: side)
            .scaleEffect(pressed ? 0.92 : 1)
            .brightness(pressed ? 0.12 : 0)
            .overlay(alignment: .bottomTrailing) {
                if printedBelow {
                    ButtonMark(label: label, size: side * 0.24)
                        .foregroundStyle(ink)
                        .offset(x: -side * 0.02, y: side * 0.14)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .animation(.easeOut(duration: 0.05), value: pressed)
    }
}

/// A pill: shoulders, triggers, Select and Start. A trigger fills to how far it is pulled.
private struct PillButton: View {
    let label: OnScreenGamepad.Label
    let fill: Color
    let ink: Color
    let value: Double
    let analog: Bool
    var slant: Double = 0
    let accent: Color

    var body: some View {
        let pressed = value > 0.1
        GeometryReader { proxy in
            let height = min(proxy.size.height, proxy.size.width)
            ZStack {
                Capsule()
                    .fill(LinearGradient(colors: [fill.mix(with: .white, by: 0.16), fill.mix(with: .black, by: 0.3)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(pressed ? 0.25 : 0.5), radius: pressed ? 1 : 3, y: pressed ? 1 : 2)
                if analog {
                    Capsule().fill(accent.opacity(0.55))
                        .mask(alignment: .top) {
                            Rectangle().frame(height: proxy.size.height * CGFloat(value))
                        }
                }
                Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.25), .black.opacity(0.4)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                ButtonMark(label: label, size: height * 0.42)
                    .foregroundStyle(ink)
            }
            .scaleEffect(pressed ? 0.95 : 1)
            .brightness(pressed ? 0.14 : 0)
            .rotationEffect(.degrees(slant))
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .animation(.easeOut(duration: 0.05), value: pressed)
    }
}

/// A cross in its well, tipping toward the direction held.
private struct DirectionPad: View {
    let directions: Set<GameGamepadState.Button>
    let fill: Color
    /// A square plate rather than a round well.
    let square: Bool

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let arm = side * 0.34
            let dx: CGFloat = (directions.contains(.right) ? 1 : 0) - (directions.contains(.left) ? 1 : 0)
            let dy: CGFloat = (directions.contains(.down) ? 1 : 0) - (directions.contains(.up) ? 1 : 0)
            ZStack {
                Group {
                    if square {
                        RoundedRectangle(cornerRadius: side * 0.12, style: .continuous).fill(Color(white: 0.06))
                    } else {
                        Circle().fill(RadialGradient(colors: [Color.black.opacity(0.5), Color.black.opacity(0.2)], center: .center, startRadius: side * 0.2, endRadius: side * 0.5))
                    }
                }
                .frame(width: side * 0.98, height: side * 0.98)
                ZStack {
                    CrossShape(arm: arm / side)
                        .fill(LinearGradient(colors: [fill.mix(with: .white, by: 0.18), fill.mix(with: .black, by: 0.35)], startPoint: .top, endPoint: .bottom))
                        .shadow(color: .black.opacity(0.6), radius: side * 0.04, y: side * 0.03)
                    CrossShape(arm: arm / side)
                        .stroke(LinearGradient(colors: [.white.opacity(0.22), .black.opacity(0.5)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    Circle()
                        .fill(RadialGradient(colors: [Color.black.opacity(0.35), Color.white.opacity(0.06)], center: .center, startRadius: 0, endRadius: arm * 0.42))
                        .frame(width: arm * 0.7, height: arm * 0.7)
                    ForEach([GameGamepadState.Button.up, .down, .left, .right], id: \.self) { direction in
                        let held = directions.contains(direction)
                        Image(systemName: Self.arrow(direction))
                            .font(.system(size: arm * 0.34, weight: .black))
                            .foregroundStyle(.white.opacity(held ? 0.95 : 0.3))
                            .shadow(color: .white.opacity(held ? 0.6 : 0), radius: 4)
                            .offset(Self.offset(direction, by: side * 0.36))
                    }
                }
                .frame(width: side, height: side)
                .rotation3DEffect(.degrees(dx == 0 && dy == 0 ? 0 : 11), axis: (x: -dy, y: dx, z: 0), perspective: 0.6)
                .animation(.easeOut(duration: 0.05), value: directions)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    static func arrow(_ direction: GameGamepadState.Button) -> String {
        switch direction {
        case .up: "arrowtriangle.up.fill"
        case .down: "arrowtriangle.down.fill"
        case .left: "arrowtriangle.left.fill"
        default: "arrowtriangle.right.fill"
        }
    }

    static func offset(_ direction: GameGamepadState.Button, by distance: CGFloat) -> CGSize {
        switch direction {
        case .up: CGSize(width: 0, height: -distance)
        case .down: CGSize(width: 0, height: distance)
        case .left: CGSize(width: -distance, height: 0)
        default: CGSize(width: distance, height: 0)
        }
    }
}

/// A plus whose arms are `arm` of its side wide, with softened corners.
private struct CrossShape: Shape {
    let arm: CGFloat
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let width = side * arm, radius = width * 0.18
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.addRoundedRect(in: CGRect(x: center.x - width / 2, y: center.y - side / 2, width: width, height: side), cornerSize: CGSize(width: radius, height: radius))
        path.addRoundedRect(in: CGRect(x: center.x - side / 2, y: center.y - width / 2, width: side, height: width), cornerSize: CGSize(width: radius, height: radius))
        return path
    }
}

/// An arcade lever seen from above: a ball top on its shaft over an octagonal gate.
private struct ArcadeLever: View {
    let directions: Set<GameGamepadState.Button>
    let ball: Color

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let dx: CGFloat = (directions.contains(.right) ? 1 : 0) - (directions.contains(.left) ? 1 : 0)
            let dy: CGFloat = (directions.contains(.down) ? 1 : 0) - (directions.contains(.up) ? 1 : 0)
            let length = max(1, hypot(dx, dy))
            let throwDistance = side * 0.2
            let tip = CGSize(width: dx / length * throwDistance, height: dy / length * throwDistance)
            ZStack {
                OctagonShape()
                    .fill(RadialGradient(colors: [Color.black.opacity(0.75), Color(white: 0.1)], center: .center, startRadius: 0, endRadius: side * 0.5))
                    .overlay(OctagonShape().stroke(Color.white.opacity(0.12), lineWidth: 1.5))
                    .frame(width: side * 0.96, height: side * 0.96)
                Circle().fill(Color(white: 0.16)).frame(width: side * 0.36, height: side * 0.36)
                    .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 1))
                // The shaft from the washer to the ball.
                Path { path in
                    path.move(to: CGPoint(x: side / 2, y: side / 2))
                    path.addLine(to: CGPoint(x: side / 2 + tip.width, y: side / 2 + tip.height))
                }
                .stroke(LinearGradient(colors: [Color(white: 0.75), Color(white: 0.35)], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: side * 0.08, lineCap: .round))
                .frame(width: side, height: side)
                Circle()
                    .fill(RadialGradient(colors: [ball.mix(with: .white, by: 0.45), ball, ball.mix(with: .black, by: 0.45)],
                                         center: UnitPoint(x: 0.38, y: 0.3), startRadius: 0, endRadius: side * 0.26))
                    .frame(width: side * 0.44, height: side * 0.44)
                    .shadow(color: .black.opacity(0.6), radius: side * 0.05, x: -tip.width * 0.2, y: side * 0.04 - tip.height * 0.2)
                    .offset(tip)
                    .animation(.easeOut(duration: 0.06), value: directions)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private struct OctagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height), radius = side / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        for index in 0 ..< 8 {
            let angle = CGFloat(index) * .pi / 4 + .pi / 8
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// An analog stick: a concave knob in its well, leaning as far as the stick is pushed.
private struct ThumbStick: View {
    let x: Double
    let y: Double
    let clicked: Bool
    /// Whether a thumb is on it.
    let held: Bool
    /// Whether it floats to the thumb; at rest it then shows only faintly where it waits.
    let floating: Bool
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let knob = side * 0.56
            let travel = (side - knob) / 2
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color.black.opacity(0.55), Color(white: 0.12)], center: .center, startRadius: side * 0.15, endRadius: side * 0.5))
                    .overlay(Circle().strokeBorder(held ? accent.opacity(0.7) : Color.white.opacity(0.14), lineWidth: held ? 2 : 1.5))
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.42), Color(white: 0.24), Color(white: 0.12)],
                                         center: UnitPoint(x: 0.4, y: 0.32), startRadius: 0, endRadius: knob * 0.62))
                    .overlay(Circle()
                        .fill(RadialGradient(colors: [Color(white: 0.12), Color(white: 0.26)], center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: knob * 0.34))
                        .frame(width: knob * 0.66, height: knob * 0.66))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: knob * 0.06, dash: [1.5, knob * 0.05])))
                    .overlay(Circle().strokeBorder(accent.opacity(clicked ? 0.9 : 0), lineWidth: 3))
                    .frame(width: knob, height: knob)
                    .scaleEffect(clicked ? 0.9 : 1)
                    .shadow(color: .black.opacity(0.6), radius: side * 0.04, y: side * 0.03)
                    .offset(x: CGFloat(x) * travel, y: CGFloat(y) * travel)
            }
            .frame(width: side, height: side)
            .opacity(floating && !held ? 0.55 : 1)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
