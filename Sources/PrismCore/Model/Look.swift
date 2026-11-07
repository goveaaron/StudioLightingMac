import Foundation

/// Easing curves for look crossfades and layer transitions.
public enum FadeCurve: String, Codable, CaseIterable, Sendable, Identifiable {
    case linear
    case easeInOut
    case sCurve

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .easeInOut: return "Ease In–Out"
        case .sCurve: return "S-Curve"
        }
    }

    /// Evaluates the curve at linear progress `t` in 0…1.
    @inline(__always)
    public func evaluate(_ t: Double) -> Double {
        let p = clamp01(t.finiteOr(0))
        switch self {
        case .linear:
            return p
        case .easeInOut:
            return p * p * (3 - 2 * p)
        case .sCurve:
            return p * p * p * (p * (p * 6 - 15) + 10)
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FadeCurve(rawValue: raw) ?? .easeInOut
    }
}

/// Named crossfade timing presets shared by the UI, Live page, and commands.
public enum FadePreset: String, Codable, CaseIterable, Sendable, Identifiable {
    case snap
    case quick
    case smooth
    case slow
    case cinematic

    public var id: String { rawValue }

    /// Crossfade duration in seconds: Snap 0 s, Quick 0.4 s, Smooth 1.5 s, Slow 4 s, Cinematic 10 s.
    public var duration: Double {
        switch self {
        case .snap: return 0.0
        case .quick: return 0.4
        case .smooth: return 1.5
        case .slow: return 4.0
        case .cinematic: return 10.0
        }
    }

    public var seconds: Double { duration }

    public var displayName: String {
        switch self {
        case .snap: return "Snap"
        case .quick: return "Quick"
        case .smooth: return "Smooth"
        case .slow: return "Slow"
        case .cinematic: return "Cinematic"
        }
    }

    public var shortLabel: String {
        switch self {
        case .snap: return "0s"
        case .quick: return "0.4s"
        case .smooth: return "1.5s"
        case .slow: return "4s"
        case .cinematic: return "10s"
        }
    }

    public static func matching(duration: Double, tolerance: Double = 0.05) -> FadePreset? {
        allCases.first { abs($0.duration - duration) <= tolerance }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FadePreset(rawValue: raw) ?? .smooth
    }
}

