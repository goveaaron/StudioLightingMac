import Foundation

/// Compact zero-allocation storage for the 13 emitter channel kinds used in the render hot path.
public struct EmitterLevels: Sendable, Hashable {
    public var red: Double = 0
    public var green: Double = 0
    public var blue: Double = 0
    public var white: Double = 0
    public var warmWhite: Double = 0
    public var coolWhite: Double = 0
    public var amber: Double = 0
    public var lime: Double = 0
    public var cyan: Double = 0
    public var magenta: Double = 0
    public var yellow: Double = 0
    public var uv: Double = 0
    public var indigo: Double = 0

    public init() {}

    @inline(__always)
    public subscript(kind: ChannelKind) -> Double {
        get {
            switch kind {
            case .red: return red
            case .green: return green
            case .blue: return blue
            case .white: return white
            case .warmWhite: return warmWhite
            case .coolWhite: return coolWhite
            case .amber: return amber
            case .lime: return lime
            case .cyan: return cyan
            case .magenta: return magenta
            case .yellow: return yellow
            case .uv: return uv
            case .indigo: return indigo
            default: return 0
            }
        }
        set {
            switch kind {
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            case .white: white = newValue
            case .warmWhite: warmWhite = newValue
            case .coolWhite: coolWhite = newValue
            case .amber: amber = newValue
            case .lime: lime = newValue
            case .cyan: cyan = newValue
            case .magenta: magenta = newValue
            case .yellow: yellow = newValue
            case .uv: uv = newValue
            case .indigo: indigo = newValue
            default: break
            }
        }
    }

    @inline(__always)
    public var maxLevel: Double {
        max(
            max(max(red, green), max(blue, white)),
            max(
                max(max(warmWhite, coolWhite), max(amber, lime)),
                max(max(cyan, magenta), max(yellow, max(uv, indigo)))
            )
        )
    }

    @inline(__always)
    public mutating func normalize() {
        let m = maxLevel
        guard m > 1e-9 else { return }
        let inv = 1.0 / m
        red *= inv
        green *= inv
        blue *= inv
        white *= inv
        warmWhite *= inv
        coolWhite *= inv
        amber *= inv
        lime *= inv
        cyan *= inv
        magenta *= inv
        yellow *= inv
        uv *= inv
        indigo *= inv
    }

    /// Multiplies every level by the matching level of `gains` (per-emitter calibration trims).
    @inline(__always)
    public mutating func multiply(by gains: EmitterLevels) {
        red *= gains.red
        green *= gains.green
        blue *= gains.blue
        white *= gains.white
        warmWhite *= gains.warmWhite
        coolWhite *= gains.coolWhite
        amber *= gains.amber
        lime *= gains.lime
        cyan *= gains.cyan
        magenta *= gains.magenta
        yellow *= gains.yellow
        uv *= gains.uv
        indigo *= gains.indigo
    }

    public func toDictionary(for emitters: Set<ChannelKind>) -> [ChannelKind: Double] {
        var out: [ChannelKind: Double] = [:]
        out.reserveCapacity(emitters.count)
        for kind in emitters where kind.isEmitter {
            out[kind] = self[kind]
        }
        return out
    }
}

extension EmitterLevels {
    /// Every level = 1 (identity gains).
    static let unity: EmitterLevels = {
        var l = EmitterLevels()
        for kind in EmitterMixer.allEmitterKinds { l[kind] = 1 }
        return l
    }()

    /// Clamps every level to 0…1 (NaN → 0) and, when `applyGamma` is set, raises it to `gamma`.
    @inline(__always)
    mutating func clampAndApplyGamma(_ gamma: Double, applyGamma: Bool) {
        red = EmitterLevels.shape(red, gamma, applyGamma)
        green = EmitterLevels.shape(green, gamma, applyGamma)
        blue = EmitterLevels.shape(blue, gamma, applyGamma)
        white = EmitterLevels.shape(white, gamma, applyGamma)
        warmWhite = EmitterLevels.shape(warmWhite, gamma, applyGamma)
        coolWhite = EmitterLevels.shape(coolWhite, gamma, applyGamma)
        amber = EmitterLevels.shape(amber, gamma, applyGamma)
        lime = EmitterLevels.shape(lime, gamma, applyGamma)
        cyan = EmitterLevels.shape(cyan, gamma, applyGamma)
        magenta = EmitterLevels.shape(magenta, gamma, applyGamma)
        yellow = EmitterLevels.shape(yellow, gamma, applyGamma)
        uv = EmitterLevels.shape(uv, gamma, applyGamma)
        indigo = EmitterLevels.shape(indigo, gamma, applyGamma)
    }

    @inline(__always)
    private static func shape(_ v: Double, _ gamma: Double, _ applyGamma: Bool) -> Double {
        let c = clamp01(v)
        guard applyGamma, c > 0, c < 1 else { return c }
        return pow(c, gamma)
    }
}

/// Bitmask of emitter `ChannelKind`s for zero-allocation hot-path checks.
public struct EmitterMask: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let red       = EmitterMask(rawValue: 1 << 0)
    public static let green     = EmitterMask(rawValue: 1 << 1)
    public static let blue      = EmitterMask(rawValue: 1 << 2)
    public static let white     = EmitterMask(rawValue: 1 << 3)
    public static let warmWhite = EmitterMask(rawValue: 1 << 4)
    public static let coolWhite = EmitterMask(rawValue: 1 << 5)
    public static let amber     = EmitterMask(rawValue: 1 << 6)
    public static let lime      = EmitterMask(rawValue: 1 << 7)
    public static let cyan      = EmitterMask(rawValue: 1 << 8)
    public static let magenta   = EmitterMask(rawValue: 1 << 9)
    public static let yellow    = EmitterMask(rawValue: 1 << 10)
    public static let uv        = EmitterMask(rawValue: 1 << 11)
    public static let indigo    = EmitterMask(rawValue: 1 << 12)

    public static let rgb: EmitterMask = [.red, .green, .blue]
    public static let cmy: EmitterMask = [.cyan, .magenta, .yellow]

    @inline(__always)
    public static func bit(for kind: ChannelKind) -> EmitterMask {
        switch kind {
        case .red: return .red
        case .green: return .green
        case .blue: return .blue
        case .white: return .white
        case .warmWhite: return .warmWhite
        case .coolWhite: return .coolWhite
        case .amber: return .amber
        case .lime: return .lime
        case .cyan: return .cyan
        case .magenta: return .magenta
        case .yellow: return .yellow
        case .uv: return .uv
        case .indigo: return .indigo
        default: return []
        }
    }

    public init(emitters: Set<ChannelKind>) {
        var mask: EmitterMask = []
        for k in emitters {
            mask.insert(EmitterMask.bit(for: k))
        }
        self = mask
    }
}

