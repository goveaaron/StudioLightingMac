import Foundation

/// Built-in software effects. All effects are computed by Prism (not the fixture's internal
/// programs), so they work identically on every light and stay in sync across fixtures.
public enum EffectKind: String, Codable, CaseIterable, Sendable {
    // Smooth / ambient
    case breathe, pulse, colorCycle, rainbow, wave, gradientSweep, aurora, ocean, lava, sunset
    case fire, candle, twinkle, comet, chase, scanner, sparkle
    // Aputure Sidus-style "special effects"
    case lightning, tv, police, fireworks, paparazzi, faultyBulb, explosion, welding, party, strobe

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EffectKind(rawValue: raw) ?? .breathe
    }

    public var displayName: String {
        switch self {
        case .breathe: return "Breathe"
        case .pulse: return "Pulse"
        case .colorCycle: return "Color Cycle"
        case .rainbow: return "Rainbow"
        case .wave: return "Wave"
        case .gradientSweep: return "Gradient Sweep"
        case .aurora: return "Aurora"
        case .ocean: return "Ocean"
        case .lava: return "Lava Lamp"
        case .sunset: return "Sunset"
        case .fire: return "Fire"
        case .candle: return "Candle"
        case .twinkle: return "Twinkle"
        case .comet: return "Comet"
        case .chase: return "Chase"
        case .scanner: return "Scanner"
        case .sparkle: return "Sparkle"
        case .lightning: return "Lightning"
        case .tv: return "TV Flicker"
        case .police: return "Police"
        case .fireworks: return "Fireworks"
        case .paparazzi: return "Paparazzi"
        case .faultyBulb: return "Faulty Bulb"
        case .explosion: return "Explosion"
        case .welding: return "Welding"
        case .party: return "Party"
        case .strobe: return "Strobe"
        }
    }

    /// Effects that flash quickly. Hidden from guests and gated by the photosensitivity setting.
    public var isFlashy: Bool {
        switch self {
        case .lightning, .police, .paparazzi, .explosion, .welding, .strobe, .faultyBulb: return true
        default: return false
        }
    }
}

public enum EffectDirection: String, Codable, CaseIterable, Sendable {
    case leftToRight, rightToLeft, topToBottom, bottomToTop, outward, inward, random

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EffectDirection(rawValue: raw) ?? .leftToRight
    }
}

/// How an effect's output combines with the underlying look.
public enum EffectBlend: String, Codable, CaseIterable, Sendable {
    /// Effect sets color and intensity.
    case replace
    /// Effect scales the look's intensity (keeps the look's colors).
    case intensityOnly
    /// Effect sets color, keeps the look's intensity.
    case colorOnly
    /// Effect output multiplies intensity and replaces color.
    case multiply

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EffectBlend(rawValue: raw) ?? .replace
    }
}

public struct EffectParameters: Codable, Hashable, Sendable {
    /// Rate multiplier; 1 = the effect's natural speed. Range 0.05…10.
    public var speed: Double
    /// Spatial size of patterns (0 = tiny/fast variation across fixtures … 1 = whole stage).
    public var size: Double
    /// Depth of modulation 0…1.
    public var amount: Double
    /// Colors used by the effect (empty = effect default palette).
    public var palette: [LightColor]
    public var direction: EffectDirection
    /// 0 = all fixtures in phase … 1 = evenly spread phases across fixtures/pixels.
    public var phaseSpread: Double
    /// 0 = hard edges … 1 = very soft.
    public var smoothness: Double
    public var minIntensity: Double
    public var maxIntensity: Double
    /// Effect-specific extras.
    public var extra: [String: Double]

    public init(speed: Double = 1, size: Double = 0.5, amount: Double = 1, palette: [LightColor] = [],
                direction: EffectDirection = .leftToRight, phaseSpread: Double = 0.5, smoothness: Double = 0.7,
                minIntensity: Double = 0, maxIntensity: Double = 1, extra: [String: Double] = [:]) {
        self.speed = speed; self.size = size; self.amount = amount; self.palette = palette
        self.direction = direction; self.phaseSpread = phaseSpread; self.smoothness = smoothness
        self.minIntensity = minIntensity; self.maxIntensity = maxIntensity; self.extra = extra
    }

    public var sanitized: EffectParameters {
        var p = self
        p.speed = clamp(speed.finiteOr(1), 0.01, 10)
        p.size = clamp01(size.finiteOr(0.5))
        p.amount = clamp01(amount.finiteOr(1))
        p.phaseSpread = clamp01(phaseSpread.finiteOr(0.5))
        p.smoothness = clamp01(smoothness.finiteOr(0.7))
        p.minIntensity = clamp01(minIntensity.finiteOr(0))
        p.maxIntensity = clamp(maxIntensity.finiteOr(1), p.minIntensity, 1)
        p.palette = Array(palette.prefix(16)).map { $0.sanitized }
        return p
    }

    private enum CodingKeys: String, CodingKey {
        case speed, size, amount, palette, direction, phaseSpread, smoothness, minIntensity, maxIntensity, extra
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            speed: try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1,
            size: try c.decodeIfPresent(Double.self, forKey: .size) ?? 0.5,
            amount: try c.decodeIfPresent(Double.self, forKey: .amount) ?? 1,
            palette: try c.decodeIfPresent([LightColor].self, forKey: .palette) ?? [],
            direction: try c.decodeIfPresent(EffectDirection.self, forKey: .direction) ?? .leftToRight,
            phaseSpread: try c.decodeIfPresent(Double.self, forKey: .phaseSpread) ?? 0.5,
            smoothness: try c.decodeIfPresent(Double.self, forKey: .smoothness) ?? 0.7,
            minIntensity: try c.decodeIfPresent(Double.self, forKey: .minIntensity) ?? 0,
            maxIntensity: try c.decodeIfPresent(Double.self, forKey: .maxIntensity) ?? 1,
            extra: try c.decodeIfPresent([String: Double].self, forKey: .extra) ?? [:]
        )
        self = self.sanitized
    }
}

/// A running (or saved) effect applied to a set of fixtures.
public struct EffectInstance: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: EffectKind
    public var name: String?
    public var targets: FixtureSelector
    public var params: EffectParameters
    public var blend: EffectBlend
    public var enabled: Bool
    /// When true and music mode is running, the effect's speed/amount follow the music.
    public var audioReactive: Bool

    public init(id: UUID = UUID(), kind: EffectKind, name: String? = nil, targets: FixtureSelector = .all,
                params: EffectParameters = EffectParameters(), blend: EffectBlend = .replace,
                enabled: Bool = true, audioReactive: Bool = false) {
        self.id = id; self.kind = kind; self.name = name; self.targets = targets; self.params = params
        self.blend = blend; self.enabled = enabled; self.audioReactive = audioReactive
    }

    private enum CodingKeys: String, CodingKey { case id, kind, name, targets, params, blend, enabled, audioReactive }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(EffectKind.self, forKey: .kind) ?? .breathe
        name = try c.decodeIfPresent(String.self, forKey: .name)
        targets = try c.decodeIfPresent(FixtureSelector.self, forKey: .targets) ?? .all
        params = try c.decodeIfPresent(EffectParameters.self, forKey: .params) ?? EffectParameters()
        blend = try c.decodeIfPresent(EffectBlend.self, forKey: .blend) ?? .replace
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        audioReactive = try c.decodeIfPresent(Bool.self, forKey: .audioReactive) ?? false
    }

    public var displayName: String { name ?? kind.displayName }
}
