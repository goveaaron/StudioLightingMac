import Foundation
import PrismCore

/// The fixture library for the app: bundled (curated + generic + converted open libraries)
/// plus the user's own profiles and definitions embedded in opened projects.
///
/// Launch cost is only the prebuilt `index.json`; full profiles are parsed lazily (and the
/// search index is built) on background queues. Use `definitionAsync(_:)` / `searchAsync(...)`
/// from UI code so a first-time lookup never stalls the main thread.
@MainActor
@Observable
final class LibraryStore {
    /// Thread-safe; safe to use from the engine and background queues.
    nonisolated let library = FixtureLibrary()
    private(set) var isLoaded = false
    /// Bumps when definitions are added (user profiles, embedded definitions).
    private(set) var revision = 0
    private(set) var problems: [String] = []
    /// Time spent in `load()` (reading the index; diagnostics and self-test).
    private(set) var loadMilliseconds: Double = 0

    nonisolated static let recentsDefaultsKey = "prism.library.recents"

    /// Sendable lookup closure for the engine/executor.
    nonisolated var lookup: @Sendable (String) -> FixtureDefinition? {
        let lib = library
        return { id in lib.definition(id) }
    }

    nonisolated func definition(_ id: String) -> FixtureDefinition? { library.definition(id) }

    /// Full definition without blocking the caller: parses its profile file on a background
    /// queue the first time.
    nonisolated func definitionAsync(_ id: String) async -> FixtureDefinition? {
        await library.definitionAsync(id)
    }

    /// Loads bundled + user libraries. Never throws; problems are collected for diagnostics.
    func load() {
        let start = Date()
        var roots: [URL] = []
        if let bundled = AppResources.fixtureLibrary { roots.append(bundled) }
        roots.append(AppResources.userFixtures)
        library.load(roots: roots)
        library.setRecentIDs(UserDefaults.standard.stringArray(forKey: Self.recentsDefaultsKey) ?? [])
        problems = library.problems
        loadMilliseconds = Date().timeIntervalSince(start) * 1000
        isLoaded = true
        revision += 1
        // Warm up in the background: the search index, the curated + generic packs (the demo
        // rig and the lights people add first) and recently used profiles.
        library.warmSearchIndex()
        library.prefetch(sources: ["curated", "generic", "user"])
        library.prefetch(library.recentIDs)
    }

    var entries: [FixtureLibraryEntry] { _ = revision; return library.allEntries }
    var manufacturers: [String] { _ = revision; return library.manufacturers }
    var count: Int { _ = revision; return library.count }
    var recentEntries: [FixtureLibraryEntry] { _ = revision; return library.recentEntries }

    /// Remembers a fixture the user just added (shown first in the Add Light wizard / library).
    func recordRecent(_ id: String) {
        library.recordRecent(id)
        UserDefaults.standard.set(library.recentIDs, forKey: Self.recentsDefaultsKey)
        revision += 1
    }

    func search(_ query: String, category: FixtureCategory? = nil, limit: Int = 200) -> [FixtureLibraryEntry] {
        _ = revision
        return library.search(query, category: category, limit: limit)
    }

    /// Off-main-actor search for large queries in the Add Light wizard.
    func searchAsync(_ query: String, category: FixtureCategory? = nil, limit: Int = 200) async -> [FixtureLibraryEntry] {
        _ = revision
        let lib = library
        return await Task.detached(priority: .userInitiated) {
            lib.search(query, category: category, limit: limit)
        }.value
    }

    /// Makes definitions embedded in a project available (shared files open anywhere).
    /// Never parses library files: only ids the library doesn't know at all are added.
    func registerEmbedded(_ defs: [FixtureDefinition]) {
        guard !defs.isEmpty else { return }
        let missing = defs.filter { !library.contains($0.id) }
        guard !missing.isEmpty else { return }
        library.add(missing)
        revision += 1
    }

    /// True for profiles the user created, edited or imported (stored in Application Support).
    func isUserProfile(_ id: String) -> Bool {
        library.entry(id)?.source == "user"
    }

    /// Saves a user-created/edited profile to ~/Library/Application Support/Prism/Fixtures.
    /// Saved profiles take precedence over bundled ones with the same id.
    func saveUserDefinition(_ def: FixtureDefinition) throws {
        var d = def
        d.source = "user"
        let file = FixtureDefinitionFile(schemaVersion: 1, fixtures: [d])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(file)
        try data.write(to: Self.userFileURL(for: d.id), options: .atomic)
        library.add([d])
        revision += 1
    }

    /// Removes a profile the user saved or imported. A bundled profile with the same id (if
    /// any) becomes visible again.
    func deleteUserDefinition(_ id: String) throws {
        let fm = FileManager.default
        let userDir = AppResources.userFixtures.standardizedFileURL.path
        var urls = [Self.userFileURL(for: id)]
        if let file = library.entry(id)?.file, !file.isEmpty, file.hasPrefix(userDir + "/") {
            urls.append(URL(fileURLWithPath: file))
        }
        for url in urls where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        load()
    }

    /// Imports `.prismfixture`, OFL `.json`, or QLC+ `.qxf` profiles and persists them to User Fixtures.
    @discardableResult
    func importProfile(from url: URL) throws -> [FixtureDefinition] {
        let defs = try FixtureImporter.importFile(at: url)
        for d in defs {
            try saveUserDefinition(d)
        }
        return defs
    }

    /// Exports a single fixture definition as a `.prismfixture` JSON file.
    func exportProfile(_ def: FixtureDefinition, to url: URL) throws {
        let data = try FixtureImporter.exportPrismFixture(def)
        try data.write(to: url, options: .atomic)
    }

    /// One file per profile, named after its id with only file-name-safe characters.
    private static func userFileURL(for id: String) -> URL {
        let safe = String(id.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "-" })
        return AppResources.userFixtures.appendingPathComponent("\(safe.isEmpty ? "profile" : safe).json")
    }
}
