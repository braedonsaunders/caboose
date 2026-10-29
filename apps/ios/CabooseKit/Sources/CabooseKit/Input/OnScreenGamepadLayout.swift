import CoreGraphics
import Foundation

extension OnScreenGamepad {
    /// How a control is drawn and how much of its frame it covers.
    public enum Shape: Sendable {
        /// A round button, a stick's well or the d-pad's reach.
        case circle
        /// A pill: shoulders, triggers, Select and Start.
        case capsule
    }

    /// A control, where it is in the pad's own points, and the group a finger owns with it.
    public struct Item: Equatable, Sendable {
        public var control: Control
        public var cluster: Cluster
        public var frame: CGRect
        public var shape: Shape
    }

    /// A controller laid out in a pad: its controls, the strip the pad's own buttons and caption
    /// take, and where a floating stick may start.
    public struct Layout: Equatable, Sendable {
        public var style: Style
        public var size: CGSize
        public var items: [Item]
        /// The pad's own strip: the type menu, the destination caption and Customize.
        public var hud: CGRect
        /// The side of the pad each stick floats in, by stick.
        public var zones: [Control: CGRect]

        public func item(_ control: Control) -> Item? { items.first { $0.control == control } }
        public func items(in cluster: Cluster) -> [Item] { items.filter { $0.cluster == cluster } }
    }

    /// The tallest the pad's own strip is.
    public static let hudHeight: CGFloat = 34
    /// The narrowest the strip may be between the shoulder buttons before it moves above them.
    static let hudMinimumWidth: CGFloat = 120
    /// No unit grows past this, so a large screen keeps thumb-sized controls at its edges.
    static let largestUnit: CGFloat = 13.5

    /// `style` laid out in a pad of `size`. Every type has a wide arrangement (a landscape
    /// phone, the panel below a hinge) and most a tall one (a portrait phone); the one that
    /// gives larger controls wins. Controls hug the pad's sides, where thumbs are, and its
    /// bottom; extra width opens the middle. `settings.scale` grows or shrinks each group
    /// about its own centre.
    public static func layout(in size: CGSize, style: Style, settings: Settings) -> Layout {
        let empty = Layout(style: style, size: size, items: [], hud: .zero, zones: [:])
        guard size.width >= 80, size.height >= 80, size.width.isFinite, size.height.isFinite else { return empty }
        let scale = CGFloat(min(Settings.scaleRange.upperBound, max(Settings.scaleRange.lowerBound, settings.scale)))
        let blueprints = [Blueprint.wide(style), Blueprint.tall(style)].compactMap { $0 }
        var best: (blueprint: Blueprint, unit: CGFloat, hudAbove: Bool)?
        for blueprint in blueprints {
            for hudAbove in blueprint.hudInRow ? [false, true] : [true] {
                let reserve = hudAbove ? hudHeight + 8 : 0
                let unit = min((size.height - reserve) / blueprint.height, size.width / blueprint.width, largestUnit)
                guard unit > 0 else { continue }
                if !hudAbove, rowGap(blueprint, unit: unit, size: size, scale: scale) < hudMinimumWidth { continue }
                if best == nil || unit > best!.unit + 0.01 { best = (blueprint, unit, hudAbove) }
                break
            }
        }
        guard let (blueprint, unit, hudAbove) = best else { return empty }
        let top = size.height - blueprint.height * unit
        var items = place(blueprint, unit: unit, top: top, size: size, scale: scale)
        items = items.map { item in
            var item = item
            item.frame = item.frame.integral
            return item
        }

        let hud: CGRect
        if hudAbove {
            let width = min(320, size.width - 24)
            hud = CGRect(x: (size.width - width) / 2, y: max(4, top - hudHeight - 8), width: width, height: hudHeight)
        } else {
            let gap = gapAtRow(items, centerY: top + Blueprint.rowY * unit, size: size)
            let width = min(320, gap.width - 16)
            let height = min(hudHeight, Blueprint.rowHeight * unit + 4)
            hud = CGRect(x: gap.midX - width / 2, y: top + Blueprint.rowY * unit - height / 2, width: width, height: height)
        }

        var zones: [Control: CGRect] = [:]
        if style.hasSticks {
            let shoulders = items.filter { $0.cluster == .leftShoulders || $0.cluster == .rightShoulders }.map(\.frame.maxY).max() ?? top
            let zoneTop = max(hud.maxY, shoulders) + 4
            zones[.leftStick] = CGRect(x: 0, y: zoneTop, width: size.width / 2, height: max(0, size.height - zoneTop))
            zones[.rightStick] = CGRect(x: size.width / 2, y: zoneTop, width: size.width / 2, height: max(0, size.height - zoneTop))
        }
        return Layout(style: style, size: size, items: items, hud: hud, zones: zones)
    }

