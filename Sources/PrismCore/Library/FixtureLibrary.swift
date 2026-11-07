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
///   ofl/*.json            — converted Open Fixture Library (MIT)
///   qlcplus/*.json        — converted QLC+ Fixture Library (Apache-2.0)
///   (user dir)/*.json     — ~/Library/Application Support/Prism/Fixtures
///
/// Thread-safe. Loading is lazy for large libraries: the index is loaded eagerly and full
/// definitions are loaded on demand.
public final class FixtureLibrary: @unchecked Sendable {
    /// Attribution notice for bundled open-source fixture libraries (for About box / Credits).
    public static let thirdPartyAttribution =
        "Fixture library includes converted profiles from the Open Fixture Library " +
        "(https://open-fixture-library.org, Copyright © 2017 Florian & Felix Edelmann and contributors, MIT License) " +
        "and the Q Light Controller Plus (QLC+) Fixture Library " +
        "(https://www.qlcplus.org, Copyright © Heikki Junnila, Massimo Callegari and QLC+ contributors, Apache License 2.0, " +
        "modified/converted to Prism JSON format)."

    private let lock = PrismLock()
    private var entries: [String: FixtureLibraryEntry] = [:]
    /// Bumped whenever `entries` changes; caches built from entries remember their generation.
    private var generation = 0
    private var searchIndexCache: FixtureSearchIndex?
    /// Single-flight search index build (other callers wait instead of building twice).
    private var searchIndexBuild: (generation: Int, group: DispatchGroup)?
    private var sortedEntriesCache: (generation: Int, entries: [FixtureLibraryEntry])?
    private var definitions: [String: FixtureDefinition] = [:]
    private var fileCache: [String: [FixtureDefinition]] = [:]
    /// Files currently being parsed (single-flight: other callers wait instead of parsing twice).
    private var inFlight: [String: DispatchGroup] = [:]
    private var roots: [URL] = []
    private var recentFixtureIDs: [String] = []
    /// Load problems (bad files) for diagnostics; loading never throws or crashes.
    public var problems: [String] { lock.withLock { _problems } }
    private var _problems: [String] = []

    public init() {}

    /// Loads the library from the given root directories. When two definitions share an id the
    /// higher-precedence source wins (see `sourceRank`); for equal precedence later roots win.
    ///
    /// Fast path: when a root contains a prebuilt `index.json`, only the index is read; the
    /// profile files it covers are parsed lazily, on first use (`definition(_:)`,
    /// `definitionAsync(_:)`, `prefetch(_:)`). Files not covered by an index (user profiles,
    /// hand-dropped files) are parsed immediately.
    public func load(roots: [URL]) {
        lock.withLock {
            self.roots = roots
            entries = [:]
            generation &+= 1
            definitions = [:]
            fileCache = [:]
            _problems = []
        }
        let fm = FileManager.default
        for root in roots {
            // Relative paths (e.g. "ofl/robe.json") whose definitions the index already lists.
            var covered = Set<String>()
            let indexURL = root.appendingPathComponent("index.json")
            if fm.fileExists(atPath: indexURL.path) {
                if let data = try? Data(contentsOf: indexURL),
                   let index = try? JSONDecoder().decode([FixtureLibraryEntry].self, from: data) {
                    lock.withLock {
                        for var e in index where !e.file.isEmpty {
                            covered.insert(e.file)
                            e.file = root.appendingPathComponent(e.file).standardizedFileURL.path
                            insertEntry(e)
                        }
                    }
                } else {
                    lock.withLock { _problems.append("Invalid library index: \(indexURL.lastPathComponent)") }
                }
            }
            guard let walker = fm.enumerator(atPath: root.path) else { continue }
            while let rel = walker.nextObject() as? String {
                let name = (rel as NSString).lastPathComponent
                if name.hasPrefix(".") {
                    walker.skipDescendants()
                    continue
                }
                let ext = (name as NSString).pathExtension.lowercased()
                guard ext == "json" || ext == "prismfixture" || ext == "qxf",
                      name != "index.json", !covered.contains(rel) else { continue }
                loadFile(root.appendingPathComponent(rel))
            }
        }
    }

