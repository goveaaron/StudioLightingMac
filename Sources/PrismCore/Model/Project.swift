import Foundation

/// A fade of one fixture from a captured state toward its current target in `LiveState.base`.
public struct FixtureFade: Hashable, Sendable {
    public var from: FixtureState
    /// PrismClock time the fade started.
    public var startTime: Double
    public var duration: Double

    public init(from: FixtureState, startTime: Double, duration: Double) {
        self.from = from; self.startTime = startTime; self.duration = max(0, duration)
    }

    /// Progress 0…1 at `time` (smooth ease-in-out).
    public func progress(at time: Double) -> Double {
        guard duration > 0 else { return 1 }
        let p = clamp01((time - startTime) / duration)
        return p * p * (3 - 2 * p)
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
    /// In-progress per-fixture fades toward `base`.
    public var fades: [UUID: FixtureFade]
    /// Fixtures currently flashing for identification → start time.
    public var identify: [UUID: Double]
    public var rawOverrides: [RawOverride]

    public init(base: FixtureStateMap = FixtureStateMap(), activeLookID: UUID? = nil, effects: [EffectInstance] = [],
                music: MusicModeSettings = MusicModeSettings(), grandMaster: Double = 1, blackout: Bool = false,
                fades: [UUID: FixtureFade] = [:], identify: [UUID: Double] = [:], rawOverrides: [RawOverride] = []) {
        self.base = base; self.activeLookID = activeLookID; self.effects = effects; self.music = music
        self.grandMaster = grandMaster; self.blackout = blackout; self.fades = fades; self.identify = identify
        self.rawOverrides = rawOverrides
    }

    /// Persisted subset.
    public var snapshot: LiveSnapshot {
        LiveSnapshot(base: base, activeLookID: activeLookID, effects: effects, music: music, grandMaster: grandMaster)
    }

    public init(snapshot: LiveSnapshot) {
        self.init(base: snapshot.base, activeLookID: snapshot.activeLookID, effects: snapshot.effects,
                  music: snapshot.music, grandMaster: snapshot.grandMaster)
    }

    /// Removes finished fades and expired identify flashes.
    public mutating func pruneExpired(at time: Double, identifyDuration: Double = 2.0) {
        fades = fades.filter { !$0.value.isFinished(at: time) }
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

    public init(base: FixtureStateMap = FixtureStateMap(), activeLookID: UUID? = nil, effects: [EffectInstance] = [],
                music: MusicModeSettings = MusicModeSettings(), grandMaster: Double = 1) {
        self.base = base; self.activeLookID = activeLookID; self.effects = effects; self.music = music
        self.grandMaster = grandMaster
    }

    private enum CodingKeys: String, CodingKey { case base, activeLookID, effects, music, grandMaster }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        base = try c.decodeIfPresent(FixtureStateMap.self, forKey: .base) ?? FixtureStateMap()
        activeLookID = try c.decodeIfPresent(UUID.self, forKey: .activeLookID)
        effects = try c.decodeIfPresent([EffectInstance].self, forKey: .effects) ?? []
        var m = try c.decodeIfPresent(MusicModeSettings.self, forKey: .music) ?? MusicModeSettings()
        m.enabled = false // never auto-start music mode when opening a file
        music = m
        grandMaster = clamp01((try c.decodeIfPresent(Double.self, forKey: .grandMaster) ?? 1).finiteOr(1))
    }
}

/// A Prism project: the rig (patch + stage), looks, groups and the last live state.
/// Saved as a `.prismlights` JSON file. Contains no secrets and no machine-specific settings,
/// so it is safe to share with other people.
public struct Project: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 1
    public static let fileExtension = "prismlights"

    public var formatVersion: Int
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

    public init(id: UUID = UUID(), name: String = "My Studio", fixtures: [PatchedFixture] = [], groups: [FixtureGroup] = [],
                looks: [Look] = [], folders: [LookFolder] = [], stage: StageSettings = StageSettings(),
                definitions: [FixtureDefinition] = [], musicDefaults: MusicModeSettings = MusicModeSettings(),
                lastLive: LiveSnapshot? = nil, notes: String = "", createdAt: Date = Date(), modifiedAt: Date = Date(),
                appVersion: String? = nil) {
        self.formatVersion = Project.currentFormatVersion
        self.id = id; self.name = name; self.fixtures = fixtures; self.groups = groups; self.looks = looks
        self.folders = folders; self.stage = stage; self.definitions = definitions; self.musicDefaults = musicDefaults
        self.lastLive = lastLive; self.notes = notes; self.createdAt = createdAt; self.modifiedAt = modifiedAt
        self.appVersion = appVersion
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, id, name, fixtures, groups, looks, folders, stage, definitions, musicDefaults, lastLive,
             notes, createdAt, modifiedAt, appVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        fixtures = try c.decodeIfPresent([PatchedFixture].self, forKey: .fixtures) ?? []
        groups = try c.decodeIfPresent([FixtureGroup].self, forKey: .groups) ?? []
        looks = try c.decodeIfPresent([Look].self, forKey: .looks) ?? []
        folders = try c.decodeIfPresent([LookFolder].self, forKey: .folders) ?? []
        stage = try c.decodeIfPresent(StageSettings.self, forKey: .stage) ?? StageSettings()
        definitions = try c.decodeIfPresent([FixtureDefinition].self, forKey: .definitions) ?? []
        musicDefaults = try c.decodeIfPresent(MusicModeSettings.self, forKey: .musicDefaults) ?? MusicModeSettings()
        lastLive = try c.decodeIfPresent(LiveSnapshot.self, forKey: .lastLive)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion)
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
