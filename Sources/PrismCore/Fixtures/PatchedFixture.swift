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

    public var sanitized: StageTransform {
        StageTransform(x: x.finiteOr(0), y: y.finiteOr(0), rotation: wrapDegrees(rotation.finiteOr(0)),
                       scale: clamp(scale.finiteOr(1), 0.1, 10), depth: depth.map { clamp01($0.finiteOr(0.5)) })
    }
}

/// Dimmer response curve mapping normalized intensity (0…1) to output drive fraction (0…1).
public enum DimmerCurve: String, Codable, CaseIterable, Hashable, Sendable {
    /// Direct 1:1 linear mapping (`y = x`).
    case linear
    /// Classic theatrical / IES square-law curve (`y = x²`) for smooth low-end dimming.
    case squareLaw
    /// Theatrical S-curve (`y = 3x² - 2x³`) with gentle toe and soft top shoulder.
    case sCurve
    /// Perceptual LED smoothing curve (CIE L* inverse + soft low-end toe so LEDs don't step at 1–5%).
    case ledSmooth

    public var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .squareLaw: return "Square Law"
        case .sCurve: return "S-Curve"
        case .ledSmooth: return "LED Smooth"
        }
    }

    /// Evaluates the dimmer curve for a normalized input `x` in `0…1`.
    @inline(__always)
    public func apply(_ x: Double) -> Double {
        let v = clamp01(x.finiteOr(0))
        guard v > 0 else { return 0 }
        guard v < 1 else { return 1 }
        switch self {
        case .linear:
            return v
        case .squareLaw:
            return v * v
        case .sCurve:
            return v * v * (3.0 - 2.0 * v)
        case .ledSmooth:
            // Blend CIE L* perceptual response with a gentle linear toe so 1% stays above zero.
            let lStar = ColorMath.perceptualToLinearIntensity(v)
            return clamp01(0.85 * lStar + 0.15 * (v * v))
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? "linear"
        switch raw.lowercased() {
        case "linear", "lin":
            self = .linear
        case "squarelaw", "square_law", "square", "quadratic", "ies":
            self = .squareLaw
        case "scurve", "s_curve", "s-curve", "smooth", "sinusoidal":
            self = .sCurve
        case "ledsmooth", "led_smooth", "led", "perceptual", "cubic":
            self = .ledSmooth
        default:
            self = .linear
        }
    }
}

/// Per-fixture safety/creative limits.
public struct FixtureLimits: Codable, Hashable, Sendable {
    /// Output intensity is scaled into [minIntensity, maxIntensity] (0…1).
    public var maxIntensity: Double
    public var minIntensity: Double
    /// If false, effects/music mode never touch this fixture (e.g. the key light while filming).
    public var allowEffects: Bool
    /// If false, strobing is suppressed entirely.
    public var allowStrobe: Bool
    /// Dimmer transfer curve applied to master intensity.
    public var dimmerCurve: DimmerCurve
    /// When true (recommended for key lights), the fixture never dims all the way to 0 DMX while
    /// `state.intensity > 0` (maintaining at least `max(minIntensity, 1/255)` until turned off).
    public var neverFullyOffUnlessZero: Bool

    public init(
        maxIntensity: Double = 1,
        minIntensity: Double = 0,
        allowEffects: Bool = true,
        allowStrobe: Bool = true,
        dimmerCurve: DimmerCurve = .linear,
        neverFullyOffUnlessZero: Bool = false
    ) {
        self.maxIntensity = maxIntensity
        self.minIntensity = minIntensity
        self.allowEffects = allowEffects
        self.allowStrobe = allowStrobe
        self.dimmerCurve = dimmerCurve
        self.neverFullyOffUnlessZero = neverFullyOffUnlessZero
    }

    private enum CodingKeys: String, CodingKey {
        case maxIntensity, minIntensity, allowEffects, allowStrobe, dimmerCurve, neverFullyOffUnlessZero
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxIntensity = clamp01((try c.decodeIfPresent(Double.self, forKey: .maxIntensity) ?? 1).finiteOr(1))
        minIntensity = clamp01((try c.decodeIfPresent(Double.self, forKey: .minIntensity) ?? 0).finiteOr(0))
        allowEffects = try c.decodeIfPresent(Bool.self, forKey: .allowEffects) ?? true
        allowStrobe = try c.decodeIfPresent(Bool.self, forKey: .allowStrobe) ?? true
        dimmerCurve = try c.decodeIfPresent(DimmerCurve.self, forKey: .dimmerCurve) ?? .linear
        neverFullyOffUnlessZero = try c.decodeIfPresent(Bool.self, forKey: .neverFullyOffUnlessZero) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(maxIntensity, forKey: .maxIntensity)
        try c.encode(minIntensity, forKey: .minIntensity)
        try c.encode(allowEffects, forKey: .allowEffects)
        try c.encode(allowStrobe, forKey: .allowStrobe)
        if dimmerCurve != .linear {
            try c.encode(dimmerCurve, forKey: .dimmerCurve)
        }
        if neverFullyOffUnlessZero {
            try c.encode(neverFullyOffUnlessZero, forKey: .neverFullyOffUnlessZero)
        }
    }

