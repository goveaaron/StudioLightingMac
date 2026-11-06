import SwiftUI
import PrismCore

/// Settings ▸ Integrations: MIDI controllers, OSC, HTTP API, Shortcuts, Stream Deck / Companion.
///
/// OWNER: Integrations workstream. Placeholder pre-wired into `SettingsView`.
struct IntegrationsSettingsPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section("Integrations") {
                Text("MIDI, OSC, Shortcuts and Stream Deck support live here.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .formStyle(.grouped)
    }
}
