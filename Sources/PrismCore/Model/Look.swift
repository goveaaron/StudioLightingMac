import Foundation

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
    public var isFavorite: Bool
    /// Optional keyboard shortcut character.
    public var shortcut: String?
    public var sortIndex: Int
    public var notes: String
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), name: String, folderID: UUID? = nil, states: FixtureStateMap = FixtureStateMap(),
                effects: [EffectInstance] = [], music: MusicModeSettings? = nil, fadeTime: Double = 1.0,
                isFavorite: Bool = false, shortcut: String? = nil, sortIndex: Int = 0, notes: String = "",
                createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.id = id; self.name = name; self.folderID = folderID; self.states = states; self.effects = effects
        self.music = music; self.fadeTime = fadeTime; self.isFavorite = isFavorite; self.shortcut = shortcut
        self.sortIndex = sortIndex; self.notes = notes; self.createdAt = createdAt; self.modifiedAt = modifiedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, folderID, states, effects, music, fadeTime, isFavorite, shortcut, sortIndex, notes, createdAt, modifiedAt
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
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        shortcut = try c.decodeIfPresent(String.self, forKey: .shortcut)
        sortIndex = try c.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()
    }

    /// Up to `max` representative display colors (for list thumbnails / dots).
    public func swatchColors(max count: Int = 4) -> [RGBColor] {
        var seen: [String] = []
        var out: [RGBColor] = []
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

    public init(width: Double = 10, height: Double = 6, props: [StageProp] = [StageProp(kind: .person, label: "Subject", transform: StageTransform(x: 5, y: 3.6))],
                background: StageBackground = .grid, photoData: Data? = nil, showLabels: Bool = true, showGlow: Bool = true,
                snapToGrid: Bool = false, gridSize: Double = 0.25) {
        self.width = width; self.height = height; self.props = props; self.background = background
        self.photoData = photoData; self.showLabels = showLabels; self.showGlow = showGlow
        self.snapToGrid = snapToGrid; self.gridSize = gridSize
    }

    private enum CodingKeys: String, CodingKey { case width, height, props, background, photoData, showLabels, showGlow, snapToGrid, gridSize }

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
    }

    /// The reference point for "left/right/above" — the first person prop, else stage center.
    public var subjectPoint: (x: Double, y: Double) {
        if let p = props.first(where: { $0.kind == .person }) { return (p.transform.x, p.transform.y) }
        return (width / 2, height / 2)
    }
}
