import SwiftUI
import PrismCore

/// Settings ▸ Music: audio source (whole Mac / one app / microphone), sensitivity, safety.
///
/// OWNER: Music workstream. Placeholder pre-wired into `SettingsView`.
struct MusicSettingsPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section("Listening") {
                LabeledContent("Status") {
                    Text(app.music.statusText).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
