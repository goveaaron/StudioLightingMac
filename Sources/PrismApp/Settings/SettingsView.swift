import SwiftUI
import PrismCore

/// Settings window. Each feature workstream adds its own pane file and a tab here.
struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            OutputSettingsPane()
                .tabItem { Label("Outputs", systemImage: "cable.connector.horizontal") }
            MusicSettingsPane()
                .tabItem { Label("Music", systemImage: "waveform") }
            AssistantSettingsPane()
                .tabItem { Label("Assistant", systemImage: "sparkles") }
            CameraSettingsPane()
                .tabItem { Label("Camera", systemImage: "camera") }
            RemoteSettingsPane()
                .tabItem { Label("Remote", systemImage: "iphone.radiowaves.left.and.right") }
            IntegrationsSettingsPane()
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
            SafetySettingsPane()
                .tabItem { Label("Safety", systemImage: "eye.trianglebadge.exclamationmark") }
        }
        .frame(width: 680, height: 480)
    }
}

struct GeneralSettingsPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var prefs = app.preferences
        Form {
            Section("Startup") {
                Toggle("Reopen my last session", isOn: $prefs.restoreLastSession)
                Toggle("Bring lights back to where they were", isOn: $prefs.restoreLastLook)
                Toggle("Show Prism in the menu bar", isOn: $prefs.showMenuBarExtra)
            }
            Section("Output") {
                LabeledContent("Refresh rate") {
                    Picker("", selection: $prefs.frameRate) {
                        Text("30 fps").tag(30.0)
                        Text("40 fps (recommended)").tag(40.0)
                        Text("44 fps").tag(44.0)
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                Toggle("Black out the lights when Prism quits", isOn: $prefs.blackoutOnQuit)
            }
            Section("Looks") {
                LabeledContent("Default crossfade") {
                    NumericField(value: $prefs.defaultFadeTime, range: 0...60, unit: "s", decimals: 1)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: prefs.frameRate) { _, fps in app.engine.setFrameRate(fps) }
    }
}

struct SafetySettingsPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var prefs = app.preferences
        Form {
            Section {
                Toggle("Photosensitive-safe mode (limit flashing to 3 per second)", isOn: $prefs.photosensitiveSafe)
                LabeledContent("Maximum strobe") {
                    NumericField(value: $prefs.maxStrobeHz, range: 1...25, unit: "Hz", decimals: 0)
                }
            } footer: {
                Text("Applies everywhere: effects, music mode, the assistant and remote guests.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: prefs.photosensitiveSafe) { _, _ in app.show.pushToEngine() }
        .onChange(of: prefs.maxStrobeHz) { _, _ in app.show.pushToEngine() }
    }
}