// MARK: - Emitter bases and per-definition profiles

/// Linear-light output (sRGB primaries, D65 white) of each emitter kind at full drive.
struct EmitterBases: Sendable {
    var red = LinearRGB(r: 1, g: 0, b: 0)
    var green = LinearRGB(r: 0, g: 1, b: 0)
    var blue = LinearRGB(r: 0, g: 0, b: 1)
    var white = EmitterBases.defaultWhite
    var warmWhite = EmitterBases.defaultWarmWhite
    var coolWhite = EmitterBases.defaultCoolWhite
    /// ~590 nm amber LED.
    var amber = LinearRGB(r: 1.0, g: 0.395, b: 0.0)
    /// ~555 nm lime (phosphor-converted green-yellow) LED.
    var lime = LinearRGB(r: 0.505, g: 1.0, b: 0.046)
    /// ~500 nm cyan LED.
    var cyan = LinearRGB(r: 0.0, g: 0.85, b: 1.0)
    var magenta = LinearRGB(r: 1.0, g: 0.075, b: 0.785)
    var yellow = LinearRGB(r: 0.92, g: 1.0, b: 0.03)
    var uv = LinearRGB(r: 0.24, g: 0.0, b: 1.0)
    var indigo = LinearRGB(r: 0.16, g: 0.0, b: 1.0)

    static let defaultWhite = ColorMath.xyToLinearSRGB(x: 0.330, y: 0.340).normalized
    static let defaultWarmWhite = ColorMath.xyToLinearSRGB(x: 0.460, y: 0.411).normalized
    static let defaultCoolWhite = ColorMath.xyToLinearSRGB(x: 0.313, y: 0.329).normalized

    static let standard = EmitterBases()

    @inline(__always)
    subscript(kind: ChannelKind) -> LinearRGB {
        get {
            switch kind {
            case .red: return red
            case .green: return green
            case .blue: return blue
            case .white: return white
            case .warmWhite: return warmWhite
            case .coolWhite: return coolWhite
            case .amber: return amber
            case .lime: return lime
            case .cyan: return cyan
            case .magenta: return magenta
            case .yellow: return yellow
            case .uv: return uv
            case .indigo: return indigo
            default: return .black
            }
        }
        set {
            switch kind {
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            case .white: white = newValue
            case .warmWhite: warmWhite = newValue
            case .coolWhite: coolWhite = newValue
            case .amber: amber = newValue
            case .lime: lime = newValue
            case .cyan: cyan = newValue
            case .magenta: magenta = newValue
            case .yellow: yellow = newValue
            case .uv: uv = newValue
            case .indigo: indigo = newValue
            default: break
            }
        }
    }
}

/// Everything the mixer needs to know about one set of emitters, computed once per distinct
/// `[ChannelKind: EmitterSpec]` (i.e. once per fixture definition) and shared immutably.
///
/// The accurate solver works in a "fixture RGB" space `K = diag(1/g)·M⁻¹`, where `M` holds the
/// fixture's R/G/B emitters as columns and `g = M⁻¹·(1,1,1)` is the drive needed for D65 white,
/// so equal amounts of the three primaries are always white. With standard (sRGB) primaries
/// `K` is the identity and nothing changes.
final class MixerProfile: Sendable {
    /// Physical linear-light output of each emitter at full drive (used for NNLS and ΔE checks).
    let linear: EmitterBases
    /// Emitter outputs expressed in the solver's fixture-RGB space (`K · linear`).
    let solver: EmitterBases
    /// True when the definition supplied its own R, G or B chromaticities.
    let customPrimaries: Bool
    /// Rows of `K` (maps linear sRGB into fixture-RGB space).
    let kRow0: LinearRGB
    let kRow1: LinearRGB
    let kRow2: LinearRGB
    /// Per-primary drive needed for D65 white (fixture-RGB amount × gain = R/G/B drive level).
    let driveGain: LinearRGB
    /// Relative luminance of each fixture primary in fixture-RGB space (sums to 1).
    let lumaWeights: LinearRGB
    /// Nominal CCT of the warm-white, white and cool-white emitters.
    let warmWhiteK: Double
    let whiteK: Double
    let coolWhiteK: Double

    /// Profile for fixtures without `emitters` specs (sRGB primaries and stock LED bases).
    static let standard = MixerProfile(specs: nil)

    private static let cache = Locked<[[ChannelKind: EmitterSpec]: MixerProfile]>([:])

    /// The (cached) profile for a definition's emitter specs. `nil` or empty → `standard`.
    static func profile(for specs: [ChannelKind: EmitterSpec]?) -> MixerProfile {
        guard let specs, !specs.isEmpty else { return standard }
        if let hit = cache.mutate({ $0[specs] }) { return hit }
        let made = MixerProfile(specs: specs)
        cache.mutate { c in
            if c.count >= 64 { c.removeAll(keepingCapacity: true) }
            c[specs] = made
        }
        return made
    }

    private struct ModeKey: Hashable {
        let definitionID: String
        let modeName: String
        let specHash: Int
    }

