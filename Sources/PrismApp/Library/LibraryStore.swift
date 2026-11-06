import Foundation
import PrismCore

/// The fixture library for the app: bundled (curated + generic + converted open libraries)
/// plus the user's own profiles and definitions embedded in opened projects.
@MainActor
@Observable
final class LibraryStore {
    /// Thread-safe; safe to use from the engine and background queues.
    nonisolated let library = FixtureLibrary()
    private(set) var isLoaded = false
    /// Bumps when definitions are added (user profiles, embedded definitions).
    private(set) var revision = 0
    private(set) var problems: [String] = []

    /// Sendable lookup closure for the engine/executor.
    nonisolated var lookup: @Sendable (String) -> FixtureDefinition? {
        let lib = library
        return { id in lib.definition(id) }
    }

    nonisolated func definition(_ id: String) -> FixtureDefinition? { library.definition(id) }

    /// Loads bundled + user libraries. Never throws; problems are collected for diagnostics.
    func load() {
        var roots: [URL] = []
        if let bundled = AppResources.fixtureLibrary { roots.append(bundled) }
        roots.append(AppResources.userFixtures)
        library.load(roots: roots)
        problems = library.problems
        isLoaded = true
        revision += 1
    }

    var entries: [FixtureLibraryEntry] { _ = revision; return library.allEntries }
    var manufacturers: [String] { _ = revision; return library.manufacturers }
    var count: Int { _ = revision; return library.count }

    func search(_ query: String, category: FixtureCategory? = nil, limit: Int = 200) -> [FixtureLibraryEntry] {
        _ = revision
        return library.search(query, category: category, limit: limit)
    }

    /// Makes definitions embedded in a project available (shared files open anywhere).
    func registerEmbedded(_ defs: [FixtureDefinition]) {
        guard !defs.isEmpty else { return }
        let missing = defs.filter { library.definition($0.id) == nil }
        guard !missing.isEmpty else { return }
        library.add(missing)
        revision += 1
    }

    /// Saves a user-created/edited profile to ~/Library/Application Support/Prism/Fixtures.
    func saveUserDefinition(_ def: FixtureDefinition) throws {
        var d = def
        if d.source == nil || d.source == "curated" || d.source == "ofl" || d.source == "qlc" { d.source = "user" }
        let file = FixtureDefinitionFile(schemaVersion: 1, fixtures: [d])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(file)
        let safeName = d.id.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = AppResources.userFixtures.appendingPathComponent("\(safeName).json")
        try data.write(to: url, options: .atomic)
        library.add([d])
        revision += 1
    }
}