/// A saved lighting look (Lightkey calls these presets). Can cover all fixtures or just some
/// ("partial looks" layer on top of whatever else is on). May include running effects and
/// music mode.
public struct Look: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var folderID: UUID?
    public var states: FixtureStateMap
    public var effects: [EffectInstance]
    /// If set, recalling this look also sets music mode.
    public var music: MusicModeSettings?
    /// Default crossfade time in seconds when recalled.
    public var fadeTime: Double
    /// Crossfade curve when recalled.
    public var fadeCurve: FadeCurve
    /// Spatial wave delay across the stage in seconds ("wave across the room" by stage position).
    public var spatialDelay: Double
    /// Direction of the spatial delay wave across the stage.
    public var delayDirection: EffectDirection
    /// Optional explicit per-fixture delay overrides in seconds.
    public var fixtureDelays: [UUID: Double]
    public var isFavorite: Bool
    /// Optional keyboard shortcut character.
    public var shortcut: String?
    public var sortIndex: Int
    public var notes: String
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), name: String, folderID: UUID? = nil, states: FixtureStateMap = FixtureStateMap(),
                effects: [EffectInstance] = [], music: MusicModeSettings? = nil, fadeTime: Double = 1.0,
                fadeCurve: FadeCurve = .easeInOut, spatialDelay: Double = 0,
                delayDirection: EffectDirection = .leftToRight, fixtureDelays: [UUID: Double] = [:],
                isFavorite: Bool = false, shortcut: String? = nil, sortIndex: Int = 0, notes: String = "",
                createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.id = id; self.name = name; self.folderID = folderID; self.states = states; self.effects = effects
        self.music = music; self.fadeTime = clamp(fadeTime.finiteOr(1), 0, 600); self.fadeCurve = fadeCurve
        self.spatialDelay = clamp(spatialDelay.finiteOr(0), 0, 60); self.delayDirection = delayDirection
        self.fixtureDelays = fixtureDelays.mapValues { clamp($0.finiteOr(0), 0, 60) }
        self.isFavorite = isFavorite; self.shortcut = shortcut
        self.sortIndex = sortIndex; self.notes = notes; self.createdAt = createdAt; self.modifiedAt = modifiedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, folderID, states, effects, music, fadeTime, fadeCurve, spatialDelay, delayDirection,
             fixtureDelays, isFavorite, shortcut, sortIndex, notes, createdAt, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Look"
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        states = try c.decodeIfPresent(FixtureStateMap.self, forKey: .states) ?? FixtureStateMap()
        effects = try c.decodeIfPresent([EffectInstance].self, forKey: .effects) ?? []
        music = try c.decodeIfPresent(MusicModeSettings.self, forKey: .music)
        fadeTime = clamp((try c.decodeIfPresent(Double.self, forKey: .fadeTime) ?? 1).finiteOr(1), 0, 600)
        fadeCurve = try c.decodeIfPresent(FadeCurve.self, forKey: .fadeCurve) ?? .easeInOut
        spatialDelay = clamp((try c.decodeIfPresent(Double.self, forKey: .spatialDelay) ?? 0).finiteOr(0), 0, 60)
        delayDirection = try c.decodeIfPresent(EffectDirection.self, forKey: .delayDirection) ?? .leftToRight
        if let rawDelays = try c.decodeIfPresent([String: Double].self, forKey: .fixtureDelays) {
            var d: [UUID: Double] = [:]
            for (k, v) in rawDelays {
                if let uid = UUID(uuidString: k) { d[uid] = clamp(v.finiteOr(0), 0, 60) }
            }
            fixtureDelays = d
        } else {
            fixtureDelays = [:]
        }
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        shortcut = try c.decodeIfPresent(String.self, forKey: .shortcut)
        sortIndex = try c.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(folderID, forKey: .folderID)
        try c.encode(states, forKey: .states)
        try c.encode(effects, forKey: .effects)
        try c.encodeIfPresent(music, forKey: .music)
        try c.encode(fadeTime, forKey: .fadeTime)
        if fadeCurve != .easeInOut { try c.encode(fadeCurve, forKey: .fadeCurve) }
        if spatialDelay > 0 {
            try c.encode(spatialDelay, forKey: .spatialDelay)
            try c.encode(delayDirection, forKey: .delayDirection)
        }
        if !fixtureDelays.isEmpty {
            var dict: [String: Double] = [:]
            for (k, v) in fixtureDelays { dict[k.uuidString] = v }
            try c.encode(dict, forKey: .fixtureDelays)
        }
        try c.encode(isFavorite, forKey: .isFavorite)
        try c.encodeIfPresent(shortcut, forKey: .shortcut)
        try c.encode(sortIndex, forKey: .sortIndex)
        try c.encode(notes, forKey: .notes)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(modifiedAt, forKey: .modifiedAt)
    }

    /// Up to `max` representative display colors (for list thumbnails / dots).
    public func swatchColors(max count: Int = 4) -> [RGB] {
        var seen: [String] = []
        var out: [RGB] = []
        for (_, state) in states.storage.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where state.intensity > 0.01 {
            let rgb = state.color.displayRGB
            if !seen.contains(rgb.hex) {
                seen.append(rgb.hex)
                out.append(rgb)
                if out.count >= count { break }
            }
        }
        return out
    }
}

public struct LookFolder: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var parentID: UUID?
    public var sortIndex: Int
    public var isExpanded: Bool

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil, sortIndex: Int = 0, isExpanded: Bool = true) {
        self.id = id; self.name = name; self.parentID = parentID; self.sortIndex = sortIndex; self.isExpanded = isExpanded
    }
}

// MARK: - Stage

