import CabooseKit
import SwiftUI

struct AgentRoutinesView: View {
    @Environment(AppModel.self) private var model
    @State private var creating = false
    let openChat: (String?) -> Void
    var body: some View {
        let library = model.agents.library
        List {
            AgentLibraryNotice(error: library.routineError, unavailable: library.routinesUnavailable,
                               loading: library.loadingRoutines, retry: { await library.refreshRoutines() })
            if !library.routinesUnavailable {
                ForEach(library.routines) { routine in
                    NavigationLink { RoutineDetail(routineID: routine.id, openChat: openChat) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: routine.paused ? "pause.circle" : "calendar.badge.clock")
                                .font(.title2).foregroundStyle(Brand.amber)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(routine.name).font(.headline)
                                Text(library.profiles.first { $0.id == routine.profileId }?.name ?? "Unavailable teammate")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(routine.paused ? "Paused" : routine.nextAt.map { "Next: \(routineDate($0))" } ?? "Schedule complete")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 5)
                    }
                }
                if library.routines.isEmpty && !library.loadingRoutines && library.routineError == nil {
                    ContentUnavailableView("Make It a Routine", systemImage: "calendar.badge.plus", description: Text("Give a teammate recurring work. Your computer runs it even when your phone is away."))
                }
                NavigationLink { RoutineHistory(routineID: nil, openChat: openChat) } label: { Label("Run History", systemImage: "clock.arrow.circlepath") }
            }
        }
        .scrollContentBackground(.hidden)
        .background { ShellBackground() }
        .navigationTitle("Routines")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("New Routine", systemImage: "plus") { creating = true }.disabled(library.routinesUnavailable) } }
        .refreshable { await library.refreshRoutines(); await library.refreshProfiles() }
        .task { await library.refreshRoutines(); await library.refreshProfiles() }
        .sheet(isPresented: $creating) { RoutineEditor(routine: nil).environment(model) }
    }
}

private func routineDate(_ text: String) -> String {
    AgentSchedule.date(text)?.formatted(date: .abbreviated, time: .shortened) ?? text
}

struct RoutineDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let routineID: String
    let openChat: (String?) -> Void
    @State private var editing = false
    @State private var deleting = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        let library = model.agents.library
        if let routine = library.routines.first(where: { $0.id == routineID }) {
            List {
                Section {
                    Label(routine.name, systemImage: "calendar.badge.clock").font(.title2.bold())
                    LabeledContent("Teammate", value: library.profiles.first { $0.id == routine.profileId }?.name ?? "Unavailable")
                    Text(routine.prompt).textSelection(.enabled)
                }
                Section {
                    LabeledContent("Repeats", value: routine.schedule.kind.rawValue.capitalized)
                    LabeledContent("Timezone", value: routine.schedule.timeZone)
                    if let time = routine.schedule.time { LabeledContent("Local Time", value: time) }
                    if let days = routine.schedule.weekdays { LabeledContent("Weekdays", value: days.map { weekdayName($0) }.joined(separator: ", ")) }
                    if let day = routine.schedule.dayOfMonth {
                        LabeledContent("Day", value: { if case .day(let n) = day { return String(n) }; return "Last" }())
                    }
                    if let at = routine.schedule.at { LabeledContent("At", value: routineDate(at)) }
                    if let interval = routine.schedule.everyMs { LabeledContent("Interval", value: "\(Double(interval) / 1000) seconds") }
                    if let anchor = routine.schedule.anchor { LabeledContent("Anchor", value: routineDate(anchor)) }
                    if let active = routine.schedule.active {
                        if let days = active.weekdays { LabeledContent("Active Days", value: days.map { weekdayName($0) }.joined(separator: ", ")) }
                        if let window = active.window { LabeledContent("Active Window", value: "\(window.start)–\(window.end)") }
                    }
                    LabeledContent("Next Run", value: routine.paused ? "Paused" : routine.nextAt.map(routineDate) ?? "Schedule complete")
                    LabeledContent("Missed Runs", value: routine.missed == "coalesce" ? "Run once when available" : "Skip")
                    LabeledContent("Delivery Grace", value: "\(routine.deliveryGraceMs / 1000) seconds")
                } header: { Text("Schedule") } footer: { Text("Overlapping runs are skipped. Calendar times use this timezone; daylight-saving gaps are skipped and repeated times run once at the earlier instant.") }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
                Section {
                    Button("Run Now", systemImage: "play.fill") { perform { try await library.run(routine.id) } }
                        .disabled(routine.paused || library.profiles.first(where: { $0.id == routine.profileId })?.archived != false || library.runs.contains { $0.routineId == routine.id && ["reserved", "active"].contains($0.status) })
                    Button(routine.paused ? "Resume" : "Pause", systemImage: routine.paused ? "play.circle" : "pause.circle") {
                        perform { try await library.saveRoutine(routine.id, body: ["paused": .bool(!routine.paused)]) }
                    }
                    NavigationLink { RoutineHistory(routineID: routine.id, openChat: openChat) } label: { Label("Run History", systemImage: "clock.arrow.circlepath") }
                } footer: { Text("Pausing stops new runs; a conversation already running continues. Resuming starts the schedule after now.") }
                Section { Button("Delete Routine", role: .destructive) { deleting = true } }
            }
            .scrollContentBackground(.hidden)
            .background { ShellBackground() }
            .navigationTitle(routine.name).navigationBarTitleDisplayMode(.inline)
            .disabled(busy)
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } } }
            .sheet(isPresented: $editing) { RoutineEditor(routine: routine).environment(model) }
            .confirmationDialog("Delete this routine?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete Routine", role: .destructive) { perform { try await library.deleteRoutine(routine.id); dismiss() } }
            } message: { Text("Run history and conversations remain available. A running conversation continues.") }
            .task { await library.refreshHistory() }
            .refreshable { await library.refreshRoutines(); await library.refreshHistory() }
        } else { ContentUnavailableView("Routine Unavailable", systemImage: "calendar.badge.exclamationmark") }
    }
    private func perform(_ work: @escaping () async throws -> Void) {
        busy = true; error = nil
        Task { defer { busy = false }; do { try await work() } catch { self.error = error.localizedDescription } }
    }
}

