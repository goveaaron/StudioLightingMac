import Foundation

/// The device-independent state of one pixel/cell.
public struct CellState: Codable, Hashable, Sendable {
    public var intensity: Double
    public var color: LightColor

    public init(intensity: Double = 1, color: LightColor = .white) {
        self.intensity = clamp01(intensity)
        self.color = color
    }

    public static func mix(_ a: CellState, _ b: CellState, _ t: Double) -> CellState {
        CellState(intensity: lerp(a.intensity, b.intensity, clamp01(t)), color: LightColor.mix(a.color, b.color, t))
    }
}

/// What a light should be doing, independent of its DMX mode.
///
/// Renderers convert this into channel values for the fixture's mode. When a fixture has pixels
/// and `cells` is non-nil, each cell's color/intensity is multiplied by the master `intensity`.
public struct FixtureState: Codable, Hashable, Sendable {
    /// Master intensity 0…1.
    public var intensity: Double
    /// Whole-fixture color.
    public var color: LightColor
    /// Optional per-pixel states (count should equal the mode's cellCount; extra/missing cells
    /// are tolerated: missing cells use `color` at full cell intensity).
    public var cells: [CellState]?
    /// Strobe rate in Hz (0 = no strobe). Clamped by safety settings at render time.
    public var strobeHz: Double
    /// Raw overrides for channels the color model doesn't cover (channel index within mode → DMX value).
    public var raw: [Int: UInt8]?

    public init(intensity: Double = 0, color: LightColor = .white, cells: [CellState]? = nil,
                strobeHz: Double = 0, raw: [Int: UInt8]? = nil) {
        self.intensity = clamp01(intensity)
        self.color = color
        self.cells = cells
        self.strobeHz = max(0, strobeHz)
        self.raw = raw
    }

    public static let off = FixtureState(intensity: 0)

    /// Full white at 5600K — the default "on" look for a newly added light.
    public static let defaultOn = FixtureState(intensity: 0.8, color: .kelvin(5600, tint: 0))

    /// Color of cell `i` taking the uniform color into account.
    public func cell(_ i: Int) -> CellState {
        if let cells, i >= 0, i < cells.count { return cells[i] }
        return CellState(intensity: 1, color: color)
    }

    public var hasPixelData: Bool { !(cells?.isEmpty ?? true) }

    /// Perceptual blend between two states (used by crossfades).
    public static func mix(_ a: FixtureState, _ b: FixtureState, _ t: Double) -> FixtureState {
        let t = clamp01(t)
        if t <= 0 { return a }
        if t >= 1 { return b }
        var out = FixtureState(
            intensity: lerp(a.intensity, b.intensity, t),
            color: LightColor.mix(a.color, b.color, t),
            cells: nil,
            strobeHz: t < 0.5 ? a.strobeHz : b.strobeHz,
            raw: t < 0.5 ? a.raw : b.raw
        )
        if a.hasPixelData || b.hasPixelData {
            let n = max(a.cells?.count ?? 0, b.cells?.count ?? 0)
            out.cells = (0..<n).map { CellState.mix(a.cell($0), b.cell($0), t) }
        }
        return out
    }

    private enum CodingKeys: String, CodingKey { case intensity, color, cells, strobeHz, raw }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intensity = clamp01((try c.decodeIfPresent(Double.self, forKey: .intensity) ?? 0).finiteOr(0))
        color = try c.decodeIfPresent(LightColor.self, forKey: .color) ?? .white
        cells = try c.decodeIfPresent([CellState].self, forKey: .cells)
        strobeHz = clamp((try c.decodeIfPresent(Double.self, forKey: .strobeHz) ?? 0).finiteOr(0), 0, 30)
        if let rawDict = try c.decodeIfPresent([String: Int].self, forKey: .raw) {
            var r: [Int: UInt8] = [:]
            for (k, v) in rawDict { if let i = Int(k), i >= 0, i < 4096 { r[i] = UInt8(clamp(v, 0, 255)) } }
            raw = r.isEmpty ? nil : r
        } else {
            raw = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(intensity, forKey: .intensity)
        try c.encode(color, forKey: .color)
        try c.encodeIfPresent(cells, forKey: .cells)
        if strobeHz > 0 { try c.encode(strobeHz, forKey: .strobeHz) }
        if let raw, !raw.isEmpty {
            var dict: [String: Int] = [:]
            for (k, v) in raw { dict[String(k)] = Int(v) }
            try c.encode(dict, forKey: .raw)
        }
    }
}

/// A map from fixture id to state that encodes as a JSON object keyed by UUID string.
public struct FixtureStateMap: Codable, Hashable, Sendable, Sequence {
    public var storage: [UUID: FixtureState]

    public init(_ storage: [UUID: FixtureState] = [:]) { self.storage = storage }

    public subscript(id: UUID) -> FixtureState? {
        get { storage[id] }
        set { storage[id] = newValue }
    }

    public var keys: Dictionary<UUID, FixtureState>.Keys { storage.keys }
    public var isEmpty: Bool { storage.isEmpty }
    public var count: Int { storage.count }

    public func makeIterator() -> Dictionary<UUID, FixtureState>.Iterator { storage.makeIterator() }

    public init(from decoder: Decoder) throws {
        let dict = try decoder.singleValueContainer().decode([String: FixtureState].self)
        var s: [UUID: FixtureState] = [:]
        for (k, v) in dict { if let id = UUID(uuidString: k) { s[id] = v } }
        storage = s
    }

    public func encode(to encoder: Encoder) throws {
        var dict: [String: FixtureState] = [:]
        for (k, v) in storage { dict[k.uuidString] = v }
        var c = encoder.singleValueContainer()
        try c.encode(dict)
    }
}
