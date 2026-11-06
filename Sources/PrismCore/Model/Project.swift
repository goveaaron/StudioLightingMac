import Foundation

/// A fade of one fixture from a captured state toward its current target in `LiveState.base`.
public struct FixtureFade: Hashable, Sendable, Codable {
    public var from: FixtureState
    /// PrismClock time the fade was scheduled.
    public var startTime: Double
    /// Active crossfade duration in seconds (after `delay`).
    public var duration: Double
    /// Per-fixture delay in seconds before interpolation starts ("wave across the room").
    public var delay: Double
    /// Interpolation curve.
    public var curve: FadeCurve

    public init(from: FixtureState, startTime: Double, duration: Double, delay: Double = 0, curve: FadeCurve = .easeInOut) {
        self.from = from
        self.startTime = startTime.finiteOr(0)
        self.duration = max(0, duration.finiteOr(0))
        self.delay = max(0, delay.finiteOr(0))
        self.curve = curve
    }

    public var endTime: Double { startTime + delay + duration }

    /// Eased progress 0…1 at `time`. Returns 0 while waiting for `delay`.
    public func progress(at time: Double) -> Double {
        let elapsed = time - (startTime + delay)
        if elapsed <= 0 { return delay + duration <= 0 ? 1 : 0 }
        guard duration > 0 else { return 1 }
        let linear = clamp01(elapsed / duration)
        return curve.evaluate(linear)
    }

    /// Overall linear progress 0…1 across `(delay + duration)` at `time`.
    public func overallProgress(at time: Double) -> Double {
        let total = delay + duration
        guard total > 0 else { return 1 }
        return clamp01((time - startTime) / total)
    }

    public func isFinished(at time: Double) -> Bool { time >= startTime + delay + duration }
}

/// Smooth fade-in or fade-out of a software effect layer.
public struct EffectFade: Hashable, Sendable, Codable {
    public var effect: EffectInstance
    public var startTime: Double
    public var duration: Double
    /// True when fading in (0 → 1), false when fading out (1 → 0).
    public var fadingIn: Bool
    public var curve: FadeCurve

    public init(effect: EffectInstance, startTime: Double, duration: Double, fadingIn: Bool, curve: FadeCurve = .easeInOut) {
        self.effect = effect
        self.startTime = startTime.finiteOr(0)
        self.duration = max(0, duration.finiteOr(0))
        self.fadingIn = fadingIn
        self.curve = curve
    }

    public var endTime: Double { startTime + duration }

    public func progress(at time: Double) -> Double {
        guard duration > 0 else { return 1 }
        return curve.evaluate(clamp01((time - startTime) / duration))
    }

    public func weight(at time: Double) -> Double {
        let p = progress(at: time)
        return fadingIn ? p : (1 - p)
    }

    public func isFinished(at time: Double) -> Bool { time >= startTime + duration }
}

/// Smooth fade-in or fade-out of the music-reactive layer.
public struct MusicFade: Hashable, Sendable, Codable {
    public var settings: MusicModeSettings
    public var startTime: Double
    public var duration: Double
    /// True when fading in (0 → 1), false when fading out (1 → 0).
    public var fadingIn: Bool
    public var curve: FadeCurve

    public init(settings: MusicModeSettings, startTime: Double, duration: Double, fadingIn: Bool, curve: FadeCurve = .easeInOut) {
        self.settings = settings
        self.startTime = startTime.finiteOr(0)
        self.duration = max(0, duration.finiteOr(0))
        self.fadingIn = fadingIn
        self.curve = curve
    }

    public var endTime: Double { startTime + duration }

    public func progress(at time: Double) -> Double {
        guard duration > 0 else { return 1 }
        return curve.evaluate(clamp01((time - startTime) / duration))
    }

    public func weight(at time: Double) -> Double {
        let p = progress(at: time)
        return fadingIn ? p : (1 - p)
    }

    public func isFinished(at time: Double) -> Bool { time >= startTime + duration }
}

