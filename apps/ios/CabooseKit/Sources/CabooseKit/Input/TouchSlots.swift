import Foundation

/// Gives each finger on the glass a touch slot, as wl_touch numbers them: the lowest free
/// slot when it lands, kept until it lifts, then free for the next finger.
public struct TouchSlots<Finger: Hashable> {
    private var slots: [Finger: Int] = [:]

    public init() {}

    public var isEmpty: Bool { slots.isEmpty }

    /// The finger's slot, giving it one if it has none.
    public mutating func slot(for finger: Finger) -> Int {
        if let slot = slots[finger] { return slot }
        let taken = Set(slots.values)
        var slot = 0
        while taken.contains(slot) { slot += 1 }
        slots[finger] = slot
        return slot
    }

    /// The finger lifted or was cancelled; its slot is free again. Returns the slot it had.
    @discardableResult public mutating func release(_ finger: Finger) -> Int? {
        slots.removeValue(forKey: finger)
    }

    public mutating func removeAll() { slots.removeAll() }
}
