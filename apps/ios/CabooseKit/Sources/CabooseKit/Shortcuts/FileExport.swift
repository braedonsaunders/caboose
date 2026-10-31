import Foundation

/// The export adapters supported by the host's catalog job endpoint.
public enum FileExportApplication: String, CaseIterable, Sendable {
    case photocraft, lightcraft, filmcraft

    public var formats: [String] {
        switch self {
        case .photocraft, .lightcraft: ["png", "jpg", "tif", "webp"]
        case .filmcraft: ["mp4", "mov"]
        }
    }

    public var inputCount: ClosedRange<Int> {
        self == .photocraft ? 1...20 : 1...1
    }

    /// Check before staging any files, including when a shortcut supplies variables.
    public func validate(format: String, count: Int) throws {
        guard formats.contains(format) else {
            throw ValidationError("Choose an output format supported by the selected app: \(formats.joined(separator: ", ")).")
        }
        guard inputCount.contains(count) else {
            throw ValidationError(self == .photocraft ? "Choose between 1 and 20 images." : "Choose exactly one input file.")
        }
    }

    private struct ValidationError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