    public static let `default` = FixtureLimits()
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
    /// White-point Kelvin trim (e.g. `+150` or `-200` K) applied to match fixtures across brands.
    public var whitePointKelvinTrim: Double
    /// White-point green/magenta tint trim (`-1…+1`, negative = greener, positive = more magenta).
    public var whitePointTintTrim: Double
    /// Optional per-fixture dimmer curve override.
    public var dimmerCurve: DimmerCurve?

    public init(
        gamma: Double = 1,
        gains: [String: Double] = [:],
        accurateColor: Bool = true,
        whitePointKelvinTrim: Double = 0,
        whitePointTintTrim: Double = 0,
        dimmerCurve: DimmerCurve? = nil
    ) {
        self.gamma = gamma
        self.gains = gains
        self.accurateColor = accurateColor
        self.whitePointKelvinTrim = whitePointKelvinTrim
        self.whitePointTintTrim = whitePointTintTrim
        self.dimmerCurve = dimmerCurve
    }

    private enum CodingKeys: String, CodingKey {
        case gamma, gains, accurateColor, whitePointKelvinTrim, whitePointTintTrim, dimmerCurve
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gamma = (try c.decodeIfPresent(Double.self, forKey: .gamma) ?? 1).finiteOr(1)
        gains = try c.decodeIfPresent([String: Double].self, forKey: .gains) ?? [:]
        accurateColor = try c.decodeIfPresent(Bool.self, forKey: .accurateColor) ?? true
        whitePointKelvinTrim = (try c.decodeIfPresent(Double.self, forKey: .whitePointKelvinTrim) ?? 0).finiteOr(0)
        whitePointTintTrim = clamp((try c.decodeIfPresent(Double.self, forKey: .whitePointTintTrim) ?? 0).finiteOr(0), -1, 1)
        dimmerCurve = try c.decodeIfPresent(DimmerCurve.self, forKey: .dimmerCurve)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(gamma, forKey: .gamma)
        try c.encode(gains, forKey: .gains)
        try c.encode(accurateColor, forKey: .accurateColor)
        if abs(whitePointKelvinTrim) > 1e-6 {
            try c.encode(whitePointKelvinTrim, forKey: .whitePointKelvinTrim)
        }
        if abs(whitePointTintTrim) > 1e-6 {
            try c.encode(whitePointTintTrim, forKey: .whitePointTintTrim)
        }
        try c.encodeIfPresent(dimmerCurve, forKey: .dimmerCurve)
    }

    public static let `default` = ColorCalibration()
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Light"
        shortName = try c.decodeIfPresent(String.self, forKey: .shortName) ?? ""
        definitionID = try c.decodeIfPresent(String.self, forKey: .definitionID) ?? "generic.dimmer"
        modeName = try c.decodeIfPresent(String.self, forKey: .modeName) ?? ""
        universe = clamp(try c.decodeIfPresent(Int.self, forKey: .universe) ?? 1, 1, 64)
        if let a = try c.decodeIfPresent(Int.self, forKey: .address) {
            address = (1...512).contains(a) ? a : nil
        } else {
            address = nil
        }
        role = try c.decodeIfPresent(FixtureRole.self, forKey: .role) ?? .other
        transform = (try c.decodeIfPresent(StageTransform.self, forKey: .transform) ?? StageTransform()).sanitized
        limits = try c.decodeIfPresent(FixtureLimits.self, forKey: .limits) ?? .default
        calibration = try c.decodeIfPresent(ColorCalibration.self, forKey: .calibration) ?? .default
        reversePixels = try c.decodeIfPresent(Bool.self, forKey: .reversePixels) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }

    /// Label for the stage: shortName if set, else name.
    public var stageLabel: String { shortName.isEmpty ? name : shortName }

    public var isPatched: Bool { address != nil }
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
