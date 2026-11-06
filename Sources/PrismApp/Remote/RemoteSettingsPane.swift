import SwiftUI
import PrismCore

/// Settings ▸ Remote: phone/web remote server, guest permissions, internet sharing, API keys.
///
/// OWNER: Remote workstream. Placeholder pre-wired into `SettingsView`.
struct RemoteSettingsPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section("Phone & web remote") {
                LabeledContent("Server") {
                    Text(app.remote.isServing ? "Running" : "Off").foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