    private func insertEntry(_ e: FixtureLibraryEntry) {
        if let existing = entries[e.id], !Self.canReplace(existing.source, with: e.source) { return }
        entries[e.id] = e
        generation &+= 1
    }

    /// Parses one profile file (once; concurrent callers wait for the first parse) and
    /// registers its definitions. Never throws: unreadable or invalid files become `problems`.
    @discardableResult
    func loadFile(_ url: URL) -> [FixtureDefinition] {
        let stdPath = url.standardizedFileURL.path
        enum Step { case cached([FixtureDefinition]), wait(DispatchGroup), parse(DispatchGroup) }
        let step: Step = lock.withLock {
            if let cached = fileCache[stdPath] { return .cached(cached) }
            if let group = inFlight[stdPath] { return .wait(group) }
            let group = DispatchGroup()
            group.enter()
            inFlight[stdPath] = group
            return .parse(group)
        }
        switch step {
        case .cached(let defs):
            return defs
        case .wait(let group):
            group.wait()
            return lock.withLock { fileCache[stdPath] } ?? []
        case .parse(let group):
            let defs = parseFile(url)
            lock.withLock {
                fileCache[stdPath] = defs
                inFlight[stdPath] = nil
                for d in defs {
                    if let existing = definitions[d.id], !Self.canReplace(existing.source, with: d.source) { continue }
                    definitions[d.id] = d
                    // Keep the richer index entry (aliases/badge come from the build tool) when present.
                    if let indexed = entries[d.id], indexed.file == stdPath { continue }
                    insertEntry(FixtureLibraryEntry(
                        id: d.id, manufacturer: d.manufacturer, model: d.model, category: d.category, aliases: d.aliases,
                        modeNames: d.modes.map(\.name), badge: d.recommendedMode?.capabilities.badge ?? "",
                        source: d.source, file: stdPath))
                }
            }
            group.leave()
            return defs
        }
    }

    /// Decodes a profile file in any supported format. Records a problem and returns `[]` on failure.
    private func parseFile(_ url: URL) -> [FixtureDefinition] {
        guard let data = try? Data(contentsOf: url) else {
            lock.withLock { _problems.append("Unreadable: \(url.lastPathComponent)") }
            return []
        }
        let decoder = JSONDecoder()
        var defs: [FixtureDefinition] = []
        if let file = try? decoder.decode(FixtureDefinitionFile.self, from: data) {
            defs = file.fixtures
        } else if let single = try? decoder.decode(FixtureDefinition.self, from: data), !single.modes.isEmpty {
            defs = [single]
        } else if let list = try? decoder.decode([FixtureDefinition].self, from: data) {
            defs = list
        } else if let imported = try? FixtureImporter.importData(data, filename: url.lastPathComponent) {
            defs = imported
        } else {
            lock.withLock { _problems.append("Invalid fixture file: \(url.lastPathComponent)") }
            return []
        }
        return defs.filter { !$0.modes.isEmpty }
    }

    /// Adds definitions programmatically (e.g. embedded project definitions, user-created).
    public func add(_ defs: [FixtureDefinition]) {
        lock.withLock {
            for d in defs where !d.modes.isEmpty {
                if let existing = definitions[d.id], !Self.canReplace(existing.source, with: d.source) { continue }
                definitions[d.id] = d
                insertEntry(FixtureLibraryEntry(
                    id: d.id, manufacturer: d.manufacturer, model: d.model, category: d.category, aliases: d.aliases,
                    modeNames: d.modes.map(\.name), badge: d.recommendedMode?.capabilities.badge ?? "",
                    source: d.source, file: ""))
            }
        }
    }

