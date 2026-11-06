import Foundation

// MARK: - Lightkey Importer
//
// Reads `.lightkeyproj` files (NSKeyedArchiver binary plists, or package directories containing
// one) using a portable object-graph decoder built on `PropertyListSerialization`.
// Never uses `NSKeyedUnarchiver` class mapping, so it runs identically on macOS and Linux.

public enum LightkeyImportError: Error, LocalizedError, Sendable {
    case unreadableFile(String)
    case invalidPropertyList(String)
    case notKeyedArchive(String)
    case fileTooLarge

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let msg):
            return "Couldn't read the Lightkey project file. \(msg)"
        case .invalidPropertyList(let msg):
            return "This file isn't a valid Lightkey archive. \(msg)"
        case .notKeyedArchive(let msg):
            return "This file doesn't look like a Lightkey project. \(msg)"
        case .fileTooLarge:
            return "The Lightkey project file is too large to import safely."
        }
    }
}

/// Summary and output of importing a Lightkey project into Prism.
public struct LightkeyImportResult: Sendable, Hashable {
    public var project: Project
    /// Plain-English notes and warnings for the user (e.g. synthesized profiles, skipped effects).
    public var warnings: [String]
    /// Specific items (profiles, capabilities, effects) that had no direct library equivalent.
    public var unmappedItems: [String]
    /// IDs of fixture definitions generated from embedded Lightkey personalities.
    public var synthesizedProfiles: [String]

    public init(project: Project, warnings: [String] = [], unmappedItems: [String] = [],
                synthesizedProfiles: [String] = []) {
        self.project = project
        self.warnings = warnings
        self.unmappedItems = unmappedItems
        self.synthesizedProfiles = synthesizedProfiles
    }

    public var importedFixtureCount: Int { project.fixtures.count }
    public var importedLookCount: Int { project.looks.count }
    public var importedFolderCount: Int { project.folders.count }

    /// Concise plain-English summary line for UI banners and toasts.
    public var summaryText: String {
        var parts: [String] = [
            "\(importedFixtureCount) light\(importedFixtureCount == 1 ? "" : "s")",
            "\(importedLookCount) look\(importedLookCount == 1 ? "" : "s")",
        ]
        if importedFolderCount > 0 {
            parts.append("\(importedFolderCount) folder\(importedFolderCount == 1 ? "" : "s")")
        }
        var text = "Imported " + parts.joined(separator: ", ") + "."
        if !synthesizedProfiles.isEmpty {
            text += " \(synthesizedProfiles.count) profile\(synthesizedProfiles.count == 1 ? " was" : "s were") auto-generated."
        }
        if !unmappedItems.isEmpty {
            text += " \(unmappedItems.count) item\(unmappedItems.count == 1 ? "" : "s") needed attention."
        }
        return text
    }
}

/// Portable NSKeyedArchiver object-graph resolver using `PropertyListSerialization`.
public struct KeyedArchiveGraph: @unchecked Sendable {
    public let objects: [Any]
    public let top: [String: Any]
    public let archiver: String
    public let version: Int

    /// Reference into `$objects`. Index 0 is always `$null`.
    public struct UIDRef: Hashable, Sendable {
        public let index: Int
        public init(_ index: Int) { self.index = index }
        public var isNull: Bool { index <= 0 }
    }

    public init(data: Data) throws {
        guard data.count <= 100_000_000 else { throw LightkeyImportError.fileTooLarge }
        guard !data.isEmpty else { throw LightkeyImportError.invalidPropertyList("The file is empty.") }

        let rawPlist: Any
        do {
            rawPlist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw LightkeyImportError.invalidPropertyList("PropertyList decode failed: \(error.localizedDescription)")
        }

        guard let dict = rawPlist as? [String: Any] else {
            throw LightkeyImportError.notKeyedArchive("Root plist is not a dictionary.")
        }
        guard let objs = dict["$objects"] as? [Any], !objs.isEmpty else {
            throw LightkeyImportError.notKeyedArchive("Missing or empty $objects table.")
        }
        guard let topDict = dict["$top"] as? [String: Any] else {
            throw LightkeyImportError.notKeyedArchive("Missing $top dictionary.")
        }

        self.objects = objs
        self.top = topDict
        self.archiver = (dict["$archiver"] as? String) ?? "NSKeyedArchiver"
        self.version = (dict["$version"] as? Int) ?? 100_000
    }

    /// Extracts a UID index from a plist value:
    /// - `["CF$UID": Int]` or `["$uid": Int]` (portable dictionary encoding)
    /// - `_CFKeyedArchiverUID` / `CFKeyedArchiverUID` (native Foundation UID token; description has `{value = N}`)
    public static func extractUID(_ value: Any?) -> UIDRef? {
        guard let value else { return nil }
        if let dict = value as? [String: Any] {
            if dict.count == 1 {
                if let idx = Self.intValue(dict["CF$UID"]) ?? Self.intValue(dict["$uid"]) {
                    return UIDRef(idx)
                }
            }
            return nil
        }
        if let nsDict = value as? NSDictionary, nsDict.count == 1 {
            if let idx = Self.intValue(nsDict["CF$UID"]) ?? Self.intValue(nsDict["$uid"]) {
                return UIDRef(idx)
            }
            return nil
        }
        // Check native _CFKeyedArchiverUID description: "<CFKeyedArchiverUID ...>{value = 42}"
        let typeName = String(describing: type(of: value))
        if typeName.contains("KeyedArchiverUID") || typeName.contains("NSCFType") {
            let desc = String(describing: value)
            if let range = desc.range(of: "value = ") {
                let tail = desc[range.upperBound...]
                let digits = tail.prefix { $0.isNumber }
                if let idx = Int(digits) {
                    return UIDRef(idx)
                }
            }
        }
        return nil
    }

    public static func intValue(_ any: Any?) -> Int? {
        guard let any else { return nil }
        if let i = any as? Int { return i }
        if let i64 = any as? Int64 { return Int(clamping: i64) }
        if let u64 = any as? UInt64 { return Int(clamping: u64) }
        if let num = any as? NSNumber { return num.intValue }
        return nil
    }

    public static func int64Value(_ any: Any?) -> Int64? {
        guard let any else { return nil }
        if let i64 = any as? Int64 { return i64 }
        if let u64 = any as? UInt64 { return Int64(bitPattern: u64) }
        if let i = any as? Int { return Int64(i) }
        if let num = any as? NSNumber { return num.int64Value }
        return nil
    }

    public static func doubleValue(_ any: Any?) -> Double? {
        guard let any else { return nil }
        if let d = any as? Double { return d }
        if let f = any as? Float { return Double(f) }
        if let i = any as? Int { return Double(i) }
        if let num = any as? NSNumber { return num.doubleValue }
        return nil
    }

    public static func boolValue(_ any: Any?) -> Bool? {
        guard let any else { return nil }
        if let b = any as? Bool { return b }
        if let i = any as? Int { return i != 0 }
        if let num = any as? NSNumber { return num.boolValue }
        return nil
    }

    /// Dereferences a UID or returns the value directly if it's already inline.
    /// Bounds-checked; returns nil for `$null` (index 0) or out-of-range indices.
    public func deref(_ value: Any?) -> Any? {
        guard let value else { return nil }
        if let uid = Self.extractUID(value) {
            return object(at: uid.index)
        }
        if let s = value as? String, s == "$null" {
            return nil
        }
        return value
    }

    public func object(at index: Int) -> Any? {
        guard index > 0, index < objects.count else { return nil }
        let obj = objects[index]
        if let s = obj as? String, s == "$null" { return nil }
        return obj
    }

    /// Returns the class name (`$classname`) of an archived object dictionary.
    public func className(of obj: Any?) -> String? {
        guard let dict = deref(obj) as? [String: Any],
              let classObj = deref(dict["$class"]) as? [String: Any] else { return nil }
        return classObj["$classname"] as? String
    }

    /// Returns the class hierarchy (`$classes`) of an archived object dictionary.
    public func classChain(of obj: Any?) -> [String] {
        guard let dict = deref(obj) as? [String: Any],
              let classObj = deref(dict["$class"]) as? [String: Any],
              let classes = classObj["$classes"] as? [String] else { return [] }
        return classes
    }

    /// Resolves a string from either a raw plist string or an `NSString`/`NSMutableString`/`NSTextStorage` dict.
    public func string(_ value: Any?, depth: Int = 0) -> String? {
        guard depth < 8, let resolved = deref(value) else { return nil }
        if let s = resolved as? String {
            return s == "$null" ? nil : s
        }
        if let dict = resolved as? [String: Any] {
            if let nsStr = dict["NS.string"] as? String {
                return nsStr
            }
            if let inner = dict["NSString"] {
                return string(inner, depth: depth + 1)
            }
            if let contents = dict["contents"] {
                return string(contents, depth: depth + 1)
            }
        }
        return nil
    }

    /// Resolves a `Data` blob from either a raw plist `Data` or an `NSData`/`NSMutableData` dict.
    public func data(_ value: Any?) -> Data? {
        guard let resolved = deref(value) else { return nil }
        if let d = resolved as? Data { return d }
        if let dict = resolved as? [String: Any] {
            if let d = dict["NS.data"] as? Data { return d }
            if let d = deref(dict["NS.bytes"]) as? Data { return d }
        }
        return nil
    }

    /// Resolves an `NSUUID` (16-byte `NS.uuidbytes`) or UUID string into a `UUID`.
    public func uuid(_ value: Any?) -> UUID? {
        guard let resolved = deref(value) else { return nil }
        if let s = resolved as? String {
            return UUID(uuidString: s)
        }
        if let dict = resolved as? [String: Any] {
            if let bytes = dict["NS.uuidbytes"] as? Data, bytes.count == 16 {
                var u: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                withUnsafeMutableBytes(of: &u) { ptr in
                    _ = bytes.copyBytes(to: ptr)
                }
                return UUID(uuid: u)
            }
            if let s = dict["NS.string"] as? String {
                return UUID(uuidString: s)
            }
        }
        return nil
    }

    /// Resolves an `NSArray` / `NSMutableArray` / `NSSet` / `NSMutableSet` or inline array into `[Any]` of dereferenced elements.
    public func array(_ value: Any?) -> [Any] {
        guard let resolved = deref(value) else { return [] }
        if let arr = resolved as? [Any] {
            return arr.compactMap { deref($0) }
        }
        if let dict = resolved as? [String: Any] {
            if let nsObjs = dict["NS.objects"] as? [Any] {
                return nsObjs.compactMap { deref($0) }
            }
        }
        return []
    }

    /// Resolves an `NSArray` / `NSSet` keeping raw UID indices alongside dereferenced objects.
    public func indexedArray(_ value: Any?) -> [(uid: Int?, object: Any)] {
        guard let resolved = deref(value) else { return [] }
        let rawList: [Any]
        if let arr = resolved as? [Any] {
            rawList = arr
        } else if let dict = resolved as? [String: Any], let nsObjs = dict["NS.objects"] as? [Any] {
            rawList = nsObjs
        } else {
            return []
        }
        var out: [(Int?, Any)] = []
        for item in rawList {
            if let uid = Self.extractUID(item), let obj = object(at: uid.index) {
                out.append((uid.index, obj))
            } else if let obj = deref(item) {
                out.append((nil, obj))
            }
        }
        return out
    }

