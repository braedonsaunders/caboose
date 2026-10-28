import Foundation

public struct AgentMemory: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var content: String
    public var createdAt: String
    public var updatedAt: String
}

public struct AgentProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var instructions: String
    public var agent: String
    public var approvals: String
    public var archived: Bool
    public var createdAt: String
    public var updatedAt: String
    public var memories: [AgentMemory]
}

public struct AgentRoutine: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var profileId: String
    public var prompt: String
    public var schedule: AgentSchedule
    public var paused: Bool
    public var missed: String
    public var overlap: String
    public var deliveryGraceMs: Int
    public var nextAt: String?
    public var createdAt: String
    public var updatedAt: String
}

public struct AgentRoutineRun: Codable, Equatable, Identifiable, Sendable {
    /// The stable conversation/task UUID, including while reservation is pending.
    public var id: String
    public var routineId: String
    public var scheduledAt: String
    public var createdAt: String
    public var finishedAt: String?
    public var trigger: String
    public var status: String
    public var detail: String?
}

/// AppKit recurrence wire format. Calendar arithmetic and DST validation belong to the host.
public struct AgentSchedule: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case once, daily, weekly, monthly, interval }
    public enum MonthDay: Codable, Equatable, Sendable {
        case day(Int), last
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let day = try? c.decode(Int.self), (1...31).contains(day) { self = .day(day) }
            else if (try? c.decode(String.self)) == "last" { self = .last }
            else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid monthly day") }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self { case .day(let n): try c.encode(n); case .last: try c.encode("last") }
        }
    }
    public struct Active: Codable, Equatable, Sendable {
        public struct Window: Codable, Equatable, Sendable {
            public var start: String
            public var end: String
            public init(start: String, end: String) { self.start = start; self.end = end }
        }
        public var weekdays: [Int]?
        public var window: Window?
        public init(weekdays: [Int]? = nil, window: Window? = nil) { self.weekdays = weekdays; self.window = window }
    }
    public var kind: Kind
    public var timeZone: String
    public var active: Active?
    public var everyMs: Int?
    public var anchor: String?
    public var at: String?
    public var time: String?
    public var weekdays: [Int]?
    public var dayOfMonth: MonthDay?

    public init(kind: Kind = .daily, timeZone: String = TimeZone.current.identifier, active: Active? = nil,
                everyMs: Int? = nil, anchor: String? = nil, at: String? = nil, time: String? = nil,
                weekdays: [Int]? = nil, dayOfMonth: MonthDay? = nil) {
        self.kind = kind; self.timeZone = timeZone; self.active = active
        self.everyMs = everyMs; self.anchor = anchor; self.at = at; self.time = time
        self.weekdays = weekdays; self.dayOfMonth = dayOfMonth
    }

    /// Only fields for the selected union case are sent. Active filters never change the anchor.
    public func normalized() -> Self {
        var result = Self(kind: kind, timeZone: timeZone, active: active)
        switch kind {
        case .once: result.at = at
        case .daily: result.time = time
        case .weekly: result.time = time; result.weekdays = weekdays?.sorted()
        case .monthly: result.time = time; result.dayOfMonth = dayOfMonth
        case .interval: result.everyMs = everyMs; result.anchor = anchor
        }
        return result
    }

    public static func instant(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    public static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    public static func validTime(_ text: String) -> Bool {
        text.range(of: "^([01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) != nil
    }
    public var validationMessage: String? {
        guard TimeZone.knownTimeZoneIdentifiers.contains(timeZone) || timeZone == "UTC" else { return "Choose an IANA timezone, such as America/Toronto." }
        switch kind {
        case .once: if Self.date(at) == nil { return "Choose a date and time." }
        case .interval:
            if (everyMs ?? 0) <= 0 || Self.date(anchor) == nil { return "Choose an interval and anchor date." }
        case .daily, .weekly, .monthly:
            if !Self.validTime(time ?? "") { return "Enter a time in 24-hour HH:mm format." }
            if kind == .weekly && (weekdays?.isEmpty != false || weekdays!.contains(where: { !(1...7).contains($0) })) { return "Choose at least one weekday." }
            if kind == .monthly {
                guard let dayOfMonth else { return "Choose a day of the month." }
                if case .day(let n) = dayOfMonth, !(1...31).contains(n) { return "Choose day 1–31 or the last day." }
            }
        }
        if let days = active?.weekdays, days.isEmpty || days.contains(where: { !(1...7).contains($0) }) { return "Choose at least one active weekday." }
        if let w = active?.window, !Self.validTime(w.start) || !Self.validTime(w.end) || w.start == w.end { return "Enter different active-window times in HH:mm format." }
        return nil
    }
}
