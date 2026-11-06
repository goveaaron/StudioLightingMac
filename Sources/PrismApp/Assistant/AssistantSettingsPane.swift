import SwiftUI
import PrismCore

/// Settings ▸ Assistant & Voice: wake phrase, push-to-talk, spoken replies, AI provider.
///
/// OWNER: Assistant workstream. Placeholder pre-wired into `SettingsView`.
struct AssistantSettingsPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section("Voice") {
                LabeledContent("Listening") {
                    Text(app.voice.isListening ? "On" : "Off").foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