    /// Imports fixture definitions from a `.prismfixture`, OFL `.json`, or QLC+ `.qxf` file and adds them.
    @discardableResult
    public func importFile(at url: URL) throws -> [FixtureDefinition] {
        let defs = try FixtureImporter.importFile(at: url)
        add(defs)
        return defs
    }

    /// Full definition by id. Parses its profile file on first use (on the calling thread);
    /// UI code should prefer `definitionAsync(_:)` for definitions that may not be loaded yet.
    public func definition(_ id: String) -> FixtureDefinition? {
        if let d = lock.withLock({ definitions[id] }) { return d }
        guard let entry = lock.withLock({ entries[id] }), !entry.file.isEmpty else { return nil }
        let defs = loadFile(URL(fileURLWithPath: entry.file))
        return lock.withLock { definitions[id] } ?? defs.first { $0.id == id }
    }

    /// Full definition by id, parsing its profile file on a background queue when needed.
    public func definitionAsync(_ id: String) async -> FixtureDefinition? {
        if let d = cachedDefinition(id) { return d }
        return await withCheckedContinuation { (cont: CheckedContinuation<FixtureDefinition?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: self.definition(id))
            }
        }
    }

    /// The definition only if it is already in memory — never touches the disk.
    public func cachedDefinition(_ id: String) -> FixtureDefinition? {
        lock.withLock { definitions[id] }
    }

    /// True when `id` is known to the library (index or loaded). Never parses anything.
    public func contains(_ id: String) -> Bool {
        lock.withLock { definitions[id] != nil || entries[id] != nil }
    }

    /// Index entry for `id` (cheap; never parses the profile).
    public func entry(_ id: String) -> FixtureLibraryEntry? {
        lock.withLock { entries[id] }
    }

    /// Parses the profile files containing `ids` on a background queue so later lookups are
    /// instant. Returns immediately; safe to call repeatedly.
    public func prefetch(_ ids: [String], qos: DispatchQoS.QoSClass = .utility) {
        let files: [String] = lock.withLock {
            var seen = Set<String>()
            for id in ids where definitions[id] == nil {
                if let f = entries[id]?.file, !f.isEmpty, fileCache[f] == nil { seen.insert(f) }
            }
            return seen.sorted()
        }
        guard !files.isEmpty else { return }
        DispatchQueue.global(qos: qos).async {
            for f in files { self.loadFile(URL(fileURLWithPath: f)) }
        }
    }

    /// Parses, in the background, every profile file holding entries from `sources`
    /// (e.g. `["curated", "generic"]`). Returns immediately.
    public func prefetch(sources: Set<String>, qos: DispatchQoS.QoSClass = .utility) {
        let ids = lock.withLock { entries.values.filter { sources.contains($0.source ?? "") }.map(\.id) }
        prefetch(ids, qos: qos)
    }

    /// Number of profile files parsed so far (diagnostics: launch should parse only the index).
    public var parsedFileCount: Int { lock.withLock { fileCache.count } }

    /// Number of full definitions currently in memory.
    public var loadedDefinitionCount: Int { lock.withLock { definitions.count } }

    /// Every entry, sorted by manufacturer then model (cached until the library changes).
    public var allEntries: [FixtureLibraryEntry] {
        let (cached, gen, snapshot): ([FixtureLibraryEntry]?, Int, [FixtureLibraryEntry]) = lock.withLock {
            if let c = sortedEntriesCache, c.generation == generation { return (c.entries, generation, []) }
            return (nil, generation, Array(entries.values))
        }
        if let cached { return cached }
        let sorted = snapshot
            .map { (key: "\($0.manufacturer.lowercased())\u{1}\($0.model.lowercased())\u{1}\($0.id)", entry: $0) }
            .sorted { $0.key < $1.key }
            .map(\.entry)
        lock.withLock {
            if generation == gen { sortedEntriesCache = (gen, sorted) }
        }
        return sorted
    }

    public var manufacturers: [String] {
        Array(Set(allEntries.map(\.manufacturer))).sorted { $0.lowercased() < $1.lowercased() }
    }

    public var count: Int { lock.withLock { entries.count } }

    /// Precedence when two definitions share an id: the user's own profiles win, then curated,
    /// generic, then converted community libraries (OFL before QLC+). Equal ranks: newer wins.
    static func sourceRank(_ source: String?) -> Int {
        switch source {
        case "user": return 5
        case "curated": return 4
        case "generic": return 3
        case "ofl": return 2
        case "qlcplus", "qlc": return 1
        default: return 0
        }
    }

    static func canReplace(_ existing: String?, with incoming: String?) -> Bool {
        sourceRank(incoming) >= sourceRank(existing)
    }

    // MARK: - Recently Used Fixtures

    public var recentIDs: [String] {
        lock.withLock { recentFixtureIDs }
    }

    public var recentEntries: [FixtureLibraryEntry] {
        lock.withLock {
            recentFixtureIDs.compactMap { entries[$0] }
        }
    }

    public func recordRecent(_ id: String, maxCount: Int = 20) {
        lock.withLock {
            recentFixtureIDs.removeAll { $0 == id }
            recentFixtureIDs.insert(id, at: 0)
            if recentFixtureIDs.count > maxCount {
                recentFixtureIDs.removeLast(recentFixtureIDs.count - maxCount)
            }
        }
    }

    /// Replaces the recently used list (e.g. restored from preferences), most recent first.
    public func setRecentIDs(_ ids: [String], maxCount: Int = 20) {
        var seen = Set<String>()
        let unique = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        lock.withLock { recentFixtureIDs = Array(unique.prefix(maxCount)) }
    }

    // MARK: - Search

    /// The search index for the current library contents, built once per change (off the
    /// calling thread's critical path when `warmSearchIndex()` ran first). Concurrent callers
    /// share a single build.
    func searchIndex() -> FixtureSearchIndex {
        enum Step { case ready(FixtureSearchIndex), wait(DispatchGroup), build(Int, [FixtureLibraryEntry], DispatchGroup) }
        let step: Step = lock.withLock {
            if let index = searchIndexCache, index.generation == generation { return .ready(index) }
            if let pending = searchIndexBuild, pending.generation == generation { return .wait(pending.group) }
            let group = DispatchGroup()
            group.enter()
            searchIndexBuild = (generation, group)
            return .build(generation, Array(entries.values), group)
        }
        switch step {
        case .ready(let index):
            return index
        case .wait(let group):
            group.wait()
            if let index = lock.withLock({ searchIndexCache }) { return index }
            let (gen, snapshot) = lock.withLock { (generation, Array(entries.values)) }
            return FixtureSearchIndex(entries: snapshot, generation: gen)
        case .build(let gen, let snapshot, let group):
            let index = FixtureSearchIndex(entries: snapshot, generation: gen)
            lock.withLock {
                if (searchIndexCache?.generation ?? Int.min) < gen { searchIndexCache = index }
                if searchIndexBuild?.generation == gen { searchIndexBuild = nil }
            }
            group.leave()
            return index
        }
    }

    /// Builds the search index on a background queue so the first search is instant.
    /// Call after `load(roots:)`; returns immediately.
    public func warmSearchIndex(qos: DispatchQoS.QoSClass = .utility) {
        DispatchQueue.global(qos: qos).async { _ = self.searchIndex() }
    }

    /// True when the search index for the current contents is built (diagnostics/self-test).
    public var isSearchIndexWarm: Bool {
        lock.withLock { searchIndexCache?.generation == generation }
    }

    /// Ranked, typo-tolerant, alias-aware search over manufacturer, model, aliases, category and
    /// badge. Curated profiles rank first, then generic, then brands popular in film/TV and on
    /// stage, then the community libraries; recently used fixtures get a boost. An empty query
    /// lists recently used fixtures first, then the curated packs.
    public func search(_ query: String, category: FixtureCategory? = nil, limit: Int = 200) -> [FixtureLibraryEntry] {
        searchIndex().search(query, category: category, limit: limit, recent: recentIDs)
    }
}
