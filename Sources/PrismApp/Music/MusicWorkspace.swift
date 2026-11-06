import SwiftUI
import PrismCore

/// Music workspace. OWNER: Music workstream.
struct MusicWorkspace: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        EmptyStateView(systemImage: "waveform", title: "Music Mode",
                       message: "Play anything on this Mac — Spotify, YouTube, Apple Music — and the lights move with it.",
                       actionTitle: app.show.live.music.enabled ? "Turn Off" : "Turn On") {
            app.music.setEnabled(!app.show.live.music.enabled)
        }
    }
}