public enum StagePropKind: String, Codable, CaseIterable, Sendable {
    case person, camera, desk, chair, sofa, backdrop, wall, plant, monitor, microphone, text

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StagePropKind(rawValue: raw) ?? .text
    }
}

/// Non-light objects drawn on the stage to make it recognisable (and give the assistant a
/// reference point for "left/right of the subject").
public struct StageProp: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: StagePropKind
    public var label: String
    public var transform: StageTransform
    /// Width/height in meters (nil = default for kind).
    public var width: Double?
    public var height: Double?

    public init(id: UUID = UUID(), kind: StagePropKind, label: String = "", transform: StageTransform = StageTransform(),
                width: Double? = nil, height: Double? = nil) {
        self.id = id; self.kind = kind; self.label = label; self.transform = transform; self.width = width; self.height = height
    }
}

public enum StageBackground: String, Codable, CaseIterable, Sendable {
    /// Deep dark gradient.
    case dark
    /// Dark with a subtle grid.
    case grid
    /// Live camera feed behind the plan (camera assist).
    case camera
    /// A user-supplied photo of the room.
    case photo

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StageBackground(rawValue: raw) ?? .grid
    }
}

public struct StageSettings: Codable, Hashable, Sendable {
    /// Stage area in meters.
    public var width: Double
    public var height: Double
    public var props: [StageProp]
    public var background: StageBackground
    /// Base64 PNG/JPEG for `.photo` backgrounds (kept small).
    public var photoData: Data?
    public var showLabels: Bool
    public var showGlow: Bool
    public var snapToGrid: Bool
    public var gridSize: Double
    /// Opacity (0.1…1) of a camera or photo backdrop behind the lights.
    public var backgroundOpacity: Double

    public init(width: Double = 10, height: Double = 6, props: [StageProp] = [StageProp(kind: .person, label: "Subject", transform: StageTransform(x: 5, y: 3.6))],
                background: StageBackground = .grid, photoData: Data? = nil, showLabels: Bool = true, showGlow: Bool = true,
                snapToGrid: Bool = false, gridSize: Double = 0.25, backgroundOpacity: Double = 0.6) {
        self.width = width; self.height = height; self.props = props; self.background = background
        self.photoData = photoData; self.showLabels = showLabels; self.showGlow = showGlow
        self.snapToGrid = snapToGrid; self.gridSize = gridSize
        self.backgroundOpacity = clamp(backgroundOpacity.finiteOr(0.6), 0.1, 1)
    }

    private enum CodingKeys: String, CodingKey { case width, height, props, background, photoData, showLabels, showGlow, snapToGrid, gridSize, backgroundOpacity }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = clamp((try c.decodeIfPresent(Double.self, forKey: .width) ?? 10).finiteOr(10), 1, 200)
        height = clamp((try c.decodeIfPresent(Double.self, forKey: .height) ?? 6).finiteOr(6), 1, 200)
        props = try c.decodeIfPresent([StageProp].self, forKey: .props) ?? []
        background = try c.decodeIfPresent(StageBackground.self, forKey: .background) ?? .grid
        photoData = try c.decodeIfPresent(Data.self, forKey: .photoData)
        showLabels = try c.decodeIfPresent(Bool.self, forKey: .showLabels) ?? true
        showGlow = try c.decodeIfPresent(Bool.self, forKey: .showGlow) ?? true
        snapToGrid = try c.decodeIfPresent(Bool.self, forKey: .snapToGrid) ?? false
        gridSize = clamp((try c.decodeIfPresent(Double.self, forKey: .gridSize) ?? 0.25).finiteOr(0.25), 0.05, 5)
        backgroundOpacity = clamp((try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.6).finiteOr(0.6), 0.1, 1)
    }

    /// The reference point for "left/right/above" — the first person prop, else stage center.
    public var subjectPoint: (x: Double, y: Double) {
        if let p = props.first(where: { $0.kind == .person }) { return (p.transform.x, p.transform.y) }
        return (width / 2, height / 2)
    }
}
