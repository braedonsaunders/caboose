import Foundation

/// A direct stroke on a mouse-only window, including the travel before UIKit recognizes it.
public struct DirectPointerDrag {
    public enum Action: Equatable {
        case move(CGPoint)
        case button(CGPoint, pressed: Bool)
    }

    private var last: CGPoint?
    public init() {}

    public mutating func begin(at point: CGPoint, translation: CGPoint) -> [Action] {
        let release = cancel()
        let origin = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
        last = point
        return release + [.move(origin), .button(origin, pressed: true), .move(point)]
    }

    public mutating func move(to point: CGPoint) -> [Action] {
        guard last != nil else { return [] }
        last = point
        return [.move(point)]
    }

    public mutating func end(at point: CGPoint) -> [Action] {
        guard last != nil else { return [] }
        last = nil
        return [.move(point), .button(point, pressed: false)]
    }

    public mutating func cancel() -> [Action] {
        guard let point = last else { return [] }
        last = nil
        return [.button(point, pressed: false)]
    }
}
