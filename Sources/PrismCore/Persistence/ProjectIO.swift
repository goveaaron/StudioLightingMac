import Foundation

public enum ProjectIOError: Error, LocalizedError {
    case unreadable(String)
    case invalidFormat(String)
    case tooNew(Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let s): return "The file couldn't be read. \(s)"
        case .invalidFormat(let s): return "This doesn't look like a Prism project. \(s)"
        case .tooNew(let v): return "This project was made with a newer version of Prism (format \(v)). Please update Prism."
        }
    }
}

/// Reading/writing `.prismlights` project files. Never crashes on bad input: everything is
/// decoded defensively, then validated and repaired.
public enum ProjectIO {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                let f = ISO8601DateFormatter()
                if let date = f.date(from: s) { return date }
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = f.date(from: s) { return date }
            }
            if let t = try? c.decode(Double.self) { return Date(timeIntervalSinceReferenceDate: t) }
            return Date()
        }
        return d
    }

    /// Serializes a project. Embeds the definitions used by its fixtures (via `library`).
    public static func data(for project: Project, library: ((String) -> FixtureDefinition?)? = nil, appVersion: String? = nil) throws -> Data {
        var p = project
        p.formatVersion = Project.currentFormatVersion
        p.modifiedAt = Date()
        if let appVersion { p.appVersion = appVersion }
        p.definitions = embeddedDefinitions(for: p, library: library)
        return try encoder().encode(p)
    }

    /// Definitions referenced by fixtures, preferring the library's current version.
    public static func embeddedDefinitions(for project: Project, library: ((String) -> FixtureDefinition?)?) -> [FixtureDefinition] {
        var out: [String: FixtureDefinition] = [:]
        for f in project.fixtures where out[f.definitionID] == nil {
            if let d = library?(f.definitionID) ?? project.definition(f.definitionID) { out[d.id] = d }
        }
        return out.values.sorted { $0.id < $1.id }
    }

    /// Writes atomically (temp file + rename) so a crash mid-save never corrupts the project.
    public static func write(_ project: Project, to url: URL, library: ((String) -> FixtureDefinition?)? = nil, appVersion: String? = nil) throws {
        let data = try data(for: project, library: library, appVersion: appVersion)
        try data.write(to: url, options: [.atomic])
    }

    public static func read(from url: URL) throws -> Project {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ProjectIOError.unreadable(error.localizedDescription) }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> Project {
        guard data.count < 200_000_000 else { throw ProjectIOError.invalidFormat("File is too large.") }
        let project: Project
        do { project = try decoder().decode(Project.self, from: data) } catch {
            throw ProjectIOError.invalidFormat(String(describing: error).prefix(300).description)
        }
        if project.formatVersion > Project.currentFormatVersion + 10 { throw ProjectIOError.tooNew(project.formatVersion) }
        return validate(project).project
    }

    public struct ValidationReport: Sendable {
        public var project: Project
        public var fixes: [String]
    }

    /// Repairs inconsistencies: duplicate ids, dangling references, missing modes, overlapping
    /// addresses are reported (not changed — the user decides), NaNs, etc.
    public static func validate(_ input: Project) -> ValidationReport {
        var p = input
        var fixes: [String] = []

        // Unique fixture ids.
        var seen = Set<UUID>()
        for i in p.fixtures.indices {
            if seen.contains(p.fixtures[i].id) { p.fixtures[i].id = UUID(); fixes.append("Duplicate fixture id repaired.") }
            seen.insert(p.fixtures[i].id)
            p.fixtures[i].transform = p.fixtures[i].transform.sanitized
            if let def = p.definition(p.fixtures[i].definitionID), def.mode(named: p.fixtures[i].modeName) == nil,
               let m = def.recommendedMode {
                fixes.append("\(p.fixtures[i].name): unknown mode “\(p.fixtures[i].modeName)” → “\(m.name)”.")
                p.fixtures[i].modeName = m.name
            }
        }
        let fixtureIDs = Set(p.fixtures.map(\.id))

        // Groups reference existing fixtures only.
        for i in p.groups.indices { p.groups[i].fixtureIDs = p.groups[i].fixtureIDs.filter { fixtureIDs.contains($0) } }

        // Looks: unique ids, drop states for missing fixtures.
        var lookIDs = Set<UUID>()
        for i in p.looks.indices {
            if lookIDs.contains(p.looks[i].id) { p.looks[i].id = UUID(); fixes.append("Duplicate look id repaired.") }
            lookIDs.insert(p.looks[i].id)
            let before = p.looks[i].states.count
            p.looks[i].states.storage = p.looks[i].states.storage.filter { fixtureIDs.contains($0.key) }
            if p.looks[i].states.count != before { fixes.append("Removed states for deleted lights from “\(p.looks[i].name)”.") }
        }
        let folderIDs = Set(p.folders.map(\.id))
        for i in p.looks.indices where p.looks[i].folderID != nil && !folderIDs.contains(p.looks[i].folderID!) {
            p.looks[i].folderID = nil
        }
        if var live = p.lastLive {
            live.base.storage = live.base.storage.filter { fixtureIDs.contains($0.key) }
            if let a = live.activeLookID, !lookIDs.contains(a) { live.activeLookID = nil }
            p.lastLive = live
        }
        return ValidationReport(project: p, fixes: fixes)
    }
}

/// DMX address bookkeeping used by the patch UI and validation.
public enum PatchMath {
    public struct Conflict: Hashable, Sendable {
        public var universe: Int
        public var a: UUID
        public var b: UUID
        public var overlap: ClosedRange<Int>
    }

    /// All pairs of fixtures whose address ranges overlap.
    public static func conflicts(_ fixtures: [ResolvedFixture]) -> [Conflict] {
        var out: [Conflict] = []
        let patched = fixtures.filter { $0.addressRange != nil }
        for i in patched.indices {
            for j in patched.indices where j > i {
                let a = patched[i], b = patched[j]
                guard a.fixture.universe == b.fixture.universe, let ra = a.addressRange, let rb = b.addressRange else { continue }
                let lo = max(ra.lowerBound, rb.lowerBound), hi = min(ra.upperBound, rb.upperBound)
                if lo <= hi { out.append(Conflict(universe: a.fixture.universe, a: a.id, b: b.id, overlap: lo...hi)) }
            }
        }
        return out
    }

    /// First address in `universe` where `channelCount` consecutive channels are free.
    public static func nextFreeAddress(channelCount: Int, universe: Int, fixtures: [ResolvedFixture], startingAt: Int = 1) -> Int? {
        let n = max(1, channelCount)
        var used = [Bool](repeating: false, count: 513)
        for f in fixtures where f.fixture.universe == universe {
            guard let r = f.addressRange else { continue }
            for a in r where a >= 1 && a <= 512 { used[a] = true }
        }
        var a = max(1, startingAt)
        while a + n - 1 <= 512 {
            if (a..<(a + n)).allSatisfy({ !used[$0] }) { return a }
            a += 1
        }
        return nil
    }

    /// Fixtures whose range extends past channel 512.
    public static func overflowing(_ fixtures: [ResolvedFixture]) -> [UUID] {
        fixtures.filter { ($0.addressRange?.upperBound ?? 0) > 512 }.map(\.id)
    }
}
