import Foundation

// Shared building blocks for the music moods (docs/research/music_reactive.md §3.1, §4.5).
// Everything is a pure function or an immutable table so moods stay deterministic for a given
// (time, features, layout) and never allocate per pixel.

// MARK: - OKLab colour

/// A colour in OKLab (L ≈ 0…1, a/b ≈ ±0.4) — the space every music mood mixes in. Palette
/// colours carry their own relative level (a dark stop is an intentionally dim "shadow" colour).
public struct MusicLab: Sendable, Equatable {
    public var L: Double
    public var a: Double
    public var b: Double

    @inline(__always)
    public init(_ L: Double, _ a: Double, _ b: Double) { self.L = L; self.a = a; self.b = b }

    public static let white = MusicLab(1, 0, 0)
    public static let black = MusicLab(0, 0, 0)

    /// sRGB hex `0xRRGGBB` → OKLab (gamut-safe by construction).
    public init(hex: UInt32) {
        let r = MusicLab.srgbToLinear(Double((hex >> 16) & 0xFF) / 255)
        let g = MusicLab.srgbToLinear(Double((hex >> 8) & 0xFF) / 255)
        let bl = MusicLab.srgbToLinear(Double(hex & 0xFF) / 255)
        self = MusicLab.fromLinear(r, g, bl)
    }

    @inline(__always) var chroma: Double { (a * a + b * b).squareRoot() }
    @inline(__always) var isFinite: Bool { L.isFinite && a.isFinite && b.isFinite }