    /// The width free between the top row's left and right groups at `unit`.
    private static func rowGap(_ blueprint: Blueprint, unit: CGFloat, size: CGSize, scale: CGFloat) -> CGFloat {
        let top = size.height - blueprint.height * unit
        return gapAtRow(place(blueprint, unit: unit, top: top, size: size, scale: scale),
                        centerY: top + Blueprint.rowY * unit, size: size).width
    }

    /// The open stretch of the strip's band around the pad's middle.
    private static func gapAtRow(_ items: [Item], centerY: CGFloat, size: CGSize) -> CGRect {
        let band = CGRect(x: 0, y: centerY - hudHeight / 2, width: size.width, height: hudHeight)
        var left: CGFloat = 0, right = size.width
        for item in items where item.frame.intersects(band) {
            if item.frame.midX < size.width / 2 { left = max(left, item.frame.maxX) } else { right = min(right, item.frame.minX) }
            if item.frame.minX < size.width / 2 && item.frame.maxX > size.width / 2 { return .zero }
        }
        return CGRect(x: left, y: band.minY, width: max(0, right - left), height: band.height)
    }

    /// The blueprint's slots in points: each group scaled about its centre, then kept inside the pad.
    private static func place(_ blueprint: Blueprint, unit: CGFloat, top: CGFloat, size: CGSize, scale: CGFloat) -> [Item] {
        var items = blueprint.slots.map { slot -> Item in
            let x: CGFloat
            switch slot.anchor {
            case .leading: x = slot.x * unit
            case .trailing: x = size.width - slot.x * unit
            case .center: x = size.width / 2 + slot.x * unit
            }
            let frame = CGRect(x: x - slot.width * unit / 2, y: top + slot.y * unit - slot.height * unit / 2,
                               width: slot.width * unit, height: slot.height * unit)
            return Item(control: slot.control, cluster: slot.cluster, frame: frame, shape: slot.shape)
        }
        var clusters: [Cluster] = []
        for item in items where !clusters.contains(item.cluster) { clusters.append(item.cluster) }
        for cluster in clusters {
            let members = items.indices.filter { items[$0].cluster == cluster }
            let union = members.map { items[$0].frame }.reduce(CGRect.null) { $0.union($1) }
            let center = CGPoint(x: union.midX, y: union.midY)
            var scaled = union
            for index in members {
                let frame = items[index].frame
                items[index].frame = CGRect(x: center.x + (frame.minX - center.x) * scale, y: center.y + (frame.minY - center.y) * scale,
                                            width: frame.width * scale, height: frame.height * scale)
            }
            scaled = members.map { items[$0].frame }.reduce(CGRect.null) { $0.union($1) }
            // A group grown past the pad's edge moves back inside it.
            let dx = scaled.minX < 0 ? -scaled.minX : (scaled.maxX > size.width ? size.width - scaled.maxX : 0)
            let dy = scaled.minY < 0 ? -scaled.minY : (scaled.maxY > size.height ? size.height - scaled.maxY : 0)
            for index in members { items[index].frame = items[index].frame.offsetBy(dx: dx, dy: dy) }
        }
        return items
    }

