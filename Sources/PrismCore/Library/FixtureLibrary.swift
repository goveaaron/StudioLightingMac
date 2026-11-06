import Foundation

/// Lightweight index entry for browsing/searching the library without loading every mode.
public struct FixtureLibraryEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var manufacturer: String
    public var model: String
    public var category: FixtureCategory
    public var aliases: [String]
    public var modeNames: [String]
    /// Badge for the recommended mode, e.g. "CCT + RGBWW · 16 px".
    public var badge: String
    public var source: String?
    /// Relative path of the JSON file containing the full definition.
    public var file: String

    public init(id: String, manufacturer: String, model: String, category: FixtureCategory, aliases: [String],
                modeNames: [String], badge: String, source: String?, file: String) {
        self.id = id; self.manufacturer = manufacturer; self.model = model; self.category = category
        self.aliases = aliases; self.modeNames = modeNames; self.badge = badge; self.source = source; self.file = file
    }

    public var displayName: String { "\(manufacturer) \(model)" }
}

/// The fixture library: curated definitions (high quality, hand-checked), generic definitions,
/// converted open-source libraries and the user's own definitions.
///
/// Directory layout (Resources/FixtureLibrary):
///   index.json            — optional prebuilt `[FixtureLibraryEntry]` for fast startup
///   curated/*.json        — FixtureDefinitionFile (wins over everything else)
///   generic/*.json
///   ofl/*.json            — converted Open Fixture Library
///   (user dir)/*.json     — ~/Library/Application Support/Prism/Fixtures
///
/// Thread-safe. Loading is lazy for large libraries: the index is loaded eagerly and full
/// definitions are loaded on demand.
public final class FixtureLibrary: @unchecked Sendable {
    private let lock = PrismLock()
    private var entries: [String: FixtureLibraryEntry] = [:]
    private var definitions: [String: FixtureDefinition] = [:]
    private var fileCache: [String: [FixtureDefinition]] = [:]
    private var roots: [URL] = []
    /// Load problems (bad files) for diagnostics; loading never throws or crashes.
    public private(set) var problems: [String] = []

    public init() {}

    /// Loads all JSON files under the given root directories (later roots override earlier ones,
    /// except that `source == "curated"` entries are never overridden by non-curated ones).
    public func load(roots: [URL]) {
        lock.withLock {
            self.roots = roots
            entries = [:]; definitions = [:]; fileCache = [:]; problems = []
        }
        let fm = FileManager.default
        for root in roots {
            // Prebuilt index (fast path for big converted libraries).
            let indexURL = root.appendingPathComponent("index.json")
            if let data = try? Data(contentsOf: indexURL),
               let index = try? JSONDecoder().decode([FixtureLibraryEntry].self, from: data) {
                lock.withLock {
                    for var e in index {
                        e.file = root.appendingPathComponent(e.file).path
                        insertEntry(e)
                    }
                }
            }
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "json", url.lastPathComponent != "index.json" else { continue }
                // Skip files already covered by the index (loaded lazily).
                let covered = lock.withLock { entries.values.contains { $0.file == url.path } }
                if covered { continue }
                loadFile(url)
            }
        }
    }

    private func insertEntry(_ e: FixtureLibraryEntry) {
        if let existing = entries[e.id], existing.source == "curated", e.source != "curated" { return }
        entries[e.id] = e
    }

    @discardableResult
    func loadFile(_ url: URL) -> [FixtureDefinition] {
        if let cached = lock.withLock({ fileCache[url.path] }) { return cached }
        guard let data = try? Data(contentsOf: url) else {
            lock.withLock { problems.append("Unreadable: \(url.lastPathComponent)") }
            return []
        }
        let decoder = JSONDecoder()
        var defs: [FixtureDefinition] = []
        if let file = try? decoder.decode(FixtureDefinitionFile.self, from: data) {
            defs = file.fixtures
        } else if let single = try? decoder.decode(FixtureDefinition.self, from: data) {
            defs = [single]
        } else if let list = try? decoder.decode([FixtureDefinition].self, from: data) {
            defs = list
        } else {
            lock.withLock { problems.append("Invalid fixture JSON: \(url.lastPathComponent)") }
            return []
        }
        defs = defs.filter { !$0.modes.isEmpty }
        lock.withLock {
            fileCache[url.path] = defs
            for d in defs {
                if let existing = definitions[d.id], existing.source == "curated", d.source != "curated" { continue }
                definitions[d.id] = d
                insertEntry(FixtureLibraryEntry(
                    id: d.id, manufacturer: d.manufacturer, model: d.model, category: d.category, aliases: d.aliases,
                    modeNames: d.modes.map(\.name), badge: d.recommendedMode?.capabilities.badge ?? "",
                    source: d.source, file: url.path))
            }
        }
        return defs
    }

    /// Adds definitions programmatically (e.g. embedded project definitions, user-created).
    public func add(_ defs: [FixtureDefinition]) {
        lock.withLock {
            for d in defs where !d.modes.isEmpty {
                if let existing = definitions[d.id], existing.source == "curated", d.source != "curated" { continue }
                definitions[d.id] = d
                insertEntry(FixtureLibraryEntry(
                    id: d.id, manufacturer: d.manufacturer, model: d.model, category: d.category, aliases: d.aliases,
                    modeNames: d.modes.map(\.name), badge: d.recommendedMode?.capabilities.badge ?? "",
                    source: d.source, file: ""))
            }
        }
    }

    /// Full definition by id (loads its file on demand).
    public func definition(_ id: String) -> FixtureDefinition? {
        if let d = lock.withLock({ definitions[id] }) { return d }
        guard let entry = lock.withLock({ entries[id] }), !entry.file.isEmpty else { return nil }
        let defs = loadFile(URL(fileURLWithPath: entry.file))
        return defs.first { $0.id == id }
    }

    public var allEntries: [FixtureLibraryEntry] {
        lock.withLock { Array(entries.values) }.sorted {
            ($0.manufacturer.lowercased(), $0.model.lowercased()) < ($1.manufacturer.lowercased(), $1.model.lowercased())
        }
    }

    public var manufacturers: [String] {
        Array(Set(allEntries.map(\.manufacturer))).sorted { $0.lowercased() < $1.lowercased() }
    }

    public var count: Int { lock.withLock { entries.count } }

    /// Ranked search over manufacturer, model, aliases and category.
    public func search(_ query: String, category: FixtureCategory? = nil, limit: Int = 200) -> [FixtureLibraryEntry] {
        let q = SelectorResolver.normalize(query)
        let words = q.split(separator: " ").map(String.init)
        var scored: [(FixtureLibraryEntry, Int)] = []
        for e in allEntries {
            if let category, e.category != category { continue }
            if words.isEmpty { scored.append((e, e.source == "curated" ? 2 : (e.source == "generic" ? 1 : 0))); continue }
            let hay = SelectorResolver.normalize(([e.manufacturer, e.model, e.category.displayName] + e.aliases).joined(separator: " "))
            var score = 0
            var allMatch = true
            for w in words {
                if hay.contains(w) { score += 10 } else { allMatch = false }
            }
            guard allMatch else { continue }
            let model = SelectorResolver.normalize(e.model)
            if model == q { score += 100 } else if model.hasPrefix(q) { score += 40 }
            if SelectorResolver.normalize(e.displayName) == q { score += 120 }
            if e.source == "curated" { score += 15 }
            scored.append((e, score))
        }
        return scored.sorted { a, b in
            a.1 != b.1 ? a.1 > b.1 : a.0.displayName.lowercased() < b.0.displayName.lowercased()
        }.prefix(limit).map(\.0)
    }
}
