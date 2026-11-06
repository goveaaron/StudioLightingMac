import Foundation
import PrismCore

/// App-wide preferences (UserDefaults). Machine-specific settings live here — never in project
/// files — so shared projects don't carry someone else's devices, keys or remote links.
///
/// Feature areas with many settings (output devices, music, assistant, remote) keep their own
/// preference stores next to their code; this holds the shared/general ones.
@MainActor
@Observable
final class AppPreferences {
    @ObservationIgnored private let defaults: UserDefaults

    /// Engine frame rate (DMX refresh), 10…60 fps. Enttec Pro handles 40 comfortably.
    var frameRate: Double { didSet { defaults.set(frameRate, forKey: Keys.frameRate) } }
    /// Caps strobes/flashes at 3 Hz everywhere (WCAG photosensitivity guidance).
    var photosensitiveSafe: Bool { didSet { defaults.set(photosensitiveSafe, forKey: Keys.photosensitiveSafe) } }
    var maxStrobeHz: Double { didSet { defaults.set(maxStrobeHz, forKey: Keys.maxStrobeHz) } }
    /// Default crossfade for new looks (seconds).
    var defaultFadeTime: Double { didSet { defaults.set(defaultFadeTime, forKey: Keys.defaultFadeTime) } }
    /// Re-open the last session on launch.
    var restoreLastSession: Bool { didSet { defaults.set(restoreLastSession, forKey: Keys.restoreLastSession) } }
    /// Bring the lights back to the last state on launch (otherwise start dark).
    var restoreLastLook: Bool { didSet { defaults.set(restoreLastLook, forKey: Keys.restoreLastLook) } }
    /// Send a blackout when quitting (default off: lights hold their state, unlike most apps).
    var blackoutOnQuit: Bool { didSet { defaults.set(blackoutOnQuit, forKey: Keys.blackoutOnQuit) } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarding) } }
    /// Show the menu bar control (keeps Prism reachable with the window closed).
    var showMenuBarExtra: Bool { didSet { defaults.set(showMenuBarExtra, forKey: Keys.menuBar) } }

    var safety: SafetySettings { SafetySettings(maxStrobeHz: maxStrobeHz, photosensitiveSafe: photosensitiveSafe) }

    enum Keys {
        static let frameRate = "prism.frameRate"
        static let photosensitiveSafe = "prism.photosensitiveSafe"
        static let maxStrobeHz = "prism.maxStrobeHz"
        static let defaultFadeTime = "prism.defaultFadeTime"
        static let restoreLastSession = "prism.restoreLastSession"
        static let restoreLastLook = "prism.restoreLastLook"
        static let blackoutOnQuit = "prism.blackoutOnQuit"
        static let onboarding = "prism.hasCompletedOnboarding"
        static let menuBar = "prism.showMenuBarExtra"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func double(_ key: String, _ fallback: Double) -> Double {
            defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        frameRate = clamp(double(Keys.frameRate, 40), 10, 60)
        photosensitiveSafe = bool(Keys.photosensitiveSafe, true)
        maxStrobeHz = clamp(double(Keys.maxStrobeHz, 12), 1, 25)
        defaultFadeTime = clamp(double(Keys.defaultFadeTime, 1.5), 0, 60)
        restoreLastSession = bool(Keys.restoreLastSession, true)
        restoreLastLook = bool(Keys.restoreLastLook, true)
        blackoutOnQuit = bool(Keys.blackoutOnQuit, false)
        hasCompletedOnboarding = bool(Keys.onboarding, false)
        showMenuBarExtra = bool(Keys.menuBar, true)
    }

    static func resetAll(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("prism.") {
            defaults.removeObject(forKey: key)
        }
    }
}
