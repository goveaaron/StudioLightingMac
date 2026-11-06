import Foundation

/// The single command language for changing the show. The UI, the assistant (typed or voice),
/// the phone remote, MIDI/OSC/HTTP and Shortcuts all produce `LightingCommand`s, which are
/// applied by `CommandExecutor` — so every input method behaves identically and remote input
/// can be validated in one place (see `RemoteGuardrails`).
public enum LightingCommand: Hashable, Sendable {
    /// Absolute intensity 0…1.
    case setIntensity(FixtureSelector, Double)
    /// Relative intensity change (−1…+1, e.g. +0.1 = "a bit brighter").
    case adjustIntensity(FixtureSelector, Double)
    case setColor(FixtureSelector, LightColor)
    /// Set CCT in Kelvin, keeping tint (switches fixtures to white).
    case setKelvin(FixtureSelector, Double)
    /// Relative warmth in Kelvin (negative = warmer). For colored fixtures shifts hue toward amber/blue.
    case adjustKelvin(FixtureSelector, Double)
    case setTint(FixtureSelector, Double)
    case adjustTint(FixtureSelector, Double)
    /// Move color toward a target hue by `amount` 0…1 ("more blue on the left").
    case shiftColor(FixtureSelector, toward: LightColor, amount: Double)
    /// Relative saturation (−1…+1).
    case adjustSaturation(FixtureSelector, Double)
    /// Paint a gradient across the selected fixtures/pixels along an axis.
    case gradient(FixtureSelector, colors: [LightColor], axis: GradientAxis)
    case turnOn(FixtureSelector)
    case turnOff(FixtureSelector)
    case recallLook(LookReference, fade: Double?)
    case saveLook(name: String, selector: FixtureSelector)
    case startEffect(EffectInstance)
    case stopEffects(FixtureSelector)
    case stopAllEffects
    case setMusicMode(enabled: Bool, mood: MusicMood?)
    case setGrandMaster(Double)
    case setBlackout(Bool)
    case identify(FixtureSelector)
    /// Applies a fade time to subsequent changes in this batch (seconds).
    case fadeTime(Double)
}

public enum GradientAxis: String, Codable, CaseIterable, Sendable {
    case horizontal, vertical, alongFixture

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = GradientAxis(rawValue: raw) ?? .horizontal
    }
}

/// Refers to a look by id or by (fuzzy) name.
public enum LookReference: Hashable, Sendable, Codable {
    case id(UUID)
    case name(String)

    private enum CodingKeys: String, CodingKey { case id, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try c.decodeIfPresent(UUID.self, forKey: .id) { self = .id(id); return }
        self = .name(try c.decodeIfPresent(String.self, forKey: .name) ?? "")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .id(let id): try c.encode(id, forKey: .id)
        case .name(let n): try c.encode(n, forKey: .name)
        }
    }
}

/// Who issued a command. Remote origins are subject to guardrails.
public enum CommandOrigin: Hashable, Sendable {
    case ui
    case assistant
    case voice
    case remote(clientID: String, linkID: UUID)
    case midi
    case osc
    case http
    case shortcuts
    case system

    public var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }
}

/// Result of applying commands, for user feedback ("Warmed 4 background lights to 3800K").
public struct CommandResult: Sendable, Equatable {
    public var affectedFixtureIDs: Set<UUID>
    public var messages: [String]
    public var warnings: [String]

    public init(affectedFixtureIDs: Set<UUID> = [], messages: [String] = [], warnings: [String] = []) {
        self.affectedFixtureIDs = affectedFixtureIDs; self.messages = messages; self.warnings = warnings
    }

    public mutating func merge(_ other: CommandResult) {
        affectedFixtureIDs.formUnion(other.affectedFixtureIDs)
        messages += other.messages
        warnings += other.warnings
    }

    public var summary: String {
        (messages + warnings).joined(separator: " ")
    }
}

// MARK: - Codable (JSON form used by the remote protocol, OSC/HTTP and AI tool calls)

