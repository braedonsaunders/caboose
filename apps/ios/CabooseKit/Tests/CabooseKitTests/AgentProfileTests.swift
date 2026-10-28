import Foundation
import Testing
@testable import CabooseKit

struct AgentProfileTests {
    @Test func saturdayAtTwoKeepsWallTimeAndZone() throws {
        let schedule = AgentSchedule(kind: .weekly, timeZone: "America/Toronto", time: "02:00", weekdays: [6])
        #expect(schedule.validationMessage == nil)
        let raw = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(schedule.normalized())) as? [String: Any])
        #expect(raw["time"] as? String == "02:00")
        #expect(raw["timeZone"] as? String == "America/Toronto")
        #expect(raw["weekdays"] as? [Int] == [6])
        #expect(raw["at"] == nil)
    }
    @Test func intervalPreservesOffsetAnchorAndActiveWindow() throws {
        let schedule = AgentSchedule(kind: .interval, timeZone: "America/Toronto",
            active: .init(weekdays: [6], window: .init(start: "22:00", end: "02:00")),
            everyMs: 300000, anchor: "2026-11-01T01:30:00-04:00", time: "09:00", weekdays: [1])
        let normalized = schedule.normalized()
        #expect(normalized.validationMessage == nil)
        #expect(normalized.anchor == schedule.anchor)
        #expect(normalized.active == schedule.active)
        #expect(normalized.time == nil)
        #expect(normalized.weekdays == nil)
        #expect(AgentSchedule.date(normalized.anchor) == AgentSchedule.date("2026-11-01T05:30:00Z"))
    }
    @Test func monthlyLastAndNumericDayRoundTrip() throws {
        for day in [AgentSchedule.MonthDay.last, .day(31)] {
            let schedule = AgentSchedule(kind: .monthly, timeZone: "UTC", time: "02:00", dayOfMonth: day)
            let decoded = try JSONDecoder().decode(AgentSchedule.self, from: JSONEncoder().encode(schedule))
            #expect(decoded.dayOfMonth == day)
            #expect(decoded.validationMessage == nil)
        }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(AgentSchedule.MonthDay.self, from: Data("0".utf8)) }
    }
    @Test func scheduleValidationRejectsInvalidFormInputs() {
        #expect(AgentSchedule(timeZone: "+05:00", time: "09:00").validationMessage != nil)
        #expect(AgentSchedule(timeZone: "UTC", time: "24:00").validationMessage != nil)
        #expect(AgentSchedule(kind: .weekly, timeZone: "UTC", time: "02:00", weekdays: []).validationMessage != nil)
        #expect(AgentSchedule(kind: .interval, timeZone: "UTC", everyMs: 0, anchor: "2026-01-01T00:00:00Z").validationMessage != nil)
        #expect(AgentSchedule(timeZone: "UTC", active: .init(window: .init(start: "09:00", end: "09:00")), time: "02:00").validationMessage != nil)
    }
    @Test func intervalBoundsMatchHost() {
        for milliseconds in [60000, 300000, 3600000] {
            #expect(AgentSchedule(kind: .interval, timeZone: "UTC", everyMs: milliseconds, anchor: "2026-10-28T13:00:00Z").validationMessage == nil)
        }
        for milliseconds in [59999, 9007199254740992] {
            #expect(AgentSchedule(kind: .interval, timeZone: "UTC", everyMs: milliseconds, anchor: "2026-10-28T13:00:00Z").validationMessage != nil)
        }
    }
    @Test func dateRoundTripIsCanonicalMilliseconds() throws {
        let date = try #require(AgentSchedule.date("2026-10-28T09:00:00-04:00"))
        #expect(AgentSchedule.instant(date) == "2026-10-28T13:00:00.000Z")
        #expect(AgentSchedule.date("2026-10-28T09:00:00") == nil)
    }
    @Test func profileAndPublicRunDecodeHostPayloads() throws {
        let profile = Data(#"{"id":"p","name":"OpenBot","description":"Research","instructions":"Cite sources","agent":"codex","approvals":"ask","archived":true,"createdAt":"2026-10-28T00:00:00Z","updatedAt":"2026-10-28T00:00:00Z","memories":[{"id":"m","title":"Preference","content":"Concise","createdAt":"2026-10-28T00:00:00Z","updatedAt":"2026-10-28T00:00:00Z"}]}"#.utf8)
        let p = try JSONDecoder().decode(AgentProfile.self, from: profile)
        #expect(p.archived)
        #expect(p.memories.first?.content == "Concise")
        for status in ["reserved", "active", "succeeded", "failed", "skipped"] {
            let payload = "{\"id\":\"task-uuid\",\"routineId\":\"r\",\"scheduledAt\":\"2026-10-28T00:00:00Z\",\"createdAt\":\"2026-10-28T00:00:00Z\",\"finishedAt\":null,\"trigger\":\"manual\",\"status\":\"\(status)\"}"
            let run = try JSONDecoder().decode(AgentRoutineRun.self, from: Data(payload.utf8))
            #expect(run.id == "task-uuid")
            #expect(run.status == status)
        }
    }
}