    private static let modeCache = Locked<[ModeKey: MixerProfile]>([:])

    /// Profile for a mode whose channels carry their own `emitter` specs (merged over the
    /// definition's `emitters`). `specHash` must cover the channel specs and the definition's
    /// specs so edited definitions never reuse a stale profile.
    static func profile(definition: FixtureDefinition, mode: FixtureMode, specHash: Int) -> MixerProfile {
        let key = ModeKey(definitionID: definition.id, modeName: mode.name, specHash: specHash)
        if let hit = modeCache.mutate({ $0[key] }) { return hit }
        var merged = definition.emitters ?? [:]
        for ch in mode.channels where ch.kind.isEmitter {
            if let spec = ch.emitter { merged[ch.kind] = spec }
        }
        let made = profile(for: merged)
        modeCache.mutate { c in
            if c.count >= 64 { c.removeAll(keepingCapacity: true) }
            c[key] = made
        }
        return made
    }

    private init(specs: [ChannelKind: EmitterSpec]?) {
        var lin = EmitterBases.standard
        var wwK = EmitterMixer.warmWhiteK
        var wK = 5600.0
        var cwK = EmitterMixer.coolWhiteK
        if let specs {
            for (kind, spec) in specs where kind.isEmitter {
                if let v = MixerProfile.linearOutput(of: spec) { lin[kind] = v }
            }
            wwK = MixerProfile.nominalKelvin(of: specs[.warmWhite], fallback: wwK)
            wK = MixerProfile.nominalKelvin(of: specs[.white], fallback: wK)
            cwK = MixerProfile.nominalKelvin(of: specs[.coolWhite], fallback: cwK)
        }
        linear = lin
        warmWhiteK = wwK
        whiteK = wK
        coolWhiteK = cwK

        var custom = false
        var r0 = LinearRGB(r: 1, g: 0, b: 0)
        var r1 = LinearRGB(r: 0, g: 1, b: 0)
        var r2 = LinearRGB(r: 0, g: 0, b: 1)
        var gain = LinearRGB(r: 1, g: 1, b: 1)
        var luma = LinearRGB(r: 0.2126729, g: 0.7151522, b: 0.0721750)
        let hasPrimarySpecs = specs.map { $0[.red] != nil || $0[.green] != nil || $0[.blue] != nil } ?? false
        if hasPrimarySpecs, let inv = MixerProfile.inverseRows(lin.red, lin.green, lin.blue) {
            let g0 = inv.0.r + inv.0.g + inv.0.b
            let g1 = inv.1.r + inv.1.g + inv.1.b
            let g2 = inv.2.r + inv.2.g + inv.2.b
            if g0 > 1e-6, g1 > 1e-6, g2 > 1e-6, g0.isFinite, g1.isFinite, g2.isFinite {
                custom = true
                r0 = inv.0 * (1 / g0)
                r1 = inv.1 * (1 / g1)
                r2 = inv.2 * (1 / g2)
                gain = LinearRGB(r: g0, g: g1, b: g2)
                let l0 = g0 * lin.red.luminance
                let l1 = g1 * lin.green.luminance
                let l2 = g2 * lin.blue.luminance
                let sum = l0 + l1 + l2
                if sum > 1e-9, l0 >= 0, l1 >= 0, l2 >= 0 {
                    luma = LinearRGB(r: l0 / sum, g: l1 / sum, b: l2 / sum)
                }
            }
        }
        customPrimaries = custom
        kRow0 = r0
        kRow1 = r1
        kRow2 = r2
        driveGain = gain
        lumaWeights = luma

        var sol = lin
        if custom {
            for kind in EmitterMixer.allEmitterKinds {
                let v = lin[kind]
                sol[kind] = LinearRGB(
                    r: r0.r * v.r + r0.g * v.g + r0.b * v.b,
                    g: r1.r * v.r + r1.g * v.g + r1.b * v.b,
                    b: r2.r * v.r + r2.g * v.g + r2.b * v.b
                )
            }
        }
        solver = sol
    }

    /// Maps linear sRGB into fixture-RGB space.
    @inline(__always)
    func toSolver(_ v: LinearRGB) -> LinearRGB {
        guard customPrimaries else { return v }
        return LinearRGB(
            r: kRow0.r * v.r + kRow0.g * v.g + kRow0.b * v.b,
            g: kRow1.r * v.r + kRow1.g * v.g + kRow1.b * v.b,
            b: kRow2.r * v.r + kRow2.g * v.g + kRow2.b * v.b
        )
    }

    /// Nominal CCT of a white emitter kind.
    @inline(__always)
    func nominalKelvin(of kind: ChannelKind) -> Double {
        switch kind {
        case .warmWhite: return warmWhiteK
        case .coolWhite: return coolWhiteK
        default: return whiteK
        }
    }

    /// Unclamped linear sRGB output of a spec (chromaticity scaled by its lumens), or nil when the
    /// spec is not physically meaningful.
    static func linearOutput(of spec: EmitterSpec) -> LinearRGB? {
        let x = spec.x, y = spec.y, lumens = spec.lumens
        guard x.isFinite, y.isFinite, lumens.isFinite,
              x >= 0, y > 0.001, x + y <= 1.0001, lumens > 0 else { return nil }
        let xyz = ColorMath.xyYToXYZ(x: x, y: y, Y: max(lumens, 0.01))
        let v = ColorMath.xyzToLinearSRGBUnclamped(X: xyz.X, Y: xyz.Y, Z: xyz.Z)
        guard v.r.isFinite, v.g.isFinite, v.b.isFinite, v.maxComponent > 1e-9 else { return nil }
        return v
    }

    private static func nominalKelvin(of spec: EmitterSpec?, fallback: Double) -> Double {
        guard let spec else { return fallback }
        if let k = spec.cctKelvin, k.isFinite, k >= 1000, k <= 25000 { return k }
        let x = spec.x, y = spec.y
        guard x.isFinite, y.isFinite, x > 0, y > 0.001, x + y <= 1.0001 else { return fallback }
        let k = ColorMath.xyToKelvinAndDuv(x: x, y: y).kelvin
        return k.isFinite && k > 0 ? k : fallback
    }

