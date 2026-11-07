import Foundation

/// Which lights a request is about, as the user described them (before binding to a rig).
public indirect enum TargetSpec: Hashable, Sendable {
    /// "everything", "all the lights".
    case everything
    /// Nothing was said — the planner uses the lights from the last request, else everything.
    case unspecified
    /// "it", "them", "those" — the lights from the last request.
    case previous
    /// "the rest", "everything else" — all lights not mentioned elsewhere in the request.
    case rest
    /// "these", "the selected lights" — the current selection.
    case selection
    case role(FixtureRole)
    case category(FixtureCategory)
    case area(SpatialArea)
    /// A fixture label ("B3", "PN1").
    case label(String)
    /// A fixture or group name as spoken ("round light", "floor tubes").
    case name(String)
    /// One light only ("the left tube") — the planner picks the best match or asks.
    case single(TargetSpec)
    /// Intersection ("the left tubes" = left ∧ tubes).
    case all([TargetSpec])
    /// Union ("the key and the fill").
    case any([TargetSpec])
    /// "everything except the key".
    case except(TargetSpec, TargetSpec)

    /// Broad targets never include the key, fill or protected lights.
    public var isBroad: Bool {
        switch self {
        case .everything, .unspecified, .rest, .area, .category: return true
        case .previous, .selection, .role, .label, .name: return false
        case .single(let t): return t.isBroad
        case .all(let items): return items.allSatisfy { $0.isBroad }
        case .any(let items): return items.contains { $0.isBroad }
        case .except(let base, _): return base.isBroad
        }
    }

    /// Spatial areas mentioned.
    public var areas: [SpatialArea] {
        switch self {
        case .area(let a): return [a]
        case .single(let t): return t.areas
        case .all(let items), .any(let items): return items.flatMap(\.areas)
        case .except(let base, _): return base.areas
        default: return []
        }
    }

    /// Left and right swapped ("no, the other side").
    public var mirrored: TargetSpec {
        switch self {
        case .area(let a): return .area(a.mirrored)
        case .single(let t): return .single(t.mirrored)
        case .all(let items): return .all(items.map(\.mirrored))
        case .any(let items): return .any(items.map(\.mirrored))
        case .except(let a, let b): return .except(a.mirrored, b.mirrored)
        default: return self
        }
    }

    /// True when the target is purely spatial (possibly narrowed by a type/role) — used to detect scenes.
    public var isSpatial: Bool {
        switch self {
        case .area: return true
        case .single(let t): return t.isSpatial
        case .all(let items): return items.contains { $0.isSpatial }
        default: return false
        }
    }

    /// Plain-English description ("the left tubes", "the key", "everything").
    public var phrase: String {
        switch self {
        case .everything, .unspecified: return "everything"
        case .previous: return "the same lights"
        case .rest: return "the rest"
        case .selection: return "the selected lights"
        case .role(let r): return "the \(TargetSpec.roleWord(r))"
        case .category(let c): return "the \(TargetSpec.categoryWord(c))"
        case .area(let a): return "the \(a.displayName)"
        case .label(let l): return l.uppercased()
        case .name(let n): return n
        case .single(let t):
            let p = t.phrase
            return p.hasSuffix("s") && !p.hasSuffix("ss") ? String(p.dropLast()) : p
        case .all(let items):
            let areas = items.compactMap { item -> String? in if case .area(let a) = item { return a.displayName }; return nil }
            let heads = items.compactMap { item -> String? in
                switch item {
                case .role(let r): return TargetSpec.roleWord(r)
                case .category(let c): return TargetSpec.categoryWord(c)
                default: return nil
                }
            }
            if !heads.isEmpty { return "the " + (areas + heads).joined(separator: " ") }
            return "the " + areas.joined(separator: " ")
        case .any(let items):
            let parts = items.map(\.phrase)
            if parts.count <= 1 { return parts.first ?? "everything" }
            return parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
        case .except(let a, let b):
            return "\(a.phrase) except \(b.phrase)"
        }
    }

    static func roleWord(_ r: FixtureRole) -> String {
        switch r {
        case .back: return "back light"
        case .hair: return "hair light"
        case .practical: return "practicals"
        case .background: return "background"
        case .accent: return "accent lights"
        case .ambient: return "ambient lights"
        case .effect: return "effect lights"
        default: return r.displayName.lowercased()
        }
    }

    static func categoryWord(_ c: FixtureCategory) -> String {
        switch c {
        case .tube: return "tubes"
        case .panel: return "panels"
        case .spot: return "spots"
        case .fresnel: return "fresnels"
        case .par: return "pars"
        case .bulb: return "bulbs"
        case .strip: return "strips"
        case .bar: return "bars"
        case .wash: return "washes"
        case .movingHead: return "moving heads"
        case .dimmer: return "dimmers"
        case .effect: return "effect lights"
        case .other: return "lights"
        }
    }
}

