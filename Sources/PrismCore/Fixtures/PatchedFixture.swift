import Foundation

/// What a light is *for* in the room. Drives intuitive defaults and natural-language commands
/// ("brighten the key", "warm up the background").
public enum FixtureRole: String, Codable, CaseIterable, Sendable {
    case key, fill, back, hair, kicker, background, accent, practical, ambient, effect, other

    public var displayName: String {
        switch self {
        case .key: return "Key"
        case .fill: return "Fill"
        case .back: return "Back / Rim"
        case .hair: return "Hair"
        case .kicker: return "Kicker"
        case .background: return "Background"
        case .accent: return "Accent"
        case .practical: return "Practical"
        case .ambient: return "Ambient"
        case .effect: return "Effect"
        case .other: return "Other"
        }
    }

    /// One-line explanation shown in the patch wizard.
    public var explanation: String {
        switch self {
        case .key: return "Main light on the subject's face."
        case .fill: return "Softer light that fills in shadows from the key."
        case .back: return "Behind the subject, separates them from the background."
        case .hair: return "From above/behind, adds shine to hair and shoulders."
        case .kicker: return "From the side/behind, adds an edge on the cheek."
        case .background: return "Lights the wall/set behind the subject."
        case .accent: return "Highlights an object or area of the set."
        case .practical: return "A visible light in the shot (lamp, neon, tube in frame)."
        case .ambient: return "General room light."
        case .effect: return "Effect light (party, music, flashes)."
        case .other: return "Anything else."
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FixtureRole(rawValue: raw) ?? .other
    }
}

/// Position of a fixture on the stage plan.
///
/// Stage coordinates are in meters. x grows to the RIGHT, y grows DOWNWARD (screen convention),
/// origin at the top-left of the stage area. "Left/right" are as seen from the camera/viewer.
public struct StageTransform: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    /// Degrees clockwise. For tubes/bars 0 = horizontal with pixel 1 on the left.
    public var rotation: Double
    /// Visual scale multiplier (1 = real size from the definition's physical dimensions).
    public var scale: Double
    /// Optional depth layer for 2.5D reasoning: 0 = front (near camera) … 1 = back wall.
    public var depth: Double?

    public init(x: Double = 0, y: Double = 0, rotation: Double = 0, scale: Double = 1, depth: Double? = nil) {
        self.x = x; self.y = y; self.rotation = rotation; self.scale = scale; self.depth = depth
    }

    /// Positions are bounded to ±1 km so corrupt files can't feed absurd values into spatial math.
    public var sanitized: StageTransform {
        StageTransform(x: clamp(x.finiteOr(0), -1000, 1000), y: clamp(y.finiteOr(0), -1000, 1000),
                       rotation: wrapDegrees(rotation.finiteOr(0)),
                       scale: clamp(scale.finiteOr(1), 0.1, 10), depth: depth.map { clamp01($0.finiteOr(0.5)) })
    }

    private enum CodingKeys: String, CodingKey { case x, y, rotation, scale, depth }

    /// Decodes leniently: missing or corrupt fields use defaults (older files may omit `scale`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = c.decodeLenient(Double.self, forKey: .x) ?? 0
        y = c.decodeLenient(Double.self, forKey: .y) ?? 0
        rotation = c.decodeLenient(Double.self, forKey: .rotation) ?? 0
        scale = c.decodeLenient(Double.self, forKey: .scale) ?? 1
        depth = c.decodeLenient(Double.self, forKey: .depth)
    }
}

/// Per-fixture safety/creative limits.
public struct FixtureLimits: Codable, Hashable, Sendable {
    /// Output intensity is scaled/clamped into [minIntensity, maxIntensity] (0…1).
    public var maxIntensity: Double
    public var minIntensity: Double
    /// If false, effects/music mode never touch this fixture (e.g. the key light while filming).
    public var allowEffects: Bool
    /// If false, strobing is suppressed entirely.
    public var allowStrobe: Bool
    /// When true, this fixture is protected from effects, music mode, and remote changes
    /// unless explicitly targeted from the UI.
    public var protected: Bool
    /// Optional Kelvin lower bound for this fixture.
    public var minKelvin: Double?
    /// Optional Kelvin upper bound for this fixture.
    public var maxKelvin: Double?

    public init(maxIntensity: Double = 1, minIntensity: Double = 0, allowEffects: Bool = true, allowStrobe: Bool = true,
                protected: Bool = false, minKelvin: Double? = nil, maxKelvin: Double? = nil) {
        let lo = clamp01(minIntensity.finiteOr(0))
        let hi = max(lo, clamp01(maxIntensity.finiteOr(1)))
        self.minIntensity = lo
        self.maxIntensity = hi
        self.allowEffects = allowEffects
        self.allowStrobe = allowStrobe
        self.protected = protected
        let kLo = minKelvin.map { clamp($0.finiteOr(1700), 1000, 20000) }
        let kHi = maxKelvin.map { clamp($0.finiteOr(12000), 1000, 20000) }
        if let loK = kLo, let hiK = kHi, hiK < loK {
            self.minKelvin = loK
            self.maxKelvin = loK
        } else {
            self.minKelvin = kLo
            self.maxKelvin = kHi
        }
    }