    /// Rows of the inverse of the matrix whose columns are `c0`, `c1`, `c2`, or nil if singular.
    private static func inverseRows(
        _ c0: LinearRGB, _ c1: LinearRGB, _ c2: LinearRGB
    ) -> (LinearRGB, LinearRGB, LinearRGB)? {
        let x12 = cross(c1, c2), x20 = cross(c2, c0), x01 = cross(c0, c1)
        let det = c0.r * x12.r + c0.g * x12.g + c0.b * x12.b
        guard det.isFinite, abs(det) > 1e-12 else { return nil }
        let inv = 1 / det
        return (x12 * inv, x20 * inv, x01 * inv)
    }

    @inline(__always)
    private static func cross(_ a: LinearRGB, _ b: LinearRGB) -> LinearRGB {
        LinearRGB(r: a.g * b.b - a.b * b.g, g: a.b * b.r - a.r * b.b, b: a.r * b.g - a.g * b.r)
    }
}

/// Per-render mixing constants for one fixture: emitter profile, mixing mode and calibration
/// (per-emitter gains, gamma, white-point trim). Building it is cheap and allocation-free.
struct MixPlan {
    let profile: MixerProfile
    let mode: ColorMixingMode
    private(set) var gains = EmitterLevels.unity
    private(set) var hasGains = false
    private(set) var gamma = 1.0
    private(set) var hasGamma = false
    private(set) var kelvinTrim = 0.0
    private(set) var tintTrim = 0.0
    private(set) var hasTrim = false
    /// Channel-wise white-point adaptation applied to non-Kelvin targets when a trim is set.
    private(set) var adaptation = LinearRGB.white

    /// Linear 5600 K reference white for the white-point trim.
    private static let trimReference: LinearRGB = {
        let xy = ColorMath.kelvinToXY(5600, tint: 0)
        return ColorMath.xyToLinearSRGB(x: xy.x, y: xy.y).normalized
    }()

    init(profile: MixerProfile, calibration cal: ColorCalibration, mode: ColorMixingMode) {
        self.profile = profile
        self.mode = mode
        for (key, value) in cal.gains {
            guard let kind = ChannelKind(rawValue: key), kind.isEmitter else { continue }
            let g = value.isFinite ? max(0, value) : 1
            if abs(g - 1) > 1e-9 {
                gains[kind] = g
                hasGains = true
            }
        }
        let gm = cal.gamma.isFinite ? clamp(cal.gamma, 0.1, 10) : 1
        gamma = gm
        hasGamma = abs(gm - 1) > 1e-9
        kelvinTrim = clamp(cal.whitePointKelvinTrim.finiteOr(0), -10_000, 10_000)
        tintTrim = clamp(cal.whitePointTintTrim.finiteOr(0), -1, 1)
        hasTrim = abs(kelvinTrim) > 1e-6 || abs(tintTrim) > 1e-6
        if hasTrim {
            let ref = MixPlan.trimReference
            let xy = ColorMath.kelvinToXY(clamp(5600 + kelvinTrim, 1700, 20000), tint: tintTrim)
            let shifted = ColorMath.xyToLinearSRGB(x: xy.x, y: xy.y).normalized
            adaptation = LinearRGB(
                r: shifted.r / max(ref.r, 0.05),
                g: shifted.g / max(ref.g, 0.05),
                b: shifted.b / max(ref.b, 0.05)
            )
        }
    }

    /// Applies the white-point trim to `.kelvin` colours. Other colours are adapted in `levels`.
    @inline(__always)
    func trimmed(_ color: LightColor) -> LightColor {
        guard hasTrim, case .kelvin(let k, let t) = color else { return color }
        return .kelvin(
            clamp(k.finiteOr(5600) + kelvinTrim, 1000, 25000),
            tint: clamp(t.finiteOr(0) + tintTrim, -1, 1)
        )
    }

    /// Emitter levels (0…1, calibrated) for an already-trimmed colour and its analysis.
    func levels(for color: LightColor, analysis a: ColorAnalysis, emitters: EmitterMask) -> EmitterLevels {
        guard !emitters.isEmpty, !a.isBlack else { return EmitterLevels() }
        var isKelvin = false
        var kelvin = 5600.0
        if case .kelvin(let k, _) = color {
            isKelvin = true
            kelvin = k
        }
        var target = a.linear
        if hasTrim, !isKelvin {
            target = LinearRGB(
                r: target.r * adaptation.r,
                g: target.g * adaptation.g,
                b: target.b * adaptation.b
            ).normalized
        }
        let whitesOnly = !emitters.isSuperset(of: .rgb) && emitters.isSubset(of: EmitterMixer.whiteEmitters)
        if whitesOnly, !isKelvin {
            let full = a.hasCCT ? a : ColorAnalysis.of(color, includeCCT: true)
            kelvin = full.kelvin + kelvinTrim
        }
        let solved = EmitterMixer.solve(
            target: target, color: color, analysis: a, emitters: emitters,
            profile: profile, mode: mode, kelvin: kelvin
        )
        var out = solved.levels
        if hasGains {
            out.multiply(by: gains)
            if solved.normalized { out.normalize() }
        }
        out.clampAndApplyGamma(gamma, applyGamma: hasGamma)
        return out
    }
}

// MARK: - Mixer

