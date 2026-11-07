import SwiftUI
import PrismCore

/// Small ring in the bottom bar that fills while a crossfade runs. It observes the live document
/// (where fades are stored) and animates with a TimelineView only while a fade is in progress, so it
/// costs nothing when idle and disappears the moment the last fade ends.
struct FadeProgressRing: View {
    @Environment(AppModel.self) private var app
    /// End time of the last fade this view waited out; changing it re-renders the view so the ring hides.
    @State private var settledEnd = -Double.infinity

    var body: some View {
        let live = app.show.live
        if let end = live.activeFadeEndTime(at: PrismClock.now()), end > settledEnd {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { _ in
                ring(live.fadeProgress(at: PrismClock.now()) ?? 1)
            }
            .task(id: end) {
                let wait = end - PrismClock.now()
                if wait.isFinite, wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(min(wait, 3600) * 1_000_000_000))
                }
                if !Task.isCancelled { settledEnd = end }
            }
        }
    }

    private func ring(_ progress: Double) -> some View {
        let clamped = progress.isFinite ? min(max(progress, 0), 1) : 1
        let percent = Int((clamped * 100).rounded())
        return ZStack {
            Circle()
                .stroke(Theme.stroke, lineWidth: 2)
            Circle()
                .trim(from: 0, to: CGFloat(clamped))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
        .help("Crossfade \(percent)%")
        .accessibilityElement()
        .accessibilityLabel("Crossfade")
        .accessibilityValue("\(percent) percent")
    }
}
