import AppIntents
import SwiftUI
import WidgetKit

struct FavoriteWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Favourite Linux App"
    @Parameter(title: "App") var app: LinuxAppEntity?
}
struct FavoriteEntry: TimelineEntry {
    let date: Date
    let app: LinuxAppEntity?
}
struct FavoriteTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> FavoriteEntry { FavoriteEntry(date: .now, app: nil) }
    func snapshot(for configuration: FavoriteWidgetConfiguration, in context: Context) async -> FavoriteEntry { FavoriteEntry(date: .now, app: configuration.app) }
    func timeline(for configuration: FavoriteWidgetConfiguration, in context: Context) async -> Timeline<FavoriteEntry> {
        Timeline(entries: [FavoriteEntry(date: .now, app: configuration.app)], policy: .never)
    }
}
struct FavoriteAppWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "favorite-app", intent: FavoriteWidgetConfiguration.self, provider: FavoriteTimeline()) { entry in
            Group {
                if let app = entry.app {
                    Button(intent: OpenLinuxAppIntent(app: app)) { Label(app.name, systemImage: "app") }
                        .buttonStyle(.plain)
                } else { Label("Choose an app", systemImage: "app") }
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Favourite Linux App")
        .description("Launch a favourite app on your computer.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}
struct FavoriteControlConfiguration: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Favourite Linux App"
    @Parameter(title: "App") var app: LinuxAppEntity?
}
struct FavoriteAppControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "favorite-app-control", intent: FavoriteControlConfiguration.self) { configuration in
            ControlWidgetButton(action: OpenLinuxAppIntent(app: configuration.app)) {
                Label(configuration.app?.name ?? "Open App", systemImage: "app")
            }
        }
        .promptsForUserConfiguration()
        .displayName("Open Linux App")
        .description("Open a favourite app on your computer.")
    }
}
struct AskAgentControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ask-agent") {
            ControlWidgetButton(action: OpenAskIntent()) {
                Label("Ask Agent", systemImage: "sparkles")
            }
        }
        .displayName("Ask Agent")
        .description("Open Caboose to ask your computer agent.")
    }
}
