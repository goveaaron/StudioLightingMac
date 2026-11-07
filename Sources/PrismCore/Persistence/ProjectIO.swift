import Foundation

public enum ProjectIOError: Error, LocalizedError {
    case unreadable(String)
    case invalidFormat(String)
    case tooNew(Int)
    case unwritable(String)
    case invalidLook(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let s): return "The file couldn't be read. \(s)"
        case .invalidFormat(let s): return "This doesn't look like a Prism project. \(s)"
        case .tooNew(let v): return "This file was made with a newer version of Prism (format \(v)). Please update Prism."
        case .unwritable(let s): return "The file couldn't be saved. \(s)"
        case .invalidLook(let s): return "This doesn't look like a Prism look file. \(s)"
        }
    }
}

/// Lightweight fixture descriptor embedded inside `.prismlook` files so a single shared look
/// can map onto another studio's rig by role, label (`shortName`), or fixture `name`.
public struct SharedFixtureHint: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var shortName: String
    public var role: FixtureRole
    public var definitionID: String
    public var modeName: String
    public var stageX: Double
    public var stageY: Double

    public init(
        id: UUID,
        name: String,
        shortName: String = "",
        role: FixtureRole = .other,
        definitionID: String = "",
        modeName: String = "",
        stageX: Double = 0.5,
        stageY: Double = 0.5
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.role = role
        self.definitionID = definitionID
        self.modeName = modeName
        self.stageX = stageX
        self.stageY = stageY
    }

    public init(fixture: PatchedFixture) {
        self.id = fixture.id
        self.name = fixture.name
        self.shortName = fixture.shortName
        self.role = fixture.role
        self.definitionID = fixture.definitionID
        self.modeName = fixture.modeName
        self.stageX = fixture.transform.x
        self.stageY = fixture.transform.y
    }

    private enum CodingKeys: String, CodingKey { case id, name, shortName, role, definitionID, modeName, stageX, stageY }

    /// Decodes defensively; only a hint without a usable fixture id is rejected.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let decodedID = c.decodeLenient(UUID.self, forKey: .id) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Fixture hint has no id."))
        }
        id = decodedID
        name = String((c.decodeLenient(String.self, forKey: .name) ?? "").prefix(200))
        shortName = String((c.decodeLenient(String.self, forKey: .shortName) ?? "").prefix(32))
        role = c.decodeLenient(FixtureRole.self, forKey: .role) ?? .other
        definitionID = String((c.decodeLenient(String.self, forKey: .definitionID) ?? "").prefix(200))
        modeName = String((c.decodeLenient(String.self, forKey: .modeName) ?? "").prefix(200))
        stageX = clamp((c.decodeLenient(Double.self, forKey: .stageX) ?? 0.5).finiteOr(0.5), -1000, 1000)
        stageY = clamp((c.decodeLenient(Double.self, forKey: .stageY) ?? 0.5).finiteOr(0.5), -1000, 1000)
    }
}

/// Self-contained `.prismlook` single-look share payload.
public struct SharedLook: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 1
    public static let fileExtension = "prismlook"

    public var formatVersion: Int
    public var look: Look
    public var fixtures: [SharedFixtureHint]
    public var definitions: [FixtureDefinition]

    public init(
        formatVersion: Int = SharedLook.currentFormatVersion,
        look: Look,
        fixtures: [SharedFixtureHint],
        definitions: [FixtureDefinition] = []
    ) {
        self.formatVersion = formatVersion
        self.look = look
        self.fixtures = fixtures
        self.definitions = definitions
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, look, fixtures, definitions }

    /// Only `look` is required; corrupt fixture hints / definitions are dropped individually.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        look = try c.decode(Look.self, forKey: .look)
        formatVersion = c.decodeLenient(Int.self, forKey: .formatVersion) ?? SharedLook.currentFormatVersion
        fixtures = c.decodeTolerantArray(SharedFixtureHint.self, forKey: .fixtures, limit: Project.maxFixtures)?.values ?? []
        definitions = c.decodeTolerantArray(FixtureDefinition.self, forKey: .definitions, limit: Project.maxDefinitions)?.values ?? []
    }
}