/// Converts a device-independent `LightColor` into emitter drive levels (`0…1`) for any LED
/// emitter topology (RGB, RGBW, RGBA, RGBWW, RGBACL, RGB+Lime, CMY, bi-color CCT, dimmer-only).
///
/// **Accurate** mode matches chromaticity exactly: it first takes as much light as possible from
/// the broadband emitters (white pairs, then amber/lime/cyan…) and covers the exact remainder with
/// R/G/B, so in-gamut colours reproduce with ΔE2000 ≈ 0 while whites and pastels come mostly from
/// the high-CRI emitters. Fixtures without a full RGB set use a small non-negative least-squares
/// solve. **Direct** mode sends the hex straight to R/G/B.
///
/// Per-definition emitter chromaticities (`FixtureDefinition.emitters`) are honoured; the derived
/// matrices are precomputed once per definition and the hot path never allocates.
public enum EmitterMixer {
    /// Nominal CCT of a standard "warm white" emitter and "cool white" emitter.
    public static let warmWhiteK = 2700.0
    public static let coolWhiteK = 6500.0

    /// Duv threshold below which a fixture switches from RGB into its native CCT white path.
    public static let nativeWhiteEnterDuv = 0.006
    /// Duv threshold above which a fixture exits its native CCT white path back to RGB (hysteresis band).
    public static let nativeWhiteExitDuv = 0.016

    /// |Duv| up to which CCT↔RGB crossfade fixtures run 100 % on their native white engine
    /// (covers the full ±1 tint range, which spans ±0.020 Duv).
    public static let nativeWhiteFullDuv = 0.0205
    /// |Duv| from which crossfade fixtures run 100 % on RGB. In between the two engines blend
    /// smoothly, so fades never pop or flicker between paths.
    public static let nativeWhiteZeroDuv = 0.028
    /// How far (in mired) outside the fixture's CCT range the native white share fades to zero.
    public static let nativeWhiteRangeFadeMired = 30.0

    static let allEmitterKinds: [ChannelKind] = [
        .red, .green, .blue, .white, .warmWhite, .coolWhite,
        .amber, .lime, .cyan, .magenta, .yellow, .uv, .indigo
    ]

    static let whiteEmitters: EmitterMask = [.white, .warmWhite, .coolWhite]

    /// White emitters ordered warm → cool (for mired blends).
    private static let whiteKinds: [ChannelKind] = [.warmWhite, .white, .coolWhite]

    // MARK: - Native White Path

    /// Share (0…1) of a CCT↔RGB crossfade fixture's output that should come from its native
    /// CCT engine for a colour with the given CCT and Duv: 1 on and near the Planckian locus and
    /// inside the fixture's CCT range, fading smoothly to 0 for saturated colours or CCTs the
    /// fixture can't make. Continuous in both inputs, so fades never jump between engines.
    public static func nativeWhiteShare(kelvin: Double, duv: Double, cctRange: ClosedRange<Double>) -> Double {
        guard kelvin.isFinite, duv.isFinite, kelvin > 0 else { return 0 }
        let duvShare = 1 - smoothstep(nativeWhiteFullDuv, nativeWhiteZeroDuv, abs(duv))
        guard duvShare > 0 else { return 0 }
        let m = 1e6 / kelvin
        let warmEdge = 1e6 / max(cctRange.lowerBound, 1)
        let coolEdge = 1e6 / max(cctRange.upperBound, 1)
        let outside = m > warmEdge ? m - warmEdge : (m < coolEdge ? coolEdge - m : 0)
        let rangeShare = 1 - smoothstep(0, nativeWhiteRangeFadeMired, outside)
        return clamp01(duvShare * rangeShare)
    }

    /// `nativeWhiteShare(kelvin:duv:cctRange:)` for a colour (0 for black).
    public static func nativeWhiteShare(for color: LightColor, cctRange: ClosedRange<Double> = 2700...10000) -> Double {
        let a = ColorAnalysis.of(color)
        guard !a.isBlack else { return 0 }
        return nativeWhiteShare(kelvin: a.kelvin, duv: a.duv, cctRange: cctRange)
    }

    /// Determines whether a fixture/cell with a `.cct` channel should use its native white path
    /// (`crossfade = 0`, driving `cct` + `tint` and zeroing RGB emitters) vs its color path (`crossfade = 1`).
    ///
    /// Used by fixtures that must *switch* engines (e.g. a colour-mode channel). Includes a
    /// hysteresis deadband (`nativeWhiteEnterDuv = 0.006` vs `nativeWhiteExitDuv = 0.016`) so
    /// crossfades and noisy inputs never flicker between paths. Crossfade fixtures blend instead
    /// (see `nativeWhiteShare`).
    public static func shouldUseNativeWhite(
        for color: LightColor,
        capabilities: ColorCapabilities,
        cctRange: ClosedRange<Double> = 2700...10000,
        previouslyNativeWhite: Bool = false
    ) -> Bool {
        shouldUseNativeWhiteFast(
            for: color,
            hasCCT: capabilities.hasCCT,
            canDoColor: capabilities.canDoColor,
            cctRange: cctRange,
            previouslyNativeWhite: previouslyNativeWhite
        )
    }

    /// Allocation-free variant of `shouldUseNativeWhite(for:capabilities:cctRange:previouslyNativeWhite:)`.
    @inline(__always)
    public static func shouldUseNativeWhiteFast(
        for color: LightColor,
        hasCCT: Bool,
        canDoColor: Bool,
        cctRange: ClosedRange<Double> = 2700...10000,
        previouslyNativeWhite: Bool = false
    ) -> Bool {
        guard hasCCT else { return false }
        if !canDoColor { return true }

        let loK = cctRange.lowerBound
        let hiK = cctRange.upperBound
        let kMargin = previouslyNativeWhite ? 500.0 : 200.0

        switch color {
        case .kelvin(let k, let tint):
            let duv = abs(ColorMath.tintToDuv(tint))
            let duvLimit = previouslyNativeWhite ? 0.022 : 0.020
            return k >= (loK - kMargin) && k <= (hiK + kMargin) && duv <= duvLimit

        case .hsi(_, let sat):
            let satLimit = previouslyNativeWhite ? 0.12 : 0.04
            return sat <= satLimit

        case .rgb, .xy:
            let a = ColorAnalysis.of(color)
            guard !a.isBlack else { return false }
            let duvLimit = previouslyNativeWhite ? nativeWhiteExitDuv : nativeWhiteEnterDuv
            guard abs(a.duv) <= duvLimit else { return false }
            return a.kelvin >= (loK - kMargin) && a.kelvin <= (hiK + kMargin)
        }
    }