/// Raw DMX channel override (channel tester, Light Finder scanning). Applied after rendering.
public struct RawOverride: Hashable, Sendable, Codable {
    public var universe: Int
    /// 1-based DMX address.
    public var address: Int
    public var value: UInt8

    public init(universe: Int, address: Int, value: UInt8) {
        self.universe = universe; self.address = address; self.value = value
    }
}

/// Everything that is live right now. Owned by the app's show controller (main thread),
/// copied into `EngineCore` as part of a `ShowSnapshot` whenever it changes.
public struct LiveState: Hashable, Sendable {
    /// Target state per fixture (fixtures missing here are off).
    public var base: FixtureStateMap
    /// The look last recalled (for "modified" indicators).
    public var activeLookID: UUID?
    public var effects: [EffectInstance]
    public var music: MusicModeSettings
    /// Grand master 0…1 scales every fixture's intensity.
    public var grandMaster: Double
    public var blackout: Bool
    /// Recording mode: locks key/fill, suppresses flashing, and makes remote control read-only.
    public var recordingMode: Bool
    /// Freeze mode: holds output at `frozenStates` (or current base) until unfrozen.
    public var isFrozen: Bool
    public var frozenStates: FixtureStateMap?
    /// In-progress per-fixture fades toward `base`.
    public var fades: [UUID: FixtureFade]
    /// In-progress effect layer fades (fade-in and fade-out).
    public var effectFades: [UUID: EffectFade]
    /// In-progress music layer fade.
    public var musicFade: MusicFade?
    /// Fixtures currently flashing for identification → start time.
    public var identify: [UUID: Double]
    public var rawOverrides: [RawOverride]

    public init(base: FixtureStateMap = FixtureStateMap(), activeLookID: UUID? = nil, effects: [EffectInstance] = [],
                music: MusicModeSettings = MusicModeSettings(), grandMaster: Double = 1, blackout: Bool = false,
                recordingMode: Bool = false, isFrozen: Bool = false, frozenStates: FixtureStateMap? = nil,
                fades: [UUID: FixtureFade] = [:], effectFades: [UUID: EffectFade] = [:], musicFade: MusicFade? = nil,
                identify: [UUID: Double] = [:], rawOverrides: [RawOverride] = []) {
        self.base = base; self.activeLookID = activeLookID; self.effects = effects; self.music = music
        self.grandMaster = grandMaster; self.blackout = blackout; self.recordingMode = recordingMode
        self.isFrozen = isFrozen; self.frozenStates = frozenStates; self.fades = fades
        self.effectFades = effectFades; self.musicFade = musicFade; self.identify = identify
        self.rawOverrides = rawOverrides
    }

    /// Persisted subset.
    public var snapshot: LiveSnapshot {
        LiveSnapshot(base: base, activeLookID: activeLookID, effects: effects, music: music,
                     grandMaster: grandMaster, recordingMode: recordingMode)
    }

    public init(snapshot: LiveSnapshot) {
        self.init(base: snapshot.base, activeLookID: snapshot.activeLookID, effects: snapshot.effects,
                  music: snapshot.music, grandMaster: snapshot.grandMaster, recordingMode: snapshot.recordingMode)
    }

    /// Returns the currently interpolated base state of fixture `id` at `time`.
    /// Used when starting a new fade mid-fade so transitions never jump.
    public func effectiveBaseState(of id: UUID, at time: Double, currentRendered: [UUID: FixtureState] = [:]) -> FixtureState {
        if let rendered = currentRendered[id] { return rendered }
        let target = base[id] ?? .off
        if let fade = fades[id], !fade.isFinished(at: time) {
            return FixtureState.mix(fade.from, target, fade.progress(at: time))
        }
        return target
    }

