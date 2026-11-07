import SwiftUI
import PrismCore

/// Bottom bar: grand master, default crossfade, live indicators and engine health.
struct BottomBar: View {
    @Environment(AppModel.self) private var app
    @State private var stats = EngineStats()

    var body: some View {
        HStack(spacing: Theme.Space.l) {
            HStack(spacing: 8) {
                Image(systemName: "sun.max.fill").foregroundStyle(Theme.textTertiary)
                PrismSlider(
                    value: Binding(get: { app.show.live.grandMaster }, set: { app.show.setGrandMaster($0) }),
                    label: "Master",
                    tint: Theme.accent,
                    height: 24)
                .frame(width: 220)
            }

            HStack(spacing: 6) {
                Image(systemName: "timer").foregroundStyle(Theme.textTertiary)
                Text("Fade").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                NumericField(value: Binding(get: { app.preferences.defaultFadeTime },
                                            set: { app.preferences.defaultFadeTime = $0 }),
                             range: 0...60, unit: "s", decimals: 1, width: 62)
                    .help("Default crossfade time for new looks")
            }

            if app.show.live.blackout {
                StatusPill(text: "BLACKOUT", color: Theme.live, pulsing: true)
            }
            if app.show.live.music.enabled {
                StatusPill(text: app.music.features.bpm > 0 ? "\(Int(app.music.features.bpm.rounded())) BPM" : "Music",
                           color: Theme.music, systemImage: "waveform")
            }
            if app.remote.connectedClients > 0 {
                StatusPill(text: "\(app.remote.connectedClients) remote", color: Theme.remote, systemImage: "iphone")
            }

            Spacer()

            FadeProgressRing()

            if let look = app.show.activeLook {
                HStack(spacing: 6) {
                    Text("Look").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    Text(look.name).font(Theme.Font.captionStrong).foregroundStyle(Theme.textPrimary)
                }
            }

            Text(String(format: "%.0f fps", stats.measuredFPS))
                .font(Theme.Font.number(11))
                .foregroundStyle(stats.measuredFPS > app.engine.frameRate * 0.8 ? Theme.textTertiary : Theme.warning)
                .help(String(format: "Engine: %.0f fps · frame %.2f ms (max %.2f ms)",
                             stats.measuredFPS, stats.lastFrameDurationMs, stats.maxFrameDurationMs))
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, 8)
        .background(Theme.panel.opacity(0.96))
        .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 1) }
        .task {
            while !Task.isCancelled {
                stats = app.engine.stats
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
