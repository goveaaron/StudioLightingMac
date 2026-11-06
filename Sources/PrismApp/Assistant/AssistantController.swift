import Foundation
import PrismCore

/// One exchange in the assistant transcript.
struct AssistantMessage: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant, system }
    let id = UUID()
    var role: Role
    var text: String
    var date = Date()
}

/// Natural-language control ("warm up the background a bit, more blue back left").
///
/// OWNER: Assistant workstream. Placeholder: no parsing yet.
@MainActor
@Observable
final class AssistantController: AppService {
    private(set) var transcript: [AssistantMessage] = []
    private(set) var isThinking = false

    func start(app: AppModel) {}
    func shutdown() {}

    /// Interprets a request and applies it. Returns the reply shown/spoken to the user.
    @discardableResult
    func submit(_ text: String, origin: CommandOrigin = .assistant) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        transcript.append(AssistantMessage(role: .user, text: trimmed))
        let reply = "The assistant isn't available in this build yet."
        transcript.append(AssistantMessage(role: .assistant, text: reply))
        return reply
    }
}