/// How much to change something.
public enum AmountSpec: Hashable, Sendable, Codable {
    /// "a little" / "a bit" / "a lot" — the engine's shared nudge sizes.
    case nudge(NudgeAmount)
    /// An explicit intensity step (0…1), e.g. "by 20%".
    case percent(Double)
    /// An explicit colour-temperature step, e.g. "by 500K".
    case kelvin(Double)
    /// Photographic stops ("2 stops").
    case stops(Double)

    /// No amount said: a bit.
    public static let standard = AmountSpec.nudge(.aBit)

    /// Half this amount ("too much" undoes about half).
    public var halved: AmountSpec {
        switch self {
        case .nudge(let n):
            switch n {
            case .aLot: return .nudge(.aBit)
            case .aBit, .aLittle: return .nudge(.aLittle)
            }
        case .percent(let p): return .percent(p / 2)
        case .kelvin(let k): return .kelvin(k / 2)
        case .stops(let s): return .stops(s / 2)
        }
    }

    /// Intensity delta (0…1).
    public var intensityDelta: Double {
        switch self {
        case .nudge(let n): return n.fraction
        case .percent(let p): return clamp(p.finiteOr(0.1), 0, 1)
        case .kelvin: return NudgeAmount.bit
        case .stops(let s): return clamp(abs(s.finiteOr(0.5)) * 0.15, 0, 1)
        }
    }

    /// Colour-temperature delta in Kelvin.
    public var kelvinDelta: Double {
        switch self {
        case .nudge(let n): return n.kelvin
        case .kelvin(let k): return clamp(abs(k.finiteOr(400)), 0, 10000)
        case .percent(let p): return clamp(p.finiteOr(0.1), 0, 1) * 4000
        case .stops: return NudgeAmount.kelvinBit
        }
    }

    /// Tint delta (−1…1 scale).
    public var tintDelta: Double {
        switch self {
        case .nudge(let n): return n.tint
        case .percent(let p): return clamp(p.finiteOr(0.1), 0, 1)
        default: return NudgeAmount.tintBit
        }
    }

    /// Saturation delta (0…1).
    public var saturationDelta: Double {
        switch self {
        case .nudge(let n):
            switch n {
            case .aLittle: return 0.1
            case .aBit: return 0.2
            case .aLot: return 0.4
            }
        case .percent(let p): return clamp(p.finiteOr(0.2), 0, 1)
        default: return 0.2
        }
    }

    /// How far to mix toward a colour ("a bit more blue").
    public var colorShift: Double {
        switch self {
        case .nudge(let n):
            switch n {
            case .aLittle: return 0.15
            case .aBit: return 0.25
            case .aLot: return 0.5
            }
        case .percent(let p): return clamp(p.finiteOr(0.25), 0, 1)
        default: return 0.25
        }
    }

    /// Words for summaries ("a little", "a bit", "a lot", "20%").
    public var phrase: String {
        switch self {
        case .nudge(let n):
            switch n {
            case .aLittle: return "a little"
            case .aBit: return "a bit"
            case .aLot: return "a lot"
            }
        case .percent(let p): return "by \(Int((p * 100).rounded()))%"
        case .kelvin(let k): return "by \(Int(k.rounded()))K"
        case .stops(let s):
            let v = abs(s)
            return v == 1 ? "by a stop" : "by \(AmountSpec.trim(v)) stops"
        }
    }

