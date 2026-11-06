import Foundation

/// Hands-free control: wake phrase ("Hey Prism…") + speech recognition → assistant.
///
/// OWNER: Assistant workstream (voice). Placeholder.
@MainActor
@Observable
final class VoiceController: AppService {
    private(set) var isListening = false
    private(set) var partialTranscript = ""

    func start(app: AppModel) {}
    func shutdown() {}

    func toggleListening() {}
}