    /// A type's arrangement in units: where each control sits from the side it hugs.
    struct Blueprint {
        enum Anchor { case leading, trailing, center }
        struct Slot {
            var control: Control
            var cluster: Cluster
            var anchor: Anchor
            /// The centre: from the left edge, from the right edge, or from the middle.
            var x: CGFloat
            var y: CGFloat
            var width: CGFloat
            var height: CGFloat
            var shape: Shape
        }

        var width: CGFloat
        var height: CGFloat
        /// Whether the pad's strip may sit between the top row's groups.
        var hudInRow: Bool
        var slots: [Slot]

        /// The centre and height of the top row, in units.
        static let rowY: CGFloat = 2.6
        static let rowHeight: CGFloat = 3.2

        static func wide(_ style: Style) -> Blueprint {
            switch style {
            case .modern:
                return Blueprint(width: 48, height: 30, hudInRow: true, slots: shoulders(trigger: (4.4, 6.4), bumper: (13.2, 7.6)) + [
                    stick(.leftStick, .leading, 8.6, 12, 11.2),
                    circle(.dpad, .dpad, .leading, 17.4, 24.2, 9.2),
                    stick(.rightStick, .trailing, 17.4, 24.2, 9.2),
                    circle(.button(.home), .button(.home), .center, 0, 8.4, 3.6),
                    pill(.select, .center, -5.2, 12.6, 4.4, 2.6),
                    pill(.start, .center, 5.2, 12.6, 4.4, 2.6),
                ] + diamond(.trailing, 8.6, 11.8, size: 11.4, button: 4.2))
            case .classic:
                return Blueprint(width: 44, height: 30, hudInRow: true, slots: [
                    shoulder(.leftShoulder, .leftShoulders, .leading, 8.2, 12.4),
                    shoulder(.rightShoulder, .rightShoulders, .trailing, 8.2, 12.4),
                    circle(.dpad, .dpad, .leading, 10, 16.4, 12.6),
                    pill(.select, .center, -3.4, 26.2, 4.6, 2.2),
                    pill(.start, .center, 3.4, 26.2, 4.6, 2.2),
                ] + diamond(.trailing, 10.4, 16.4, size: 14.4, button: 5.2))
            case .retro:
                return Blueprint(width: 40, height: 30, hudInRow: true, slots: [
                    circle(.dpad, .dpad, .leading, 10.4, 16, 13.6),
                    circle(.button(.south), .face, .trailing, 15.2, 17.2, 7),
                    circle(.button(.east), .face, .trailing, 6.6, 14.6, 7),
                    pill(.select, .center, -3.6, 26.4, 5, 2.2),
                    pill(.start, .center, 3.6, 26.4, 5, 2.2),
                ])
            case .arcade:
                // Two rows of four in the curve of an arcade panel: the punches above the kicks.
                let columns: [(top: GameGamepadState.Button, bottom: GameGamepadState.Button, x: CGFloat, y: CGFloat)] = [
                    (.west, .south, 22.1, 12.4), (.north, .east, 16, 11.2),
                    (.rightShoulder, .rightTrigger, 9.9, 11.2), (.leftShoulder, .leftTrigger, 3.8, 11.8),
                ]
                return Blueprint(width: 46, height: 30, hudInRow: true, slots: [
                    circle(.dpad, .dpad, .leading, 10, 16.4, 13.2),
                    pill(.select, .center, -4.8, 26.4, 4.2, 2.2),
                    circle(.button(.home), .button(.home), .center, 0, 26.4, 3),
                    pill(.start, .center, 4.8, 26.4, 4.2, 2.2),
                ] + columns.flatMap { column in [
                    circle(.button(column.top), .face, .trailing, column.x, column.y, 5),
                    circle(.button(column.bottom), .face, .trailing, column.x, column.y + 6.4, 5),
                ] })
            }
        }

