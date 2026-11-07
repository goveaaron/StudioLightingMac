import Foundation

/// Relative nudge amounts shared by the assistant, inspector, and keyboard shortcuts:
/// "a little" = 5%, "a bit" = 10%, "a lot" = 25%, plus Kelvin, tint, and stop equivalents.
public enum NudgeAmount: String, Codable, CaseIterable, Sendable {
    case aLittle
    case aBit
    case aLot

    /// Relative intensity / saturation fraction: 5%, 10%, 25%.
    public static let little: Double = 0.05
    public static let bit: Double = 0.10
    public static let lot: Double = 0.25

    /// Relative CCT delta in Kelvin.
    public static let kelvinLittle: Double = 200
    public static let kelvinBit: Double = 400
    public static let kelvinLot: Double = 1000

    /// Relative green/magenta tint delta (-1…+1 scale).
    public static let tintLittle: Double = 0.05
    public static let tintBit: Double = 0.10
    public static let tintLot: Double = 0.25

    /// Photographic stop equivalents.
    public static let stopsLittle: Double = 1.0 / 3.0
    public static let stopsBit: Double = 0.5
    public static let stopsLot: Double = 1.0

    public var fraction: Double {
        switch self {
        case .aLittle: return Self.little
        case .aBit: return Self.bit
        case .aLot: return Self.lot
        }
    }

    public var kelvin: Double {
        switch self {
        case .aLittle: return Self.kelvinLittle
        case .aBit: return Self.kelvinBit
        case .aLot: return Self.kelvinLot
        }
    }

    public var tint: Double {
        switch self {
        case .aLittle: return Self.tintLittle
        case .aBit: return Self.tintBit
        case .aLot: return Self.tintLot
        }
    }

    public var stops: Double {
        switch self {
        case .aLittle: return Self.stopsLittle
        case .aBit: return Self.stopsBit
        case .aLot: return Self.stopsLot
        }
    }

    /// Parses natural-language quantifier phrases ("a little", "slightly", "a bit", "a lot", "much").
    public static func from(phrase: String) -> NudgeAmount? {
        let s = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("a lot") || s.contains("way ") || s.contains("much") || s.contains("heavily") || s == "lot" {
            return .aLot
        }
        if s.contains("a little") || s.contains("slightly") || s.contains("tiny") || s.contains("touch") || s == "little" {
            return .aLittle
        }
        if s.contains("a bit") || s.contains("bit") || s.contains("some") {
            return .aBit
        }
        return nil
    }
}

public typealias LightingNudge = NudgeAmount

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
    /// Sets per-cell states across pixel fixtures.
    case setCells(FixtureSelector, cells: [CellState])
    /// Paints specific 0-based cell indices (or all cells if empty) on pixel fixtures with a color and optional intensity.
    case paintCells(FixtureSelector, cellIndices: [Int], color: LightColor, intensity: Double?)
    case turnOn(FixtureSelector)
    case turnOff(FixtureSelector)
    case recallLook(LookReference, fade: Double?)
    case saveLook(name: String, selector: FixtureSelector)
    /// Duplicates an existing look under an optional new name.
    case copyLook(LookReference, newName: String?)
    case startEffect(EffectInstance)
    /// Updates parameters of a specific effect (by id) or effects targeting `selector`.
    case setEffectParameters(effectID: UUID?, selector: FixtureSelector, params: EffectParameters)
    case stopEffects(FixtureSelector)
    case stopAllEffects
    case setMusicMode(enabled: Bool, mood: MusicMood?)
    /// Sets whether matched fixtures are protected from effects, music mode, and remote changes.
    case setFixtureProtection(FixtureSelector, Bool)
    /// Toggles studio recording mode (locks key/fill, prevents flashing, makes remote read-only).
    case setRecordingMode(Bool)
    /// Holds (freezes) or unfreezes live DMX output.
    case freeze(Bool)
    /// Swaps colors between two selectors, or across the fixtures matched by a single selector.
    case swapColors(FixtureSelector, FixtureSelector?)
    case setGrandMaster(Double)
    case setBlackout(Bool)
    case identify(FixtureSelector)
    /// Applies a fade time to subsequent changes in this batch (seconds).
    case fadeTime(Double)

    // MARK: Shared Nudge Constants

    /// "a little" = 5% (0.05)
    public static let nudgeALittle: Double = NudgeAmount.little
    /// "a bit" = 10% (0.10)
    public static let nudgeABit: Double = NudgeAmount.bit
    /// "a lot" = 25% (0.25)
    public static let nudgeALot: Double = NudgeAmount.lot

    /// Kelvin nudge equivalents: 200K, 400K, 1000K.
    public static let kelvinNudgeALittle: Double = NudgeAmount.kelvinLittle
    public static let kelvinNudgeABit: Double = NudgeAmount.kelvinBit
    public static let kelvinNudgeALot: Double = NudgeAmount.kelvinLot

    /// Tint nudge equivalents (-1…+1 scale): 0.05, 0.10, 0.25.
    public static let tintNudgeALittle: Double = NudgeAmount.tintLittle
    public static let tintNudgeABit: Double = NudgeAmount.tintBit
    public static let tintNudgeALot: Double = NudgeAmount.tintLot

    // MARK: Convenience Factories

    public static func setCells(_ selector: FixtureSelector, _ cells: [CellState]) -> LightingCommand {
        .setCells(selector, cells: cells)
    }

    public static func setCells(_ selector: FixtureSelector, colors: [LightColor]) -> LightingCommand {
        .setCells(selector, cells: colors.map { CellState(intensity: 1, color: $0.sanitized) })
    }

    public static func paintCells(_ selector: FixtureSelector, cellIndices: [Int], color: LightColor) -> LightingCommand {
        .paintCells(selector, cellIndices: cellIndices, color: color, intensity: nil)
    }

    public static func paintCells(_ selector: FixtureSelector, indices: [Int], color: LightColor, intensity: Double? = nil) -> LightingCommand {
        .paintCells(selector, cellIndices: indices, color: color, intensity: intensity)
    }

    public static func setEffectParameters(_ params: EffectParameters, for selector: FixtureSelector = .all) -> LightingCommand {
        .setEffectParameters(effectID: nil, selector: selector, params: params)
    }

    public static func setEffectParameters(_ selector: FixtureSelector, _ params: EffectParameters) -> LightingCommand {
        .setEffectParameters(effectID: nil, selector: selector, params: params)
    }

    public static func setEffectParameters(id: UUID, _ params: EffectParameters) -> LightingCommand {
        .setEffectParameters(effectID: id, selector: .all, params: params)
    }

    public static func setFixtureProtection(_ selector: FixtureSelector, protected: Bool) -> LightingCommand {
        .setFixtureProtection(selector, protected)
    }

    public static func swapColors(_ selector: FixtureSelector) -> LightingCommand {
        .swapColors(selector, nil)
    }

    public static func copyLook(_ look: LookReference) -> LightingCommand {
        .copyLook(look, newName: nil)
    }
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
public enum CommandOrigin: Hashable, Sendable, Codable {
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