    // MARK: - Public Mixing API

    /// Returns drive levels keyed by emitter kind, max component ≤ 1.
    /// - Parameters:
    ///   - color: target color (chromaticity; brightness is handled by intensity)
    ///   - emitters: the emitter kinds available on this fixture/cell
    ///   - calibration: per-fixture calibration
    public static func mix(
        _ color: LightColor,
        emitters: Set<ChannelKind>,
        calibration: ColorCalibration = .default
    ) -> [ChannelKind: Double] {
        mix(color, emitters: emitters, emitterSpecs: nil, calibration: calibration)
    }

    /// Returns drive levels keyed by emitter kind, using optional per-fixture `EmitterSpec` overrides.
    /// - Parameter mode: mixing mode; `nil` uses `calibration.mixingMode`, then `.accurate`.
    public static func mix(
        _ color: LightColor,
        emitters: Set<ChannelKind>,
        emitterSpecs: [ChannelKind: EmitterSpec]?,
        calibration: ColorCalibration = .default,
        mode: ColorMixingMode? = nil
    ) -> [ChannelKind: Double] {
        guard !emitters.isEmpty else { return [:] }
        let mask = EmitterMask(emitters: emitters)
        let levels = mixFast(color, emitters: mask, emitterSpecs: emitterSpecs, calibration: calibration, mode: mode)
        return levels.toDictionary(for: emitters)
    }

    // MARK: - Zero-Allocation Hot-Path Mixer

    /// Computes `EmitterLevels` without heap dictionary or set allocations.
    /// - Parameter mode: mixing mode; `nil` uses `calibration.mixingMode`, then `.accurate`.
    public static func mixFast(
        _ color: LightColor,
        emitters: EmitterMask,
        emitterSpecs: [ChannelKind: EmitterSpec]? = nil,
        calibration: ColorCalibration = .default,
        mode: ColorMixingMode? = nil
    ) -> EmitterLevels {
        guard !emitters.isEmpty else { return EmitterLevels() }
        let plan = MixPlan(
            profile: MixerProfile.profile(for: emitterSpecs),
            calibration: calibration,
            mode: mode ?? calibration.mixingMode ?? .accurate
        )
        let c = plan.trimmed(color)
        let needCCT = !emitters.isSuperset(of: .rgb) && emitters.isSubset(of: whiteEmitters)
        return plan.levels(for: c, analysis: ColorAnalysis.of(c, includeCCT: needCCT), emitters: emitters)
    }

    // MARK: - Reconstruction & Accuracy

    /// Linear sRGB output of an emitter kind at full drive. Stock bases are normalised to a peak
    /// of 1; definition-supplied specs are scaled by their lumens and may fall outside sRGB.
    @inline(__always)
    public static func emitterLinearBasis(
        for kind: ChannelKind,
        emitterSpecs: [ChannelKind: EmitterSpec]? = nil
    ) -> LinearRGB {
        MixerProfile.profile(for: emitterSpecs).linear[kind]
    }

    /// Reconstructs the normalized linear sRGB chromaticity produced by a set of emitter levels.
    public static func reconstructedLinearRGB(
        from levels: [ChannelKind: Double],
        emitterSpecs: [ChannelKind: EmitterSpec]? = nil
    ) -> LinearRGB {
        let bases = MixerProfile.profile(for: emitterSpecs).linear
        var r = 0.0, g = 0.0, b = 0.0
        for (kind, weight) in levels where weight > 0 && kind.isEmitter {
            let basis = bases[kind]
            r += weight * basis.r
            g += weight * basis.g
            b += weight * basis.b
        }
        return LinearRGB(r: r, g: g, b: b).normalized
    }

    /// Reconstructs the display `RGB` color produced by a set of emitter levels.
    public static func reconstructedRGB(
        from levels: [ChannelKind: Double],
        emitterSpecs: [ChannelKind: EmitterSpec]? = nil
    ) -> RGB {
        RGB(linear: reconstructedLinearRGB(from: levels, emitterSpecs: emitterSpecs))
    }

    /// Computes the CIEDE2000 color difference (ΔE2000) between a target `LightColor` and the
    /// chromaticity reconstructed from `levels`.
    public static func deltaE2000(
        target: LightColor,
        levels: [ChannelKind: Double],
        emitterSpecs: [ChannelKind: EmitterSpec]? = nil
    ) -> Double {
        ColorMath.deltaE2000(target.linearRGB, reconstructedLinearRGB(from: levels, emitterSpecs: emitterSpecs))
    }

    // MARK: - Solvers

    /// Uncalibrated levels for `target` (normalised linear sRGB). `normalized` reports whether
    /// the result is peak-normalised (so calibration gains may re-normalise it).
    static func solve(
        target: LinearRGB,
        color: LightColor,
        analysis a: ColorAnalysis,
        emitters: EmitterMask,
        profile p: MixerProfile,
        mode: ColorMixingMode,
        kelvin: Double
    ) -> (levels: EmitterLevels, normalized: Bool) {
        var out = EmitterLevels()
        if emitters.isSuperset(of: .rgb) {
            if mode == .direct {
                let d = directRGB(color, a)
                out.red = clamp01(d.r)
                out.green = clamp01(d.g)
                out.blue = clamp01(d.b)
                return (out, false)
            }
            return (solveAccurateRGB(target: target, saturation: a.saturation, emitters: emitters, profile: p), true)
        }
        if emitters.isSuperset(of: .cmy) {
            // Subtractive flags over a white source: never re-normalise (that over-saturates pastels).
            var r = target.r, g = target.g, b = target.b
            if mode == .direct {
                let d = directRGB(color, a)
                r = d.r; g = d.g; b = d.b
            }
            out.cyan = clamp01(1 - r)
            out.magenta = clamp01(1 - g)
            out.yellow = clamp01(1 - b)
            return (out, false)
        }
        if emitters.isSubset(of: whiteEmitters) {
            return (whiteBlend(kelvin: kelvin, emitters: emitters, profile: p), true)
        }
        if emitters.rawValue.nonzeroBitCount == 1 {
            for kind in allEmitterKinds where emitters.contains(EmitterMask.bit(for: kind)) {
                out[kind] = 1
            }
            return (out, true)
        }
        return (solveNNLS(target: target, emitters: emitters, bases: p.linear), true)
    }

