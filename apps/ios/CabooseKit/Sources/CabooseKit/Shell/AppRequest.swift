import Foundation

/// An app the owner describes in Apps, which an agent builds as a Caboose app
/// (docs/architecture.md, Agent apps): web files in `~/Apps/<id>/`, published to Apps.
public struct AppRequest: Hashable, Sendable {
    /// The longest description the composer takes; the task prompt has room to spare.
    public static let maxLength = 4000

    /// The owner's words, without surrounding whitespace.
    public let description: String

    public init(_ description: String) {
        self.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Something to build, within the composer's limit.
    public var isValid: Bool { !description.isEmpty && description.count <= Self.maxLength }

    /// The agent task's prompt: the owner's description, and how to deliver it as an app
    /// rather than a reply. The agent's own guidance (app_guide) carries the format.
    public var prompt: String {
        """
        Make me a Caboose app: \(description)

        Build it as a Caboose app: read app_guide first, publish it with app_publish so it \
        appears in my Apps screen, and open it with app_open to check it at a phone size and \
        a desktop size before you finish. Complete app_guide's interaction acceptance checks: \
        exercise the primary action, text entry, buttons, scrolling and saved-state reload, \
        using only test-owned data. Address input-layout warnings and preserve existing app data. \
        Report what you actually tested, including any phone touch checks you could not run. \
        Tell me its name when it is ready.
        """
    }
}