struct RoutineHistory: View {
    @Environment(AppModel.self) private var model
    let routineID: String?
    let openChat: (String?) -> Void
    @State private var opening = false
    @State private var error: String?
    var body: some View {
        let library = model.agents.library
        let runs = library.runs.filter { routineID == nil || $0.routineId == routineID }
        List {
            AgentLibraryNotice(error: error ?? library.historyError, loading: library.loadingHistory, retry: { error = nil; await library.refreshHistory() })
            ForEach(runs) { run in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(run.status.capitalized).font(.headline)
                        Spacer()
                        Text(run.trigger == "manual" ? "Manual" : "Scheduled").font(.caption).foregroundStyle(.secondary)
                    }
                    if routineID == nil { Text(library.routines.first { $0.id == run.routineId }?.name ?? "Deleted routine").font(.subheadline) }
                    Text(routineDate(run.scheduledAt)).font(.caption).foregroundStyle(.secondary)
                    if let detail = run.detail { Text(detail).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
                    if run.status != "reserved" && run.status != "skipped" {
                        Button("Open Conversation", systemImage: "bubble.left") {
                            opening = true; error = nil
                            Task {
                                defer { opening = false }
                                await model.agents.refresh()
                                if model.agents.tasks.contains(where: { $0.id == run.id }) { openChat(run.id) }
                                else { error = "This conversation is not available. Try again after the computer reconnects." }
                            }
                        }.disabled(opening)
                    }
                }.padding(.vertical, 6)
            }
            if runs.isEmpty && !library.loadingHistory && library.historyError == nil {
                ContentUnavailableView("No Runs Yet", systemImage: "clock", description: Text("Scheduled and manual runs appear here when the host reserves them."))
            }
        }
        .scrollContentBackground(.hidden)
        .background { ShellBackground() }
        .navigationTitle("Run History").navigationBarTitleDisplayMode(.inline)
        .task { await library.refreshHistory() }
        .refreshable { await library.refreshHistory() }
    }
}

private func weekdayName(_ day: Int) -> String {
    let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    return (1...7).contains(day) ? names[day - 1] : String(day)
}

