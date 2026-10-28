import ActivityKit
import Foundation

/// Shared by the app and widget extension. Hosts update this shape over APNs.
struct JobAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var detail: String
    }
    var jobID: String
    var kind: String
    var title: String
}