    /// Human-readable actor attribution for the History timeline.
    public var displayName: String {
        switch self {
        case .ui: return "UI"
        case .assistant: return "Assistant"
        case .voice: return "Voice"
        case .remote(let clientID, _):
            let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Remote Guest" : "Remote (\(trimmed))"
        case .midi: return "MIDI"
        case .osc: return "OSC"
        case .http: return "HTTP API"
        case .shortcuts: return "Shortcuts"
        case .system: return "System"
        }
    }

    public var systemImage: String {
        switch self {
        case .ui: return "cursorarrow.click"
        case .assistant: return "sparkles"
        case .voice: return "waveform.and.mic"
        case .remote: return "iphone"
        case .midi: return "pianokeys"
        case .osc: return "dot.radiowaves.left.and.right"
        case .http: return "network"
        case .shortcuts: return "bolt.fill"
        case .system: return "gearshape"
        }
    }
}

/// Result of applying commands, for user feedback ("Warmed 4 background lights to 3800K").
public struct CommandResult: Sendable, Equatable, CustomStringConvertible {
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

    public var description: String { summary }
}

// MARK: - Codable (JSON form used by the remote protocol, OSC/HTTP and AI tool calls)

extension LightingCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case op, target, secondaryTarget, value, color, toward, amount, colors, axis, look, fade, name,
             effect, effectID, params, enabled, mood, cells, cellIndices, intensity
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
        case "setCells":
            let decodedCells: [CellState]
            if let cs = try c.decodeIfPresent([CellState].self, forKey: .cells) {
                decodedCells = Array(cs.prefix(1024)).map { CellState(intensity: clamp01($0.intensity.finiteOr(1)), color: $0.color.sanitized) }
            } else if let cols = try c.decodeIfPresent([LightColor].self, forKey: .colors) {
                decodedCells = Array(cols.prefix(1024)).map { CellState(intensity: 1, color: $0.sanitized) }
            } else {
                decodedCells = []
            }
            self = .setCells(try target(), cells: decodedCells)
        case "paintCells":
            let indices = Array((try c.decodeIfPresent([Int].self, forKey: .cellIndices) ?? []).prefix(1024)).filter { $0 >= 0 && $0 < 1024 }
            let col = (try c.decodeIfPresent(LightColor.self, forKey: .color) ?? .white).sanitized
            let rawInt = try c.decodeIfPresent(Double.self, forKey: .intensity) ?? (try c.decodeIfPresent(Double.self, forKey: .value))
            let clampedInt = rawInt.map { clamp01($0.finiteOr(1)) }
            self = .paintCells(try target(), cellIndices: indices, color: col, intensity: clampedInt)
        case "turnOn": self = .turnOn(try target())
        case "turnOff": self = .turnOff(try target())
        case "recallLook":
            self = .recallLook(try c.decodeIfPresent(LookReference.self, forKey: .look) ?? .name(""),
                               fade: try c.decodeIfPresent(Double.self, forKey: .fade).map { clamp($0.finiteOr(1), 0, 600) })
        case "saveLook": self = .saveLook(name: try c.decodeIfPresent(String.self, forKey: .name) ?? "New Look", selector: try target())
        case "copyLook":
            self = .copyLook(try c.decodeIfPresent(LookReference.self, forKey: .look) ?? .name(""),
                             newName: try c.decodeIfPresent(String.self, forKey: .name))
        case "startEffect":
            guard let e = try c.decodeIfPresent(EffectInstance.self, forKey: .effect) else {
                throw DecodingError.dataCorruptedError(forKey: .effect, in: c, debugDescription: "missing effect")
            }
            self = .startEffect(e)
        case "setEffectParameters":
            let eid = try c.decodeIfPresent(UUID.self, forKey: .effectID)
            let p = (try c.decodeIfPresent(EffectParameters.self, forKey: .params) ?? EffectParameters()).sanitized
            self = .setEffectParameters(effectID: eid, selector: try target(), params: p)
        case "stopEffects": self = .stopEffects(try target())
        case "stopAllEffects": self = .stopAllEffects
        case "setMusicMode":
            self = .setMusicMode(enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
                                 mood: try c.decodeIfPresent(MusicMood.self, forKey: .mood))
        case "setFixtureProtection":
            self = .setFixtureProtection(try target(), try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true)
        case "setRecordingMode":
            self = .setRecordingMode(try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true)
        case "freeze":
            self = .freeze(try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true)
        case "swapColors":
            self = .swapColors(try target(), try c.decodeIfPresent(FixtureSelector.self, forKey: .secondaryTarget))
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
        case .setCells(let t, let cells):
            try c.encode("setCells", forKey: .op); try c.encode(t, forKey: .target); try c.encode(cells, forKey: .cells)
        case .paintCells(let t, let indices, let col, let intensity):
            try c.encode("paintCells", forKey: .op); try c.encode(t, forKey: .target)
            try c.encode(indices, forKey: .cellIndices); try c.encode(col, forKey: .color)
            try c.encodeIfPresent(intensity, forKey: .intensity)
        case .turnOn(let t): try c.encode("turnOn", forKey: .op); try c.encode(t, forKey: .target)
        case .turnOff(let t): try c.encode("turnOff", forKey: .op); try c.encode(t, forKey: .target)
        case .recallLook(let ref, let fade): try c.encode("recallLook", forKey: .op); try c.encode(ref, forKey: .look); try c.encodeIfPresent(fade, forKey: .fade)
        case .saveLook(let name, let t): try c.encode("saveLook", forKey: .op); try c.encode(name, forKey: .name); try c.encode(t, forKey: .target)
        case .copyLook(let ref, let newName):
            try c.encode("copyLook", forKey: .op); try c.encode(ref, forKey: .look); try c.encodeIfPresent(newName, forKey: .name)
        case .startEffect(let e): try c.encode("startEffect", forKey: .op); try c.encode(e, forKey: .effect)
        case .setEffectParameters(let eid, let t, let p):
            try c.encode("setEffectParameters", forKey: .op); try c.encodeIfPresent(eid, forKey: .effectID)
            try c.encode(t, forKey: .target); try c.encode(p, forKey: .params)
        case .stopEffects(let t): try c.encode("stopEffects", forKey: .op); try c.encode(t, forKey: .target)
        case .stopAllEffects: try c.encode("stopAllEffects", forKey: .op)
        case .setMusicMode(let enabled, let mood): try c.encode("setMusicMode", forKey: .op); try c.encode(enabled, forKey: .enabled); try c.encodeIfPresent(mood, forKey: .mood)
        case .setFixtureProtection(let t, let b): try c.encode("setFixtureProtection", forKey: .op); try c.encode(t, forKey: .target); try c.encode(b, forKey: .enabled)
        case .setRecordingMode(let b): try c.encode("setRecordingMode", forKey: .op); try c.encode(b, forKey: .enabled)
        case .freeze(let b): try c.encode("freeze", forKey: .op); try c.encode(b, forKey: .enabled)
        case .swapColors(let a, let b): try c.encode("swapColors", forKey: .op); try c.encode(a, forKey: .target); try c.encodeIfPresent(b, forKey: .secondaryTarget)
        case .setGrandMaster(let v): try c.encode("setGrandMaster", forKey: .op); try c.encode(v, forKey: .value)
        case .setBlackout(let b): try c.encode("setBlackout", forKey: .op); try c.encode(b, forKey: .enabled)
        case .identify(let t): try c.encode("identify", forKey: .op); try c.encode(t, forKey: .target)
        case .fadeTime(let v): try c.encode("fadeTime", forKey: .op); try c.encode(v, forKey: .value)
        }
    }
}

public extension FixtureSelector {
    /// Convenience selector for a single fixture ID.
    static func id(_ id: UUID) -> FixtureSelector { .fixtures([id]) }
    /// Convenience selector for a list of fixture IDs.
    static func ids(_ ids: [UUID]) -> FixtureSelector { .fixtures(ids) }
}

public extension LightColor {
    /// Correlated color temperature in Kelvin.
    var kelvinEquivalent: Double { approximateKelvin.kelvin }
}