    /// Overall crossfade progress 0…1 across all active fades at `time`, or `nil` when no fade is active.
    public func fadeProgress(at time: Double) -> Double? {
        var minStart = Double.infinity
        var maxEnd = -Double.infinity
        var anyActive = false

        for f in fades.values where !f.isFinished(at: time) {
            anyActive = true
            minStart = min(minStart, f.startTime)
            maxEnd = max(maxEnd, f.endTime)
        }
        for ef in effectFades.values where !ef.isFinished(at: time) {
            anyActive = true
            minStart = min(minStart, ef.startTime)
            maxEnd = max(maxEnd, ef.endTime)
        }
        if let mf = musicFade, !mf.isFinished(at: time) {
            anyActive = true
            minStart = min(minStart, mf.startTime)
            maxEnd = max(maxEnd, mf.endTime)
        }

        guard anyActive, maxEnd > minStart else { return nil }
        return clamp01((time - minStart) / (maxEnd - minStart))
    }

    public func isFading(at time: Double) -> Bool {
        fadeProgress(at: time) != nil
    }

    public func remainingFadeTime(at time: Double) -> Double {
        var maxEnd = time
        for f in fades.values where !f.isFinished(at: time) { maxEnd = max(maxEnd, f.endTime) }
        for ef in effectFades.values where !ef.isFinished(at: time) { maxEnd = max(maxEnd, ef.endTime) }
        if let mf = musicFade, !mf.isFinished(at: time) { maxEnd = max(maxEnd, mf.endTime) }
        return max(0, maxEnd - time)
    }

    /// Removes finished fades and expired identify flashes.
    public mutating func pruneExpired(at time: Double, identifyDuration: Double = 2.0) {
        fades = fades.filter { !$0.value.isFinished(at: time) }
        effectFades = effectFades.filter { !$0.value.isFinished(at: time) }
        if let mf = musicFade, mf.isFinished(at: time) { musicFade = nil }
        identify = identify.filter { time - $0.value < identifyDuration }
    }
}

/// The part of the live state saved with a project (so reopening restores the look).
public struct LiveSnapshot: Codable, Hashable, Sendable {
    public var base: FixtureStateMap
    public var activeLookID: UUID?
    public var effects: [EffectInstance]
    public var music: MusicModeSettings
    public var grandMaster: Double
    public var recordingMode: Bool

    public init(base: FixtureStateMap = FixtureStateMap(), activeLookID: UUID? = nil, effects: [EffectInstance] = [],
                music: MusicModeSettings = MusicModeSettings(), grandMaster: Double = 1, recordingMode: Bool = false) {
        self.base = base; self.activeLookID = activeLookID; self.effects = effects; self.music = music
        self.grandMaster = grandMaster; self.recordingMode = recordingMode
    }

    private enum CodingKeys: String, CodingKey { case base, activeLookID, effects, music, grandMaster, recordingMode }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        base = (try? c.decodeIfPresent(FixtureStateMap.self, forKey: .base)) ?? FixtureStateMap()
        activeLookID = try? c.decodeIfPresent(UUID.self, forKey: .activeLookID)
        effects = (try? c.decodeIfPresent([EffectInstance].self, forKey: .effects)) ?? []
        var m = (try? c.decodeIfPresent(MusicModeSettings.self, forKey: .music)) ?? MusicModeSettings()
        m.enabled = false // never auto-start music mode when opening a file
        music = m
        grandMaster = clamp01(((try? c.decodeIfPresent(Double.self, forKey: .grandMaster)) ?? 1).finiteOr(1))
        recordingMode = (try? c.decodeIfPresent(Bool.self, forKey: .recordingMode)) ?? false
    }
}