    /// The sRGB values Direct mode sends: the exact hex for `.rgb`, the sRGB equivalent otherwise.
    @inline(__always)
    static func directRGB(_ color: LightColor, _ a: ColorAnalysis) -> RGB {
        if case .rgb(let c) = color { return c }
        return a.display
    }

    /// Bi-colour / multi-white fixtures: blend the two present whites that bracket the target
    /// CCT, linearly in mired (the warmest/coolest white alone outside their span).
    static func whiteBlend(kelvin: Double, emitters: EmitterMask, profile p: MixerProfile) -> EmitterLevels {
        var out = EmitterLevels()
        let m = 1e6 / clamp(kelvin.finiteOr(5600), 1000, 25000)
        var warm: ChannelKind? = nil
        var warmM = 0.0
        var cool: ChannelKind? = nil
        var coolM = 0.0
        for kind in whiteKinds where emitters.contains(EmitterMask.bit(for: kind)) {
            let km = 1e6 / max(p.nominalKelvin(of: kind), 1)
            if km >= m, warm == nil || km < warmM { warm = kind; warmM = km }
            if km <= m, cool == nil || km > coolM { cool = kind; coolM = km }
        }
        switch (warm, cool) {
        case let (w?, c?):
            if w == c || warmM - coolM < 1e-9 {
                out[w] = 1
            } else {
                let t = clamp01((warmM - m) / (warmM - coolM))
                let peak = max(1 - t, t)
                out[w] = (1 - t) / peak
                out[c] = t / peak
            }
        case let (w?, nil):
            out[w] = 1
        case let (nil, c?):
            out[c] = 1
        default:
            break
        }
        return out
    }

    /// Non-negative least squares by cyclic coordinate descent (≤ 13 unknowns, 3 equations),
    /// falling back to the best-aligned single emitter when nothing fits.
    static func solveNNLS(target t: LinearRGB, emitters: EmitterMask, bases: EmitterBases) -> EmitterLevels {
        var x = EmitterLevels()
        var recon = LinearRGB.black
        for _ in 0..<40 {
            var maxStep = 0.0
            for kind in allEmitterKinds where emitters.contains(EmitterMask.bit(for: kind)) {
                let b = bases[kind]
                let norm2 = b.r * b.r + b.g * b.g + b.b * b.b
                guard norm2 > 1e-12 else { continue }
                let grad = b.r * (recon.r - t.r) + b.g * (recon.g - t.g) + b.b * (recon.b - t.b)
                let old = x[kind]
                let new = max(0, old - grad / norm2)
                let step = new - old
                if step != 0 {
                    x[kind] = new
                    recon = recon + b * step
                    maxStep = max(maxStep, abs(step))
                }
            }
            if maxStep < 1e-7 { break }
        }
        if !(x.maxLevel > 1e-9) {
            var best: ChannelKind? = nil
            var bestCos = -Double.infinity
            for kind in allEmitterKinds where emitters.contains(EmitterMask.bit(for: kind)) {
                let b = bases[kind]
                let n = (b.r * b.r + b.g * b.g + b.b * b.b).squareRoot()
                guard n > 1e-9 else { continue }
                let cosine = (b.r * t.r + b.g * t.g + b.b * t.b) / n
                if cosine > bestCos { bestCos = cosine; best = kind }
            }
            if let best { x[best] = 1 }
        }
        x.normalize()
        return x
    }

    /// Largest `s` such that `rem − s·b` stays non-negative in every channel `b` lights.
    @inline(__always)
    static func extractable(_ rem: LinearRGB, _ b: LinearRGB) -> Double {
        var s = Double.infinity
        if b.r > 1e-6 { s = min(s, rem.r / b.r) }
        if b.g > 1e-6 { s = min(s, rem.g / b.g) }
        if b.b > 1e-6 { s = min(s, rem.b / b.b) }
        return s.isFinite ? max(0, s) : 0
    }

    @inline(__always)
    private static func take(_ s: Double, _ b: LinearRGB, from rem: inout LinearRGB) {
        rem = LinearRGB(r: max(0, rem.r - s * b.r), g: max(0, rem.g - s * b.g), b: max(0, rem.b - s * b.b))
    }

    /// Blend `t` (0 = all `a`, 1 = all `b`) of two white emitters whose composite covers the most
    /// luminance of `rem` (so the least is left for R/G/B). Each channel limit makes the covered
    /// luminance a monotone function of `t`, so the optimum is at an end point or where two
    /// channel limits cross.
    static func bestPairBlend(_ rem: LinearRGB, _ a: LinearRGB, _ b: LinearRGB, luma w: LinearRGB) -> Double {
        @inline(__always)
        func covered(_ c: LinearRGB) -> Double {
            extractable(rem, c) * max(0, w.r * c.r + w.g * c.g + w.b * c.b)
        }
        var bestT = 0.0
        var bestS = covered(a)
        let s1 = covered(b)
        if s1 > bestS + 1e-12 { bestS = s1; bestT = 1 }
        let d = b - a
        func consider(_ ri: Double, _ ai: Double, _ di: Double, _ rj: Double, _ aj: Double, _ dj: Double) {
            let den = ri * dj - rj * di
            guard abs(den) > 1e-15 else { return }
            let t = (rj * ai - ri * aj) / den
            guard t > 0, t < 1, t.isFinite else { return }
            let s = covered(a + d * t)
            if s > bestS + 1e-12 { bestS = s; bestT = t }
        }
        consider(rem.r, a.r, d.r, rem.g, a.g, d.g)
        consider(rem.r, a.r, d.r, rem.b, a.b, d.b)
        consider(rem.g, a.g, d.g, rem.b, a.b, d.b)
        return bestT
    }