extension LightingCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case op, target, value, color, toward, amount, colors, axis, look, fade, name, effect, enabled, mood
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let op = try c.decode(String.self, forKey: .op)
        func target() throws -> FixtureSelector { try c.decodeIfPresent(FixtureSelector.self, forKey: .target) ?? .all }
        func value(_ d: Double = 0) throws -> Double { (try c.decodeIfPresent(Double.self, forKey: .value) ?? d).finiteOr(d) }
        switch op {
        case "setIntensity": self = .setIntensity(try target(), clamp01(try value()))
        case "adjustIntensity": self = .adjustIntensity(try target(), clamp(try value(), -1, 1))
        case "setColor": self = .setColor(try target(), (try c.decodeIfPresent(LightColor.self, forKey: .color) ?? .white).sanitized)
        case "setKelvin": self = .setKelvin(try target(), clamp(try value(5600), 1000, 20000))
        case "adjustKelvin": self = .adjustKelvin(try target(), clamp(try value(), -10000, 10000))
        case "setTint": self = .setTint(try target(), clamp(try value(), -1, 1))
        case "adjustTint": self = .adjustTint(try target(), clamp(try value(), -2, 2))
        case "shiftColor":
            self = .shiftColor(try target(), toward: (try c.decodeIfPresent(LightColor.self, forKey: .toward) ?? .white).sanitized,
                               amount: clamp01((try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0.25).finiteOr(0.25)))
        case "adjustSaturation": self = .adjustSaturation(try target(), clamp(try value(), -1, 1))
        case "gradient":
            self = .gradient(try target(), colors: Array((try c.decodeIfPresent([LightColor].self, forKey: .colors) ?? []).prefix(16)).map { $0.sanitized },
                             axis: try c.decodeIfPresent(GradientAxis.self, forKey: .axis) ?? .horizontal)
        case "turnOn": self = .turnOn(try target())
        case "turnOff": self = .turnOff(try target())
        case "recallLook":
            self = .recallLook(try c.decodeIfPresent(LookReference.self, forKey: .look) ?? .name(""),
                               fade: try c.decodeIfPresent(Double.self, forKey: .fade).map { clamp($0.finiteOr(1), 0, 600) })
        case "saveLook": self = .saveLook(name: try c.decodeIfPresent(String.self, forKey: .name) ?? "New Look", selector: try target())
        case "startEffect":
            guard let e = try c.decodeIfPresent(EffectInstance.self, forKey: .effect) else {
                throw DecodingError.dataCorruptedError(forKey: .effect, in: c, debugDescription: "missing effect")
            }
            self = .startEffect(e)
        case "stopEffects": self = .stopEffects(try target())
        case "stopAllEffects": self = .stopAllEffects
        case "setMusicMode":
            self = .setMusicMode(enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
                                 mood: try c.decodeIfPresent(MusicMood.self, forKey: .mood))
        case "setGrandMaster": self = .setGrandMaster(clamp01(try value(1)))
        case "setBlackout": self = .setBlackout(try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true)
        case "identify": self = .identify(try target())
        case "fadeTime": self = .fadeTime(clamp(try value(1), 0, 600))
        default:
            throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "unknown op \(op)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setIntensity(let t, let v): try c.encode("setIntensity", forKey: .op); try c.encode(t, forKey: .target); try c.encode(v, forKey: .value)
        case .adjustIntensity(let t, let v): try c.encode("adjustIntensity", forKey: .op); try c.encode(t, forKey: .target); try c.encode(v, forKey: .value)
        case .setColor(let t, let col): try c.encode("setColor", forKey: .op); try c.encode(t, forKey: .target); try c.encode(col, forKey: .color)
        case .setKelvin(let t, let v): try c.encode("setKelvin", forKey: .op); try c.encode(t, forKey: .target); try c.encode(v, forKey: .value)
        case .adjustKelvin(let t, let v): try c.encode("adjustKelvin", forKey: .op); try c.encode(t, forKey: .target); try c.encode(v, forKey: .value)
        case .setTint(let t, let v): try c.encode("setTint", forKey: .op); try c.encode(t, forKey: .target); try c.encode(v, forKey: .value)
        case .adjustTint(let t, let v): try c.encode("adjustTint", forKey: .op); try c.encode(t, forKey: .target); try c.encode(v, forKey: .value)
        case .shiftColor(let t, let toward, let amount):
            try c.encode("shiftColor", forKey: .op); try c.encode(t, forKey: .target); try c.encode(toward, forKey: .toward); try c.encode(amount, forKey: .amount)
        case .adjustSaturation(let t, let v): try c.encode("adjustSaturation", forKey: .op); try c.encode(t, forKey: .target); try c.encode(v, forKey: .value)
        case .gradient(let t, let colors, let axis):
            try c.encode("gradient", forKey: .op); try c.encode(t, forKey: .target); try c.encode(colors, forKey: .colors); try c.encode(axis, forKey: .axis)
        case .turnOn(let t): try c.encode("turnOn", forKey: .op); try c.encode(t, forKey: .target)
        case .turnOff(let t): try c.encode("turnOff", forKey: .op); try c.encode(t, forKey: .target)
        case .recallLook(let ref, let fade): try c.encode("recallLook", forKey: .op); try c.encode(ref, forKey: .look); try c.encodeIfPresent(fade, forKey: .fade)
        case .saveLook(let name, let t): try c.encode("saveLook", forKey: .op); try c.encode(name, forKey: .name); try c.encode(t, forKey: .target)
        case .startEffect(let e): try c.encode("startEffect", forKey: .op); try c.encode(e, forKey: .effect)
        case .stopEffects(let t): try c.encode("stopEffects", forKey: .op); try c.encode(t, forKey: .target)
        case .stopAllEffects: try c.encode("stopAllEffects", forKey: .op)
        case .setMusicMode(let enabled, let mood): try c.encode("setMusicMode", forKey: .op); try c.encode(enabled, forKey: .enabled); try c.encodeIfPresent(mood, forKey: .mood)
        case .setGrandMaster(let v): try c.encode("setGrandMaster", forKey: .op); try c.encode(v, forKey: .value)
        case .setBlackout(let b): try c.encode("setBlackout", forKey: .op); try c.encode(b, forKey: .enabled)
        case .identify(let t): try c.encode("identify", forKey: .op); try c.encode(t, forKey: .target)
        case .fadeTime(let v): try c.encode("fadeTime", forKey: .op); try c.encode(v, forKey: .value)
        }
    }
}
