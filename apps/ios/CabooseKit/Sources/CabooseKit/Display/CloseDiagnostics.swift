import CoreGraphics
import Foundation
import QuartzCore

/// Explicitly opt-in, close-only metadata. Never changes the display protocol.
@MainActor public enum CloseDiagnostics {
    public static let setting = "CabooseCloseDiagnosticsEnabled"
    public static var enabled: Bool { UserDefaults.standard.bool(forKey: setting) }

    public struct Context: Codable {
        public var overviewOpen: Bool?
        public var cursor: CGPoint?
        public init(overviewOpen: Bool? = nil, cursor: CGPoint? = nil) {
            self.overviewOpen = overviewOpen
            self.cursor = cursor
        }
    }

    private struct Caller: Codable {
        var file: String
        var line: UInt
        var context: Context
    }
    private struct Record: Codable {
        var monotonicSeconds: Double
        var window: Int
        var connection: Int
        var epoch: String?
        var geometry: CGRect
        var caller: Caller?
        /// Measured SwiftUI label bounds, not UIKit's effective hit region.
        var controlFrameGlobal: CGRect?
    }
    private static var caller: Caller?
    private static var controlFrame: CGRect?
    private static var records: [Record] = []

    public static func withControlFrame(_ frame: CGRect?, action: () -> Void) {
        guard enabled else { action(); return }
        let previous = controlFrame
        controlFrame = frame
        defer { controlFrame = previous }
        action()
    }

    static func withCaller(file: StaticString, line: UInt, context: Context, action: () -> Void) {
        guard enabled else { action(); return }
        let previous = caller
        caller = Caller(file: String(String(describing: file).prefix(192)), line: line, context: context)
        defer { caller = previous }
        action()
    }

    // The current server emits exactly sixteen lowercase hexadecimal characters.
    // Do not copy arbitrary peer-controlled strings into a diagnostic artifact.
    static func safeEpoch(_ epoch: String?) -> String? {
        guard let epoch, epoch.utf8.count == 16,
              epoch.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return epoch
    }

    /// Called once at the canonical close entry, including unattributed callers.
    /// This records a request, not confirmation that a delayed game close was sent.
    static func record(window: RemoteWindow, connection: Int, epoch: String?) {
        guard enabled else { records.removeAll(keepingCapacity: false); return }
        records.append(Record(monotonicSeconds: CACurrentMediaTime(), window: window.id,
                              connection: connection, epoch: safeEpoch(epoch), geometry: window.frame,
                              caller: caller, controlFrameGlobal: controlFrame))
        records = Array(records.suffix(64))
        guard let data = try? JSONEncoder().encode(records), data.count <= 131_072,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let directory = caches.appendingPathComponent("CabooseDiagnostics", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("close-requests.json"), options: .atomic)
        } catch {
            // Diagnostics must never prevent or change a close request.
        }
    }
}

extension DisplaySession {
    /// Attributes a UI request while retaining the existing protocol requirement.
    public func closeDiagnosed(_ window: RemoteWindow, context: CloseDiagnostics.Context = .init(),
                               file: StaticString = #fileID, line: UInt = #line) {
        CloseDiagnostics.withCaller(file: file, line: line, context: context) { close(window) }
    }
}
