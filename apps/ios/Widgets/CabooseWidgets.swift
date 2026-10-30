import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CabooseWidgets: WidgetBundle {
    var body: some Widget {
        JobActivityWidget()
        ComputerWidget()
        ComputerPowerControl()
        FavoriteAppWidget()
        FavoriteAppControl()
        AskAgentControl()
    }
}

struct JobActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JobAttributes.self) { context in
            VStack(alignment: .leading, spacing: 6) {
                Label(context.attributes.title, systemImage: symbol(context.attributes)).font(.headline)
                Text(context.state.detail.isEmpty ? context.state.status.capitalized : context.state.detail)
                    .font(.subheadline).lineLimit(2)
                Text(context.state.status.capitalized).font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .activityBackgroundTint(Color(red: 0.10, green: 0.09, blue: 0.17))
            .widgetURL(taskURL(context.attributes))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: symbol(context.attributes)) }
                DynamicIslandExpandedRegion(.center) { Text(context.attributes.title).lineLimit(1) }
                DynamicIslandExpandedRegion(.bottom) { Text(context.state.detail.isEmpty ? context.state.status.capitalized : context.state.detail).lineLimit(2) }
            } compactLeading: { Image(systemName: symbol(context.attributes)) }
              compactTrailing: { Image(systemName: context.state.status == "running" ? "ellipsis" : "checkmark") }
              minimal: { Image(systemName: symbol(context.attributes)) }
            .widgetURL(taskURL(context.attributes))
        }
    }
    private func taskURL(_ attributes: JobAttributes) -> URL? {
        switch attributes.kind {
        case "agent": return URL(string: "caboose://task/\(attributes.jobID)")
        case "command": return URL(string: "caboose://command/\(attributes.jobID)")
        default: return URL(string: "caboose://home")
        }
    }
    private func symbol(_ attributes: JobAttributes) -> String {
        attributes.kind == "command" ? "terminal" : "sparkles"
    }
}