    public static let `default` = FixtureLimits()

    public var sanitized: FixtureLimits {
        FixtureLimits(maxIntensity: maxIntensity, minIntensity: minIntensity, allowEffects: allowEffects,
                      allowStrobe: allowStrobe, protected: protected, minKelvin: minKelvin, maxKelvin: maxKelvin)
    }

    private enum CodingKeys: String, CodingKey {
        case maxIntensity, minIntensity, allowEffects, allowStrobe, protected, minKelvin, maxKelvin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let minI = (c.decodeLenient(Double.self, forKey: .minIntensity) ?? 0).finiteOr(0)
        let maxI = (c.decodeLenient(Double.self, forKey: .maxIntensity) ?? 1).finiteOr(1)
        let allowFX = c.decodeLenient(Bool.self, forKey: .allowEffects) ?? true
        let allowStr = c.decodeLenient(Bool.self, forKey: .allowStrobe) ?? true
        let prot = c.decodeLenient(Bool.self, forKey: .protected) ?? false
        let minK = c.decodeLenient(Double.self, forKey: .minKelvin)
        let maxK = c.decodeLenient(Double.self, forKey: .maxKelvin)
        self.init(maxIntensity: maxI, minIntensity: minI, allowEffects: allowFX, allowStrobe: allowStr,
                  protected: prot, minKelvin: minK, maxKelvin: maxK)
    }
}

/// Per-fixture color calibration so different lights match each other and the screen.
public struct ColorCalibration: Codable, Hashable, Sendable {
    /// Exponent applied to emitter values before sending (1 = linear). LED fixtures that
    /// already apply a perceptual curve may look better with ~0.6–0.8.
    public var gamma: Double
    /// Per-emitter gain trims (e.g. reduce a too-strong green), keyed by ChannelKind raw value.
    public var gains: [String: Double]
    /// How hex colors are converted: true = photometrically accurate (decode sRGB gamma);
    /// false = send hex bytes directly like most consoles.
    public var accurateColor: Bool

    public init(gamma: Double = 1, gains: [String: Double] = [:], accurateColor: Bool = true) {
        self.gamma = gamma; self.gains = gains; self.accurateColor = accurateColor
    }

    public static let `default` = ColorCalibration()

    /// Gamma within 0.2…5 and gains within 0…4 (finite), at most 32 emitters.
    public var sanitized: ColorCalibration {
        var g: [String: Double] = [:]
        for (k, v) in gains.prefix(32) { g[String(k.prefix(32))] = clamp(v.finiteOr(1), 0, 4) }
        return ColorCalibration(gamma: clamp(gamma.finiteOr(1), 0.2, 5), gains: g, accurateColor: accurateColor)
    }

    private enum CodingKeys: String, CodingKey { case gamma, gains, accurateColor }

    /// Decodes leniently and sanitizes (calibration values feed straight into DMX math).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = ColorCalibration(gamma: c.decodeLenient(Double.self, forKey: .gamma) ?? 1,
                                gains: c.decodeLenient([String: Double].self, forKey: .gains) ?? [:],
                                accurateColor: c.decodeLenient(Bool.self, forKey: .accurateColor) ?? true).sanitized
    }
}