struct RoutineEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let routine: AgentRoutine?
    @State private var name: String
    @State private var profileID: String
    @State private var prompt: String
    @State private var schedule: AgentSchedule
    @State private var instant: Date
    @State private var intervalAmount: String
    @State private var intervalUnit: Int
    @State private var monthlyLast: Bool
    @State private var monthDay: Int
    @State private var missed: String
    @State private var grace: Int
    @State private var filterDays: Bool
    @State private var activeDays: [Int]
    @State private var filterWindow: Bool
    @State private var windowStart: String
    @State private var windowEnd: String
    @State private var busy = false
    @State private var error: String?
    init(routine: AgentRoutine?) {
        self.routine = routine
        let s = routine?.schedule ?? AgentSchedule(time: "09:00", weekdays: [6], dayOfMonth: .day(1))
        _name = State(initialValue: routine?.name ?? ""); _profileID = State(initialValue: routine?.profileId ?? "")
        _prompt = State(initialValue: routine?.prompt ?? ""); _schedule = State(initialValue: s)
        _instant = State(initialValue: AgentSchedule.date(s.at ?? s.anchor) ?? Date().addingTimeInterval(3600))
        let milliseconds = s.everyMs ?? 300000
        let unit = [3600000, 60000, 1000, 1].first { milliseconds % $0 == 0 } ?? 1
        _intervalAmount = State(initialValue: String(milliseconds / unit)); _intervalUnit = State(initialValue: unit)
        var last = false, day = 1
        if case .last = s.dayOfMonth { last = true }
        if case .day(let n) = s.dayOfMonth { day = n }
        _monthlyLast = State(initialValue: last); _monthDay = State(initialValue: day)
        _missed = State(initialValue: routine?.missed ?? "skip"); _grace = State(initialValue: routine?.deliveryGraceMs ?? 30000)
        _filterDays = State(initialValue: s.active?.weekdays != nil); _activeDays = State(initialValue: s.active?.weekdays ?? Array(1...7))
        _filterWindow = State(initialValue: s.active?.window != nil)
        _windowStart = State(initialValue: s.active?.window?.start ?? "09:00"); _windowEnd = State(initialValue: s.active?.window?.end ?? "17:00")
    }
    private var prepared: AgentSchedule {
        var s = schedule
        s.at = AgentSchedule.instant(instant); s.anchor = AgentSchedule.instant(instant)
        s.time = s.time ?? "09:00"; s.weekdays = s.weekdays ?? [6]
        let (milliseconds, overflow) = (Int(intervalAmount) ?? 0).multipliedReportingOverflow(by: intervalUnit)
        s.everyMs = overflow ? 0 : milliseconds
        s.dayOfMonth = monthlyLast ? .last : .day(monthDay)
        s.active = filterDays || filterWindow ? .init(weekdays: filterDays ? activeDays : nil, window: filterWindow ? .init(start: windowStart, end: windowEnd) : nil) : nil
        return s.normalized()
    }
    var body: some View {
        NavigationStack {
            Form {
                identity
                cadence
                activePeriod
                Section {
                    Picker("If Missed", selection: $missed) {
                        Text("Skip").tag("skip")
                        Text("Run once when available").tag("coalesce")
                    }
                    Stepper("Delivery grace: \(grace / 1000) seconds", value: $grace, in: 0...300000, step: 1000)
                } header: { Text("Run Policy") } footer: { Text("Runs never overlap. Skip allows this grace after the scheduled time. Run once catches up a single missed occurrence. Manual runs require an unpaused routine.") }
                if let message = prepared.validationMessage { Text(message).font(.footnote).foregroundStyle(.orange) }
                if let error { Text(error).foregroundStyle(.orange) }
            }
            .scrollContentBackground(.hidden)
            .background { ShellBackground() }
            .navigationTitle(routine == nil ? "New Routine" : "Edit Routine").navigationBarTitleDisplayMode(.inline)
            .disabled(busy)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!valid || busy) }
            }
            .overlay { if busy { ProgressView() } }
            .task {
                await model.agents.library.refreshProfiles()
                if profileID.isEmpty { profileID = model.agents.library.activeProfiles.first?.id ?? "" }
            }
        }
    }
    private var identity: some View {
        Section("Work") {
            AgentLibraryNotice(error: model.agents.library.profileError, unavailable: model.agents.library.profilesUnavailable, loading: model.agents.library.loadingProfiles, retry: { await model.agents.library.refreshProfiles() })
            NativeTextInput("Routine name", text: $name)
            Picker("Teammate", selection: $profileID) {
                Text("Choose a teammate").tag("")
                ForEach(model.agents.library.profiles.filter { !$0.archived || $0.id == profileID }) { Text($0.name + ($0.archived ? " (Archived)" : "")).tag($0.id) }
            }
            if model.agents.library.activeProfiles.isEmpty { Text("Create or restore a teammate before scheduling work.").font(.footnote).foregroundStyle(.secondary) }
            NativeTextInput("What should happen each run?", text: $prompt, lines: 4...12)
        }
    }
    private var cadence: some View {
        Section {
            Picker("Frequency", selection: $schedule.kind) {
                ForEach(AgentSchedule.Kind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            NativeTextInput("IANA timezone", text: $schedule.timeZone, capitalization: .none, correction: false)
            if schedule.kind == .once || schedule.kind == .interval {
                DatePicker(schedule.kind == .once ? "Run At" : "Interval Anchor", selection: $instant)
                    .environment(\.timeZone, TimeZone(identifier: schedule.timeZone) ?? .current)
            }
            if schedule.kind == .interval {
                NativeTextInput("Every", text: $intervalAmount, keyboard: .numberPad)
                Picker("Unit", selection: $intervalUnit) {
                    Text("Hours").tag(3600000); Text("Minutes").tag(60000); Text("Seconds").tag(1000); Text("Milliseconds").tag(1)
                }
            }
            if [.daily, .weekly, .monthly].contains(schedule.kind) {
                NativeTextInput("Local time (HH:mm)", text: Binding(get: { schedule.time ?? "09:00" }, set: { schedule.time = $0 }), keyboard: .numbersAndPunctuation)
            }
            if schedule.kind == .weekly {
                weekdayPicker(days: Binding(get: { schedule.weekdays ?? [6] }, set: { schedule.weekdays = $0 }))
            }
            if schedule.kind == .monthly {
                Toggle("Last Day of Month", isOn: $monthlyLast)
                if !monthlyLast { Stepper("Day \(monthDay)", value: $monthDay, in: 1...31) }
            }
        } header: { Text("Schedule") } footer: {
            Text("Calendar times follow the named timezone. Missing daylight-saving times are skipped; repeated times run once. Interval anchors preserve the cadence. Days absent from a month are skipped.")
        }
    }
    private var activePeriod: some View {
        Section {
            Toggle("Limit to Weekdays", isOn: $filterDays)
            if filterDays { weekdayPicker(days: $activeDays) }
            Toggle("Limit to Time Window", isOn: $filterWindow)
            if filterWindow {
                NativeTextInput("Start (HH:mm)", text: $windowStart, keyboard: .numbersAndPunctuation)
                NativeTextInput("End (HH:mm)", text: $windowEnd, keyboard: .numbersAndPunctuation)
            }
        } header: { Text("Active Period") } footer: {
            Text("Filters scheduled occurrences without shifting their cadence. The end is exclusive. An earlier end crosses midnight; weekdays belong to the day the window opens. Manual runs bypass this filter.")
        }
    }
    private func weekdayPicker(days: Binding<[Int]>) -> some View {
        ForEach(1...7, id: \.self) { day in
            Toggle(weekdayName(day), isOn: Binding(get: { days.wrappedValue.contains(day) }, set: { on in
                var selected = days.wrappedValue.filter { $0 != day }
                if on { selected.append(day) }; days.wrappedValue = selected.sorted()
            }))
        }
    }
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf16.count <= 80 && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && prompt.utf16.count <= 16000 && !profileID.isEmpty && prepared.validationMessage == nil
    }
    private func save() {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                try await model.agents.library.saveRoutine(routine?.id, body: ["name": .string(name), "profileId": .string(profileID), "prompt": .string(prompt), "schedule": try prepared.requestValue(), "missed": .string(missed), "overlap": .string("skip"), "deliveryGraceMs": .int(grace)])
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