/// Reading/writing `.prismlights` project files and `.prismlook` single-look files.
/// Never crashes on bad input: everything is decoded defensively, migrated, and repaired.
public enum ProjectIO {
    /// Project files larger than this are refused (protects against hostile or runaway files).
    public static let maxProjectFileBytes = 200_000_000
    /// `.prismlook` files larger than this are refused.
    public static let maxLookFileBytes = 50_000_000
    /// At most this many repair messages are reported individually; the rest are summarized.
    public static let maxReportedFixes = 40

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
            if let t = try? c.decode(Double.self), t.isFinite, abs(t) < 1e11 { return Date(timeIntervalSinceReferenceDate: t) }
            return Date()
        }
        return d
    }

    /// Default root directory for rolling backups (`~/Library/Application Support/Prism/Backups`).
    public static var defaultBackupsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = base.appendingPathComponent("Prism", isDirectory: true).appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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

    // MARK: - Atomic writes

    /// Writes `data` to a temporary file in the same directory as `url`, flushes it to disk, and atomically
    /// renames it over `url`, so a crash or power loss mid-save leaves either the old or the new file — never
    /// a torn one. When `previousURL` is given, the file being replaced is kept there (hard link, else copy)
    /// as a second line of defense.
    public static func writeAtomic(_ data: Data, to url: URL, keepingPreviousAt previousURL: URL? = nil) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
                throw ProjectIOError.unwritable(error.localizedDescription)
            }
        }
        let tempURL = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        defer {
            if fm.fileExists(atPath: tempURL.path) {
                try? fm.removeItem(at: tempURL)
            }
        }
        guard fm.createFile(atPath: tempURL.path, contents: nil) else {
            throw ProjectIOError.unwritable("Couldn't create a file in “\(dir.lastPathComponent)”.")
        }
        do {
            let handle = try FileHandle(forWritingTo: tempURL)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        } catch {
            throw ProjectIOError.unwritable(error.localizedDescription)
        }

        if let previousURL, previousURL != url, fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: previousURL)
            if (try? fm.linkItem(at: url, to: previousURL)) == nil {
                try? fm.copyItem(at: url, to: previousURL)
            }
        }

        if rename(tempURL.path, url.path) != 0 {
            // Fall back to FileManager replacement (e.g. when POSIX rename isn't possible on this volume).
            do { _ = try fm.replaceItemAt(url, withItemAt: tempURL) } catch {
                throw ProjectIOError.unwritable(error.localizedDescription)
            }
        }
        // Best effort: persist the directory entry too.
        let dirFD = open(dir.path, O_RDONLY)
        if dirFD >= 0 {
            _ = fsync(dirFD)
            _ = close(dirFD)
        }
    }

    /// Writes atomically (temp file in same directory + rename) so a crash mid-save never corrupts the project.
    /// Optionally records a rolling backup when `recordBackup` is true.
    public static func write(
        _ project: Project,
        to url: URL,
        library: ((String) -> FixtureDefinition?)? = nil,
        appVersion: String? = nil,
        recordBackup: Bool = false,
        backupsRoot: URL? = nil,
        keepingPreviousAt previousURL: URL? = nil
    ) throws {
        let encoded = try data(for: project, library: library, appVersion: appVersion)
        try writeAtomic(encoded, to: url, keepingPreviousAt: previousURL)
        if recordBackup {
            _ = try? Self.recordBackup(for: project, data: encoded, backupsRoot: backupsRoot)
        }
    }

    // MARK: - Rolling Backups (last 10 saves + 24 hourly snapshots)

    /// One file in a project's backup folder.
    public struct BackupEntry: Hashable, Sendable, Identifiable {
        public enum Kind: String, Sendable {
            /// Written on every explicit save (the last 10 are kept).
            case save
            /// The first save/autosave of each hour (the last 24 are kept).
            case hourly
            case other
        }

        public var url: URL
        public var date: Date
        public var kind: Kind
        public var id: URL { url }

        public init(url: URL, date: Date, kind: Kind) {
            self.url = url; self.date = date; self.kind = kind
        }
    }

    /// `<backupsRoot>/<projectID>/`, created if needed.
    public static func backupDirectory(for projectID: UUID, backupsRoot: URL? = nil) throws -> URL {
        let dir = (backupsRoot ?? defaultBackupsDirectory).appendingPathComponent(projectID.uuidString, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
                throw ProjectIOError.unwritable(error.localizedDescription)
            }
        }
        return dir
    }

    /// Records a rolling backup of `project` under `<backupsRoot>/<project.id>/`, keeping the
    /// last `maxRecentSaves` (10) save snapshots and up to `maxHourlySnapshots` (24) hourly snapshots.
    @discardableResult
    public static func recordBackup(
        for project: Project,
        data: Data? = nil,
        library: ((String) -> FixtureDefinition?)? = nil,
        backupsRoot: URL? = nil,
        now: Date = Date(),
        maxRecentSaves: Int = 10,
        maxHourlySnapshots: Int = 24
    ) throws -> URL {
        let dir = try backupDirectory(for: project.id, backupsRoot: backupsRoot)
        let payload = try data ?? Self.data(for: project, library: library)
        let seconds = now.timeIntervalSince1970.finiteOr(0)
        let millis = Int64(clamp(seconds * 1000.0, 0, 9.0e14).rounded())
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        let saveURL = dir.appendingPathComponent(String(format: "save-%015lld-", millis) + suffix + ".prismlights")
        try writeAtomic(payload, to: saveURL)
        let hourlyURL = try? writeHourlySnapshotIfNeeded(payload, in: dir, now: now)
        prune(dir, prefix: "save-", keep: maxRecentSaves, protecting: saveURL)
        prune(dir, prefix: "hourly-", keep: maxHourlySnapshots, protecting: hourlyURL)
        return saveURL
    }

    /// Records only the hourly snapshot (if this hour has none yet). Used by autosave so crash recovery
    /// has history without flooding the "last 10 saves" list.
    @discardableResult
    public static func recordHourlySnapshot(
        for project: Project,
        data: Data? = nil,
        library: ((String) -> FixtureDefinition?)? = nil,
        backupsRoot: URL? = nil,
        now: Date = Date(),
        maxHourlySnapshots: Int = 24
    ) throws -> URL {
        let dir = try backupDirectory(for: project.id, backupsRoot: backupsRoot)
        let hourlyURL = dir.appendingPathComponent(hourlyFileName(for: now))
        if FileManager.default.fileExists(atPath: hourlyURL.path) { return hourlyURL }
        let payload = try data ?? Self.data(for: project, library: library)
        let written = try writeHourlySnapshotIfNeeded(payload, in: dir, now: now)
        prune(dir, prefix: "hourly-", keep: maxHourlySnapshots, protecting: written)
        return written
    }

    static func hourlyFileName(for date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? cal.timeZone
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
        return String(
            format: "hourly-%04ld-%02ld-%02ld-%02ld.prismlights",
            comps.year ?? 2026, comps.month ?? 1, comps.day ?? 1, comps.hour ?? 0
        )
    }

    private static func writeHourlySnapshotIfNeeded(_ payload: Data, in dir: URL, now: Date) throws -> URL {
        let url = dir.appendingPathComponent(hourlyFileName(for: now))
        if !FileManager.default.fileExists(atPath: url.path) {
            try writeAtomic(payload, to: url)
        }
        return url
    }

    /// Deletes the oldest files with `prefix` beyond `keep` (names sort chronologically). Never deletes
    /// `protected` — the file just written survives even if the system clock jumped backwards.
    private static func prune(_ dir: URL, prefix: String, keep: Int, protecting protected: URL?) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let protectedName = protected?.lastPathComponent
        let files = contents
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "prismlights" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var excess = files.count - max(1, keep)
        guard excess > 0 else { return }
        for old in files where excess > 0 && old.lastPathComponent != protectedName {
            try? fm.removeItem(at: old)
            excess -= 1
        }
    }

    /// Backups for `projectID`, newest first.
    public static func backupEntries(for projectID: UUID, backupsRoot: URL? = nil) -> [BackupEntry] {
        let dir = (backupsRoot ?? defaultBackupsDirectory).appendingPathComponent(projectID.uuidString, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? cal.timeZone
        let entries: [BackupEntry] = contents.compactMap { url in
            let name = url.lastPathComponent
            guard url.pathExtension == "prismlights", !name.hasPrefix(".") else { return nil }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if name.hasPrefix("save-") {
                let digits = name.dropFirst("save-".count).prefix { $0.isNumber }
                if let ms = Int64(digits) {
                    return BackupEntry(url: url, date: Date(timeIntervalSince1970: Double(ms) / 1000), kind: .save)
                }
                return BackupEntry(url: url, date: mtime ?? .distantPast, kind: .save)
            }
            if name.hasPrefix("hourly-") {
                let parts = name.dropFirst("hourly-".count).dropLast(".prismlights".count).split(separator: "-").compactMap { Int($0) }
                if parts.count == 4 {
                    var comps = DateComponents()
                    comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]; comps.hour = parts[3]
                    if let date = cal.date(from: comps) { return BackupEntry(url: url, date: date, kind: .hourly) }
                }
                return BackupEntry(url: url, date: mtime ?? .distantPast, kind: .hourly)
            }
            return BackupEntry(url: url, date: mtime ?? .distantPast, kind: .other)
        }
        return entries.sorted { $0.date != $1.date ? $0.date > $1.date : $0.url.lastPathComponent > $1.url.lastPathComponent }
    }

    /// Lists available backup files for `projectID` sorted newest first.
    public static func listBackups(for projectID: UUID, backupsRoot: URL? = nil) -> [URL] {
        backupEntries(for: projectID, backupsRoot: backupsRoot).map(\.url)
    }

    // MARK: - Reading, Migration & Validation

    public static func read(from url: URL) throws -> Project {
        try readWithReport(from: url).project
    }

    public static func readWithReport(from url: URL) throws -> ValidationReport {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ProjectIOError.unreadable(error.localizedDescription) }
        return try decodeWithReport(data)
    }

    public static func decode(_ data: Data) throws -> Project {
        try decodeWithReport(data).project
    }

    public static func decodeWithReport(_ data: Data) throws -> ValidationReport {
        guard !data.isEmpty else { throw ProjectIOError.invalidFormat("The file is empty.") }
        guard data.count < maxProjectFileBytes else { throw ProjectIOError.invalidFormat("File is too large.") }
        let project: Project
        do { project = try decoder().decode(Project.self, from: data) } catch {
            throw ProjectIOError.invalidFormat(describe(error))
        }
        if project.formatVersion > Project.currentFormatVersion + 10 { throw ProjectIOError.tooNew(project.formatVersion) }
        return validate(project)
    }

    /// A short, human-readable reason for a decoding failure.
    static func describe(_ error: Error) -> String {
        let text: String
        if case DecodingError.dataCorrupted(let ctx) = error {
            text = ctx.debugDescription
        } else if case DecodingError.keyNotFound(let key, _) = error {
            text = "Missing “\(key.stringValue)”."
        } else if case DecodingError.typeMismatch(_, let ctx) = error {
            text = ctx.debugDescription
        } else if case DecodingError.valueNotFound(_, let ctx) = error {
            text = ctx.debugDescription
        } else {
            text = error.localizedDescription
        }
        return String(text.prefix(300))
    }

    public struct ValidationReport: Sendable {
        public var project: Project
        public var fixes: [String]

        public init(project: Project, fixes: [String] = []) {
            self.project = project
            self.fixes = fixes
        }
    }

    /// Runs schema migrations (`v1 → v2` etc.) and repairs inconsistencies: duplicate ids,
    /// dangling references, folder cycles, missing modes, NaNs, and corrupt sections recovered during decoding.
    public static func validate(_ input: Project) -> ValidationReport {
        var p = input
        var fixes: [String] = input.decodeFixes
        p.decodeFixes = []

        // Schema migrations.
        if p.formatVersion > Project.currentFormatVersion {
            fixes.append("This project was saved by a newer version of Prism (format v\(p.formatVersion)). Settings this version doesn't know were skipped.")
            p.formatVersion = Project.currentFormatVersion
        } else if p.formatVersion < Project.currentFormatVersion {
            let fromVersion = max(0, p.formatVersion)
            if fromVersion < 2 {
                // v2 defaults key/fill fixtures to disallow effects unless explicitly targeted.
                for i in p.fixtures.indices where p.fixtures[i].role == .key || p.fixtures[i].role == .fill {
                    p.fixtures[i].limits.allowEffects = false
                }
            }
            p.formatVersion = Project.currentFormatVersion
            fixes.append("Migrated project from format v\(fromVersion) to v\(Project.currentFormatVersion).")
        }

        // Definitions: unique ids (first wins).
        var definitionIDs = Set<String>()
        let definitionCount = p.definitions.count
        p.definitions = p.definitions.filter { definitionIDs.insert($0.id).inserted }
        if p.definitions.count != definitionCount { fixes.append("Removed duplicate fixture definitions.") }
        var definitionsByID: [String: FixtureDefinition] = [:]
        for d in p.definitions { definitionsByID[d.id] = d }

        // Unique fixture ids & sanitized limits/transforms/modes.
        var seen = Set<UUID>()
        var duplicateFixtures = 0
        for i in p.fixtures.indices {
            if !seen.insert(p.fixtures[i].id).inserted {
                p.fixtures[i].id = UUID()
                seen.insert(p.fixtures[i].id)
                duplicateFixtures += 1
            }
            p.fixtures[i].transform = p.fixtures[i].transform.sanitized
            p.fixtures[i].limits = p.fixtures[i].limits.sanitized
            if let def = definitionsByID[p.fixtures[i].definitionID], def.mode(named: p.fixtures[i].modeName) == nil,
               let m = def.recommendedMode {
                fixes.append("\(p.fixtures[i].name): unknown mode “\(p.fixtures[i].modeName)” → “\(m.name)”.")
                p.fixtures[i].modeName = m.name
            }
        }
        if duplicateFixtures > 0 { fixes.append(plural(duplicateFixtures, "duplicate light id", "repaired")) }
        let fixtureIDs = Set(p.fixtures.map(\.id))

        // Groups: unique ids, existing members only.
        var groupIDs = Set<UUID>()
        var duplicateGroups = 0
        for i in p.groups.indices {
            if !groupIDs.insert(p.groups[i].id).inserted {
                p.groups[i].id = UUID()
                groupIDs.insert(p.groups[i].id)
                duplicateGroups += 1
            }
            p.groups[i].fixtureIDs = p.groups[i].fixtureIDs.filter { fixtureIDs.contains($0) }
        }
        if duplicateGroups > 0 { fixes.append(plural(duplicateGroups, "duplicate group id", "repaired")) }

        // Folders: unique ids, parents must exist, no self-parenting, no cycles.
        var folderIDs = Set<UUID>()
        var duplicateFolders = 0
        for i in p.folders.indices {
            if !folderIDs.insert(p.folders[i].id).inserted {
                p.folders[i].id = UUID()
                folderIDs.insert(p.folders[i].id)
                duplicateFolders += 1
            }
        }
        if duplicateFolders > 0 { fixes.append(plural(duplicateFolders, "duplicate folder id", "repaired")) }
        var parentByID: [UUID: UUID] = [:]
        for i in p.folders.indices {
            guard let parent = p.folders[i].parentID else { continue }
            if parent == p.folders[i].id || !folderIDs.contains(parent) {
                p.folders[i].parentID = nil
            } else {
                parentByID[p.folders[i].id] = parent
            }
        }
        var cyclesBroken = 0
        for i in p.folders.indices {
            let start = p.folders[i].id
            var visited: Set<UUID> = [start]
            var cursor = parentByID[start]
            while let current = cursor {
                if current == start {
                    p.folders[i].parentID = nil
                    parentByID[start] = nil
                    cyclesBroken += 1
                    break
                }
                // Reached a cycle that doesn't include `start`; it's broken when one of its members is visited.
                if !visited.insert(current).inserted { break }
                cursor = parentByID[current]
            }
        }
        if cyclesBroken > 0 { fixes.append(plural(cyclesBroken, "looping folder", "moved to the top level")) }

        // Looks: unique ids, drop states/delays for missing fixtures, dangling folders.
        var lookIDs = Set<UUID>()
        var duplicateLooks = 0
        var trimmedLooks: [String] = []
        for i in p.looks.indices {
            if !lookIDs.insert(p.looks[i].id).inserted {
                p.looks[i].id = UUID()
                lookIDs.insert(p.looks[i].id)
                duplicateLooks += 1
            }
            let before = p.looks[i].states.count
            p.looks[i].states.storage = p.looks[i].states.storage.filter { fixtureIDs.contains($0.key) }
            if p.looks[i].states.count != before { trimmedLooks.append(p.looks[i].name) }
            p.looks[i].fixtureDelays = p.looks[i].fixtureDelays.filter { fixtureIDs.contains($0.key) }
            if let folder = p.looks[i].folderID, !folderIDs.contains(folder) {
                p.looks[i].folderID = nil
            }
        }
        if duplicateLooks > 0 { fixes.append(plural(duplicateLooks, "duplicate look id", "repaired")) }
        if trimmedLooks.count > 3 {
            fixes.append("Removed states for deleted lights from \(trimmedLooks.count) looks.")
        } else {
            for name in trimmedLooks { fixes.append("Removed states for deleted lights from “\(name)”.") }
        }

        if var live = p.lastLive {
            live.base.storage = live.base.storage.filter { fixtureIDs.contains($0.key) }
            if let a = live.activeLookID, !lookIDs.contains(a) { live.activeLookID = nil }
            live.grandMaster = clamp01(live.grandMaster)
            p.lastLive = live
        }

        if fixes.count > maxReportedFixes {
            let hidden = fixes.count - maxReportedFixes
            fixes = Array(fixes.prefix(maxReportedFixes))
            fixes.append("…and \(hidden) more repairs.")
        }
        return ValidationReport(project: p, fixes: fixes)
    }

    private static func plural(_ count: Int, _ noun: String, _ verb: String) -> String {
        count == 1 ? "1 \(noun) \(verb)." : "\(count) \(noun)s \(verb)."
    }

    // MARK: - Single-Look Sharing (`.prismlook`) & Look Import / Merge

    /// Builds a self-contained `SharedLook` for exporting a single look.
    public static func sharedLook(for look: Look, in project: Project, library: ((String) -> FixtureDefinition?)? = nil) -> SharedLook {
        let hints = project.fixtures.map { SharedFixtureHint(fixture: $0) }
        let defs = embeddedDefinitions(for: project, library: library)
        return SharedLook(look: look, fixtures: hints, definitions: defs)
    }

    public static func data(forLook look: Look, in project: Project, library: ((String) -> FixtureDefinition?)? = nil) throws -> Data {
        let payload = sharedLook(for: look, in: project, library: library)
        return try encoder().encode(payload)
    }

    public static func writeLook(_ look: Look, from project: Project, to url: URL, library: ((String) -> FixtureDefinition?)? = nil) throws {
        let payload = try data(forLook: look, in: project, library: library)
        try writeAtomic(payload, to: url)
    }

    /// Detects a bare `Look` JSON object (top-level `states` key) without decoding it.
    private struct BareLookProbe: Decodable {
        let hasStates: Bool
        private enum CodingKeys: String, CodingKey { case states }
        init(from decoder: Decoder) throws {
            hasStates = (try? decoder.container(keyedBy: CodingKeys.self))?.contains(.states) ?? false
        }
    }

    public static func decodeLook(_ data: Data) throws -> SharedLook {
        guard !data.isEmpty else { throw ProjectIOError.invalidLook("The file is empty.") }
        guard data.count < maxLookFileBytes else { throw ProjectIOError.invalidLook("Look file is too large.") }
        let shared: SharedLook
        do {
            shared = try decoder().decode(SharedLook.self, from: data)
        } catch {
            // Also accept a bare `Look` JSON document.
            if let probe = try? decoder().decode(BareLookProbe.self, from: data), probe.hasStates,
               let bareLook = try? decoder().decode(Look.self, from: data) {
                return SharedLook(look: bareLook, fixtures: [])
            }
            throw ProjectIOError.invalidLook(describe(error))
        }
        if shared.formatVersion > SharedLook.currentFormatVersion + 10 {
            throw ProjectIOError.tooNew(shared.formatVersion)
        }
        return shared
    }

    public static func readLook(from url: URL) throws -> SharedLook {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ProjectIOError.unreadable(error.localizedDescription) }
        return try decodeLook(data)
    }

    /// Maps target fixture IDs (`targetFixture.id`) to the best matching source fixture ID (`sourceFixture.id`),
    /// matching by role first, then label (`shortName`), then `name` (and exact `id` when identical).
    public static func matchTargetFixturesToSource(
        sourceFixtures: [SharedFixtureHint],
        targetFixtures: [PatchedFixture]
    ) -> [UUID: UUID] {
        guard !sourceFixtures.isEmpty, !targetFixtures.isEmpty else {
            // If no fixture hints are available, preserve matching UUIDs directly.
            var identity: [UUID: UUID] = [:]
            for t in targetFixtures { identity[t.id] = t.id }
            return identity
        }

        let sourceByID = Dictionary(sourceFixtures.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var targetToSource: [UUID: UUID] = [:]
        var usedSourceIDs = Set<UUID>()

        // 0. Exact ID match when role or name also aligns.
        for tf in targetFixtures {
            if let sf = sourceByID[tf.id], (sf.role == tf.role || sf.name.caseInsensitiveCompare(tf.name) == .orderedSame) {
                targetToSource[tf.id] = sf.id
                usedSourceIDs.insert(sf.id)
            }
        }

        // 1. Match by role (excluding .other), pairing by matching label/name within the role first,
        //    then by left-to-right stage order.
        for role in FixtureRole.allCases where role != .other {
            let roleSources = sourceFixtures
                .filter { $0.role == role }
                .sorted { ($0.stageX, $0.stageY, $0.shortName, $0.name) < ($1.stageX, $1.stageY, $1.shortName, $1.name) }
            guard !roleSources.isEmpty else { continue }

            let unmatchedRoleTargets = targetFixtures
                .filter { $0.role == role && targetToSource[$0.id] == nil }
                .sorted { ($0.transform.x, $0.transform.y, $0.shortName, $0.name) < ($1.transform.x, $1.transform.y, $1.shortName, $1.name) }

            for (idx, tf) in unmatchedRoleTargets.enumerated() {
                if !tf.shortName.isEmpty,
                   let byLabel = roleSources.first(where: { !usedSourceIDs.contains($0.id) && $0.shortName.caseInsensitiveCompare(tf.shortName) == .orderedSame }) {
                    targetToSource[tf.id] = byLabel.id
                    usedSourceIDs.insert(byLabel.id)
                } else if let byName = roleSources.first(where: { !usedSourceIDs.contains($0.id) && $0.name.caseInsensitiveCompare(tf.name) == .orderedSame }) {
                    targetToSource[tf.id] = byName.id
                    usedSourceIDs.insert(byName.id)
                } else if let unused = roleSources.first(where: { !usedSourceIDs.contains($0.id) }) {
                    targetToSource[tf.id] = unused.id
                    usedSourceIDs.insert(unused.id)
                } else {
                    // More target fixtures of this role than source fixtures: reuse sources in stage order.
                    let mappedIdx = min(roleSources.count - 1, idx)
                    targetToSource[tf.id] = roleSources[mappedIdx].id
                }
            }
        }

        // 2. Match remaining target fixtures by label (`shortName`).
        for tf in targetFixtures where targetToSource[tf.id] == nil && !tf.shortName.isEmpty {
            if let sf = sourceFixtures.first(where: { !usedSourceIDs.contains($0.id) && $0.shortName.caseInsensitiveCompare(tf.shortName) == .orderedSame })
                ?? sourceFixtures.first(where: { $0.shortName.caseInsensitiveCompare(tf.shortName) == .orderedSame }) {
                targetToSource[tf.id] = sf.id
                usedSourceIDs.insert(sf.id)
            }
        }

        // 3. Match remaining target fixtures by `name`.
        for tf in targetFixtures where targetToSource[tf.id] == nil && !tf.name.isEmpty {
            if let sf = sourceFixtures.first(where: { !usedSourceIDs.contains($0.id) && $0.name.caseInsensitiveCompare(tf.name) == .orderedSame })
                ?? sourceFixtures.first(where: { $0.name.caseInsensitiveCompare(tf.name) == .orderedSame }) {
                targetToSource[tf.id] = sf.id
                usedSourceIDs.insert(sf.id)
            }
        }

        return targetToSource
    }

    private static func remapSelector(_ selector: FixtureSelector, sourceToTargets: [UUID: [UUID]]) -> FixtureSelector {
        switch selector {
        case .fixtures(let ids):
            let mapped = ids.flatMap { sourceToTargets[$0] ?? [] }
            return mapped.isEmpty ? selector : .fixtures(mapped)
        case .union(let items):
            return .union(items.map { remapSelector($0, sourceToTargets: sourceToTargets) })
        case .intersection(let items):
            return .intersection(items.map { remapSelector($0, sourceToTargets: sourceToTargets) })
        case .excluding(let a, let b):
            return .excluding(
                remapSelector(a, sourceToTargets: sourceToTargets),
                remapSelector(b, sourceToTargets: sourceToTargets)
            )
        default:
            return selector
        }
    }

    /// Imports a `SharedLook` into `project`, remapping fixture states by role, label, and name.
    @discardableResult
    public static func importLook(
        _ shared: SharedLook,
        into project: inout Project,
        overwriteExistingByName: Bool = false
    ) -> Look {
        let targetToSource = matchTargetFixturesToSource(
            sourceFixtures: shared.fixtures,
            targetFixtures: project.fixtures
        )
        var sourceToTargets: [UUID: [UUID]] = [:]
        for (targetID, sourceID) in targetToSource {
            sourceToTargets[sourceID, default: []].append(targetID)
        }

        var remappedStates = FixtureStateMap()
        if shared.fixtures.isEmpty {
            let validIDs = Set(project.fixtures.map(\.id))
            for (id, state) in shared.look.states where validIDs.contains(id) {
                remappedStates[id] = state
            }
        } else {
            for (targetID, sourceID) in targetToSource {
                if let state = shared.look.states[sourceID] {
                    remappedStates[targetID] = state
                }
            }
        }

        var remappedDelays: [UUID: Double] = [:]
        for (targetID, sourceID) in targetToSource {
            if let delay = shared.look.fixtureDelays[sourceID] {
                remappedDelays[targetID] = delay
            }
        }

        var imported = shared.look
        imported.states = remappedStates
        imported.fixtureDelays = remappedDelays
        imported.effects = shared.look.effects.map { eff in
            var copy = eff
            copy.targets = remapSelector(eff.targets, sourceToTargets: sourceToTargets)
            return copy
        }
        imported.folderID = nil
        imported.modifiedAt = Date()
        let trimmedName = imported.name.trimmingCharacters(in: .whitespacesAndNewlines)
        imported.name = trimmedName.isEmpty ? "Imported Look" : String(trimmedName.prefix(200))

        if overwriteExistingByName,
           let idx = project.looks.firstIndex(where: { $0.name.caseInsensitiveCompare(imported.name) == .orderedSame }) {
            imported.id = project.looks[idx].id
            imported.sortIndex = project.looks[idx].sortIndex
            imported.folderID = project.looks[idx].folderID
            project.looks[idx] = imported
            return imported
        }

        if project.looks.contains(where: { $0.id == imported.id }) {
            imported.id = UUID()
        }
        let existingNames = Set(project.looks.map { $0.name.lowercased() })
        if existingNames.contains(imported.name.lowercased()) {
            let base = imported.name
            var n = 2
            while existingNames.contains("\(base) \(n)".lowercased()) { n += 1 }
            imported.name = "\(base) \(n)"
        }
        imported.sortIndex = (project.looks.map(\.sortIndex).max() ?? -1) &+ 1
        project.looks.append(imported)
        return imported
    }

    /// Imports/merges looks from `source` project into `target` project, matching fixtures by role,
    /// then label (`shortName`), then `name`.
    @discardableResult
    public static func mergeLooks(
        from source: Project,
        into target: inout Project,
        lookIDs: Set<UUID>? = nil,
        overwriteExistingByName: Bool = false
    ) -> [Look] {
        let hints = source.fixtures.map { SharedFixtureHint(fixture: $0) }
        let looksToImport = source.looks.filter { look in lookIDs.map { $0.contains(look.id) } ?? true }
        var importedLooks: [Look] = []
        importedLooks.reserveCapacity(looksToImport.count)
        for look in looksToImport {
            let shared = SharedLook(look: look, fixtures: hints, definitions: source.definitions)
            let merged = importLook(shared, into: &target, overwriteExistingByName: overwriteExistingByName)
            importedLooks.append(merged)
        }
        return importedLooks
    }
}
