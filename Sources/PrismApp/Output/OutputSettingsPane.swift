import SwiftUI
import PrismCore

/// Settings ▸ Outputs: DMX interfaces, Art-Net / sACN, universes, sleep prevention.
///
/// OWNER: Hardware workstream. Placeholder pre-wired into `SettingsView`.
struct OutputSettingsPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section("DMX interface") {
                LabeledContent("Status") {
                    Text(app.outputs.summary.title).foregroundStyle(Theme.textSecondary)
                }
                Text(app.outputs.summary.detail)
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .formStyle(.grouped)
    }
}