    static func trim(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

/// One zone of a scene request ("teal on the left").
public struct SceneZone: Hashable, Sendable {
    public var target: TargetSpec
    public var color: ColorSpec

    public init(target: TargetSpec, color: ColorSpec) {
        self.target = target; self.color = color
    }
}

/// Questions the assistant can answer.
public enum AssistantQuery: Hashable, Sendable {
    /// "What's on?"
    case whatsOn
    /// "What can you do?"
    case help
    /// "How bright is the key?" / "What colour is the background?"
    case state(TargetSpec)
}

/// One thing the user asked for, before it is bound to the rig.
public enum ParsedAction: Hashable, Sendable {
    case adjustIntensity(TargetSpec, direction: Int, amount: AmountSpec)
    case setIntensity(TargetSpec, level: Double)
    case scaleStops(TargetSpec, stops: Double)
    case turnOn(TargetSpec)
    case turnOff(TargetSpec)
    case setColor(TargetSpec, [ColorSpec])
    case shiftColor(TargetSpec, toward: ColorSpec, amount: AmountSpec)
    case reduceColor(TargetSpec, ColorSpec, amount: AmountSpec)
    /// +1 = warmer, −1 = cooler.
    case adjustWarmth(TargetSpec, direction: Int, amount: AmountSpec)
    case setKelvin(TargetSpec, kelvin: Double)
    /// +1 = toward magenta, −1 = toward green.
    case adjustTint(TargetSpec, direction: Int, amount: AmountSpec)
    case adjustSaturation(TargetSpec, direction: Int, amount: AmountSpec)
    case gradient(TargetSpec, [ColorSpec])
    case scene([SceneZone])
    case blackout(Bool)
    /// "Lights back on": releases blackout and turns on lights that are off.
    case lightsOn
    case recallLook(String)
    case saveLook(String?)
    case startEffect(EffectKind, TargetSpec, speed: Double?)
    case stopEffects(TargetSpec?)
    case music(enabled: Bool, mood: MusicMood?)
    case identify(TargetSpec)
    case swapColors(TargetSpec?, TargetSpec?)
    case freeze(Bool)
    case recordingMode(Bool)
    case grandMaster(Double)
    case undo
    case redo
    case query(AssistantQuery)
    /// Follow-up: do the last change again ("a bit more"), optionally on other lights.
    case more(AmountSpec?, TargetSpec?)
    /// Follow-up: take back part of the last change ("too much").
    case less(AmountSpec?)
    /// Correction: the same change on the opposite side ("no, the other side").
    case otherSide
    /// Correction: the same change on different lights ("no, the fill").
    case retarget(TargetSpec)
    /// Correction: the same lights in a different colour ("actually, pink").
    case recolor([ColorSpec])
    /// Follow-up: the same change on more lights ("the right too").
    case repeatOn(TargetSpec)
    /// "Thanks", "perfect".
    case acknowledge
    /// Only lights were named ("the key") — ask what to do with them.
    case clarifyTarget(TargetSpec)

    /// The lights this action targets, when it has them.
    public var target: TargetSpec? {
        switch self {
        case .adjustIntensity(let t, _, _), .setIntensity(let t, _), .scaleStops(let t, _), .turnOn(let t), .turnOff(let t),
             .setColor(let t, _), .shiftColor(let t, _, _), .reduceColor(let t, _, _), .adjustWarmth(let t, _, _),
             .setKelvin(let t, _), .adjustTint(let t, _, _), .adjustSaturation(let t, _, _), .gradient(let t, _),
             .startEffect(_, let t, _), .identify(let t), .clarifyTarget(let t), .retarget(let t), .repeatOn(let t):
            return t
        case .stopEffects(let t): return t
        default: return nil
        }
    }

    /// The same action aimed at different lights.
    public func retargeted(_ t: TargetSpec) -> ParsedAction {
        switch self {
        case .adjustIntensity(_, let d, let a): return .adjustIntensity(t, direction: d, amount: a)
        case .setIntensity(_, let l): return .setIntensity(t, level: l)
        case .scaleStops(_, let s): return .scaleStops(t, stops: s)
        case .turnOn: return .turnOn(t)
        case .turnOff: return .turnOff(t)
        case .setColor(_, let c): return .setColor(t, c)
        case .shiftColor(_, let c, let a): return .shiftColor(t, toward: c, amount: a)
        case .reduceColor(_, let c, let a): return .reduceColor(t, c, amount: a)
        case .adjustWarmth(_, let d, let a): return .adjustWarmth(t, direction: d, amount: a)
        case .setKelvin(_, let k): return .setKelvin(t, kelvin: k)
        case .adjustTint(_, let d, let a): return .adjustTint(t, direction: d, amount: a)
        case .adjustSaturation(_, let d, let a): return .adjustSaturation(t, direction: d, amount: a)
        case .gradient(_, let c): return .gradient(t, c)
        case .startEffect(let k, _, let s): return .startEffect(k, t, speed: s)
        case .stopEffects: return .stopEffects(t)
        case .identify: return .identify(t)
        case .clarifyTarget: return .clarifyTarget(t)
        default: return self
        }
    }

    /// True for relative changes that "a bit more" / "too much" can repeat or soften.
    public var isRelative: Bool {
        switch self {
        case .adjustIntensity, .shiftColor, .reduceColor, .adjustWarmth, .adjustTint, .adjustSaturation, .scaleStops: return true
        default: return false
        }
    }

    /// The opposite relative change ("too much" after "warmer" → a little cooler).
    public func inverted(amount: AmountSpec?) -> ParsedAction? {
        switch self {
        case .adjustIntensity(let t, let d, let a): return .adjustIntensity(t, direction: -d, amount: amount ?? a.halved)
        case .adjustWarmth(let t, let d, let a): return .adjustWarmth(t, direction: -d, amount: amount ?? a.halved)
        case .adjustTint(let t, let d, let a): return .adjustTint(t, direction: -d, amount: amount ?? a.halved)
        case .adjustSaturation(let t, let d, let a): return .adjustSaturation(t, direction: -d, amount: amount ?? a.halved)
        case .shiftColor(let t, let c, let a): return .reduceColor(t, c, amount: amount ?? a.halved)
        case .reduceColor(let t, let c, let a): return .shiftColor(t, toward: c, amount: amount ?? a.halved)
        case .scaleStops(let t, let s): return .scaleStops(t, stops: -s / 2)
        default: return nil
        }
    }

    /// The same relative change with a different amount ("a lot more").
    public func withAmount(_ amount: AmountSpec?) -> ParsedAction {
        guard let amount else { return self }
        switch self {
        case .adjustIntensity(let t, let d, _): return .adjustIntensity(t, direction: d, amount: amount)
        case .adjustWarmth(let t, let d, _): return .adjustWarmth(t, direction: d, amount: amount)
        case .adjustTint(let t, let d, _): return .adjustTint(t, direction: d, amount: amount)
        case .adjustSaturation(let t, let d, _): return .adjustSaturation(t, direction: d, amount: amount)
        case .shiftColor(let t, let c, _): return .shiftColor(t, toward: c, amount: amount)
        case .reduceColor(let t, let c, _): return .reduceColor(t, c, amount: amount)
        default: return self
        }
    }
}

/// The parser's understanding of one utterance.
public struct ParsedRequest: Hashable, Sendable {
    /// What the user typed or said.
    public var text: String
    /// Normalized tokens after the wake phrase was removed.
    public var tokens: [String]
    public var actions: [ParsedAction]
    /// "slowly", "over 5 seconds" (nil = default fade).
    public var fadeSeconds: Double?
    /// The wake phrase that started the utterance, if any.
    public var wakePhrase: WakePhraseMatcher.Match?
    /// The utterance began with "no" / "actually" — it corrects the last change.
    public var isCorrection: Bool
    /// Words the parser could not use (for "I didn't catch …").
    public var unknownWords: [String]

    public init(text: String, tokens: [String] = [], actions: [ParsedAction] = [], fadeSeconds: Double? = nil,
                wakePhrase: WakePhraseMatcher.Match? = nil, isCorrection: Bool = false, unknownWords: [String] = []) {
        self.text = text; self.tokens = tokens; self.actions = actions; self.fadeSeconds = fadeSeconds
        self.wakePhrase = wakePhrase; self.isCorrection = isCorrection; self.unknownWords = unknownWords
    }

    /// True when nothing actionable was understood.
    public var isEmpty: Bool { actions.isEmpty }
}
