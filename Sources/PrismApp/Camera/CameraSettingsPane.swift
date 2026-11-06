import SwiftUI
import PrismCore

/// Settings ▸ Camera: which camera, white-balance reference, verification sensitivity.
///
/// OWNER: Camera workstream. Placeholder pre-wired into `SettingsView`.
struct CameraSettingsPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section("Camera") {
                LabeledContent("Status") {
                    Text(app.camera.isRunning ? "Running" : "Off").foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