    @inline(__always)
    static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    @inline(__always)
    static func linearToSRGB(_ c: Double) -> Double {
        let c = clamp01(c)
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    static func fromLinear(_ r: Double, _ g: Double, _ b: Double) -> MusicLab {
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return MusicLab(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// Linear sRGB (unclamped; may leave 0…1 for out-of-gamut colours).
    @inline(__always)
    func linearUnclamped() -> (r: Double, g: Double, b: Double) {
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    @inline(__always)
    private static func inGamut(_ c: (r: Double, g: Double, b: Double)) -> Bool {
        let lo = -1e-4, hi = 1 + 1e-4
        return c.r >= lo && c.r <= hi && c.g >= lo && c.g <= hi && c.b >= lo && c.b <= hi
    }

    /// Gamut-mapped linear sRGB in 0…1: chroma is reduced at constant lightness and hue
    /// (§5.2) until the colour fits. Non-finite input maps to black.
    func linear() -> (r: Double, g: Double, b: Double) {
        guard isFinite else { return (0, 0, 0) }
        let l = clamp01(L)
        let c = MusicLab(l, a, b).linearUnclamped()
        if MusicLab.inGamut(c) { return (clamp01(c.r), clamp01(c.g), clamp01(c.b)) }
        var lo = 0.0, hi = 1.0
        for _ in 0..<10 {
            let mid = 0.5 * (lo + hi)
            if MusicLab.inGamut(MusicLab(l, a * mid, b * mid).linearUnclamped()) { lo = mid } else { hi = mid }
        }
        let m = MusicLab(l, a * lo, b * lo).linearUnclamped()
        return (clamp01(m.r), clamp01(m.g), clamp01(m.b))
    }

    /// The same colour pulled inside the sRGB gamut.
    func gamutMapped() -> MusicLab {
        let c = linear()
        return MusicLab.fromLinear(c.r, c.g, c.b)
    }

    /// Gamma-encoded sRGB for `LightColor.rgb`.
    public var rgb: RGB {
        let c = linear()
        return RGB(r: MusicLab.linearToSRGB(c.r), g: MusicLab.linearToSRGB(c.g), b: MusicLab.linearToSRGB(c.b))
    }

    /// Relative luminance (0…1) of the colour at full level.
    var luminance: Double {
        let c = linear()
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }

    /// WCAG "saturated red" test on linear values: R / (R + G + B) ≥ 0.8.
    var isSaturatedRed: Bool {
        let c = linear()
        let s = c.r + c.g + c.b
        return s > 1e-4 && c.r / s >= 0.8
    }

    // MARK: Perceptual operations

    @inline(__always)
    static func lerp(_ x: MusicLab, _ y: MusicLab, _ t: Double) -> MusicLab {
        MusicLab(x.L + (y.L - x.L) * t, x.a + (y.a - x.a) * t, x.b + (y.b - x.b) * t)
    }

    /// `mixOK` (§4.5): chroma-restoring OKLab mix for nearby hues (no grey midpoint), an OKLCH
    /// arc for near-complementary pairs, a straight line when either end is near-neutral.
    static func mix(_ x: MusicLab, _ y: MusicLab, _ t: Double) -> MusicLab {
        let t = clamp01(t)
        if t <= 0 { return x }
        if t >= 1 { return y }
        let cx = x.chroma, cy = y.chroma
        if min(cx, cy) < 0.02 { return lerp(x, y, t) }
        let hx = atan2(x.b, x.a), hy = atan2(y.b, y.a)
        var dh = hy - hx
        if dh > .pi { dh -= 2 * .pi }
        if dh < -.pi { dh += 2 * .pi }
        if abs(dh) <= 150 * .pi / 180 {
            var m = lerp(x, y, t)
            let cm = m.chroma
            let ct = cx + (cy - cx) * t
            if cm > 1e-4 { m.a *= ct / cm; m.b *= ct / cm }
            return m
        }
        // Near-complementary: travel around the hue circle on the side with more gamut room.
        let alt = dh > 0 ? dh - 2 * .pi : dh + 2 * .pi
        let lm = 0.5 * (x.L + y.L)
        let arc = cuspChroma(hue: hx + 0.5 * dh, L: lm) >= cuspChroma(hue: hx + 0.5 * alt, L: lm) ? dh : alt
        let h = hx + arc * t
        let L = x.L + (y.L - x.L) * t
        let C = cx + (cy - cx) * t
        return MusicLab(L, C * cos(h), C * sin(h))
    }

    /// Largest in-gamut chroma at a hue (radians) and lightness (coarse search).
    static func cuspChroma(hue: Double, L: Double) -> Double {
        let ca = cos(hue), sa = sin(hue)
        var lo = 0.0, hi = 0.4
        for _ in 0..<8 {
            let mid = 0.5 * (lo + hi)
            if inGamut(MusicLab(L, mid * ca, mid * sa).linearUnclamped()) { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// OKLCH hue rotation in degrees.
    func hueShifted(_ degrees: Double) -> MusicLab {
        guard degrees != 0, degrees.isFinite else { return self }
        let r = degrees * .pi / 180
        let c = cos(r), s = sin(r)
        return MusicLab(L, a * c - b * s, a * s + b * c)
    }

    /// OKLCH chroma scaling.
    @inline(__always)
    func chromaScaled(_ k: Double) -> MusicLab {
        let k = max(0, k.finiteOr(1))
        return MusicLab(L, a * k, b * k)
    }

    /// Euclidean ΔE in OKLab.
    @inline(__always)
    static func distance(_ x: MusicLab, _ y: MusicLab) -> Double {
        let dl = x.L - y.L, da = x.a - y.a, db = x.b - y.b
        return (dl * dl + da * da + db * db).squareRoot()
    }
}

// MARK: - Palettes

/// An ordered set of colour stops baked into OKLab lookup tables (§3.1 "Palettes").
/// `cyclic(q)` wraps from the last stop back to the first; `clamped(q)` runs first → last.
public struct MoodPalette: Sendable {
    public let name: String
    public let hexStops: [UInt32]
    let stops: [MusicLab]
    private let cyclicLUT: [MusicLab]
    private let clampedLUT: [MusicLab]
    static let lutSize = 128

    public init(_ name: String, _ hex: [UInt32]) {
        self.name = name
        let hx = hex.isEmpty ? [0xFFFFFF] : hex
        hexStops = hx
        let s = hx.map { MusicLab(hex: $0) }
        stops = s
        cyclicLUT = MoodPalette.bake(s, cyclic: true)
        clampedLUT = MoodPalette.bake(s, cyclic: false)
    }

    private static func bake(_ s: [MusicLab], cyclic: Bool) -> [MusicLab] {
        let n = s.count
        guard n > 1 else { return Array(repeating: s.first ?? .white, count: lutSize) }
        let segments = cyclic ? n : n - 1
        var out: [MusicLab] = []
        out.reserveCapacity(lutSize)
        for i in 0..<lutSize {
            let q = cyclic ? Double(i) / Double(lutSize) : Double(i) / Double(lutSize - 1)
            let pos = q * Double(segments)
            let k = min(segments - 1, Int(pos))
            let w = pos - Double(k)
            out.append(MusicLab.mix(s[k], s[(k + 1) % n], w).gamutMapped())
        }
        return out
    }

    public var count: Int { stops.count }

    /// Cyclic sample (q wraps).
    @inline(__always)
    func cyclic(_ q: Double) -> MusicLab {
        guard q.isFinite else { return cyclicLUT[0] }
        let n = Double(MoodPalette.lutSize)
        var x = (q - q.rounded(.down)) * n
        if x >= n { x = 0 }
        let i = Int(x)
        let w = x - Double(i)
        return MusicLab.lerp(cyclicLUT[i], cyclicLUT[(i + 1) % MoodPalette.lutSize], w)
    }

    /// Clamped sample (q ∈ 0…1, first → last stop).
    @inline(__always)
    func clamped(_ q: Double) -> MusicLab {
        let x = clamp01(q) * Double(MoodPalette.lutSize - 1)
        let i = min(MoodPalette.lutSize - 2, Int(x))
        let w = x - Double(i)
        return MusicLab.lerp(clampedLUT[i], clampedLUT[i + 1], w)
    }

    /// Stop `i mod count`.
    @inline(__always)
    func stop(_ i: Int) -> MusicLab {
        let n = stops.count
        return stops[((i % n) + n) % n]
    }

    /// Stop colours for previews and UI swatches.
    public var previewColors: [RGB] { stops.map(\.rgb) }
}

// MARK: - Kernels and noise

/// Smooth kernels shared by the moods (§3.1). All are C¹-continuous so nothing steps.
enum MoodMath {
    @inline(__always)
    static func fract(_ x: Double) -> Double {
        guard x.isFinite else { return 0 }
        return x - x.rounded(.down)
    }

    @inline(__always)
    static func gauss(_ x: Double, _ w: Double) -> Double {
        let w = max(w, 1e-6)
        return exp(-0.5 * x * x / (w * w))
    }

    /// Asymmetric raised-cosine beat kernel: 1 exactly at φ = 0, 0 at φ = 1 − a.
    @inline(__always)
    static func kb(_ phi: Double, a: Double, s: Double) -> Double {
        let p = fract(phi)
        let a = clamp(a, 0.01, 0.99)
        let v: Double
        if p < 1 - a {
            v = 0.5 + 0.5 * cos(.pi * p / (1 - a))
        } else {
            v = 0.5 - 0.5 * cos(.pi * (p - (1 - a)) / a)
        }
        return s == 1 ? v : pow(max(0, v), s)
    }

    /// Bi-exponential event envelope normalised to peak 1 (0 before the event).
    @inline(__always)
    static func env(_ dt: Double, ta: Double, td: Double) -> Double {
        guard dt > 0, dt.isFinite else { return 0 }
        let ta = max(ta, 1e-3)
        var td = max(td, 1e-3)
        if abs(td - ta) < 1e-4 { td = ta + 1e-3 }
        if dt > 12 * td + ta { return 0 }
        let tp = ta * td / (td - ta) * log(td / ta)
        let norm = exp(-tp / td) - exp(-tp / ta)
        guard norm > 1e-9 else { return 0 }
        return max(0, (exp(-dt / td) - exp(-dt / ta)) / norm)
    }

    /// Integer hash → 0…1.
    @inline(__always)
    static func hash01(_ a: UInt64, _ b: UInt64 = 0) -> Double {
        var z = a &* 0x9E37_79B9_7F4A_7C15 &+ b &* 0xBF58_476D_1CE4_E5B9 &+ 0x94D0_49BB_1331_11EB
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    /// Stable 64-bit seed for a fixture UUID (FNV-1a).
    static func seed(_ id: UUID) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        let u = id.uuid
        withUnsafeBytes(of: u) { raw in
            for byte in raw { h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        }
        return h
    }

    // Improved Perlin noise (Perlin 2002) with a fixed, deterministic permutation.
    private static let perm: [Int] = {
        var p = Array(0..<256)
        var s: UInt64 = 0x5EED_1234_ABCD_0042
        for i in stride(from: 255, to: 0, by: -1) {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let j = Int((s >> 33) % UInt64(i + 1))
            p.swapAt(i, j)
        }
        return p + p
    }()

    @inline(__always)
    private static func fade(_ t: Double) -> Double { t * t * t * (t * (t * 6 - 15) + 10) }

    @inline(__always)
    private static func grad(_ hash: Int, _ x: Double, _ y: Double, _ z: Double) -> Double {
        let h = hash & 15
        let u = h < 8 ? x : y
        let v = h < 4 ? y : (h == 12 || h == 14 ? x : z)
        return ((h & 1) == 0 ? u : -u) + ((h & 2) == 0 ? v : -v)
    }

    @inline(__always)
    private static func wrap256(_ x: Double) -> Double {
        // Perlin noise repeats every 256 units, so reducing keeps precision after hours of motion.
        guard x.isFinite else { return 0 }
        let r = x.truncatingRemainder(dividingBy: 256)
        return r < 0 ? r + 256 : r
    }

    /// Gradient noise in −1…1.
    static func noise3(_ x: Double, _ y: Double, _ z: Double) -> Double {
        let x = wrap256(x), y = wrap256(y), z = wrap256(z)
        let fx = x.rounded(.down), fy = y.rounded(.down), fz = z.rounded(.down)
        let X = Int(fx) & 255, Y = Int(fy) & 255, Z = Int(fz) & 255
        let xf = x - fx, yf = y - fy, zf = z - fz
        let u = fade(xf), v = fade(yf), w = fade(zf)
        let p = perm
        let A = p[X] + Y, AA = p[A] + Z, AB = p[A + 1] + Z
        let B = p[X + 1] + Y, BA = p[B] + Z, BB = p[B + 1] + Z
        let x1 = lerpD(grad(p[AA], xf, yf, zf), grad(p[BA], xf - 1, yf, zf), u)
        let x2 = lerpD(grad(p[AB], xf, yf - 1, zf), grad(p[BB], xf - 1, yf - 1, zf), u)
        let y1 = lerpD(x1, x2, v)
        let x3 = lerpD(grad(p[AA + 1], xf, yf, zf - 1), grad(p[BA + 1], xf - 1, yf, zf - 1), u)
        let x4 = lerpD(grad(p[AB + 1], xf, yf - 1, zf - 1), grad(p[BB + 1], xf - 1, yf - 1, zf - 1), u)
        let y2 = lerpD(x3, x4, v)
        return max(-1, min(1, lerpD(y1, y2, w)))
    }

    /// Fractal sum of `octaves` noise layers, normalised to −1…1.
    static func fbm3(_ x: Double, _ y: Double, _ z: Double, octaves: Int) -> Double {
        var sum = 0.0, amp = 1.0, norm = 0.0, f = 1.0
        for _ in 0..<max(1, min(octaves, 5)) {
            sum += amp * noise3(x * f, y * f, z * f)
            norm += amp
            amp *= 0.5
            f *= 2
        }
        return sum / norm
    }

    @inline(__always)
    private static func lerpD(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    /// Deterministic per-pixel Poisson glints (§3.3 helpers): events at ≤ `rate` per second with a
    /// ≥ 1 s refractory slot, each a smooth `env(ta, td)`. Returns 0…1.
    static func sparkle(seed: UInt64, time t: Double, rate: Double, ta: Double = 0.05, td: Double = 0.35) -> Double {
        guard rate > 0, t.isFinite else { return 0 }
        let slot = 1.0
        let p = min(1, rate * slot)
        let k = (t / slot).rounded(.down)
        var best = 0.0
        for j in 0..<2 {
            let idx = k - Double(j)
            let ui = UInt64(bitPattern: Int64(idx))
            guard hash01(seed, ui) < p else { continue }
            let at = (idx + 0.7 * hash01(seed &+ 0x51, ui)) * slot
            best = max(best, env(t - at, ta: ta, td: td))
        }
        return best
    }
}