/// A light placed in the project: which model/mode it is, where it is in DMX space and on stage.
public struct PatchedFixture: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Friendly name, e.g. "Left Tube", "Key".
    public var name: String
    /// Short label drawn on the stage, e.g. "B1".
    public var shortName: String
    public var definitionID: String
    public var modeName: String
    /// 1-based universe number.
    public var universe: Int
    /// 1-based DMX start address (1…512), or nil when the light is on stage but not patched.
    public var address: Int?
    public var role: FixtureRole
    public var transform: StageTransform
    public var limits: FixtureLimits
    public var calibration: ColorCalibration
    /// Reverse pixel order (when a tube is mounted the other way round).
    public var reversePixels: Bool
    public var locked: Bool
    public var hidden: Bool
    public var notes: String
    public var tags: [String]

    public init(id: UUID = UUID(), name: String, shortName: String = "", definitionID: String, modeName: String,
                universe: Int = 1, address: Int? = nil, role: FixtureRole = .other,
                transform: StageTransform = StageTransform(), limits: FixtureLimits = .default,
                calibration: ColorCalibration = .default, reversePixels: Bool = false, locked: Bool = false,
                hidden: Bool = false, notes: String = "", tags: [String] = []) {
        self.id = id; self.name = name; self.shortName = shortName; self.definitionID = definitionID
        self.modeName = modeName; self.universe = universe; self.address = address; self.role = role
        self.transform = transform; self.limits = limits; self.calibration = calibration
        self.reversePixels = reversePixels; self.locked = locked; self.hidden = hidden; self.notes = notes
        self.tags = tags
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, shortName, definitionID, modeName, universe, address, role, transform, limits,
             calibration, reversePixels, locked, hidden, notes, tags
    }

    /// Decodes defensively: each field falls back to a safe default so one corrupt value never
    /// drops the light from the rig. Only an entry without a usable `definitionID` is rejected
    /// (it isn't a light at all; the project decoder drops and reports it).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let defID = c.decodeLenient(String.self, forKey: .definitionID)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !defID.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Fixture has no definitionID."))
        }
        id = c.decodeLenient(UUID.self, forKey: .id) ?? UUID()
        name = String((c.decodeLenient(String.self, forKey: .name) ?? "Light").prefix(200))
        shortName = String((c.decodeLenient(String.self, forKey: .shortName) ?? "").prefix(32))
        definitionID = defID
        modeName = c.decodeLenient(String.self, forKey: .modeName) ?? ""
        universe = clamp(c.decodeLenient(Int.self, forKey: .universe) ?? 1, 1, 64)
        if let a = c.decodeLenient(Int.self, forKey: .address) {
            address = (1...512).contains(a) ? a : nil
        } else {
            address = nil
        }
        role = c.decodeLenient(FixtureRole.self, forKey: .role) ?? .other
        transform = (c.decodeLenient(StageTransform.self, forKey: .transform) ?? StageTransform()).sanitized
        limits = c.decodeLenient(FixtureLimits.self, forKey: .limits) ?? .default
        calibration = c.decodeLenient(ColorCalibration.self, forKey: .calibration) ?? .default
        reversePixels = c.decodeLenient(Bool.self, forKey: .reversePixels) ?? false
        locked = c.decodeLenient(Bool.self, forKey: .locked) ?? false
        hidden = c.decodeLenient(Bool.self, forKey: .hidden) ?? false
        notes = c.decodeLenient(String.self, forKey: .notes) ?? ""
        tags = Array((c.decodeLenient([String].self, forKey: .tags) ?? []).prefix(64))
    }

    /// Label for the stage: shortName if set, else name.
    public var stageLabel: String { shortName.isEmpty ? name : shortName }

    public var isPatched: Bool { address != nil }

    /// True when this fixture is protected from effects, music mode, and remote changes
    /// (key/fill role, `limits.protected`, or `limits.allowEffects == false`).
    public var isProtected: Bool {
        role == .key || role == .fill || limits.protected || !limits.allowEffects
    }
}

/// A saved set of fixtures ("All Tubes", "Background", "Key & Fill").
public struct FixtureGroup: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var fixtureIDs: [UUID]
    /// Display color (hex) for the group chip.
    public var colorHex: String?

    public init(id: UUID = UUID(), name: String, fixtureIDs: [UUID], colorHex: String? = nil) {
        self.id = id; self.name = name; self.fixtureIDs = fixtureIDs; self.colorHex = colorHex
    }

    private enum CodingKeys: String, CodingKey { case id, name, fixtureIDs, colorHex }

    /// Decodes defensively: corrupt member ids are skipped and missing fields default.
    /// Only an entry with neither a name nor members is rejected.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedName = c.decodeLenient(String.self, forKey: .name)
        let members = c.decodeTolerantArray(UUID.self, forKey: .fixtureIDs, limit: Project.maxFixtures)?.values
        guard decodedName != nil || members != nil else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Group has neither a name nor members."))
        }
        id = c.decodeLenient(UUID.self, forKey: .id) ?? UUID()
        let trimmed = (decodedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        name = trimmed.isEmpty ? "Group" : String(trimmed.prefix(200))
        var seen = Set<UUID>()
        fixtureIDs = (members ?? []).filter { seen.insert($0).inserted }
        colorHex = c.decodeLenient(String.self, forKey: .colorHex).map { String($0.prefix(16)) }
    }
}

/// A fixture definition + mode resolved for a patched fixture (computed, not stored).
public struct ResolvedFixture: Sendable, Identifiable {
    public var fixture: PatchedFixture
    public var definition: FixtureDefinition
    public var mode: FixtureMode

    public init(fixture: PatchedFixture, definition: FixtureDefinition, mode: FixtureMode) {
        self.fixture = fixture; self.definition = definition; self.mode = mode
    }

    public var id: UUID { fixture.id }
    public var capabilities: ColorCapabilities { mode.capabilities }
    public var channelCount: Int { mode.channelCount }
    public var cellCount: Int { mode.cellCount }

    /// DMX address range occupied (1-based, inclusive), nil when unpatched.
    public var addressRange: ClosedRange<Int>? {
        guard let a = fixture.address else { return nil }
        return a...(a + max(mode.channelCount, 1) - 1)
    }

    /// Physical length in meters for drawing (tubes/bars) — falls back to sensible defaults.
    public var visualLengthMeters: Double {
        if let l = definition.physical?.lengthMM { return l / 1000 }
        switch definition.category {
        case .tube: return 1.2
        case .bar, .strip: return 1.0
        case .panel: return 0.6
        default: return 0.3
        }
    }
}