    /// Resolves an `NSDictionary` / `NSMutableDictionary` into `[String: Any]` with dereferenced keys and values.
    public func dictionary(_ value: Any?) -> [String: Any] {
        guard let resolved = deref(value) else { return [:] }
        if let dict = resolved as? [String: Any] {
            if let keys = dict["NS.keys"] as? [Any], let vals = dict["NS.objects"] as? [Any] {
                var result: [String: Any] = [:]
                let count = min(keys.count, vals.count)
                for i in 0..<count {
                    guard let k = string(keys[i]), let v = deref(vals[i]) else { continue }
                    result[k] = v
                }
                return result
            }
            // Plain dictionary if not an NSKeyedArchiver class wrapper
            if dict["$class"] == nil {
                var result: [String: Any] = [:]
                for (k, v) in dict {
                    if let dv = deref(v) { result[k] = dv }
                }
                return result
            }
        }
        return [:]
    }

    /// Finds all object dictionaries in `$objects` whose class name or class chain matches `className`.
    public func allInstances(of className: String) -> [(uid: Int, dict: [String: Any])] {
        var result: [(Int, [String: Any])] = []
        for i in 1..<objects.count {
            guard let dict = objects[i] as? [String: Any] else { continue }
            if self.className(of: dict) == className || self.classChain(of: dict).contains(className) {
                result.append((i, dict))
            }
        }
        return result
    }
}

// MARK: - Importer Implementation

public enum LightkeyImporter {