/// Helper wrapper to decode array elements tolerantly without failing the entire array when one element is corrupt.
private struct TolerantElement<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// A Prism project: the rig (patch + stage), looks, groups and the last live state.
/// Saved as a `.prismlights` JSON file. Contains no secrets and no machine-specific settings,
/// so it is safe to share with other people.
public struct Project: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 2
    public static let fileExtension = "prismlights"

    public var formatVersion: Int
    /// Alias for schema version.
    public var version: Int {
        get { formatVersion }
        set { formatVersion = newValue }
    }
    public var id: UUID
    public var name: String
    public var fixtures: [PatchedFixture]
    public var groups: [FixtureGroup]
    public var looks: [Look]
    public var folders: [LookFolder]
    public var stage: StageSettings
    /// Fixture definitions used by this project, embedded for portability.
    public var definitions: [FixtureDefinition]
    public var musicDefaults: MusicModeSettings
    public var lastLive: LiveSnapshot?
    public var notes: String
    public var createdAt: Date
    public var modifiedAt: Date
    /// App version that last wrote the file.
    public var appVersion: String?
    /// Diagnostics collected during tolerant decoding (reported through `openReport`, not persisted).
    public var decodeFixes: [String] = []

    public init(id: UUID = UUID(), name: String = "My Studio", fixtures: [PatchedFixture] = [], groups: [FixtureGroup] = [],
                looks: [Look] = [], folders: [LookFolder] = [], stage: StageSettings = StageSettings(),
                definitions: [FixtureDefinition] = [], musicDefaults: MusicModeSettings = MusicModeSettings(),
                lastLive: LiveSnapshot? = nil, notes: String = "", createdAt: Date = Date(), modifiedAt: Date = Date(),
                appVersion: String? = nil, formatVersion: Int = Project.currentFormatVersion) {
        self.formatVersion = formatVersion
        self.id = id; self.name = name; self.fixtures = fixtures; self.groups = groups; self.looks = looks
        self.folders = folders; self.stage = stage; self.definitions = definitions; self.musicDefaults = musicDefaults
        self.lastLive = lastLive; self.notes = notes; self.createdAt = createdAt; self.modifiedAt = modifiedAt
        self.appVersion = appVersion
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, version, id, name, fixtures, groups, looks, folders, stage, definitions, musicDefaults,
             lastLive, notes, createdAt, modifiedAt, appVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var fixes: [String] = []

        if let fv = try c.decodeIfPresent(Int.self, forKey: .formatVersion) {
            formatVersion = fv
        } else if let v = try c.decodeIfPresent(Int.self, forKey: .version) {
            formatVersion = v
        } else {
            formatVersion = 1
        }

        if let decodedID = try? c.decodeIfPresent(UUID.self, forKey: .id) {
            id = decodedID
        } else {
            id = UUID()
            if c.contains(.id) { fixes.append("Repaired corrupt project ID.") }
        }

        if let decodedName = try? c.decodeIfPresent(String.self, forKey: .name) {
            let trimmed = decodedName.trimmingCharacters(in: .whitespacesAndNewlines)
            name = trimmed.isEmpty ? "Untitled" : trimmed
        } else {
            name = "Untitled"
            if c.contains(.name) { fixes.append("Repaired corrupt project name.") }
        }

        func decodeArray<T: Decodable>(_ key: CodingKeys, label: String) -> [T] {
            guard c.contains(key) else { return [] }
            if let direct = try? c.decodeIfPresent([T].self, forKey: key) { return direct }
            if let tolerant = try? c.decode([TolerantElement<T>].self, forKey: key) {
                let valid = tolerant.compactMap(\.value)
                let dropped = tolerant.count - valid.count
                if dropped > 0 { fixes.append("Repaired \(dropped) corrupt entr\(dropped == 1 ? "y" : "ies") in \(label).") }
                return valid
            }
            fixes.append("Repaired corrupt \(label) section.")
            return []
        }

        fixtures = decodeArray(.fixtures, label: "fixtures")
        groups = decodeArray(.groups, label: "groups")
        looks = decodeArray(.looks, label: "looks")
        folders = decodeArray(.folders, label: "folders")
        definitions = decodeArray(.definitions, label: "definitions")

        if c.contains(.stage) {
            if let s = try? c.decodeIfPresent(StageSettings.self, forKey: .stage) {
                stage = s
            } else {
                stage = StageSettings()
                fixes.append("Repaired corrupt stage settings.")
            }
        } else {
            stage = StageSettings()
        }

        if c.contains(.musicDefaults) {
            if let m = try? c.decodeIfPresent(MusicModeSettings.self, forKey: .musicDefaults) {
                musicDefaults = m
            } else {
                musicDefaults = MusicModeSettings()
                fixes.append("Repaired corrupt music settings.")
            }
        } else {
            musicDefaults = MusicModeSettings()
        }

        if c.contains(.lastLive) {
            if let l = try? c.decodeIfPresent(LiveSnapshot.self, forKey: .lastLive) {
                lastLive = l
            } else {
                lastLive = nil
                fixes.append("Repaired corrupt live snapshot.")
            }
        } else {
            lastLive = nil
        }

        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        modifiedAt = (try? c.decodeIfPresent(Date.self, forKey: .modifiedAt)) ?? Date()
        appVersion = try? c.decodeIfPresent(String.self, forKey: .appVersion)
        decodeFixes = fixes
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(fixtures, forKey: .fixtures)
        try c.encode(groups, forKey: .groups)
        try c.encode(looks, forKey: .looks)
        try c.encode(folders, forKey: .folders)
        try c.encode(stage, forKey: .stage)
        try c.encode(definitions, forKey: .definitions)
        try c.encode(musicDefaults, forKey: .musicDefaults)
        try c.encodeIfPresent(lastLive, forKey: .lastLive)
        try c.encode(notes, forKey: .notes)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(modifiedAt, forKey: .modifiedAt)
        try c.encodeIfPresent(appVersion, forKey: .appVersion)
    }

    public static func == (lhs: Project, rhs: Project) -> Bool {
        lhs.formatVersion == rhs.formatVersion &&
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.fixtures == rhs.fixtures &&
        lhs.groups == rhs.groups &&
        lhs.looks == rhs.looks &&
        lhs.folders == rhs.folders &&
        lhs.stage == rhs.stage &&
        lhs.definitions == rhs.definitions &&
        lhs.musicDefaults == rhs.musicDefaults &&
        lhs.lastLive == rhs.lastLive &&
        lhs.notes == rhs.notes &&
        lhs.createdAt == rhs.createdAt &&
        lhs.modifiedAt == rhs.modifiedAt &&
        lhs.appVersion == rhs.appVersion
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(formatVersion)
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(fixtures)
        hasher.combine(groups)
        hasher.combine(looks)
        hasher.combine(folders)
        hasher.combine(stage)
        hasher.combine(definitions)
        hasher.combine(musicDefaults)
        hasher.combine(lastLive)
        hasher.combine(notes)
        hasher.combine(createdAt)
        hasher.combine(modifiedAt)
        hasher.combine(appVersion)
    }

    // MARK: Lookups

    public func fixture(_ id: UUID) -> PatchedFixture? { fixtures.first { $0.id == id } }
    public func look(_ id: UUID) -> Look? { looks.first { $0.id == id } }
    public func group(_ id: UUID) -> FixtureGroup? { groups.first { $0.id == id } }
    public func definition(_ id: String) -> FixtureDefinition? { definitions.first { $0.id == id } }

    /// Resolves every fixture against embedded definitions (and an optional external library
    /// lookup). Fixtures whose definition/mode cannot be found are skipped.
    public func resolvedFixtures(library: ((String) -> FixtureDefinition?)? = nil) -> [ResolvedFixture] {
        fixtures.compactMap { f in
            guard let def = definition(f.definitionID) ?? library?(f.definitionID),
                  let mode = def.mode(named: f.modeName) ?? def.recommendedMode else { return nil }
            return ResolvedFixture(fixture: f, definition: def, mode: mode)
        }
    }
}

/// Project + live state: the full show the app is running.
public struct ShowDocument: Hashable, Sendable {
    public var project: Project
    public var live: LiveState

    public init(project: Project = Project(), live: LiveState = LiveState()) {
        self.project = project
        self.live = live
    }
}
