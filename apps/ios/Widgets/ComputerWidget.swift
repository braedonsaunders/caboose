import AppIntents
import SwiftUI
import WidgetKit

private func widgetClient() async throws -> HostClient {
    guard let credentials = Credentials.load() else { throw HostClient.Failure.unauthorized }
    return HostClient(baseURL: await credentials.reachableURL(), token: credentials.token)
}

struct ComputerEntry: TimelineEntry {
    let date: Date
    let name: String
    let state: String
    let tasks: Int
}

struct ComputerTimeline: TimelineProvider {
    func placeholder(in context: Context) -> ComputerEntry { ComputerEntry(date: .now, name: "Computer", state: "Unknown", tasks: 0) }
    func getSnapshot(in context: Context, completion: @escaping (ComputerEntry) -> Void) {
        Task { completion(await load()) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ComputerEntry>) -> Void) {
        Task {
            let entry = await load()
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
        }
    }
    private func load() async -> ComputerEntry {
        do {
            let status = try await widgetClient().computer()
            return ComputerEntry(date: .now, name: status.settings.name, state: status.state, tasks: status.tasks.running)
        } catch {
            return ComputerEntry(date: .now, name: "Computer", state: "Unavailable", tasks: 0)
        }
    }
}

struct ComputerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "computer-status", provider: ComputerTimeline()) { entry in
            VStack(alignment: .leading) {
                Label(entry.name, systemImage: "desktopcomputer").font(.headline).lineLimit(1)
                Text(entry.state.capitalized).font(.subheadline)
                if entry.state != "Unavailable" { Text("\(entry.tasks) running agent tasks").font(.caption) }
            }
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(URL(string: "caboose://home"))
        }
        .configurationDisplayName("Computer")
        .description("See your computer's state and running agent tasks.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct ComputerPowerIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Set Computer Power"
    @Parameter(title: "Awake") var value: Bool
    func perform() async throws -> some IntentResult {
        let client = try await widgetClient()
        if value { _ = try await client.wake() } else { try await client.park() }
        return .result()
    }
}

struct ComputerPowerProvider: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool { try await widgetClient().computer().state == "running" }
}

struct ComputerPowerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "computer-power", provider: ComputerPowerProvider()) { isOn in
            ControlWidgetToggle(isOn: isOn, action: ComputerPowerIntent()) {
                Label("Computer", systemImage: "desktopcomputer")
            } valueLabel: { on in Text(on ? "Awake" : "Parked") }
        }
        .displayName("Computer Power")
        .description("Wake or park your computer.")
    }
}
