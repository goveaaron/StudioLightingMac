import Foundation

/// Locates bundled resources without `Bundle.module` (SwiftPM's generated accessor for
/// executables looks next to the binary and *crashes* when the folder is missing inside an
/// .app bundle).
///
/// Lookup order:
///   1. `Prism.app/Contents/Resources/<name>` (packaged app; copied by scripts/build_app.sh)
///   2. `<repo>/Resources/<name>` (running from `swift run` / tests during development)
enum AppResources {
    static func url(_ name: String) -> URL? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL?.appendingPathComponent(name), fm.fileExists(atPath: res.path) {
            return res
        }
        let devRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // App
            .deletingLastPathComponent() // PrismApp
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo
            .appendingPathComponent("Resources")
            .appendingPathComponent(name)
        if fm.fileExists(atPath: devRoot.path) { return devRoot }
        return nil
    }

    static var fixtureLibrary: URL? { url("FixtureLibrary") }
    static var webRemote: URL? { url("WebRemote") }

    /// ~/Library/Application Support/Prism (created on demand).
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Prism", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func supportSubdirectory(_ name: String) -> URL {
        let dir = supportDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// User-created fixture profiles.
    static var userFixtures: URL { supportSubdirectory("Fixtures") }
    /// Crash-safe autosave of the current session.
    static var autosaveURL: URL { supportDirectory.appendingPathComponent("Current Session.prismlights") }
    /// Rolling backups (last N saves).
    static var backups: URL { supportSubdirectory("Backups") }

    static var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }
}