        static func tall(_ style: Style) -> Blueprint? {
            switch style {
            case .modern:
                return Blueprint(width: 30, height: 36, hudInRow: false, slots: shoulders(trigger: (3.4, 5.2), bumper: (9.9, 6)) + [
                    pill(.select, .center, -4.6, 7.4, 4.2, 2.6),
                    circle(.button(.home), .button(.home), .center, 0, 7.4, 3.2),
                    pill(.start, .center, 4.6, 7.4, 4.2, 2.6),
                    stick(.leftStick, .leading, 8, 16, 11),
                    circle(.dpad, .dpad, .leading, 8.6, 29.4, 10),
                    stick(.rightStick, .trailing, 8.6, 29.4, 10),
                ] + diamond(.trailing, 8, 16, size: 11, button: 4))
            case .classic:
                return Blueprint(width: 30, height: 29, hudInRow: false, slots: [
                    shoulder(.leftShoulder, .leftShoulders, .leading, 7, 11.2),
                    shoulder(.rightShoulder, .rightShoulders, .trailing, 7, 11.2),
                    pill(.select, .center, -3.4, 7.4, 4.6, 2.2),
                    pill(.start, .center, 3.4, 7.4, 4.6, 2.2),
                    circle(.dpad, .dpad, .leading, 7.6, 21, 11.6),
                ] + diamond(.trailing, 7.6, 21, size: 12.4, button: 4.6))
            case .retro:
                return Blueprint(width: 30, height: 24, hudInRow: false, slots: [
                    circle(.dpad, .dpad, .leading, 7.4, 10.4, 10.8),
                    circle(.button(.south), .face, .trailing, 11.4, 12.4, 6.4),
                    circle(.button(.east), .face, .trailing, 5, 7.6, 6.4),
                    pill(.select, .center, -3.4, 21.6, 4.6, 2.2),
                    pill(.start, .center, 3.4, 21.6, 4.6, 2.2),
                ])
            case .arcade:
                return nil
            }
        }

        private static func circle(_ control: Control, _ cluster: Cluster, _ anchor: Anchor, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat) -> Slot {
            Slot(control: control, cluster: cluster, anchor: anchor, x: x, y: y, width: size, height: size, shape: .circle)
        }

        private static func stick(_ control: Control, _ anchor: Anchor, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat) -> Slot {
            circle(control, control == .leftStick ? .leftStick : .rightStick, anchor, x, y, size)
        }

        private static func pill(_ button: GameGamepadState.Button, _ anchor: Anchor, _ x: CGFloat, _ y: CGFloat,
                                 _ width: CGFloat, _ height: CGFloat) -> Slot {
            Slot(control: .button(button), cluster: .button(button), anchor: anchor, x: x, y: y, width: width, height: height, shape: .capsule)
        }

        private static func shoulder(_ button: GameGamepadState.Button, _ cluster: Cluster, _ anchor: Anchor, _ x: CGFloat, _ width: CGFloat) -> Slot {
            Slot(control: .button(button), cluster: cluster, anchor: anchor, x: x, y: rowY, width: width, height: rowHeight, shape: .capsule)
        }

        /// A trigger at each outer corner and a bumper inside it.
        private static func shoulders(trigger: (x: CGFloat, width: CGFloat), bumper: (x: CGFloat, width: CGFloat)) -> [Slot] {
            [
                shoulder(.leftTrigger, .leftShoulders, .leading, trigger.x, trigger.width),
                shoulder(.leftShoulder, .leftShoulders, .leading, bumper.x, bumper.width),
                shoulder(.rightShoulder, .rightShoulders, .trailing, bumper.x, bumper.width),
                shoulder(.rightTrigger, .rightShoulders, .trailing, trigger.x, trigger.width),
            ]
        }

        /// Four face buttons in a diamond `size` across, centred at (`x`, `y`).
        private static func diamond(_ anchor: Anchor, _ x: CGFloat, _ y: CGFloat, size: CGFloat, button: CGFloat) -> [Slot] {
            let reach = (size - button) / 2
            // The diamond's left is toward the middle for a trailing cluster.
            let inward: CGFloat = anchor == .trailing ? 1 : -1
            let places: [(GameGamepadState.Button, CGFloat, CGFloat)] = [
                (.north, 0, -reach), (.south, 0, reach), (.west, inward * reach, 0), (.east, -inward * reach, 0),
            ]
            return places.map { circle(.button($0.0), .face, anchor, x + $0.1, y + $0.2, button) }
        }
    }
}
