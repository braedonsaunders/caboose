import BackgroundTasks
import Foundation

/// Backs up every computer this phone keeps backups of, in a background processing task iOS
/// runs when it chooses (typically overnight, on power and Wi-Fi), at most every few hours.
enum BackupScheduler {
    static let identifier = "com.braedonsaunders.caboose.backup"

    /// Call from `application(_:didFinishLaunchingWithOptions:)`, before launch completes.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return task.setTaskCompleted(success: false) }
            run(task)
        }
    }

    /// Ask iOS for the next run; harmless to call often.
    static func schedule() {
        guard !BackupStore.enabled.isEmpty else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            return
        }
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func run(_ task: BGProcessingTask) {
        schedule()
        let work = Task.detached(priority: .background) {
            let computers = ((try? Credentials.loadCollection())?.computers ?? []).filter { BackupStore.enabled.contains($0.id) }
            var succeeded = true
            for credentials in computers {
                if Task.isCancelled { break }
                do { _ = try await BackupEngine.shared.backUp(credentials) } catch { succeeded = false }
            }
            task.setTaskCompleted(success: succeeded && !Task.isCancelled)
        }
        // Every step is committed, so stopping here loses nothing already stored.
        task.expirationHandler = { work.cancel() }
    }
}
