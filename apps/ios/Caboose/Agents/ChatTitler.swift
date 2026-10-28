import Foundation
import FoundationModels

/// Names a chat for the chat list from its first message, with Apple's on-device model where
/// Apple Intelligence is available. It only names: what the owner says always goes to the
/// chat's agent. Without the model the list shows the first line of the message.
enum ChatTitler {
    static func title(for prompt: String) async -> String? {
        guard SystemLanguageModel.default.availability == .available else { return nil }
        let session = LanguageModelSession(instructions: """
            You name chats. Reply with a title of two to five words for a chat that begins with the user's message: \
            no quotes, no punctuation at the end, in the message's language.
            """)
        guard let reply = try? await session.respond(to: String(prompt.prefix(2000)), options: GenerationOptions(sampling: .greedy)) else { return nil }
        let title = reply.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'.").union(.whitespacesAndNewlines))
        guard !title.isEmpty, title.count <= 60, !title.contains("\n") else { return nil }
        return title
    }
}