    /// Accurate mode for fixtures with R, G and B: broadband emitters first, exact R/G/B remainder.
    static func solveAccurateRGB(
        target lin: LinearRGB,
        saturation: Double,
        emitters: EmitterMask,
        profile p: MixerProfile
    ) -> EmitterLevels {
        var out = EmitterLevels()
        let sb = p.solver

        // 1. Target in fixture-RGB space. Wide-gamut primaries: whites and pastels are matched
        // colorimetrically; saturated colours map gamut-relative (sRGB red → the fixture's red).
        var v = lin
        if p.customPrimaries {
            let kv = p.toSolver(lin)
            let sigma = smoothstep(0.5, 1, saturation)
            v = LinearRGB(r: lerp(kv.r, lin.r, sigma), g: lerp(kv.g, lin.g, sigma), b: lerp(kv.b, lin.b, sigma))
            if v.minComponent < 0 {
                // Out of the fixture gamut: desaturate toward equal-luminance grey until it fits.
                let w = p.lumaWeights
                let l = w.r * v.r + w.g * v.g + w.b * v.b
                if l > 1e-9 {
                    var alpha = 1.0
                    if v.r < 0 { alpha = min(alpha, l / (l - v.r)) }
                    if v.g < 0 { alpha = min(alpha, l / (l - v.g)) }
                    if v.b < 0 { alpha = min(alpha, l / (l - v.b)) }
                    v = LinearRGB(r: l + alpha * (v.r - l), g: l + alpha * (v.g - l), b: l + alpha * (v.b - l))
                }
            }
        }
        var rem = LinearRGB(r: max(0, v.r.finiteOr(0)), g: max(0, v.g.finiteOr(0)), b: max(0, v.b.finiteOr(0)))

        // 2. White emitters: the warm/cool pair that fits best, then any remaining single white.
        let hasW = emitters.contains(.white)
        let hasWW = emitters.contains(.warmWhite)
        let hasCW = emitters.contains(.coolWhite)
        var whiteUsedInPair = false
        if hasWW && (hasCW || hasW) {
            let coolIsW = !hasCW
            let a = sb.warmWhite
            let b = coolIsW ? sb.white : sb.coolWhite
            let t = bestPairBlend(rem, a, b, luma: p.lumaWeights)
            let composite = a * (1 - t) + b * t
            let s = extractable(rem, composite)
            if s > 0 {
                take(s, composite, from: &rem)
                out.warmWhite += s * (1 - t)
                if coolIsW { out.white += s * t } else { out.coolWhite += s * t }
            }
            whiteUsedInPair = coolIsW
        }
        if hasW && !whiteUsedInPair {
            let s = extractable(rem, sb.white)
            take(s, sb.white, from: &rem)
            out.white += s
        }
        if hasWW && !hasCW && !hasW {
            let s = extractable(rem, sb.warmWhite)
            take(s, sb.warmWhite, from: &rem)
            out.warmWhite += s
        }
        if hasCW && !hasWW {
            let s = extractable(rem, sb.coolWhite)
            take(s, sb.coolWhite, from: &rem)
            out.coolWhite += s
        }

        // 3. RGBACL without whites: amber + lime + cyan together make a broadband "virtual white".
        if !hasW && !hasWW && !hasCW && emitters.isSuperset(of: [.amber, .lime, .cyan]) {
            let composite = sb.amber * 0.35 + sb.lime * 0.35 + sb.cyan * 0.85
            let s = 0.9 * extractable(rem, composite)
            if s > 0 {
                take(s, composite, from: &rem)
                out.amber += 0.35 * s
                out.lime += 0.35 * s
                out.cyan += 0.85 * s
            }
        }

        // 4. Remaining auxiliary emitters take most (not all) of what fits, keeping R/G/B in play.
        extractAux(.lime, 0.85, sb.lime, emitters, &rem, &out)
        extractAux(.amber, 0.88, sb.amber, emitters, &rem, &out)
        extractAux(.cyan, 0.85, sb.cyan, emitters, &rem, &out)
        extractAux(.yellow, 0.80, sb.yellow, emitters, &rem, &out)
        extractAux(.magenta, 0.80, sb.magenta, emitters, &rem, &out)
        extractAux(.indigo, 0.75, sb.indigo, emitters, &rem, &out)
        if emitters.contains(.uv) {
            // UV only for deep blue/violet targets.
            let violet = smoothstep(2, 3, rem.b / max(rem.g, 1e-9))
            if violet > 0 {
                extractAux(.uv, 0.65 * violet, sb.uv, emitters, &rem, &out)
            }
        }

        // 5. Exact remainder on R/G/B (fixture-RGB amount × white-balance gain = drive).
        out.red = rem.r * p.driveGain.r
        out.green = rem.g * p.driveGain.g
        out.blue = rem.b * p.driveGain.b
        out.normalize()
        return out
    }

    @inline(__always)
    private static func extractAux(
        _ kind: ChannelKind,
        _ fraction: Double,
        _ basis: LinearRGB,
        _ emitters: EmitterMask,
        _ rem: inout LinearRGB,
        _ out: inout EmitterLevels
    ) {
        guard emitters.contains(EmitterMask.bit(for: kind)) else { return }
        let s = fraction * extractable(rem, basis)
        guard s > 0 else { return }
        take(s, basis, from: &rem)
        out[kind] += s
    }
}
