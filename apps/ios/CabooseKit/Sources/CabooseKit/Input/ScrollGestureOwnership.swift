/// Keeps direct and hardware pans from cancelling or appending to each other's
/// scroll driver. Changing the finger count ends ownership until a new gesture.
public struct ScrollGestureOwnership<Owner: Equatable> {
    private var owner: Owner?
    private var contacts = 0
    public var isActive: Bool { owner != nil }
    public init() {}

    public mutating func begin(_ owner: Owner, contacts: Int) {
        self.owner = owner
        self.contacts = contacts
    }

    public mutating func update(_ owner: Owner, contacts: Int) -> Bool {
        guard self.owner == owner else { return false }
        guard self.contacts == contacts else { cancel(); return false }
        return true
    }

    public mutating func end(_ owner: Owner) -> Bool {
        guard self.owner == owner else { return false }
        cancel()
        return true
    }

    public mutating func cancel() { owner = nil }
}
