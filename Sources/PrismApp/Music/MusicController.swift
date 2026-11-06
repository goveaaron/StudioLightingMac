import Foundation
import PrismCore

/// Music mode: captures system audio (Spotify, YouTube…), analyses it and feeds the engine.
///
/// OWNER: Music workstream. Placeholder keeps the API used by the toolbar/bottom bar.
@MainActor
@Observable
final class MusicController: AppService {
    /// Latest analysis (UI meters). The engine receives features directly from the analyzer.
    private(set) var features: AudioFeatures = .silent
    private(set) var isCapturing = false
    private(set) var statusText = "Off"

    var isEnabled: Bool { AppModel.shared.show.live.music.enabled }

    func start(app: AppModel) {}
    func shutdown() {}

    func setEnabled(_ enabled: Bool) {
        AppModel.shared.show.apply(.setMusicMode(enabled: enabled, mood: nil), undoName: "Music Mode")
    }
}
