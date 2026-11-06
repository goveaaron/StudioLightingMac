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

    public func toDictionary(for emitters: Set<ChannelKind>) -> [ChannelKind: Double] {
        var out: [ChannelKind: Double] = [:]
        out.reserveCapacity(emitters.count)
        for kind in emitters where kind.isEmitter {
            out[kind] = self[kind]
        }
        return out
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

/// Converts a device-independent `LightColor` into emitter drive levels (`0…1`) for any LED
/// emitter topology (RGB, RGBW, RGBA, RGBWW, RGBACL, RGB+Lime, CMY, bi-color CCT, dimmer-only)
/// using broadband-preferring chromaticity decomposition + active-set Non-Negative Least Squares (NNLS).
public enum EmitterMixer {
    /// Nominal CCT of a standard "warm white" emitter and "cool white" emitter.
    public static let warmWhiteK = 2700.0
    public static let coolWhiteK = 6500.0

    /// Duv threshold below which a fixture switches from RGB into its native CCT white path.
    public static let nativeWhiteEnterDuv = 0.006
    /// Duv threshold above which a fixture exits its native CCT white path back to RGB (hysteresis band).
    public static let nativeWhiteExitDuv = 0.016

    // MARK: - Native White Path with Hysteresis

    /// Determines whether a fixture/cell with a `.cct` channel should use its native white path
    /// (`crossfade = 0`, driving `cct` + `tint` and zeroing RGB emitters) vs its color path (`crossfade = 1`).
    ///
    /// Includes a hysteresis deadband (`nativeWhiteEnterDuv = 0.006` vs `nativeWhiteExitDuv = 0.016`)
    /// so crossfades and noisy inputs never flicker between paths.
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
            let xy = color.xy
            let (k, duv) = ColorMath.xyToKelvinAndDuv(x: xy.x, y: xy.y)
            let duvLimit = previouslyNativeWhite ? nativeWhiteExitDuv : nativeWhiteEnterDuv
            guard abs(duv) <= duvLimit else { return false }
            return k >= (loK - kMargin) && k <= (hiK + kMargin)
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
    public static func mix(
        _ color: LightColor,
        emitters: Set<ChannelKind>,
        emitterSpecs: [ChannelKind: EmitterSpec]?,
        calibration: ColorCalibration = .default
    ) -> [ChannelKind: Double] {
        guard !emitters.isEmpty else { return [:] }
        let mask = EmitterMask(emitters: emitters)
        let levels = mixFast(color, emitters: mask, emitterSpecs: emitterSpecs, calibration: calibration)
        return levels.toDictionary(for: emitters)
    }

    // MARK: - Zero-Allocation Hot-Path Mixer

    /// Computes `EmitterLevels` without heap dictionary or set allocations.
    public static func mixFast(
        _ color: LightColor,
        emitters: EmitterMask,
        emitterSpecs: [ChannelKind: EmitterSpec]? = nil,
        calibration: ColorCalibration = .default
    ) -> EmitterLevels {
        var out = EmitterLevels()
        guard !emitters.isEmpty else { return out }

        let adjustedColor = applyWhitePointTrim(to: color, calibration: calibration)
        let hasRGB = emitters.isSuperset(of: .rgb)
        let hasW = emitters.contains(.white)
        let hasWW = emitters.contains(.warmWhite)
        let hasCW = emitters.contains(.coolWhite)

        // 1. Non-RGB fixtures (bi-color WW/CW, single white, or CMY).
        if !hasRGB {
            if emitters.isSuperset(of: .cmy) {
                let lin = calibration.accurateColor ? adjustedColor.linearRGB : adjustedColor.displayRGB.linear
                out.cyan = clamp01(1.0 - lin.r)
                out.magenta = clamp01(1.0 - lin.g)
                out.yellow = clamp01(1.0 - lin.b)
                out.normalize()
                return applyCalibrationFast(out, emitters: emitters, calibration: calibration)
            }
            if hasWW || hasCW {
                let wwK = emitterSpecs?[.warmWhite]?.cctKelvin ?? warmWhiteK
                let cwK = emitterSpecs?[.coolWhite]?.cctKelvin ?? coolWhiteK
                let k = adjustedColor.approximateKelvin.kelvin
                let denom = (1e6 / wwK) - (1e6 / cwK)
                let mixT = abs(denom) > 1e-6 ? clamp01(((1e6 / wwK) - (1e6 / max(k, 1))) / denom) : 0.5
                if hasWW && hasCW {
                    let ww = 1.0 - mixT
                    let cw = mixT
                    let m = max(ww, cw, 1e-6)
                    out.warmWhite = ww / m
                    out.coolWhite = cw / m
                } else if hasWW {
                    out.warmWhite = 1.0
                } else {
                    out.coolWhite = 1.0
                }
            }
            if hasW {
                out.white = 1.0
            }
            // Any isolated single emitters (e.g. amber-only or UV-only)
            for kind in allEmitterKinds where emitters.contains(EmitterMask.bit(for: kind)) {
                if !hasWW && !hasCW && !hasW {
                    out[kind] = 1.0
                }
            }
            return applyCalibrationFast(out, emitters: emitters, calibration: calibration)
        }

        // 2. Direct mode (`accurateColor == false`):
        // Hex codes pass straight to R/G/B channels (`#FF00AA` -> exact R/G/B).
        if !calibration.accurateColor {
            if case .rgb(let rawRGB) = adjustedColor {
                out.red = clamp01(rawRGB.r)
                out.green = clamp01(rawRGB.g)
                out.blue = clamp01(rawRGB.b)
                return applyCalibrationFast(out, emitters: emitters, calibration: calibration)
            }
            let d = adjustedColor.displayRGB
            var r = d.r, g = d.g, b = d.b
            if hasW || hasWW || hasCW {
                let w = max(0, min(r, min(g, b)))
                r -= w; g -= w; b -= w
                if hasWW && hasCW {
                    let k = adjustedColor.isWhiteish ? adjustedColor.approximateKelvin.kelvin : 5600
                    let t = clamp01((1e6 / warmWhiteK - 1e6 / max(k, 1)) / (1e6 / warmWhiteK - 1e6 / coolWhiteK))
                    out.warmWhite = w * (1.0 - t)
                    out.coolWhite = w * t
                } else if hasW {
                    out.white = w
                } else if hasWW {
                    out.warmWhite = w
                } else if hasCW {
                    out.coolWhite = w
                }
            }
            out.red = r
            out.green = g
            out.blue = b
            out.normalize()
            return applyCalibrationFast(out, emitters: emitters, calibration: calibration)
        }

        // 3. Accurate mode (`accurateColor == true`):
        // Solve in linear RGB / CIE XYZ space so the combined tristimulus output matches
        // `targetLinear` (ΔE2000 < 2, typically < 0.2) while maximizing broadband W/WW/CW/A/L/C emitters.
        let targetLinear = adjustedColor.linearRGB
        let hasCustomRGBSpecs = (emitterSpecs?[.red] != nil || emitterSpecs?[.green] != nil || emitterSpecs?[.blue] != nil)

        if !hasCustomRGBSpecs {
            out = solveStandardRGBPlusAuxiliary(
                target: targetLinear,
                color: adjustedColor,
                emitters: emitters,
                emitterSpecs: emitterSpecs
            )
        } else {
            out = solveGeneralNNLS(
                target: targetLinear,
                color: adjustedColor,
                emitters: emitters,
                emitterSpecs: emitterSpecs
            )
        }

        out.normalize()
        return applyCalibrationFast(out, emitters: emitters, calibration: calibration)
    }

    // MARK: - Broadband Extraction + Exact Residual / NNLS Solver

    private static let allEmitterKinds: [ChannelKind] = [
        .red, .green, .blue, .white, .warmWhite, .coolWhite,
        .amber, .lime, .cyan, .magenta, .yellow, .uv, .indigo
    ]

    private static let defaultWhiteBasis: LinearRGB = ColorMath.xyToLinearSRGB(x: 0.330, y: 0.340).normalized
    private static let defaultWarmWhiteBasis: LinearRGB = ColorMath.xyToLinearSRGB(x: 0.460, y: 0.411).normalized
    private static let defaultCoolWhiteBasis: LinearRGB = ColorMath.xyToLinearSRGB(x: 0.313, y: 0.329).normalized

    /// Linear sRGB basis vector (normalized to max component = 1, weighted by relative efficacy)
    /// for a given emitter kind.
    @inline(__always)
    public static func emitterLinearBasis(
        for kind: ChannelKind,
        emitterSpecs: [ChannelKind: EmitterSpec]? = nil
    ) -> LinearRGB {
        if let custom = emitterSpecs?[kind] {
            let xyz = ColorMath.xyYToXYZ(x: custom.x, y: custom.y, Y: max(custom.lumens, 0.05))
            return ColorMath.xyzToLinearSRGB(X: xyz.X, Y: xyz.Y, Z: xyz.Z).clamped
        }
        switch kind {
        case .red:
            return LinearRGB(r: 1.0, g: 0.0, b: 0.0)
        case .green:
            return LinearRGB(r: 0.0, g: 1.0, b: 0.0)
        case .blue:
            return LinearRGB(r: 0.0, g: 0.0, b: 1.0)
        case .white:
            return defaultWhiteBasis
        case .warmWhite:
            return defaultWarmWhiteBasis
        case .coolWhite:
            return defaultCoolWhiteBasis
        case .amber:
            // ~590nm Amber LED
            return LinearRGB(r: 1.0, g: 0.395, b: 0.0)
        case .lime:
            // ~555nm Lime LED
            return LinearRGB(r: 0.505, g: 1.0, b: 0.046)
        case .cyan:
            // ~500nm Cyan LED
            return LinearRGB(r: 0.0, g: 0.85, b: 1.0)
        case .magenta:
            return LinearRGB(r: 1.0, g: 0.075, b: 0.785)
        case .yellow:
            return LinearRGB(r: 0.92, g: 1.0, b: 0.03)
        case .indigo:
            return LinearRGB(r: 0.16, g: 0.0, b: 1.0)
        case .uv:
            return LinearRGB(r: 0.24, g: 0.0, b: 1.0)
        default:
            return .black
        }
    }

    /// Reconstructs the normalized linear sRGB chromaticity produced by a set of emitter levels.
    public static func reconstructedLinearRGB(
        from levels: [ChannelKind: Double],
        emitterSpecs: [ChannelKind: EmitterSpec]? = nil
    ) -> LinearRGB {
        var r = 0.0, g = 0.0, b = 0.0
        for (kind, weight) in levels where weight > 0 && kind.isEmitter {
            let basis = emitterLinearBasis(for: kind, emitterSpecs: emitterSpecs)
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
        let targetRGB = RGB(linear: target.linearRGB)
        let mixedRGB = reconstructedRGB(from: levels, emitterSpecs: emitterSpecs)
        return ColorMath.deltaE2000(targetRGB, mixedRGB)
    }

    /// Fast analytical + broadband-priority solver when R, G, B use standard sRGB primaries
    /// and any combination of W, WW, CW, Amber, Lime, Cyan, Magenta, Yellow, Indigo, UV are present.
    private static func solveStandardRGBPlusAuxiliary(
        target: LinearRGB,
        color: LightColor,
        emitters: EmitterMask,
        emitterSpecs: [ChannelKind: EmitterSpec]?
    ) -> EmitterLevels {
        var out = EmitterLevels()
        var remR = max(0, target.r)
        var remG = max(0, target.g)
        var remB = max(0, target.b)

        // Pure RGB fast path (0 auxiliary emitters)
        let auxMask = emitters.subtracting(.rgb)
        if auxMask.isEmpty {
            out.red = remR
            out.green = remG
            out.blue = remB
            return out
        }

        // Helper: maximum scale `s >= 0` such that `rem - s * basis >= 0` component-wise.
        @inline(__always)
        func maxExtractable(_ basis: LinearRGB) -> Double {
            var limit = Double.greatestFiniteMagnitude
            if basis.r > 1e-6 { limit = min(limit, remR / basis.r) }
            if basis.g > 1e-6 { limit = min(limit, remG / basis.g) }
            if basis.b > 1e-6 { limit = min(limit, remB / basis.b) }
            return limit.isFinite ? max(0, limit) : 0
        }

        @inline(__always)
        func subtract(_ weight: Double, _ basis: LinearRGB) {
            guard weight > 1e-9 else { return }
            remR = max(0, remR - weight * basis.r)
            remG = max(0, remG - weight * basis.g)
            remB = max(0, remB - weight * basis.b)
        }

        // Step 1: Broadband White extraction (WW + CW dual-white, or single W / WW / CW)
        let hasW = emitters.contains(.white)
        let hasWW = emitters.contains(.warmWhite)
        let hasCW = emitters.contains(.coolWhite)

        if hasWW && hasCW {
            let bWW = emitterLinearBasis(for: .warmWhite, emitterSpecs: emitterSpecs)
            let bCW = emitterLinearBasis(for: .coolWhite, emitterSpecs: emitterSpecs)
            // Estimate warm/cool ratio from target red/blue ratio in linear space (avoids expensive uv scan when possible)
            let mixT: Double
            if case .kelvin(let k, _) = color {
                mixT = clamp01((1e6 / warmWhiteK - 1e6 / max(k, 1)) / (1e6 / warmWhiteK - 1e6 / coolWhiteK))
            } else {
                // Smoothly map linear B/R ratio between warmWhite (B/R ≈ 0.20) and coolWhite (B/R ≈ 1.0)
                let br = remR > 1e-4 ? (remB / remR) : 1.0
                mixT = clamp01((br - bWW.b) / max(bCW.b - bWW.b, 0.1))
            }
            let combined = LinearRGB(
                r: lerp(bWW.r, bCW.r, mixT),
                g: lerp(bWW.g, bCW.g, mixT),
                b: lerp(bWW.b, bCW.b, mixT)
            )
            let wDual = maxExtractable(combined)
            if wDual > 0 {
                let wWW = wDual * (1.0 - mixT)
                let wCW = wDual * mixT
                out.warmWhite += wWW
                out.coolWhite += wCW
                subtract(wWW, bWW)
                subtract(wCW, bCW)
            }
            // Secondary pass: if warm or cool residual remains (e.g. warm white 2700K or warm pastel), extract remaining WW or CW
            let extraWW = maxExtractable(bWW) * 0.92
            if extraWW > 1e-5 {
                out.warmWhite += extraWW
                subtract(extraWW, bWW)
            }
            let extraCW = maxExtractable(bCW) * 0.92
            if extraCW > 1e-5 {
                out.coolWhite += extraCW
                subtract(extraCW, bCW)
            }
        } else if hasW {
            let bW = emitterLinearBasis(for: .white, emitterSpecs: emitterSpecs)
            let w = maxExtractable(bW)
            if w > 0 {
                out.white = w
                subtract(w, bW)
            }
        } else if hasWW {
            let bWW = emitterLinearBasis(for: .warmWhite, emitterSpecs: emitterSpecs)
            let w = maxExtractable(bWW)
            if w > 0 {
                out.warmWhite = w
                subtract(w, bWW)
            }
        } else if hasCW {
            let bCW = emitterLinearBasis(for: .coolWhite, emitterSpecs: emitterSpecs)
            let w = maxExtractable(bCW)
            if w > 0 {
                out.coolWhite = w
                subtract(w, bCW)
            }
        }

        // Step 2: RGBACL / RGB+Lime / RGBA spectral-fullness extraction
        // When no dedicated W/WW/CW emitter is present (e.g. RGBACL or RGB+Lime), Lime + Amber + Cyan
        // can synthesize high-CRI white/pastels before falling back to narrowband R/G/B.
        let hasAmber = emitters.contains(.amber)
        let hasLime = emitters.contains(.lime)
        let hasCyan = emitters.contains(.cyan)

        if hasLime && hasAmber && hasCyan && !hasW && !hasWW && !hasCW {
            // Virtual white from Lime + Amber + Cyan
            let bL = emitterLinearBasis(for: .lime, emitterSpecs: emitterSpecs)
            let bA = emitterLinearBasis(for: .amber, emitterSpecs: emitterSpecs)
            let bC = emitterLinearBasis(for: .cyan, emitterSpecs: emitterSpecs)
            // Balanced ACL triad (~0.35 A + 0.35 L + 0.85 C produces near-neutral white)
            let aclBasis = LinearRGB(
                r: 0.35 * bA.r + 0.35 * bL.r + 0.85 * bC.r,
                g: 0.35 * bA.g + 0.35 * bL.g + 0.85 * bC.g,
                b: 0.35 * bA.b + 0.35 * bL.b + 0.85 * bC.b
            )
            let wACL = maxExtractable(aclBasis) * 0.90
            if wACL > 1e-5 {
                let wA = 0.35 * wACL
                let wL = 0.35 * wACL
                let wC = 0.85 * wACL
                out.amber += wA
                out.lime += wL
                out.cyan += wC
                subtract(wA, bA)
                subtract(wL, bL)
                subtract(wC, bC)
            }
        }

        // Individual secondary emitter extraction (Lime, Amber, Cyan, Yellow, Magenta, Indigo, UV)
        // Extract up to 85% of the feasible residual along each present auxiliary emitter so
        // narrowband primaries and broadband secondaries share load smoothly while keeping
        // the exact tristimulus sum `sum w_k * E_k == target`!
        if hasLime {
            let bL = emitterLinearBasis(for: .lime, emitterSpecs: emitterSpecs)
            let wL = maxExtractable(bL) * 0.85
            if wL > 1e-5 {
                out.lime += wL
                subtract(wL, bL)
            }
        }
        if hasAmber {
            let bA = emitterLinearBasis(for: .amber, emitterSpecs: emitterSpecs)
            let wA = maxExtractable(bA) * 0.88
            if wA > 1e-5 {
                out.amber += wA
                subtract(wA, bA)
            }
        }
        if hasCyan {
            let bC = emitterLinearBasis(for: .cyan, emitterSpecs: emitterSpecs)
            let wC = maxExtractable(bC) * 0.85
            if wC > 1e-5 {
                out.cyan += wC
                subtract(wC, bC)
            }
        }
        if emitters.contains(.yellow) {
            let bY = emitterLinearBasis(for: .yellow, emitterSpecs: emitterSpecs)
            let wY = maxExtractable(bY) * 0.80
            if wY > 1e-5 {
                out.yellow += wY
                subtract(wY, bY)
            }
        }
        if emitters.contains(.magenta) {
            let bM = emitterLinearBasis(for: .magenta, emitterSpecs: emitterSpecs)
            let wM = maxExtractable(bM) * 0.80
            if wM > 1e-5 {
                out.magenta += wM
                subtract(wM, bM)
            }
        }
        if emitters.contains(.indigo) {
            let bI = emitterLinearBasis(for: .indigo, emitterSpecs: emitterSpecs)
            let wI = maxExtractable(bI) * 0.75
            if wI > 1e-5 {
                out.indigo += wI
                subtract(wI, bI)
            }
        }
        if emitters.contains(.uv) {
            let bUV = emitterLinearBasis(for: .uv, emitterSpecs: emitterSpecs)
            // Engage UV only when blue dominates green strongly (deep blue / violet / UV hues)
            if remB > remG * 2.5 {
                let wUV = maxExtractable(bUV) * 0.65
                if wUV > 1e-5 {
                    out.uv += wUV
                    subtract(wUV, bUV)
                }
            }
        }

        // Step 3: Exact remaining primary R, G, B residual
        // Because every subtraction kept `remR, remG, remB >= 0`, setting R = remR, G = remG, B = remB
        // guarantees `sum_{k} out[k] * basis(k) == target` identically!
        out.red = remR
        out.green = remG
        out.blue = remB
        return out
    }

    /// General Non-Negative Least Squares (NNLS) solver in CIE XYZ / LinearRGB when custom R/G/B
    /// `EmitterSpec` primaries are provided.
    private static func solveGeneralNNLS(
        target: LinearRGB,
        color: LightColor,
        emitters: EmitterMask,
        emitterSpecs: [ChannelKind: EmitterSpec]?
    ) -> EmitterLevels {
        // Start from the broadband heuristic solution, then refine via projected Gauss-Seidel NNLS
        // on the 3xN linear system `A * w = target`.
        var out = solveStandardRGBPlusAuxiliary(
            target: target,
            color: color,
            emitters: emitters,
            emitterSpecs: emitterSpecs
        )

        var activeKinds: [ChannelKind] = []
        activeKinds.reserveCapacity(8)
        var bases: [LinearRGB] = []
        bases.reserveCapacity(8)
        var weights: [Double] = []
        weights.reserveCapacity(8)
        var norms2: [Double] = []
        norms2.reserveCapacity(8)

        for kind in allEmitterKinds where emitters.contains(EmitterMask.bit(for: kind)) {
            let b = emitterLinearBasis(for: kind, emitterSpecs: emitterSpecs)
            let n2 = b.r * b.r + b.g * b.g + b.b * b.b
            guard n2 > 1e-9 else { continue }
            activeKinds.append(kind)
            bases.append(b)
            weights.append(out[kind])
            norms2.append(n2)
        }

        guard !activeKinds.isEmpty else { return out }

        // Compute current residual `res = target - A * w`
        var resR = target.r
        var resG = target.g
        var resB = target.b
        for i in 0..<activeKinds.count {
            let w = weights[i]
            let b = bases[i]
            resR -= w * b.r
            resG -= w * b.g
            resB -= w * b.b
        }

        // Coordinate-descent / projected Gauss-Seidel NNLS (converges in < 20 iterations for 3xN)
        for _ in 0..<24 {
            var maxDelta = 0.0
            for i in 0..<activeKinds.count {
                let b = bases[i]
                let oldW = weights[i]
                let grad = resR * b.r + resG * b.g + resB * b.b
                let newW = max(0.0, oldW + grad / norms2[i])
                let dw = newW - oldW
                if abs(dw) > 1e-7 {
                    weights[i] = newW
                    resR -= dw * b.r
                    resG -= dw * b.g
                    resB -= dw * b.b
                    maxDelta = max(maxDelta, abs(dw))
                }
            }
            if maxDelta < 1e-6 { break }
        }

        for i in 0..<activeKinds.count {
            out[activeKinds[i]] = weights[i]
        }
        return out
    }

    // MARK: - Calibration & White-Point Trim

    private static func applyWhitePointTrim(to color: LightColor, calibration: ColorCalibration) -> LightColor {
        let kTrim = calibration.whitePointKelvinTrim.finiteOr(0)
        let tTrim = calibration.whitePointTintTrim.finiteOr(0)
        guard abs(kTrim) > 1e-6 || abs(tTrim) > 1e-6 else { return color }

        switch color {
        case .kelvin(let k, let t):
            return .kelvin(clamp(k + kTrim, 1700, 20000), tint: clamp(t + tTrim, -1, 1))
        default:
            // Apply chromatic adaptation scaling relative to neutral 5600K reference
            let ref = ColorMath.xyToLinearSRGB(x: ColorMath.d65XY.x, y: ColorMath.d65XY.y)
            let shiftedXY = ColorMath.kelvinToXY(clamp(5600 + kTrim, 1700, 20000), tint: clamp(tTrim, -1, 1))
            let shifted = ColorMath.xyToLinearSRGB(x: shiftedXY.x, y: shiftedXY.y)
            let base = color.linearRGB
            let adapted = LinearRGB(
                r: base.r * (shifted.r / max(ref.r, 0.05)),
                g: base.g * (shifted.g / max(ref.g, 0.05)),
                b: base.b * (shifted.b / max(ref.b, 0.05))
            ).clamped.normalized
            return .rgb(RGB(linear: adapted))
        }
    }

    @inline(__always)
    static func applyCalibrationFast(
        _ levels: EmitterLevels,
        emitters: EmitterMask,
        calibration cal: ColorCalibration
    ) -> EmitterLevels {
        let hasGains = !cal.gains.isEmpty
        let hasGamma = cal.gamma != 1.0 && cal.gamma > 0 && cal.gamma.isFinite
        guard hasGains || hasGamma else { return levels }

        var out = levels
        let gamma = cal.gamma.finiteOr(1.0)
        for kind in allEmitterKinds where emitters.contains(EmitterMask.bit(for: kind)) {
            var x = clamp01(out[kind].finiteOr(0))
            if hasGains, let g = cal.gains[kind.rawValue] {
                x = clamp01(x * g.finiteOr(1))
            }
            if hasGamma && x > 0 {
                x = pow(x, gamma)
            }
            out[kind] = x
        }
        return out
    }

    static func applyCalibration(_ levels: [ChannelKind: Double], _ cal: ColorCalibration) -> [ChannelKind: Double] {
        var out = levels
        for (k, v) in levels {
            var x = clamp01(v.finiteOr(0))
            if let g = cal.gains[k.rawValue] { x = clamp01(x * g.finiteOr(1)) }
            if cal.gamma != 1, cal.gamma > 0 { x = pow(x, cal.gamma) }
            out[k] = x
        }
        return out
    }
}