    /// Imports a `.lightkeyproj` file or package directory from disk.
    public static func importProject(
        at url: URL,
        library: ((String) -> FixtureDefinition?)? = nil
    ) throws -> LightkeyImportResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw LightkeyImportError.unreadableFile("File not found at \(url.lastPathComponent).")
        }

        let projectName = url.deletingPathExtension().lastPathComponent
        if isDir.boolValue {
            let archiveURL = try findArchiveInPackage(at: url)
            let data: Data
            do {
                data = try Data(contentsOf: archiveURL)
            } catch {
                throw LightkeyImportError.unreadableFile(error.localizedDescription)
            }
            return try importProject(from: data, projectName: projectName, library: library)
        } else {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw LightkeyImportError.unreadableFile(error.localizedDescription)
            }
            return try importProject(from: data, projectName: projectName, library: library)
        }
    }

    /// Locates the keyed-archive plist inside a `.lightkeyproj` package directory.
    private static func findArchiveInPackage(at directoryURL: URL) throws -> URL {
        let fm = FileManager.default
        let candidates = [
            "Project.lightkeyproj",
            "document.archive",
            "project.archive",
            "Contents/Resources/Project.lightkeyproj",
            "Contents/Resources/document.archive",
        ]
        for relative in candidates {
            let u = directoryURL.appendingPathComponent(relative)
            if fm.fileExists(atPath: u.path) { return u }
        }
        if let enumerator = fm.enumerator(at: directoryURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                if ["lightkeyproj", "archive", "plist", "bplist"].contains(ext) {
                    return fileURL
                }
                if let head = try? FileHandle(forReadingFrom: fileURL).read(upToCount: 8),
                   head == Data("bplist00".utf8) {
                    return fileURL
                }
            }
        }
        throw LightkeyImportError.unreadableFile("No Lightkey archive found inside package \(directoryURL.lastPathComponent).")
    }

    /// Decodes a `.lightkeyproj` binary/XML keyed archive `Data` into a Prism `Project` and report.
    public static func importProject(
        from data: Data,
        projectName: String = "Imported Lightkey Show",
        library: ((String) -> FixtureDefinition?)? = nil
    ) throws -> LightkeyImportResult {
        let graph = try KeyedArchiveGraph(data: data)

        var warnings: [String] = []
        var unmappedItems: [String] = []
        var synthesizedProfileIDs: [String] = []
        var embeddedDefinitions: [String: FixtureDefinition] = [:]

        // 1. Extract embedded `LXFixtureProfile` records
        let parsedProfiles = extractProfiles(from: graph)

        // 2. Extract universes (`LXDMXUniverse`) and their 1-based numbers
        let universeMap = extractUniverses(from: graph)

        // 3. Extract stage canvas geometry (`LXStage`, `LXFixtureCanvasItem`, etc.)
        let stagePositions = extractStagePositions(from: graph)

        // 4. Extract fixtures (`LXDMXFixture`)
        let rawFixtures = extractRawFixtures(from: graph, universeMap: universeMap)

        // Determine stage bounds and coordinate conversion
        var stage = StageSettings(
            width: 5.2,
            height: 9.2,
            props: [StageProp(kind: .person, label: "Subject", transform: StageTransform(x: 2.55, y: 6.5))]
        )
        let mappedTransforms = mapStageTransforms(
            fixtures: rawFixtures,
            stagePositions: stagePositions,
            stage: &stage
        )

        var patchedFixtures: [PatchedFixture] = []
        var fixtureByUUID: [UUID: PatchedFixture] = [:]
        var resolvedModesByFixtureID: [UUID: FixtureMode] = [:]

        for (idx, raw) in rawFixtures.enumerated() {
            let resolvedProfile = resolveFixtureProfileAndMode(
                raw: raw,
                parsedProfiles: parsedProfiles,
                library: library,
                embeddedDefinitions: &embeddedDefinitions,
                synthesizedProfileIDs: &synthesizedProfileIDs,
                warnings: &warnings,
                unmappedItems: &unmappedItems
            )

            let transform = mappedTransforms[raw.uuid] ?? defaultTransform(index: idx, total: max(rawFixtures.count, 1), stage: stage)
            let role = inferRole(name: raw.name, shortName: raw.shortName, category: resolvedProfile.definition.category, transform: transform, stage: stage)

            let friendlyName: String
            if !raw.name.isEmpty && raw.name != raw.shortName {
                friendlyName = raw.name
            } else if !raw.shortName.isEmpty {
                friendlyName = "\(resolvedProfile.definition.model) \(raw.shortName)"
            } else {
                friendlyName = "\(resolvedProfile.definition.model) \(idx + 1)"
            }

            let patched = PatchedFixture(
                id: raw.uuid,
                name: friendlyName,
                shortName: raw.shortName,
                definitionID: resolvedProfile.definition.id,
                modeName: resolvedProfile.mode.name,
                universe: clamp(raw.universe, 1, 64),
                address: (1...512).contains(raw.address) ? raw.address : nil,
                role: role,
                transform: transform,
                notes: raw.comments
            )
            patchedFixtures.append(patched)
            fixtureByUUID[patched.id] = patched
            resolvedModesByFixtureID[patched.id] = resolvedProfile.mode
        }

        // 5. Build helpful default groups (e.g. All Tubes, Background)
        let groups = buildGroups(for: patchedFixtures, definitions: embeddedDefinitions, library: library)

        // 6. Extract Cue timings (so presets referenced by a single cue inherit its fadeInDuration / favorite status)
        let cueMetadata = extractCueMetadata(from: graph)

        // 7. Extract Preset Groups (Folders) and Presets (Looks)
        let (folders, looks) = extractFoldersAndLooks(
            from: graph,
            fixtureByUUID: fixtureByUUID,
            resolvedModesByFixtureID: resolvedModesByFixtureID,
            cueMetadata: cueMetadata,
            warnings: &warnings,
            unmappedItems: &unmappedItems
        )

        let cleanName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        var project = Project(
            name: cleanName.isEmpty ? "Imported Lightkey Show" : cleanName,
            fixtures: patchedFixtures,
            groups: groups,
            looks: looks,
            folders: folders,
            stage: stage,
            definitions: embeddedDefinitions.values.sorted { $0.id < $1.id },
            notes: "Imported from Lightkey."
        )
        if let firstLook = looks.first(where: { !$0.states.isEmpty }) ?? looks.first {
            project.lastLive = LiveSnapshot(base: firstLook.states, activeLookID: firstLook.id)
        }

        let validated = ProjectIO.validate(project)
        for fix in validated.fixes {
            warnings.append(fix)
        }

        return LightkeyImportResult(
            project: validated.project,
            warnings: deduplicatePreservingOrder(warnings),
            unmappedItems: deduplicatePreservingOrder(unmappedItems),
            synthesizedProfiles: deduplicatePreservingOrder(synthesizedProfileIDs)
        )
    }

    // MARK: - Internal Models

    struct ParsedCapability {
        var className: String
        var channel: Int
        var customName: String?
        var colorComponent: String?
        var beamIndexes: [Int]
        var settings: [[String: Any]]
    }

    struct ParsedPersonality {
        var name: String
        var capabilities: [ParsedCapability]
        var explicitChannelCount: Int?

        var channelCount: Int {
            if let explicitChannelCount, explicitChannelCount > 0 { return explicitChannelCount }
            guard let maxCh = capabilities.map(\.channel).max() else { return 1 }
            let minCh = capabilities.map(\.channel).min() ?? 0
            return minCh == 0 ? (maxCh + 1) : maxCh
        }
    }

    struct ParsedProfile {
        var uuid: UUID
        var name: String
        var manufacturer: String
        var personalities: [ParsedPersonality]
    }

    struct RawLightkeyFixture {
        var uidIndex: Int?
        var uuid: UUID
        var name: String
        var shortName: String
        var comments: String
        var address: Int
        var universe: Int
        var profileUUID: UUID?
        var inlineProfile: ParsedProfile?
        var personalityIndex: Int
        var flexWidth: Int
        var flexHeight: Int
        var inlinePosition: (x: Double, y: Double)?
        var inlineRotation: Double?
    }

    struct StagePlacement {
        var x: Double
        var y: Double
        var width: Double?
        var height: Double?
        var rotationDegreesCW: Double
    }

    struct CueMeta {
        var fadeIn: Double
        var activateAtStartup: Bool
    }

    // MARK: - Step 1: Profiles

    private static func extractProfiles(from graph: KeyedArchiveGraph) -> [UUID: ParsedProfile] {
        var result: [UUID: ParsedProfile] = [:]
        var candidates: [[String: Any]] = []

        if let topProfiles = graph.top["fixtureProfiles"] {
            for item in graph.array(topProfiles) {
                if let dict = item as? [String: Any] { candidates.append(dict) }
            }
        }
        for (_, dict) in graph.allInstances(of: "LXFixtureProfile") {
            candidates.append(dict)
        }

        for dict in candidates {
            guard let parsed = parseProfileDict(dict, graph: graph) else { continue }
            result[parsed.uuid] = parsed
        }
        return result
    }

    private static func parseProfileDict(_ dict: [String: Any], graph: KeyedArchiveGraph) -> ParsedProfile? {
        let uuid = graph.uuid(dict["UUID"]) ?? UUID()
        let name = graph.string(dict["name"]) ?? graph.string(dict["model"]) ?? "Unknown Fixture"
        let manufacturer = graph.string(dict["manufacturer"]) ?? "Generic"

        var personalities: [ParsedPersonality] = []
        for persAny in graph.array(dict["personalities"]) {
            guard let pDict = persAny as? [String: Any] else { continue }
            let pName = graph.string(pDict["name"]) ?? graph.string(pDict["customName"]) ?? "Default"
            let explicitCount = KeyedArchiveGraph.intValue(graph.deref(pDict["channelCount"]))
                ?? KeyedArchiveGraph.intValue(graph.deref(pDict["footprint"]))

            var caps: [ParsedCapability] = []
            for (idx, capAny) in graph.array(pDict["capabilities"]).enumerated() {
                guard let cDict = capAny as? [String: Any] else { continue }
                let cls = graph.className(of: cDict) ?? (cDict["$classname"] as? String) ?? "LXCustomCapability"
                let ch = KeyedArchiveGraph.intValue(graph.deref(cDict["channel"])) ?? idx
                let customName = graph.string(cDict["customName"]) ?? graph.string(cDict["name"])
                let colorComp = graph.string(cDict["colorComponent"]) ?? graph.string(cDict["component"])
                let beams = parseBeamIndexes(cDict["beamIndexes"], graph: graph)
                var settings: [[String: Any]] = []
                for sAny in graph.array(cDict["settings"]) {
                    if let sDict = sAny as? [String: Any] { settings.append(sDict) }
                }
                caps.append(ParsedCapability(
                    className: cls,
                    channel: ch,
                    customName: customName,
                    colorComponent: colorComp,
                    beamIndexes: beams,
                    settings: settings
                ))
            }
            personalities.append(ParsedPersonality(
                name: pName,
                capabilities: caps,
                explicitChannelCount: explicitCount
            ))
        }

        return ParsedProfile(uuid: uuid, name: name, manufacturer: manufacturer, personalities: personalities)
    }

    private static func parseBeamIndexes(_ raw: Any?, graph: KeyedArchiveGraph) -> [Int] {
        guard let resolved = graph.deref(raw) else { return [] }
        if let arr = resolved as? [Any] {
            return arr.compactMap { KeyedArchiveGraph.intValue(graph.deref($0)) }
        }
        if let s = graph.string(raw) {
            // e.g. "0-7" or "0,1"
            let parts = s.split(whereSeparator: { $0 == "-" || $0 == "," || $0 == " " })
            if parts.count == 2, s.contains("-"), let lo = Int(parts[0]), let hi = Int(parts[1]), lo <= hi, hi - lo < 512 {
                return Array(lo...hi)
            }
            return parts.compactMap { Int($0) }
        }
        return []
    }

    // MARK: - Step 2: Universes

    private static func extractUniverses(from graph: KeyedArchiveGraph) -> [UUID: Int] {
        var map: [UUID: Int] = [:]
        var nextIndex = 1

        var universeDicts: [[String: Any]] = []
        if let topU = graph.top["universes"] {
            for u in graph.array(topU) {
                if let d = u as? [String: Any] { universeDicts.append(d) }
            }
        }
        for (_, d) in graph.allInstances(of: "LXDMXUniverse") {
            universeDicts.append(d)
        }

        for d in universeDicts {
            guard let uuid = graph.uuid(d["UUID"]) else { continue }
            if map[uuid] != nil { continue }
            if let num = KeyedArchiveGraph.intValue(graph.deref(d["universeNumber"]))
                ?? KeyedArchiveGraph.intValue(graph.deref(d["number"]))
                ?? KeyedArchiveGraph.intValue(graph.deref(d["index"])) {
                // Convert 0-based universe 0 to 1-based universe 1
                map[uuid] = num <= 0 ? (num + 1) : num
            } else {
                map[uuid] = nextIndex
            }
            nextIndex += 1
        }
        return map
    }

    // MARK: - Step 3: Stage Positions & Rotations

    private static func extractStagePositions(from graph: KeyedArchiveGraph) -> [UUID: StagePlacement] {
        var placements: [UUID: StagePlacement] = [:]

        // Collect all stage items from `$top["stages"]` or any `LXStage` / `LXFixtureCanvasItem`
        var candidateItems: [[String: Any]] = []
        if let topStages = graph.top["stages"] {
            for stageObj in graph.array(topStages) {
                if let sDict = stageObj as? [String: Any] {
                    for key in ["items", "fixtures", "fixtureItems", "canvasItems", "childNodes"] {
                        for item in graph.array(sDict[key]) {
                            if let iDict = item as? [String: Any] { candidateItems.append(iDict) }
                        }
                    }
                }
            }
        }
        for (_, sDict) in graph.allInstances(of: "LXStage") {
            for key in ["items", "fixtures", "fixtureItems", "canvasItems", "childNodes"] {
                for item in graph.array(sDict[key]) {
                    if let iDict = item as? [String: Any] { candidateItems.append(iDict) }
                }
            }
        }
        for cls in ["LXFixtureCanvasItem", "LXStageFixtureItem", "LXStageFixture", "LXCanvasItem"] {
            for (_, iDict) in graph.allInstances(of: cls) {
                candidateItems.append(iDict)
            }
        }

        for item in candidateItems {
            let fixUUID = graph.uuid(item["fixtureUUID"])
                ?? (graph.deref(item["fixture"]) as? [String: Any]).flatMap { graph.uuid($0["UUID"]) }
                ?? graph.uuid(item["UUID"])
            guard let uuid = fixUUID else { continue }

            guard let coords = parsePointOrRect(from: item, graph: graph) else { continue }
            let rot = parseRotationCW(from: item, graph: graph)
            placements[uuid] = StagePlacement(
                x: coords.x,
                y: coords.y,
                width: coords.w,
                height: coords.h,
                rotationDegreesCW: rot
            )
        }

        return placements
    }

    private static func parsePointOrRect(
        from dict: [String: Any],
        graph: KeyedArchiveGraph
    ) -> (x: Double, y: Double, w: Double?, h: Double?)? {
        if let centerStr = graph.string(dict["center"]) ?? graph.string(dict["position"]),
           let pt = parsePointString(centerStr) {
            let sz = graph.string(dict["unrotatedSize"]).flatMap(parsePointString)
            return (pt.0, pt.1, sz?.0, sz?.1)
        }
        if let rectStr = graph.string(dict["rect"]) ?? graph.string(dict["frame"]),
           let r = parseRectString(rectStr) {
            return (r.x + r.w / 2.0, r.y + r.h / 2.0, r.w, r.h)
        }
        if let x = KeyedArchiveGraph.doubleValue(graph.deref(dict["x"])),
           let y = KeyedArchiveGraph.doubleValue(graph.deref(dict["y"])) {
            let w = KeyedArchiveGraph.doubleValue(graph.deref(dict["width"]))
            let h = KeyedArchiveGraph.doubleValue(graph.deref(dict["height"]))
            return (x, y, w, h)
        }
        return nil
    }

    private static func parseRotationCW(from dict: [String: Any], graph: KeyedArchiveGraph) -> Double {
        if let degCW = KeyedArchiveGraph.doubleValue(graph.deref(dict["rotation"]))
            ?? KeyedArchiveGraph.doubleValue(graph.deref(dict["rotationDegrees"])) {
            return wrapDegrees(degCW)
        }
        if let angleCCW = KeyedArchiveGraph.doubleValue(graph.deref(dict["angleCCW"]))
            ?? KeyedArchiveGraph.doubleValue(graph.deref(dict["angle"])) {
            // If small (<= 2π) and non-integer, might be radians, otherwise degrees CCW
            let degreesCCW: Double
            if abs(angleCCW) <= .pi * 2.001 && angleCCW.truncatingRemainder(dividingBy: 15.0) != 0 && abs(angleCCW) > 0.01 {
                degreesCCW = angleCCW * 180.0 / .pi
            } else {
                degreesCCW = angleCCW
            }
            return wrapDegrees(-degreesCCW)
        }
        return 0
    }

    /// Parses `"{x, y}"` into `(Double, Double)`.
    public static func parsePointString(_ s: String) -> (Double, Double)? {
        let cleaned = s.replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = cleaned.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]), x.isFinite, y.isFinite else {
            return nil
        }
        return (x, y)
    }

    /// Parses `"{{x, y}, {w, h}}"` into `(x, y, w, h)`.
    public static func parseRectString(_ s: String) -> (x: Double, y: Double, w: Double, h: Double)? {
        let cleaned = s.replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = cleaned.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4,
              let x = Double(parts[0]), let y = Double(parts[1]),
              let w = Double(parts[2]), let h = Double(parts[3]),
              x.isFinite, y.isFinite, w.isFinite, h.isFinite else {
            return nil
        }
        return (x, y, w, h)
    }

    // MARK: - Step 4: Raw Fixtures

    private static func extractRawFixtures(
        from graph: KeyedArchiveGraph,
        universeMap: [UUID: Int]
    ) -> [RawLightkeyFixture] {
        var fixtures: [RawLightkeyFixture] = []
        var seenUUIDs = Set<UUID>()

        var candidates: [(uid: Int?, dict: [String: Any], fallbackUniverse: Int)] = []

        // First walk `$top.universes` -> `fixtures`
        if let topU = graph.top["universes"] {
            for (uIdx, uObj) in graph.array(topU).enumerated() {
                guard let uDict = uObj as? [String: Any] else { continue }
                let uUUID = graph.uuid(uDict["UUID"])
                let uNum = uUUID.flatMap { universeMap[$0] } ?? (uIdx + 1)
                for (fUID, fObj) in graph.indexedArray(uDict["fixtures"]) {
                    if let fDict = fObj as? [String: Any] {
                        candidates.append((fUID, fDict, uNum))
                    }
                }
            }
        }
        if let topF = graph.top["fixtures"] {
            for (fUID, fObj) in graph.indexedArray(topF) {
                if let fDict = fObj as? [String: Any] {
                    candidates.append((fUID, fDict, 1))
                }
            }
        }
        for (uid, fDict) in graph.allInstances(of: "LXDMXFixture") {
            candidates.append((uid, fDict, 1))
        }

        for (uid, dict, fallbackUniverse) in candidates {
            let uuid = graph.uuid(dict["UUID"]) ?? UUID()
            guard !seenUUIDs.contains(uuid) else { continue }
            seenUUIDs.insert(uuid)

            let shortName = graph.string(dict["shortName"]) ?? ""
            let name = graph.string(dict["name"]) ?? graph.string(dict["userName"]) ?? shortName
            let comments = graph.string(dict["comments"]) ?? ""
            let address = KeyedArchiveGraph.intValue(graph.deref(dict["address"])) ?? 1
            let personalityIndex = max(0, KeyedArchiveGraph.intValue(graph.deref(dict["personalityIndex"])) ?? 0)
            let flexWidth = max(1, KeyedArchiveGraph.intValue(graph.deref(dict["flexWidth"])) ?? 1)
            let flexHeight = max(1, KeyedArchiveGraph.intValue(graph.deref(dict["flexHeight"])) ?? 1)

            var universe = fallbackUniverse
            if let uUUID = graph.uuid(dict["universeUUID"]), let mapped = universeMap[uUUID] {
                universe = mapped
            } else if let uDict = graph.deref(dict["universe"]) as? [String: Any] {
                if let uUUID = graph.uuid(uDict["UUID"]), let mapped = universeMap[uUUID] {
                    universe = mapped
                } else if let num = KeyedArchiveGraph.intValue(graph.deref(uDict["universeNumber"]))
                    ?? KeyedArchiveGraph.intValue(graph.deref(uDict["number"])) {
                    universe = num <= 0 ? (num + 1) : num
                }
            } else if let num = KeyedArchiveGraph.intValue(graph.deref(dict["universeNumber"])) {
                universe = num <= 0 ? (num + 1) : num
            }

            let profileUUID = graph.uuid(dict["fixtureProfileUUID"])
                ?? (graph.deref(dict["fixtureProfile"]) as? [String: Any]).flatMap { graph.uuid($0["UUID"]) }
            let inlineProfile = (graph.deref(dict["fixtureProfile"]) as? [String: Any]).flatMap {
                parseProfileDict($0, graph: graph)
            }

            let inlinePoint = parsePointOrRect(from: dict, graph: graph).map { (x: $0.x, y: $0.y) }
            let inlineRot: Double?
            if dict["rotation"] != nil || dict["angleCCW"] != nil || dict["angle"] != nil || dict["rotationDegrees"] != nil {
                inlineRot = parseRotationCW(from: dict, graph: graph)
            } else {
                inlineRot = nil
            }

            fixtures.append(RawLightkeyFixture(
                uidIndex: uid,
                uuid: uuid,
                name: name,
                shortName: shortName,
                comments: comments,
                address: address,
                universe: universe,
                profileUUID: profileUUID,
                inlineProfile: inlineProfile,
                personalityIndex: personalityIndex,
                flexWidth: flexWidth,
                flexHeight: flexHeight,
                inlinePosition: inlinePoint,
                inlineRotation: inlineRot
            ))
        }

        return fixtures
    }

    private static func mapStageTransforms(
        fixtures: [RawLightkeyFixture],
        stagePositions: [UUID: StagePlacement],
        stage: inout StageSettings
    ) -> [UUID: StageTransform] {
        var rawPoints: [UUID: (x: Double, y: Double, rot: Double)] = [:]
        for f in fixtures {
            if let sp = stagePositions[f.uuid] {
                rawPoints[f.uuid] = (sp.x, sp.y, sp.rotationDegreesCW)
            } else if let pt = f.inlinePosition {
                rawPoints[f.uuid] = (pt.x, pt.y, f.inlineRotation ?? 0)
            }
        }
        guard !rawPoints.isEmpty else { return [:] }

        let xs = rawPoints.values.map(\.x)
        let ys = rawPoints.values.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return [:] }

        // If coordinates are already in studio meters (0...15), preserve them directly.
        if minX >= 0 && maxX <= 15 && minY >= 0 && maxY <= 15 {
            stage.width = max(stage.width, ceil(maxX + 1.0))
            stage.height = max(stage.height, ceil(maxY + 1.0))
            var out: [UUID: StageTransform] = [:]
            for (id, p) in rawPoints {
                let depth = clamp01(1.0 - (p.y / max(stage.height, 1)))
                out[id] = StageTransform(x: p.x, y: p.y, rotation: p.rot, scale: 1, depth: depth).sanitized
            }
            return out
        }

        // Otherwise map Lightkey canvas pixel coordinates into stage meter coordinates with a clean margin.
        let spanX = max(maxX - minX, 100.0)
        let spanY = max(maxY - minY, 100.0)
        let aspect = clamp(spanX / spanY, 0.45, 2.2)
        if aspect < 0.85 {
            stage.width = 5.2
            stage.height = 9.2
        } else {
            stage.width = 10.0
            stage.height = 6.0
        }

        let marginX = stage.width * 0.14
        let marginY = stage.height * 0.14
        let usableW = max(stage.width - 2 * marginX, 1.0)
        let usableH = max(stage.height - 2 * marginY, 1.0)

        var out: [UUID: StageTransform] = [:]
        for (id, p) in rawPoints {
            let nx = rawPoints.count == 1 ? 0.5 : clamp01((p.x - minX) / spanX)
            let ny = rawPoints.count == 1 ? 0.4 : clamp01((p.y - minY) / spanY)
            let mx = marginX + nx * usableW
            let my = marginY + ny * usableH
            let depth = clamp01(1.0 - (my / max(stage.height, 1)))
            out[id] = StageTransform(x: mx, y: my, rotation: p.rot, scale: 1, depth: depth).sanitized
        }
        return out
    }

    private static func defaultTransform(index: Int, total: Int, stage: StageSettings) -> StageTransform {
        let frac = Double(index + 1) / Double(total + 1)
        return StageTransform(x: stage.width * frac, y: stage.height * 0.3, rotation: 0, scale: 1, depth: 0.7)
    }

    private static func inferRole(
        name: String,
        shortName: String,
        category: FixtureCategory,
        transform: StageTransform,
        stage: StageSettings
    ) -> FixtureRole {
        let combined = "\(name) \(shortName)".lowercased()
        if combined.contains("key") || shortName.uppercased().hasPrefix("PN") { return .key }
        if combined.contains("fill") { return .fill }
        if combined.contains("hair") { return .hair }
        if combined.contains("rim") || combined.contains("back") { return .back }
        if combined.contains("floor") || combined.contains("accent") { return .accent }
        if combined.contains("round") || combined.contains("practical") || shortName.uppercased() == "P1" {
            return .practical
        }
        if category == .panel { return .key }
        if category == .dimmer { return .practical }
        if category == .tube {
            return transform.y > stage.height * 0.72 ? .accent : .background
        }
        return .other
    }

    // MARK: - Step 4b: Profile Mapping & Synthesis

    private static func resolveFixtureProfileAndMode(
        raw: RawLightkeyFixture,
        parsedProfiles: [UUID: ParsedProfile],
        library: ((String) -> FixtureDefinition?)?,
        embeddedDefinitions: inout [String: FixtureDefinition],
        synthesizedProfileIDs: inout [String],
        warnings: inout [String],
        unmappedItems: inout [String]
    ) -> (definition: FixtureDefinition, mode: FixtureMode) {
        let profile = raw.profileUUID.flatMap { parsedProfiles[$0] } ?? raw.inlineProfile

        guard let profile else {
            let fallback = BuiltinImportDefinitions.genericDimmer
            embeddedDefinitions[fallback.id] = fallback
            let label = raw.shortName.isEmpty ? raw.name : raw.shortName
            let msg = "\(label): missing fixture profile in Lightkey archive; mapped to Generic Dimmer (1 ch)."
            warnings.append(msg)
            unmappedItems.append(msg)
            return (fallback, fallback.modes[0])
        }

        let personality: ParsedPersonality
        if raw.personalityIndex >= 0 && raw.personalityIndex < profile.personalities.count {
            personality = profile.personalities[raw.personalityIndex]
        } else if let first = profile.personalities.first {
            personality = first
            warnings.append("\(raw.name): personality index \(raw.personalityIndex) out of range; used '\(first.name)'.")
        } else {
            personality = ParsedPersonality(name: "Default", capabilities: [], explicitChannelCount: 1)
        }

        let normMfg = profile.manufacturer.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normModel = profile.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let chCount = max(1, personality.channelCount * max(1, raw.flexWidth * raw.flexHeight > 1 && personality.channelCount <= 4 ? raw.flexWidth * raw.flexHeight : 1))

        // 1. Check for Aputure / amaran PT pixel tube family (exact channel-count mapping per brief)
        if (normMfg.contains("aputure") || normMfg.contains("amaran") || normModel.contains("amaran"))
            && (normModel.contains("pt") || normModel.contains("pixel tube")) {
            let def = library?("amaran.pt4c") ?? BuiltinImportDefinitions.amaranPT4c
            embeddedDefinitions[def.id] = def
            if let mode = matchAmaranPTMode(in: def, personalityName: personality.name, channelCount: chCount) {
                return (def, mode)
            }
        }

        // 2. Check candidate IDs in library lookup
        let candidateIDs = [
            FixtureDefinition.makeID(manufacturer: profile.manufacturer, model: profile.name),
            "amaran.\(profile.name.lowercased().replacingOccurrences(of: "amaran ", with: "").replacingOccurrences(of: " ", with: "-"))",
            "aputure.\(profile.name.lowercased().replacingOccurrences(of: "aputure ", with: "").replacingOccurrences(of: " ", with: "-"))",
        ]
        for candID in candidateIDs {
            if let libDef = library?(candID) ?? embeddedDefinitions[candID] {
                if let matchedMode = matchMode(in: libDef, personalityName: personality.name, channelCount: chCount) {
                    embeddedDefinitions[libDef.id] = libDef
                    return (libDef, matchedMode)
                }
            }
        }

        // 3. Check standard generic profiles if manufacturer is Generic or matches standard footprints
        if normMfg == "generic" || normModel.contains("generic") || normModel == "dimmer" {
            if chCount == 1, let dimmer = library?("generic.dimmer") ?? Optional(BuiltinImportDefinitions.genericDimmer),
               let m = dimmer.modes.first {
                embeddedDefinitions[dimmer.id] = dimmer
                return (dimmer, m)
            }
        }

        // 4. Synthesize a FixtureDefinition from the embedded Lightkey personality capabilities
        let synthesized = synthesizeDefinition(from: profile, personality: personality, effectiveChannelCount: chCount)
        if var existing = embeddedDefinitions[synthesized.id] {
            if existing.mode(named: synthesized.modes[0].name) == nil {
                existing.modes.append(synthesized.modes[0])
                embeddedDefinitions[existing.id] = existing
            }
            let mode = existing.mode(named: synthesized.modes[0].name) ?? synthesized.modes[0]
            return (existing, mode)
        } else {
            embeddedDefinitions[synthesized.id] = synthesized
            synthesizedProfileIDs.append(synthesized.id)
            let msg = "Synthesized profile for \(profile.manufacturer) \(profile.name) (\(personality.name), \(chCount) ch) — please verify channel layout."
            warnings.append(msg)
            unmappedItems.append("\(profile.manufacturer) \(profile.name) · \(personality.name)")
            return (synthesized, synthesized.modes[0])
        }
    }

    private static func matchAmaranPTMode(
        in def: FixtureDefinition,
        personalityName: String,
        channelCount: Int
    ) -> FixtureMode? {
        if let exact = def.mode(named: personalityName), exact.channelCount == channelCount {
            return exact
        }
        // Match by channel count per `docs/research/aputure_profiles.md` §2.6
        let candidates = def.modes.filter { $0.channelCount == channelCount }
        if candidates.count == 1 { return candidates[0] }
        if candidates.count > 1 {
            let lower = personalityName.lowercased()
            if lower.contains("fx") {
                return candidates.first { $0.name.lowercased().contains("fx") } ?? candidates[0]
            }
            if lower.contains("hsi") {
                return candidates.first { $0.name.lowercased().contains("hsi") } ?? candidates[0]
            }
            return candidates[0]
        }
        return def.mode(named: personalityName) ?? def.recommendedMode
    }

    private static func matchMode(
        in def: FixtureDefinition,
        personalityName: String,
        channelCount: Int
    ) -> FixtureMode? {
        if let byName = def.mode(named: personalityName), byName.channelCount == channelCount {
            return byName
        }
        if let byCount = def.modes.first(where: { $0.channelCount == channelCount }) {
            return byCount
        }
        return def.mode(named: personalityName)
    }

    private static func synthesizeDefinition(
        from profile: ParsedProfile,
        personality: ParsedPersonality,
        effectiveChannelCount: Int
    ) -> FixtureDefinition {
        let sortedCaps = personality.capabilities.sorted { $0.channel < $1.channel }
        let minCh = sortedCaps.map(\.channel).min() ?? 0
        let baseOffset = minCh == 1 ? 1 : 0
        let totalChannels = max(effectiveChannelCount, personality.channelCount, 1)

        var channels = (0..<totalChannels).map { idx in
            ChannelDefinition(kind: .generic, label: "Channel \(idx + 1)")
        }

        // Track emitter sequence per cell to assign R/G/B/W when colorComponent isn't explicit
        var emitterCursorByCell: [Int: Int] = [:]
        let emitterSequence: [ChannelKind] = [.red, .green, .blue, .white, .warmWhite, .coolWhite, .amber, .uv]

        // Detect pixel grouping either from beamIndexes or from repeated capability patterns
        let distinctBeamGroups = Set(sortedCaps.map { $0.beamIndexes }).filter { !$0.isEmpty }
        let sortedBeamStarts = distinctBeamGroups.compactMap { $0.min() }.sorted()

        for cap in sortedCaps {
            let chIdx = clamp(cap.channel - baseOffset, 0, totalChannels - 1)
            let cellIndex: Int?
            if let beamStart = cap.beamIndexes.min(), let groupIdx = sortedBeamStarts.firstIndex(of: beamStart), sortedBeamStarts.count > 1 {
                cellIndex = groupIdx
            } else {
                cellIndex = nil
            }

            let cls = cap.className
            if cls.contains("IntensityFine") {
                channels[chIdx] = ChannelDefinition(kind: .intensity, fine: true, cell: cellIndex, label: cap.customName)
            } else if cls.contains("Intensity") {
                channels[chIdx] = ChannelDefinition(kind: .intensity, cell: cellIndex, label: cap.customName)
            } else if cls.contains("ColorComponent") {
                let kind = resolveColorComponentKind(cap: cap, cellKey: cellIndex ?? -1, cursor: &emitterCursorByCell, sequence: emitterSequence)
                channels[chIdx] = ChannelDefinition(kind: kind, cell: cellIndex, label: cap.customName)
            } else if cls.contains("ColorFilter") || cls.contains("CCT") {
                channels[chIdx] = ChannelDefinition(kind: .cct, cell: cellIndex, label: cap.customName ?? "CCT", physical: PhysicalRange(from: 2700, to: 10000))
            } else if cls.contains("GreenSaturation") || cls.contains("Tint") {
                channels[chIdx] = ChannelDefinition(kind: .tint, cell: cellIndex, label: cap.customName ?? "G/M Tint", defaultValue: 128, physical: PhysicalRange(from: -1, to: 1))
            } else if cls.contains("XfadeToColor") || cls.contains("Crossfade") {
                channels[chIdx] = ChannelDefinition(kind: .crossfade, cell: cellIndex, label: cap.customName ?? "Crossfade", physical: PhysicalRange(from: 0, to: 1))
            } else if cls.contains("ShutterStrobe") || cls.contains("Strobe") {
                channels[chIdx] = ChannelDefinition(
                    kind: .strobe,
                    cell: cellIndex,
                    label: cap.customName ?? "Strobe",
                    capabilities: [
                        ChannelCapability(from: 0, to: 19, label: "Open", tag: "off"),
                        ChannelCapability(from: 20, to: 255, label: "Strobe", tag: "strobe", physical: [1, 25]),
                    ]
                )
            } else if cls.contains("PanFine") {
                channels[chIdx] = ChannelDefinition(kind: .pan, fine: true, cell: cellIndex)
            } else if cls.contains("PanTiltSpeed") {
                channels[chIdx] = ChannelDefinition(kind: .generic, cell: cellIndex, label: "Pan/Tilt Speed")
            } else if cls.contains("Pan") {
                channels[chIdx] = ChannelDefinition(kind: .pan, cell: cellIndex)
            } else if cls.contains("TiltFine") {
                channels[chIdx] = ChannelDefinition(kind: .tilt, fine: true, cell: cellIndex)
            } else if cls.contains("Tilt") {
                channels[chIdx] = ChannelDefinition(kind: .tilt, cell: cellIndex)
            } else if cls.contains("Zoom") {
                channels[chIdx] = ChannelDefinition(kind: .zoom, cell: cellIndex)
            } else if cls.contains("Command") || cls.contains("Mode") {
                channels[chIdx] = ChannelDefinition(kind: .control, cell: cellIndex, label: cap.customName ?? "Control")
            } else {
                let kind = inferKindFromName(cap.customName)
                channels[chIdx] = ChannelDefinition(kind: kind, cell: cellIndex, label: cap.customName)
            }
        }

        // If cells weren't assigned via beamIndexes, check if channels form N identical RGB/CCT blocks
        assignRepeatingPixelCellsIfNeeded(&channels)

        let category = inferCategory(manufacturer: profile.manufacturer, model: profile.name, channels: channels)
        let mode = FixtureMode(
            name: personality.name.isEmpty ? "\(totalChannels)ch" : personality.name,
            shortName: "\(totalChannels)ch",
            summary: "Imported from Lightkey (\(totalChannels) ch)",
            recommended: true,
            channels: channels
        )

        let id = "imported.\(FixtureDefinition.makeID(manufacturer: profile.manufacturer, model: profile.name))"
        return FixtureDefinition(
            id: id,
            manufacturer: profile.manufacturer,
            model: profile.name,
            category: category,
            cctRange: mode.capabilities.hasCCT ? [2700, 10000] : nil,
            modes: [mode],
            source: "imported",
            notes: "Synthesized from embedded Lightkey profile."
        )
    }

    private static func resolveColorComponentKind(
        cap: ParsedCapability,
        cellKey: Int,
        cursor: inout [Int: Int],
        sequence: [ChannelKind]
    ) -> ChannelKind {
        let hint = (cap.colorComponent ?? cap.customName ?? "").lowercased()
        if hint.contains("red") || hint == "r" { return .red }
        if hint.contains("green") || hint == "g" { return .green }
        if hint.contains("blue") || hint == "b" { return .blue }
        if hint.contains("warm") || hint == "ww" { return .warmWhite }
        if hint.contains("cool") || hint == "cw" { return .coolWhite }
        if hint.contains("white") || hint == "w" { return .white }
        if hint.contains("amber") || hint == "a" { return .amber }
        if hint.contains("uv") || hint.contains("ultra") { return .uv }
        if hint.contains("cyan") || hint == "c" { return .cyan }
        if hint.contains("magenta") || hint == "m" { return .magenta }
        if hint.contains("yellow") || hint == "y" { return .yellow }
        let idx = cursor[cellKey, default: 0]
        cursor[cellKey] = idx + 1
        return sequence[idx % sequence.count]
    }

    private static func inferKindFromName(_ name: String?) -> ChannelKind {
        guard let n = name?.lowercased() else { return .generic }
        if n.contains("dimmer") || n.contains("intensity") { return .intensity }
        if n == "red" || n.hasPrefix("red ") { return .red }
        if n == "green" || n.hasPrefix("green ") { return .green }
        if n == "blue" || n.hasPrefix("blue ") { return .blue }
        if n.contains("warm white") { return .warmWhite }
        if n.contains("cool white") { return .coolWhite }
        if n.contains("white") { return .white }
        if n.contains("cct") || n.contains("kelvin") { return .cct }
        if n.contains("tint") || n.contains("g/m") { return .tint }
        if n.contains("crossfade") || n.contains("xfade") { return .crossfade }
        if n.contains("hue") { return .hue }
        if n.contains("sat") { return .saturation }
        if n.contains("strobe") { return .strobe }
        if n.contains("fan") { return .fan }
        return .generic
    }

    private static func assignRepeatingPixelCellsIfNeeded(_ channels: inout [ChannelDefinition]) {
        guard channels.allSatisfy({ $0.cell == nil }) else { return }
        let redIndices = channels.indices.filter { channels[$0].kind == .red && !channels[$0].fine }
        guard redIndices.count >= 2 else { return }

        let pixelCount = redIndices.count
        let stride = redIndices[1] - redIndices[0]
        guard stride >= 3 else { return }
        let isUniform = (1..<redIndices.count).allSatisfy { redIndices[$0] - redIndices[$0 - 1] == stride }
        guard isUniform else { return }

        // Determine block start (e.g. if intensity/cct precede red in each pixel block)
        let firstRed = redIndices[0]
        let headerCount = firstRed % stride
        guard headerCount + pixelCount * stride <= channels.count else { return }

        let pattern = (0..<stride).map { channels[headerCount + $0].kind }
        for px in 0..<pixelCount {
            let blockStart = headerCount + px * stride
            let matches = (0..<stride).allSatisfy { channels[blockStart + $0].kind == pattern[$0] }
            if matches {
                for offset in 0..<stride {
                    channels[blockStart + offset].cell = px
                }
            }
        }
    }

    private static func inferCategory(
        manufacturer: String,
        model: String,
        channels: [ChannelDefinition]
    ) -> FixtureCategory {
        let text = "\(manufacturer) \(model)".lowercased()
        if text.contains("tube") || text.contains("pt1c") || text.contains("pt2c") || text.contains("pt4c") || text.contains("amaran pt") || text.contains("t2c") || text.contains("t4c") {
            return .tube
        }
        if text.contains("bar") || text.contains("infinibar") || text.contains("batten") {
            return .bar
        }
        if text.contains("panel") || text.contains("nova") || text.contains("f21") || text.contains("f22") {
            return .panel
        }
        if text.contains("spot") || text.contains("cob") || text.contains("ls ") || text.contains("storm") {
            return .spot
        }
        if channels.contains(where: { $0.kind == .pan || $0.kind == .tilt }) {
            return .movingHead
        }
        if channels.contains(where: { $0.cell != nil }) {
            return .tube
        }
        if channels.count == 1 && channels[0].kind == .intensity {
            return .dimmer
        }
        return .par
    }

    // MARK: - Step 5: Groups

    private static func buildGroups(
        for fixtures: [PatchedFixture],
        definitions: [String: FixtureDefinition],
        library: ((String) -> FixtureDefinition?)?
    ) -> [FixtureGroup] {
        var groups: [FixtureGroup] = []
        let tubes = fixtures.filter { f in
            let cat = (definitions[f.definitionID] ?? library?(f.definitionID))?.category
            return cat == .tube || f.shortName.uppercased().hasPrefix("B")
        }
        if tubes.count >= 2 {
            groups.append(FixtureGroup(name: "All Tubes", fixtureIDs: tubes.map(\.id), colorHex: "#FF4FD8"))
        }
        let backFixtures = fixtures.filter { $0.role == .background }
        if backFixtures.count >= 2 && backFixtures.map(\.id) != tubes.map(\.id) {
            groups.append(FixtureGroup(name: "Background", fixtureIDs: backFixtures.map(\.id), colorHex: "#38BDF8"))
        }
        return groups
    }

    // MARK: - Step 6: Cue Metadata

    private static func extractCueMetadata(from graph: KeyedArchiveGraph) -> [Int: CueMeta] {
        var metaByPresetUID: [Int: CueMeta] = [:]
        for (_, cueDict) in graph.allInstances(of: "LXCue") {
            let fadeIn = KeyedArchiveGraph.doubleValue(graph.deref(cueDict["fadeInDuration"]))
                ?? KeyedArchiveGraph.doubleValue(graph.deref(cueDict["fadeDuration"]))
                ?? 1.0
            let startup = KeyedArchiveGraph.boolValue(graph.deref(cueDict["activateAtStartup"])) ?? false
            for (presetUID, _) in graph.indexedArray(cueDict["presets"]) {
                if let uid = presetUID {
                    metaByPresetUID[uid] = CueMeta(fadeIn: clamp(fadeIn, 0, 60), activateAtStartup: startup)
                }
            }
        }
        return metaByPresetUID
    }

    // MARK: - Step 7: Preset Groups (Folders) & Presets (Looks)

    private static func extractFoldersAndLooks(
        from graph: KeyedArchiveGraph,
        fixtureByUUID: [UUID: PatchedFixture],
        resolvedModesByFixtureID: [UUID: FixtureMode],
        cueMetadata: [Int: CueMeta],
        warnings: inout [String],
        unmappedItems: inout [String]
    ) -> (folders: [LookFolder], looks: [Look]) {
        var folders: [LookFolder] = []
        var looks: [Look] = []
        var visitedUIDs = Set<Int>()

        func walkNode(uid: Int?, obj: Any, parentFolderID: UUID?) {
            if let uid {
                guard !visitedUIDs.contains(uid) else { return }
                visitedUIDs.insert(uid)
            }
            guard let dict = obj as? [String: Any] else { return }
            let cls = graph.className(of: dict) ?? (dict["$classname"] as? String) ?? ""

            if cls == "LXRootPresetGroup" || cls == "LXPresetGroup" {
                let rawName = (graph.string(dict["name"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let isRootOrOrphan = cls == "LXRootPresetGroup"
                    || rawName.isEmpty
                    || rawName == "Cue Orphan Presets Group"
                    || rawName.lowercased() == "root"

                var currentFolderID = parentFolderID
                if !isRootOrOrphan {
                    let folder = LookFolder(
                        id: graph.uuid(dict["UUID"]) ?? UUID(),
                        name: rawName,
                        parentID: parentFolderID,
                        sortIndex: folders.count
                    )
                    folders.append(folder)
                    currentFolderID = folder.id
                }

                for (childUID, childObj) in graph.indexedArray(dict["childNodes"]) {
                    walkNode(uid: childUID, obj: childObj, parentFolderID: currentFolderID)
                }
            } else if cls == "LXPreset" {
                if let look = parsePresetAsLook(
                    uid: uid,
                    dict: dict,
                    folderID: parentFolderID,
                    sortIndex: looks.count,
                    graph: graph,
                    fixtureByUUID: fixtureByUUID,
                    resolvedModesByFixtureID: resolvedModesByFixtureID,
                    cueMetadata: cueMetadata,
                    warnings: &warnings,
                    unmappedItems: &unmappedItems
                ) {
                    looks.append(look)
                }
            } else if cls == "LXSequence" {
                // Sequence: import its first step as a Look and note that sequence steps were flattened
                let seqName = graph.string(dict["name"]) ?? "Sequence"
                let children = graph.indexedArray(dict["childNodes"])
                if let first = children.first,
                   let firstDict = first.object as? [String: Any],
                   var look = parsePresetAsLook(
                       uid: first.uid,
                       dict: firstDict,
                       folderID: parentFolderID,
                       sortIndex: looks.count,
                       graph: graph,
                       fixtureByUUID: fixtureByUUID,
                       resolvedModesByFixtureID: resolvedModesByFixtureID,
                       cueMetadata: cueMetadata,
                       warnings: &warnings,
                       unmappedItems: &unmappedItems
                   ) {
                    look.name = seqName
                    looks.append(look)
                    warnings.append("Sequence '\(seqName)' was imported as a static look from its first step.")
                }
            }
        }

        if let rootRef = graph.top["rootPresetGroup"] {
            let rootUID = KeyedArchiveGraph.extractUID(rootRef)?.index
            if let rootObj = graph.deref(rootRef) {
                walkNode(uid: rootUID, obj: rootObj, parentFolderID: nil)
            }
        }

        // Also capture any standalone `LXPreset` instances not reached via `rootPresetGroup`
        // (excluding sequence step presets that carry a `duration` key)
        for (uid, dict) in graph.allInstances(of: "LXPreset") where !visitedUIDs.contains(uid) {
            if dict["duration"] != nil { continue }
            if let look = parsePresetAsLook(
                uid: uid,
                dict: dict,
                folderID: nil,
                sortIndex: looks.count,
                graph: graph,
                fixtureByUUID: fixtureByUUID,
                resolvedModesByFixtureID: resolvedModesByFixtureID,
                cueMetadata: cueMetadata,
                warnings: &warnings,
                unmappedItems: &unmappedItems
            ) {
                looks.append(look)
            }
        }

        return (folders, looks)
    }

    private static func parsePresetAsLook(
        uid: Int?,
        dict: [String: Any],
        folderID: UUID?,
        sortIndex: Int,
        graph: KeyedArchiveGraph,
        fixtureByUUID: [UUID: PatchedFixture],
        resolvedModesByFixtureID: [UUID: FixtureMode],
        cueMetadata: [Int: CueMeta],
        warnings: inout [String],
        unmappedItems: inout [String]
    ) -> Look? {
        let name = (graph.string(dict["name"]) ?? "Look \(sortIndex + 1)").trimmingCharacters(in: .whitespacesAndNewlines)
        let lookID = graph.uuid(dict["UUID"]) ?? UUID()
        let meta = uid.flatMap { cueMetadata[$0] }

        var stateMap = FixtureStateMap()
        if let fpData = graph.data(dict["fpStore"]) {
            decodeFPStore(
                data: fpData,
                presetName: name,
                fixtureByUUID: fixtureByUUID,
                resolvedModesByFixtureID: resolvedModesByFixtureID,
                into: &stateMap,
                warnings: &warnings,
                unmappedItems: &unmappedItems
            )
        }

        return Look(
            id: lookID,
            name: name.isEmpty ? "Look \(sortIndex + 1)" : name,
            folderID: folderID,
            states: stateMap,
            fadeTime: meta?.fadeIn ?? 1.2,
            isFavorite: meta?.activateAtStartup ?? false,
            sortIndex: sortIndex
        )
    }

    // MARK: - fpStore Inner Binary Plist Decoding

    /// Unpacks a Lightkey 64-bit integer color (`bits 0-15: Blue, 16-31: Green, 32-47: Red, 48-63: Alpha`).
    public static func unpackColor(_ packed: Int64) -> RGB {
        let u = UInt64(bitPattern: packed)
        let b16 = Double(u & 0xFFFF) / 65535.0
        let g16 = Double((u >> 16) & 0xFFFF) / 65535.0
        let r16 = Double((u >> 32) & 0xFFFF) / 65535.0
        return RGB(r: r16, g: g16, b: b16)
    }

    /// Packs an `RGB` into Lightkey's 64-bit integer format (`Blue` in bits 0–15, `Green` 16–31, `Red` 32–47).
    public static func packColor(_ rgb: RGB, alpha: UInt16 = 0) -> Int64 {
        let r16 = UInt64(clamp(Int((rgb.r * 65535.0).rounded()), 0, 65535))
        let g16 = UInt64(clamp(Int((rgb.g * 65535.0).rounded()), 0, 65535))
        let b16 = UInt64(clamp(Int((rgb.b * 65535.0).rounded()), 0, 65535))
        let a16 = UInt64(alpha)
        let packed = (b16 & 0xFFFF) | ((g16 & 0xFFFF) << 16) | ((r16 & 0xFFFF) << 32) | ((a16 & 0xFFFF) << 48)
        return Int64(bitPattern: packed)
    }

    private static func decodeFPStore(
        data: Data,
        presetName: String,
        fixtureByUUID: [UUID: PatchedFixture],
        resolvedModesByFixtureID: [UUID: FixtureMode],
        into stateMap: inout FixtureStateMap,
        warnings: inout [String],
        unmappedItems: inout [String]
    ) {
        guard !data.isEmpty,
              let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let fpDict = raw as? [String: Any] else {
            warnings.append("Look '\(presetName)' had an unreadable fpStore state payload.")
            return
        }

        // Report native Lightkey effects (`effects` array with opaque `parameters` blob)
        if let effects = fpDict["effects"] as? [[String: Any]], !effects.isEmpty {
            let msg = "Look '\(presetName)' uses \(effects.count) built-in Lightkey effect\(effects.count == 1 ? "" : "s") (opaque format); imported base colors and intensities."
            warnings.append(msg)
            unmappedItems.append("Effect in '\(presetName)'")
        }

        // Schema 1 (older): `umbrellaContainers`
        if let umbrella = fpDict["umbrellaContainers"] as? [String: Any] {
            for (uuidStr, containerAny) in umbrella {
                guard let fixUUID = UUID(uuidString: uuidStr),
                      fixtureByUUID[fixUUID] != nil,
                      let container = containerAny as? [String: Any] else { continue }

                let definedFeatures = (container["definedFeatures"] as? [String]) ?? []
                let segments = (container["segmentContainers"] as? [[String: Any]]) ?? []
                if let state = buildFixtureState(
                    fromSegments: segments,
                    definedFeatures: definedFeatures,
                    targetCellCount: resolvedModesByFixtureID[fixUUID]?.cellCount ?? 0
                ) {
                    stateMap[fixUUID] = state
                }
            }
        }

        // Schema 2 (newer): `containers`
        if let containers = fpDict["containers"] as? [String: Any] {
            for (uuidStr, containerAny) in containers {
                guard let fixUUID = UUID(uuidString: uuidStr),
                      fixtureByUUID[fixUUID] != nil,
                      let container = containerAny as? [String: Any] else { continue }

                var segments: [[String: Any]] = []
                if let subs = container["subcontainers"] as? [[String: Any]] {
                    for sub in subs {
                        if let content = sub["content"] as? [String: Any] {
                            segments.append(content)
                        }
                    }
                }
                if segments.isEmpty, let content = container["content"] as? [String: Any], !content.isEmpty {
                    segments.append(content)
                }
                if let state = buildFixtureState(
                    fromSegments: segments,
                    definedFeatures: [],
                    targetCellCount: resolvedModesByFixtureID[fixUUID]?.cellCount ?? 0
                ) {
                    stateMap[fixUUID] = state
                }
            }
        }
    }

    private static func buildFixtureState(
        fromSegments segments: [[String: Any]],
        definedFeatures: [String],
        targetCellCount: Int
    ) -> FixtureState? {
        guard !segments.isEmpty else { return nil }

        let parsedCells: [(intensity: Double, color: LightColor, strobeHz: Double)] = segments.map { seg in
            let hasIntensityFeature = definedFeatures.isEmpty || definedFeatures.contains("Intensity")
            let rawInt = KeyedArchiveGraph.doubleValue(seg["intensity"])
            let intensity = clamp01(rawInt ?? (hasIntensityFeature ? 1.0 : 1.0))

            var lightColor: LightColor = .white
            if let colorArr = seg["color"] as? [Any], let first = colorArr.first,
               let packed = KeyedArchiveGraph.int64Value(first) {
                let rgb = unpackColor(packed)
                lightColor = .rgb(rgb)
            } else if let packed = KeyedArchiveGraph.int64Value(seg["color"]) {
                let rgb = unpackColor(packed)
                lightColor = .rgb(rgb)
            } else if let cw = KeyedArchiveGraph.doubleValue(seg["coolWhite"]), cw > 0.01 {
                lightColor = .kelvin(5600, tint: 0)
            }

            let shutter = KeyedArchiveGraph.intValue(seg["shutterState"]) ?? 1
            let strobeHz: Double
            if shutter == 2 {
                strobeHz = clamp(KeyedArchiveGraph.doubleValue(seg["strobeSpeed"]) ?? 8.0, 1, 25)
            } else {
                strobeHz = 0
            }

            return (intensity, lightColor, strobeHz)
        }

        if parsedCells.count == 1 {
            let c = parsedCells[0]
            return FixtureState(intensity: c.intensity, color: c.color, cells: nil, strobeHz: c.strobeHz)
        }

        // Multi-segment fixture: map segments onto cells
        let maxIntensity = parsedCells.map(\.intensity).max() ?? 1.0
        let masterIntensity = maxIntensity > 0 ? maxIntensity : 0.0
        let cellStates: [CellState] = parsedCells.map { seg in
            let relInt = masterIntensity > 1e-6 ? clamp01(seg.intensity / masterIntensity) : 0
            return CellState(intensity: relInt, color: seg.color)
        }
        let adaptedCells = resampleCells(cellStates, toCount: targetCellCount > 0 ? targetCellCount : cellStates.count)
        let summaryColor = parsedCells.first(where: { $0.intensity > 0.01 })?.color ?? parsedCells[0].color
        let strobe = parsedCells.map(\.strobeHz).max() ?? 0

        return FixtureState(
            intensity: masterIntensity,
            color: summaryColor,
            cells: adaptedCells,
            strobeHz: strobe
        )
    }

    private static func resampleCells(_ cells: [CellState], toCount targetCount: Int) -> [CellState] {
        guard !cells.isEmpty, targetCount > 0, cells.count != targetCount else { return cells }
        if cells.count == 1 {
            return Array(repeating: cells[0], count: targetCount)
        }
        return (0..<targetCount).map { i in
            let pos = Double(i) / Double(max(targetCount - 1, 1)) * Double(cells.count - 1)
            let lo = clamp(Int(floor(pos)), 0, cells.count - 1)
            let hi = clamp(Int(ceil(pos)), 0, cells.count - 1)
            let t = pos - Double(lo)
            return CellState.mix(cells[lo], cells[hi], t)
        }
    }

    private static func deduplicatePreservingOrder(_ list: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in list where !seen.contains(s) {
            seen.insert(s)
            out.append(s)
        }
        return out
    }
}

// MARK: - Built-in Curated Fallback Definitions for Importer

enum BuiltinImportDefinitions {
    static let genericDimmer = FixtureDefinition(
        id: "generic.dimmer",
        manufacturer: "Generic",
        model: "Dimmer",
        category: .dimmer,
        aliases: ["dimmer", "1ch"],
        modes: [
            FixtureMode(name: "8-bit", shortName: "1ch", summary: "Brightness only", recommended: true,
                        channels: [ChannelDefinition(kind: .intensity)])
        ],
        source: "generic"
    )

    /// Full amaran PT4c definition matching `docs/research/aputure_profiles.md` §2.3–§2.6.
    static let amaranPT4c: FixtureDefinition = {
        func wholeTubeCCTRGB() -> FixtureMode {
            FixtureMode(
                name: "CCT & RGB",
                shortName: "10ch",
                summary: "Whole tube · full color + white balance",
                recommended: false,
                channels: [
                    ChannelDefinition(kind: .intensity),
                    ChannelDefinition(kind: .cct, physical: PhysicalRange(from: 2700, to: 10000)),
                    ChannelDefinition(kind: .tint, defaultValue: 128, physical: PhysicalRange(from: -1, to: 1)),
                    ChannelDefinition(kind: .crossfade, physical: PhysicalRange(from: 0, to: 1)),
                    ChannelDefinition(kind: .red),
                    ChannelDefinition(kind: .green),
                    ChannelDefinition(kind: .blue),
                    ChannelDefinition(kind: .nothing),
                    ChannelDefinition(kind: .nothing),
                    ChannelDefinition(kind: .strobe, capabilities: [
                        ChannelCapability(from: 0, to: 19, label: "No strobe", tag: "off"),
                        ChannelCapability(from: 20, to: 255, label: "Strobe 1–25 Hz", tag: "strobe", physical: [1, 25]),
                    ]),
                ]
            )
        }

        func wholeTubeCCT() -> FixtureMode {
            FixtureMode(
                name: "CCT",
                shortName: "6ch",
                summary: "Whole tube · white balance only",
                channels: [
                    ChannelDefinition(kind: .intensity),
                    ChannelDefinition(kind: .cct, physical: PhysicalRange(from: 2700, to: 10000)),
                    ChannelDefinition(kind: .tint, defaultValue: 128, physical: PhysicalRange(from: -1, to: 1)),
                    ChannelDefinition(kind: .nothing),
                    ChannelDefinition(kind: .nothing),
                    ChannelDefinition(kind: .strobe),
                ]
            )
        }

        func wholeTubeRGB() -> FixtureMode {
            FixtureMode(
                name: "RGB",
                shortName: "7ch",
                summary: "Whole tube · RGB color",
                channels: [
                    ChannelDefinition(kind: .intensity),
                    ChannelDefinition(kind: .red),
                    ChannelDefinition(kind: .green),
                    ChannelDefinition(kind: .blue),
                    ChannelDefinition(kind: .nothing),
                    ChannelDefinition(kind: .nothing),
                    ChannelDefinition(kind: .strobe),
                ]
            )
        }

        func lightEngineMode(pixels: Int, recommended: Bool = false) -> FixtureMode {
            var chs: [ChannelDefinition] = []
            for px in 0..<pixels {
                chs.append(ChannelDefinition(kind: .intensity, cell: px))
                chs.append(ChannelDefinition(kind: .cct, cell: px, physical: PhysicalRange(from: 2700, to: 10000)))
                chs.append(ChannelDefinition(kind: .tint, cell: px, defaultValue: 128, physical: PhysicalRange(from: -1, to: 1)))
                chs.append(ChannelDefinition(kind: .crossfade, cell: px, physical: PhysicalRange(from: 0, to: 1)))
                chs.append(ChannelDefinition(kind: .red, cell: px))
                chs.append(ChannelDefinition(kind: .green, cell: px))
                chs.append(ChannelDefinition(kind: .blue, cell: px))
            }
            return FixtureMode(
                name: "Light Engine CCT & RGB \(pixels) Pixels",
                shortName: "\(pixels * 7)ch",
                summary: "Full color + white balance · \(pixels) zones\(recommended ? " (recommended)" : "")",
                recommended: recommended,
                channels: chs
            )
        }

        return FixtureDefinition(
            id: "amaran.pt4c",
            manufacturer: "amaran",
            model: "PT4c",
            category: .tube,
            aliases: ["amaran pt", "pt4c", "pt2c", "pt1c", "aputure amaran pt"],
            physical: PhysicalSpec(lengthMM: 1200, diameterMM: 42, weightKG: 1.375),
            cctRange: [2700, 10000],
            modes: [
                wholeTubeCCTRGB(),
                wholeTubeCCT(),
                wholeTubeRGB(),
                lightEngineMode(pixels: 2),
                lightEngineMode(pixels: 4),
                lightEngineMode(pixels: 8, recommended: true),
                lightEngineMode(pixels: 16),
            ],
            source: "curated",
            notes: "Requires the amaran USB-C to DMX adapter. Keep the DMX Address screen open and hold OK for 2s to lock.",
            addressHelp: "1. Plug in the amaran USB-C to DMX adapter.\n2. Press MENU → DMX Settings.\n3. Set DMX Address and hold OK for 2s to lock.\n4. Set DMX Profiles to match the chosen mode.\n5. Set DMX Loss Behavior to Hold Last Setting.\n6. Leave the DMX Address screen visible."
        )
    }()
}

// MARK: - Synthetic `.lightkeyproj` Archive Builder (for Tests, Self-Tests & Tour Preview)

/// Builds valid NSKeyedArchiver binary plist `.lightkeyproj` archives following the schemas in
/// `docs/research/lightkey_format/class-schemas.md` and `fpstore-format.md`.
public final class LightkeyArchiveBuilder {
    private var objects: [Any] = ["$null"]
    private var classUIDs: [String: Int] = [:]

    public init() {}

    public func uid(_ index: Int) -> [String: Int] {
        ["CF$UID": index]
    }

    @discardableResult
    public func add(_ object: Any) -> [String: Int] {
        let idx = objects.count
        objects.append(object)
        return uid(idx)
    }

    public func rawString(_ text: String) -> [String: Int] {
        add(text)
    }

    public func classRef(_ name: String, chain: [String]? = nil) -> [String: Int] {
        if let existing = classUIDs[name] {
            return uid(existing)
        }
        let classes = chain ?? [name, "NSObject"]
        let ref = add([
            "$classname": name,
            "$classes": classes,
        ] as [String: Any])
        if let idx = ref["CF$UID"] {
            classUIDs[name] = idx
        }
        return ref
    }

    public func uuidObject(_ uuid: UUID = UUID()) -> [String: Int] {
        var u = uuid.uuid
        let data = withUnsafeBytes(of: &u) { Data($0) }
        return add([
            "NS.uuidbytes": data,
            "$class": classRef("NSUUID"),
        ] as [String: Any])
    }

    public func nsArray(_ refs: [[String: Int]]) -> [String: Int] {
        add([
            "NS.objects": refs,
            "$class": classRef("NSArray"),
        ] as [String: Any])
    }

    public func nsSet(_ refs: [[String: Int]]) -> [String: Int] {
        add([
            "NS.objects": refs,
            "$class": classRef("NSSet"),
        ] as [String: Any])
    }

    public func nsDictionary(keys: [[String: Int]] = [], values: [[String: Int]] = []) -> [String: Int] {
        add([
            "NS.keys": keys,
            "NS.objects": values,
            "$class": classRef("NSDictionary"),
        ] as [String: Any])
    }

    public func capability(
        className: String,
        channel: Int,
        customName: String? = nil,
        colorComponent: String? = nil,
        beamIndexes: [Int] = []
    ) -> [String: Int] {
        var dict: [String: Any] = [
            "channel": channel,
            "settings": nsArray([]),
            "$class": classRef(className),
        ]
        if let customName { dict["customName"] = rawString(customName) }
        if let colorComponent { dict["colorComponent"] = rawString(colorComponent) }
        if !beamIndexes.isEmpty {
            dict["beamIndexes"] = add(beamIndexes)
        }
        return add(dict)
    }

    public func personality(name: String, capabilities: [[String: Int]]) -> [String: Int] {
        add([
            "name": rawString(name),
            "capabilities": nsArray(capabilities),
            "$class": classRef("LXPersonality"),
        ] as [String: Any])
    }

    public func fixtureProfile(
        uuid: UUID = UUID(),
        manufacturer: String,
        name: String,
        personalities: [[String: Int]]
    ) -> [String: Int] {
        add([
            "UUID": uuidObject(uuid),
            "manufacturer": rawString(manufacturer),
            "name": rawString(name),
            "personalities": nsArray(personalities),
            "$class": classRef("LXFixtureProfile"),
        ] as [String: Any])
    }

    public func fixture(
        uuid: UUID = UUID(),
        shortName: String,
        name: String? = nil,
        comments: String = "",
        address: Int,
        universeUUID: UUID,
        profileUUID: UUID,
        personalityIndex: Int = 0
    ) -> [String: Int] {
        var dict: [String: Any] = [
            "UUID": uuidObject(uuid),
            "shortName": rawString(shortName),
            "comments": rawString(comments),
            "address": address,
            "instanceCount": 1,
            "universeUUID": uuidObject(universeUUID),
            "fixtureProfileUUID": uuidObject(profileUUID),
            "personalityIndex": personalityIndex,
            "ignoresMasterIntensity": false,
            "flexWidth": 1,
            "flexHeight": 1,
            "externalReference": rawString(""),
            "$class": classRef("LXDMXFixture"),
        ]
        if let name { dict["name"] = rawString(name) }
        return add(dict)
    }

    public func universe(uuid: UUID = UUID(), number: Int = 1, fixtures: [[String: Int]]) -> [String: Int] {
        add([
            "UUID": uuidObject(uuid),
            "universeNumber": number,
            "fixtures": nsArray(fixtures),
            "$class": classRef("LXDMXUniverse"),
        ] as [String: Any])
    }

    public func stageItem(fixtureUUID: UUID, center: (Double, Double), size: (Double, Double) = (80, 24), angleCCW: Double = 0) -> [String: Int] {
        add([
            "fixtureUUID": uuidObject(fixtureUUID),
            "center": rawString("{\(center.0), \(center.1)}"),
            "unrotatedSize": rawString("{\(size.0), \(size.1)}"),
            "angleCCW": angleCCW,
            "$class": classRef("LXFixtureCanvasItem", chain: ["LXFixtureCanvasItem", "LXCanvasItem", "NSObject"]),
        ] as [String: Any])
    }

    public func stage(items: [[String: Int]]) -> [String: Int] {
        add([
            "name": rawString("Stage"),
            "items": nsArray(items),
            "$class": classRef("LXStage"),
        ] as [String: Any])
    }

    public func fpStoreData(
        fixtureStates: [UUID: [(intensity: Double, rgb: RGB)]],
        includeNativeEffect: Bool = false
    ) throws -> Data {
        var umbrella: [String: Any] = [:]
        for (uuid, segments) in fixtureStates {
            let segDicts: [[String: Any]] = segments.map { seg in
                [
                    "intensity": seg.intensity,
                    "color": [LightkeyImporter.packColor(seg.rgb)],
                    "xfadeToColor": 1.0,
                ]
            }
            umbrella[uuid.uuidString.uppercased()] = [
                "definedFeatures": ["Intensity", "Color"],
                "fixtureContainer": [String: Any](),
                "segmentContainers": segDicts,
            ] as [String: Any]
        }
        var root: [String: Any] = [
            "isMutable": false,
            "umbrellaContainers": umbrella,
        ]
        if includeNativeEffect {
            root["effects"] = [
                [
                    "effectClass": 1000,
                    "feature": "Color",
                    "extent": [String: Any](),
                    "parameters": Data([0x01, 0x02, 0x03, 0x04]),
                ] as [String: Any]
            ]
        }
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    public func preset(uuid: UUID = UUID(), name: String, fpStore: Data) -> [String: Int] {
        add([
            "name": rawString(name),
            "UUID": uuidObject(uuid),
            "active": false,
            "childNodes": nsArray([]),
            "fpStore": add(fpStore),
            "$class": classRef("LXPreset"),
        ] as [String: Any])
    }

    public func presetGroup(
        uuid: UUID = UUID(),
        name: String,
        children: [[String: Int]],
        mutuallyExclusive: Bool = false,
        isRoot: Bool = false
    ) -> [String: Int] {
        add([
            "name": rawString(name),
            "UUID": uuidObject(uuid),
            "childNodes": nsArray(children),
            "presetsAreMutuallyExclusive": mutuallyExclusive,
            "$class": classRef(isRoot ? "LXRootPresetGroup" : "LXPresetGroup"),
        ] as [String: Any])
    }

    public func cue(
        uuid: UUID = UUID(),
        name: String,
        fadeIn: Double = 1.5,
        fadeOut: Double = 1.5,
        activateAtStartup: Bool = false,
        presets: [[String: Int]]
    ) -> [String: Int] {
        let emptyDict = nsDictionary()
        let orphan = presetGroup(name: "Cue Orphan Presets Group", children: [], isRoot: true)
        return add([
            "name": rawString(name),
            "UUID": uuidObject(uuid),
            "active": false,
            "activateAtStartup": activateAtStartup,
            "activateAtShutdown": false,
            "excludeFromLiveTriggers": false,
            "requiresUnlockedApp": false,
            "fadeInDuration": fadeIn,
            "fadeOutDuration": fadeOut,
            "fadeDuration": 0.5,
            "holdDuration": -1.0,
            "priority": 5,
            "intensity": 1.0,
            "presets": nsArray(presets),
            "orphanPresetsGroup": orphan,
            "metaModifiers": emptyDict,
            "metaModifierDefaults": emptyDict,
            "activeSpeedModifiers": nsSet([]),
            "intensityFeatures": uid(0),
            "$class": classRef("LXCue", chain: ["LXCue", "LXCueObjC", "NSObject"]),
        ] as [String: Any])
    }

    public func finalizeArchive(top: [String: [String: Int]]) throws -> Data {
        let archive: [String: Any] = [
            "$version": 100_000,
            "$archiver": "NSKeyedArchiver",
            "$top": top,
            "$objects": objects,
        ]
        return try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
    }

    /// Generates a synthetic `.lightkeyproj` archive mirroring the London Studio rig:
    /// 8 × Amaran PT tubes (B1–B8, 8-pixel 56ch mode), 1 × Key Panel (PN1), 1 × Round Dimmer (P1),
    /// folders ("Random", "Cool Setups"), and looks ("Chill Vibes 4", "Blackout", "WNDT").
    public static func londonStudioArchiveData() throws -> Data {
        let b = LightkeyArchiveBuilder()
        let u1UUID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let ptProfileUUID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
        let panelProfileUUID = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
        let dimmerProfileUUID = UUID(uuidString: "20000000-0000-4000-8000-000000000003")!

        // Build 56-channel "Light Engine CCT & RGB 8 Pixels" personality for Amaran PT
        var ptCaps: [[String: Int]] = []
        for px in 0..<8 {
            let base = px * 7
            let beams = [px * 2, px * 2 + 1]
            ptCaps.append(b.capability(className: "LXIntensityCapability", channel: base + 0, beamIndexes: beams))
            ptCaps.append(b.capability(className: "LXColorFilterCapability", channel: base + 1, beamIndexes: beams))
            ptCaps.append(b.capability(className: "LXGreenSaturationCapability", channel: base + 2, beamIndexes: beams))
            ptCaps.append(b.capability(className: "LXXfadeToColorCapability", channel: base + 3, beamIndexes: beams))
            ptCaps.append(b.capability(className: "LXColorComponentCapability", channel: base + 4, colorComponent: "Red", beamIndexes: beams))
            ptCaps.append(b.capability(className: "LXColorComponentCapability", channel: base + 5, colorComponent: "Green", beamIndexes: beams))
            ptCaps.append(b.capability(className: "LXColorComponentCapability", channel: base + 6, colorComponent: "Blue", beamIndexes: beams))
        }
        let ptPers = b.personality(name: "Light Engine CCT & RGB 8 Pixels", capabilities: ptCaps)
        let ptProfile = b.fixtureProfile(uuid: ptProfileUUID, manufacturer: "Aputure", name: "Amaran PT", personalities: [ptPers])

        // Panel profile (6ch RGBWW)
        let panelCaps = [
            b.capability(className: "LXIntensityCapability", channel: 0),
            b.capability(className: "LXColorComponentCapability", channel: 1, colorComponent: "Red"),
            b.capability(className: "LXColorComponentCapability", channel: 2, colorComponent: "Green"),
            b.capability(className: "LXColorComponentCapability", channel: 3, colorComponent: "Blue"),
            b.capability(className: "LXColorComponentCapability", channel: 4, colorComponent: "WarmWhite"),
            b.capability(className: "LXColorComponentCapability", channel: 5, colorComponent: "CoolWhite"),
        ]
        let panelPers = b.personality(name: "Dimmer + RGBWW", capabilities: panelCaps)
        let panelProfile = b.fixtureProfile(uuid: panelProfileUUID, manufacturer: "amaran", name: "F22c", personalities: [panelPers])

        // Dimmer profile (1ch)
        let dimPers = b.personality(name: "8-bit", capabilities: [b.capability(className: "LXIntensityCapability", channel: 0)])
        let dimProfile = b.fixtureProfile(uuid: dimmerProfileUUID, manufacturer: "Generic", name: "Dimmer", personalities: [dimPers])

        // Fixtures
        let tubeSpecs: [(Int, String, String, Int, (Double, Double), Double)] = [
            (1, "B1", "Tube Left", 1, (101, 604), 90),
            (2, "B2", "Tube Back Left", 57, (134, 392), 0),
            (3, "B3", "Tube Back Right", 113, (335, 392), 0),
            (4, "B4", "Tube Back Center", 169, (252, 473), 0),
            (5, "B5", "Tube Right", 225, (394, 606), -90),
            (6, "B6", "Floor Tube 2", 281, (342, 761), 55),
            (7, "B7", "Floor Tube 1", 337, (313, 759), 55),
            (8, "B8", "Floor Tube 3", 393, (373, 766), 55),
        ]

        var fixtureRefs: [[String: Int]] = []
        var stageItems: [[String: Int]] = []

        for (idx, short, name, addr, pt, angleCCW) in tubeSpecs {
            let uuid = DemoRig.IDs.tube(idx)
            fixtureRefs.append(b.fixture(uuid: uuid, shortName: short, name: name, address: addr, universeUUID: u1UUID, profileUUID: ptProfileUUID))
            stageItems.append(b.stageItem(fixtureUUID: uuid, center: pt, angleCCW: angleCCW))
        }

        fixtureRefs.append(b.fixture(uuid: DemoRig.IDs.pn1, shortName: "PN1", name: "Key Panel", address: 449, universeUUID: u1UUID, profileUUID: panelProfileUUID))
        stageItems.append(b.stageItem(fixtureUUID: DemoRig.IDs.pn1, center: (119, 820), angleCCW: 0))

        fixtureRefs.append(b.fixture(uuid: DemoRig.IDs.p1, shortName: "P1", name: "Round Light", address: 455, universeUUID: u1UUID, profileUUID: dimmerProfileUUID))
        stageItems.append(b.stageItem(fixtureUUID: DemoRig.IDs.p1, center: (143, 133), angleCCW: 0))

        let u1 = b.universe(uuid: u1UUID, number: 1, fixtures: fixtureRefs)
        let stg = b.stage(items: stageItems)

        let cyan = RGB(hex: "#14D8F0")!
        let pink = RGB(hex: "#FF2FB4")!
        let teal = RGB(hex: "#00C2A8")!
        let blue = RGB(hex: "#1F4BFF")!

        let chillFP = try b.fpStoreData(fixtureStates: [
            DemoRig.IDs.p1: [(1.0, .white)],
            DemoRig.IDs.tube(1): [(1.0, cyan)],
            DemoRig.IDs.tube(2): [(1.0, pink)],
            DemoRig.IDs.tube(3): [(1.0, pink)],
            DemoRig.IDs.tube(4): [(1.0, pink)],
            DemoRig.IDs.tube(5): [(1.0, cyan)],
            DemoRig.IDs.tube(6): [(1.0, pink)],
            DemoRig.IDs.tube(7): [(1.0, pink)],
            DemoRig.IDs.tube(8): [(1.0, cyan)],
        ])
        let chillPreset = b.preset(name: "Chill Vibes 4", fpStore: chillFP)
        let chillCue = b.cue(name: "Chill Vibes 4", fadeIn: 1.5, activateAtStartup: true, presets: [chillPreset])

        let blackoutFP = try b.fpStoreData(fixtureStates: [
            DemoRig.IDs.p1: [(0.0, .black)],
            DemoRig.IDs.tube(1): [(0.0, .black)],
            DemoRig.IDs.pn1: [(0.0, .black)],
        ])
        let blackoutPreset = b.preset(name: "Blackout", fpStore: blackoutFP)

        let wndtFP = try b.fpStoreData(fixtureStates: [
            DemoRig.IDs.tube(1): [(1.0, teal)],
            DemoRig.IDs.tube(5): [(1.0, blue)],
            DemoRig.IDs.tube(2): [(1.0, pink)],
            DemoRig.IDs.tube(3): [(1.0, pink)],
            DemoRig.IDs.pn1: [(0.8, .white)],
        ], includeNativeEffect: true)
        let wndtPreset = b.preset(name: "WNDT", fpStore: wndtFP)

        let randomFolder = b.presetGroup(name: "Random", children: [blackoutPreset])
        let coolFolder = b.presetGroup(name: "Cool Setups", children: [wndtPreset], mutuallyExclusive: true)
        let rootGroup = b.presetGroup(name: "Root", children: [chillPreset, randomFolder, coolFolder], isRoot: true)

        return try b.finalizeArchive(top: [
            "universes": b.nsArray([u1]),
            "fixtureProfiles": b.nsArray([ptProfile, panelProfile, dimProfile]),
            "stages": b.nsArray([stg]),
            "rootPresetGroup": rootGroup,
            "cues": b.nsArray([chillCue]),
        ])
    }
}
