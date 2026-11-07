import Foundation

/// Color science used across Prism. Pure functions, no state.
///
/// Conventions:
///  - "linear" = linear-light RGB with sRGB/Rec.709 primaries, D65 white.
///  - Tint: -1 = full green … +1 = full magenta, mapped to Duv = -tint × `ColorMath.maxDuv`.
public enum ColorMath {
    /// Duv corresponding to tint = ±1 (≈ the range Aputure/ARRI G/M controls cover).
    public static let maxDuv = 0.02

    /// D65 reference white in CIE 1931 XYZ (matches the sRGB matrix row sums).
    public static let d65XYZ: (X: Double, Y: Double, Z: Double) = (0.9504700, 1.0000000, 1.0888300)

    /// D65 chromaticity in CIE 1931 xy.
    public static let d65XY: (x: Double, y: Double) = (0.3127266, 0.3290231)

    // MARK: sRGB transfer

    @inline(__always)
    public static func srgbToLinear(_ c: Double) -> Double {
        let c = clamp01(c)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    @inline(__always)
    public static func linearToSRGB(_ c: Double) -> Double {
        let c = clamp01(c)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    @inline(__always)
    public static func rgbToLinear(_ c: RGB) -> LinearRGB {
        c.linear
    }

    @inline(__always)
    public static func linearToRGB(_ c: LinearRGB) -> RGB {
        RGB(linear: c)
    }

    // MARK: Perceptual intensity transfer (CIE L* / Stevens power law)

    /// Converts a perceptual intensity `p` (0…1) to relative linear luminance `Y` (0…1)
    /// using the inverse CIE L* transfer function.
    @inline(__always)
    public static func perceptualToLinearIntensity(_ p: Double) -> Double {
        let p = clamp01(p.finiteOr(0))
        if p <= 0.08 {
            return p / 9.03296296296
        }
        let f = (p + 0.16) / 1.16
        return f * f * f
    }

    /// Converts a linear luminance `Y` (0…1) to perceptual lightness `L*` normalized to 0…1.
    @inline(__always)
    public static func linearToPerceptualIntensity(_ y: Double) -> Double {
        let y = clamp01(y.finiteOr(0))
        if y <= 0.008856451679 {
            return 9.03296296296 * y
        }
        return 1.16 * cbrt(y) - 0.16
    }

    // MARK: Planckian locus / CCT

    /// CIE 1931 xy of a blackbody at `kelvin` (Kim et al. cubic spline, valid 1667–25000K;
    /// values outside are clamped, with smooth C1 blending at the 2222K and 4000K spline knots).
    public static func planckianXY(_ kelvin: Double) -> (x: Double, y: Double) {
        let t = clamp(kelvin.finiteOr(5600), 1667, 25000)
        let t2 = t * t, t3 = t2 * t

        let xLow = -0.2661239e9 / t3 - 0.2343589e6 / t2 + 0.8776956e3 / t + 0.179910
        let xHigh = -3.0258469e9 / t3 + 2.1070379e6 / t2 + 0.2226347e3 / t + 0.240390
        let x: Double
        if t <= 3950 {
            x = xLow
        } else if t >= 4050 {
            x = xHigh
        } else {
            let w = smoothstep(3950, 4050, t)
            x = lerp(xLow, xHigh, w)
        }

        let x2 = x * x, x3 = x2 * x
        let yLow = -1.1063814 * x3 - 1.34811020 * x2 + 2.18555832 * x - 0.20219683
        let yMid = -0.9549476 * x3 - 1.37418593 * x2 + 2.09137015 * x - 0.16748867
        let yHigh = 3.0817580 * x3 - 5.87338670 * x2 + 3.75112997 * x - 0.37001483

        let y: Double
        if t <= 2200 {
            y = yLow
        } else if t < 2245 {
            y = lerp(yLow, yMid, smoothstep(2200, 2245, t))
        } else if t <= 3950 {
            y = yMid
        } else if t < 4050 {
            y = lerp(yMid, yHigh, smoothstep(3950, 4050, t))
        } else {
            y = yHigh
        }
        return (x, y)
    }

    /// Unit normal to the Planckian locus in CIE 1960 (u, v) space at `kelvin`, pointing toward
    /// positive Duv (+v, greener).
    @inline(__always)
    static func planckianUVNormal(_ kelvin: Double) -> (nu: Double, nv: Double) {
        let k = clamp(kelvin.finiteOr(5600), 1667, 25000)
        let m = 1_000_000.0 / k
        let dm = 0.02
        let k1 = clamp(1_000_000.0 / (m + dm), 1667, 25000)
        let k2 = clamp(1_000_000.0 / max(m - dm, 40), 1667, 25000)
        let p1 = planckianXY(k1), p2 = planckianXY(k2)
        let (u1, v1) = xyToUV(p1.x, p1.y), (u2, v2) = xyToUV(p2.x, p2.y)
        var du = u2 - u1, dv = v2 - v1
        let len = max(sqrt(du * du + dv * dv), 1e-12)
        du /= len; dv /= len
        var nu = dv, nv = -du
        if nv < 0 { nu = -nu; nv = -nv }
        return (nu, nv)
    }

    /// xy for a CCT plus tint (green/magenta offset perpendicular to the locus in CIE 1960 uv).
    public static func kelvinToXY(_ kelvin: Double, tint: Double = 0) -> (x: Double, y: Double) {
        let k = clamp(kelvin.finiteOr(5600), 1667, 25000)
        let base = planckianXY(k)
        let tint = clamp(tint.finiteOr(0), -1, 1)
        guard abs(tint) > 1e-7 else { return base }
        let duv = -tint * maxDuv // positive Duv = above locus = greener
        let (u0, v0) = xyToUV(base.x, base.y)
        let (nu, nv) = planckianUVNormal(k)
        let u = u0 + duv * nu, v = v0 + duv * nv
        return uvToXY(u, v)
    }

    public static func kelvinToXY(kelvin: Double, tint: Double = 0) -> (x: Double, y: Double) {
        kelvinToXY(kelvin, tint: tint)
    }

    public static func kelvinToRGB(_ kelvin: Double, tint: Double = 0) -> RGB {
        let (x, y) = kelvinToXY(kelvin, tint: tint)
        return RGB(linear: xyToLinearSRGB(x: x, y: y).normalized)
    }

    public static func kelvinToRGB(kelvin: Double, tint: Double = 0) -> RGB {
        kelvinToRGB(kelvin, tint: tint)
    }

    /// CIE 1960 UCS (u, v), used for CCT and Duv calculations.
    @inline(__always)
    public static func xyToUV(_ x: Double, _ y: Double) -> (u: Double, v: Double) {
        let d = -2 * x + 12 * y + 3
        guard abs(d) > 1e-12 else { return (0.2, 0.3) }
        return (4 * x / d, 6 * y / d)
    }

    @inline(__always)
    public static func uvToXY(_ u: Double, _ v: Double) -> (x: Double, y: Double) {
        let d = 2 * u - 8 * v + 4
        guard abs(d) > 1e-12 else { return (0.3127, 0.329) }
        return (3 * u / d, 2 * v / d)
    }

    /// CIE 1976 UCS (u', v').
    @inline(__always)
    public static func xyToUPrimeVPrime(_ x: Double, _ y: Double) -> (uPrime: Double, vPrime: Double) {
        let (u, v) = xyToUV(x, y)
        return (u, 1.5 * v)
    }

    @inline(__always)
    public static func uPrimeVPrimeToXY(_ uPrime: Double, _ vPrime: Double) -> (x: Double, y: Double) {
        uvToXY(uPrime, vPrime / 1.5)
    }

    /// Planckian locus sampled in CIE 1960 (u, v) at 1-mired steps from 40 mired (25000 K) to
    /// 600 mired (1667 K), interleaved as `[u0, v0, u1, v1, …]`. Built once, read-only afterwards.
    private static let locusUVTable: [Double] = {
        var table: [Double] = []
        table.reserveCapacity(2 * 561)
        for i in 0..<561 {
            let p = planckianXY(1_000_000.0 / (40.0 + Double(i)))
            let uv = xyToUV(p.x, p.y)
            table.append(uv.u)
            table.append(uv.v)
        }
        return table
    }()

    /// CCT and signed Duv for a chromaticity in CIE 1931 xy.
    /// Positive Duv is above the Planckian locus (greener); negative Duv is below (more magenta).
    ///
    /// Real-time safe: a coarse + local scan of a precomputed 1-mired locus table, parabolic
    /// refinement (≈ 0.001 mired), then one exact locus/normal evaluation for Duv. Agrees with the
    /// exhaustive search (`xyToKelvinAndDuvReference`) to well under 1 K and 1e-5 Duv near the locus.
    public static func xyToKelvinAndDuv(x: Double, y: Double) -> (kelvin: Double, duv: Double) {
        guard x.isFinite, y.isFinite else { return (5600, 0) }
        let (u, v) = xyToUV(x, y)
        let mired: Double = locusUVTable.withUnsafeBufferPointer { t -> Double in
            let n = t.count / 2
            guard n > 2 else { return 1_000_000.0 / 5600.0 }
            @inline(__always)
            func dist2(_ i: Int) -> Double {
                let du = u - t[2 * i], dv = v - t[2 * i + 1]
                return du * du + dv * dv
            }
            var best = 0
            var bestD = Double.infinity
            var i = 0
            while i < n {
                let d = dist2(i)
                if d < bestD { bestD = d; best = i }
                i += 8
            }
            let last = dist2(n - 1)
            if last < bestD { bestD = last; best = n - 1 }
            var j = max(0, best - 8)
            let hi = min(n - 1, best + 8)
            while j <= hi {
                let d = dist2(j)
                if d < bestD { bestD = d; best = j }
                j += 1
            }
            var m = 40.0 + Double(best)
            if best > 0 && best < n - 1 {
                let fm = dist2(best - 1), fp = dist2(best + 1)
                let denom = fm - 2 * bestD + fp
                if denom > 1e-30 {
                    m += clamp(0.5 * (fm - fp) / denom, -0.5, 0.5)
                }
            }
            return m
        }
        let kelvin = clamp(1_000_000.0 / mired, 1000, 25000)
        let locus = planckianXY(kelvin)
        let (ul, vl) = xyToUV(locus.x, locus.y)
        let (nu, nv) = planckianUVNormal(kelvin)
        let duv = (u - ul) * nu + (v - vl) * nv
        return (kelvin, duv)
    }

    /// Exhaustive reference CCT search (281-point scan + golden-section refinement on the exact
    /// locus). Too slow for the render loop; kept to validate `xyToKelvinAndDuv` in tests.
    static func xyToKelvinAndDuvReference(x: Double, y: Double) -> (kelvin: Double, duv: Double) {
        guard x.isFinite, y.isFinite else { return (5600, 0) }
        let (u, v) = xyToUV(x, y)
        @inline(__always)
        func dist2(_ mired: Double) -> Double {
            let p = planckianXY(1_000_000.0 / mired)
            let (ul, vl) = xyToUV(p.x, p.y)
            return (u - ul) * (u - ul) + (v - vl) * (v - vl)
        }
        // Mired range covering 1667K…25000K (40…600 mired).
        let lo = 40.0, hi = 600.0
        let steps = 280
        var best = lo
        var bestD = Double.infinity
        for i in 0...steps {
            let m = lo + (hi - lo) * Double(i) / Double(steps)
            let d = dist2(m)
            if d < bestD { bestD = d; best = m }
        }
        let stepSize = (hi - lo) / Double(steps)
        var a = max(lo, best - stepSize), b = min(hi, best + stepSize)
        let phi = (sqrt(5.0) - 1) / 2
        var c = b - phi * (b - a), d = a + phi * (b - a)
        var fc = dist2(c), fd = dist2(d)
        for _ in 0..<44 {
            if fc < fd {
                b = d; d = c; fd = fc; c = b - phi * (b - a); fc = dist2(c)
            } else {
                a = c; c = d; fc = fd; d = a + phi * (b - a); fd = dist2(d)
            }
        }
        let mired = (a + b) / 2
        let kelvin = clamp(1_000_000.0 / mired, 1000, 25000)
        let locus = planckianXY(kelvin)
        let (ul, vl) = xyToUV(locus.x, locus.y)
        let (nu, nv) = planckianUVNormal(kelvin)
        let duv = (u - ul) * nu + (v - vl) * nv
        return (kelvin, duv)
    }

    /// CCT and tint for a chromaticity: finds the closest point on the Planckian locus in
    /// CIE 1960 uv (table scan in mired space + parabolic refinement, see `xyToKelvinAndDuv`), then
    /// derives the signed Duv (positive = above the locus = greener) and maps it to tint (−1…+1).
    public static func xyToKelvinAndTint(x: Double, y: Double) -> (kelvin: Double, tint: Double) {
        let (kelvin, duv) = xyToKelvinAndDuv(x: x, y: y)
        return (kelvin, duvToTint(duv))
    }

    // MARK: Tint / Duv / Aputure & Sidus G/M mappings

    /// Converts Prism tint (-1 = full green … +1 = full magenta) to CIE 1960 Duv.
    @inline(__always)
    public static func tintToDuv(_ tint: Double) -> Double {
        -clamp(tint.finiteOr(0), -1, 1) * maxDuv
    }

    /// Converts CIE 1960 Duv to Prism tint (-1 = full green … +1 = full magenta).
    @inline(__always)
    public static func duvToTint(_ duv: Double) -> Double {
        clamp(-duv.finiteOr(0) / maxDuv, -1, 1)
    }

    /// Converts Prism tint (-1 = green … +1 = magenta) to the Aputure/Sidus G/M scale
    /// (-1.0 = Full Minus Green / Magenta … 0 = Neutral … +1.0 = Full Plus Green).
    @inline(__always)
    public static func tintToSidusGM(_ tint: Double) -> Double {
        -clamp(tint.finiteOr(0), -1, 1)
    }

    /// Converts Aputure/Sidus G/M (-1.0 = Full Minus Green … +1.0 = Full Plus Green) to Prism tint.
    @inline(__always)
    public static func sidusGMToTint(_ gm: Double) -> Double {
        -clamp(gm.finiteOr(0), -1, 1)
    }

    /// Encodes Prism tint (-1 = full green … 0 = neutral … +1 = full magenta) into Aputure's
    /// Gen-1 8-bit DMX G/M table (`docs/research/aputure_profiles.md` §1.1):
    ///  - 11–20: Full Minus Green (tint = +1)
    ///  - 21–119: -99% … -1% Minus Green
    ///  - 120–145: Neutral (128 default)
    ///  - 146–244: +1% … +99% Plus Green
    ///  - 245–255: Full Plus Green (tint = -1)
    public static func tintToAputureDMX(_ tint: Double) -> UInt8 {
        let t = clamp(tint.finiteOr(0), -1, 1)
        if abs(t) < 0.005 { return 128 }
        if t < 0 {
            // Plus Green: g in (0, 1]
            let g = -t
            if g >= 0.995 { return 250 }
            let f = clamp01((g - 0.01) / 0.98)
            return UInt8(clamp(Int((146.0 + f * 98.0).rounded()), 146, 244))
        } else {
            // Minus Green (Magenta): m in (0, 1]
            let m = t
            if m >= 0.995 { return 15 }
            let f = clamp01((m - 0.01) / 0.98)
            return UInt8(clamp(Int((119.0 - f * 98.0).rounded()), 21, 119))
        }
    }

    /// Decodes an Aputure Gen-1 8-bit G/M DMX value into Prism tint (-1 = green … +1 = magenta).
    public static func aputureDMXToTint(_ dmx: UInt8) -> Double {
        switch dmx {
        case 0...10, 120...145:
            return 0
        case 11...20:
            return 1.0
        case 21...119:
            let f = Double(119 - Int(dmx)) / 98.0
            return clamp(0.01 + f * 0.98, 0.01, 0.99)
        case 146...244:
            let f = Double(Int(dmx) - 146) / 98.0
            return -clamp(0.01 + f * 0.98, 0.01, 0.99)
        default: // 245...255
            return -1.0
        }
    }

    // MARK: XYZ / xyY <-> linear sRGB

    @inline(__always)
    public static func xyYToXYZ(x: Double, y: Double, Y: Double = 1) -> (X: Double, Y: Double, Z: Double) {
        let ySafe = max(y.finiteOr(0.329), 1e-6)
        let xSafe = x.finiteOr(0.3127)
        let YSafe = max(0, Y.finiteOr(1))
        let X = xSafe * YSafe / ySafe
        let Z = (1 - xSafe - ySafe) * YSafe / ySafe
        return (X, YSafe, Z)
    }

    @inline(__always)
    public static func xyzToXYY(X: Double, Y: Double, Z: Double) -> (x: Double, y: Double, Y: Double) {
        let sum = X + Y + Z
        guard sum > 1e-9, sum.isFinite else { return (d65XY.x, d65XY.y, max(0, Y.finiteOr(0))) }
        return (X / sum, Y / sum, Y)
    }

    public static func xyToLinearSRGB(x: Double, y: Double, Y: Double = 1) -> LinearRGB {
        let (X, YVal, Z) = xyYToXYZ(x: x, y: y, Y: Y)
        return xyzToLinearSRGB(X: X, Y: YVal, Z: Z)
    }

    /// Unclamped matrix conversion from CIE 1931 XYZ (D65) to linear sRGB.
    @inline(__always)
    public static func xyzToLinearSRGBUnclamped(X: Double, Y: Double, Z: Double) -> LinearRGB {
        LinearRGB(
            r: 3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z,
            g: -0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z,
            b: 0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z
        )
    }

    public static func xyzToLinearSRGB(X: Double, Y: Double, Z: Double) -> LinearRGB {
        xyzToLinearSRGBUnclamped(X: X, Y: Y, Z: Z).clampedNonNegative
    }

    public static func linearSRGBToXYZ(_ c: LinearRGB) -> (X: Double, Y: Double, Z: Double) {
        (
            0.4124564 * c.r + 0.3575761 * c.g + 0.1804375 * c.b,
            0.2126729 * c.r + 0.7151522 * c.g + 0.0721750 * c.b,
            0.0193339 * c.r + 0.1191920 * c.g + 0.9503041 * c.b
        )
    }

    public static func linearSRGBToXY(_ c: LinearRGB) -> (x: Double, y: Double) {
        let (X, Y, Z) = linearSRGBToXYZ(c)
        let sum = X + Y + Z
        guard sum > 1e-9 else { return (0.3127, 0.3290) }
        return (X / sum, Y / sum)
    }

    // MARK: OKLab & OKLCh (Björn Ottosson)

    public static func linearToOKLab(_ c: LinearRGB) -> (L: Double, a: Double, b: Double) {
        let r = c.r.finiteOr(0), g = c.g.finiteOr(0), b = c.b.finiteOr(0)
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        return (
            0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        )
    }

    public static func okLabToLinear(L: Double, a: Double, b: Double) -> LinearRGB {
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return LinearRGB(
            r: 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            g: -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            b: -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    @inline(__always)
    public static func okLabToOKLCh(L: Double, a: Double, b: Double) -> (L: Double, C: Double, h: Double) {
        let C = hypot(a, b)
        let h = C > 1e-9 ? wrapDegrees(atan2(b, a) * 180.0 / .pi) : 0
        return (L, C, h)
    }

    @inline(__always)
    public static func okLChToOKLab(L: Double, C: Double, h: Double) -> (L: Double, a: Double, b: Double) {
        let rad = h.finiteOr(0) * .pi / 180.0
        let cSafe = max(0, C.finiteOr(0))
        return (L, cSafe * cos(rad), cSafe * sin(rad))
    }

    public static func linearToOKLCh(_ c: LinearRGB) -> (L: Double, C: Double, h: Double) {
        let lab = linearToOKLab(c)
        return okLabToOKLCh(L: lab.L, a: lab.a, b: lab.b)
    }

    public static func okLChToLinear(L: Double, C: Double, h: Double) -> LinearRGB {
        let lab = okLChToOKLab(L: L, C: C, h: h)
        return okLabToLinear(L: lab.L, a: lab.a, b: lab.b)
    }

    public static func rgbToOKLab(_ c: RGB) -> (L: Double, a: Double, b: Double) {
        linearToOKLab(c.linear)
    }

    public static func okLabToRGB(L: Double, a: Double, b: Double) -> RGB {
        RGB(linear: gamutMapOKLab(L: L, a: a, b: b))
    }

    public static func rgbToOKLCh(_ c: RGB) -> (L: Double, C: Double, h: Double) {
        linearToOKLCh(c.linear)
    }

    public static func okLChToRGB(L: Double, C: Double, h: Double) -> RGB {
        RGB(linear: gamutMapOKLCh(L: L, C: C, h: h))
    }

    // MARK: HSB / HSV and HSL

    public static func rgbToHSB(_ c: RGB) -> (h: Double, s: Double, b: Double) {
        c.hsb
    }

    public static func hsbToRGB(h: Double, s: Double, b: Double) -> RGB {
        RGB(hue: h, saturation: s, brightness: b)
    }

    public static func rgbToHSL(_ c: RGB) -> (h: Double, s: Double, l: Double) {
        let maxC = max(c.r, c.g, c.b)
        let minC = min(c.r, c.g, c.b)
        let delta = maxC - minC
        let l = 0.5 * (maxC + minC)
        guard delta > 1e-9 else { return (0, 0, l) }
        let s = delta / max(1 - abs(2 * l - 1), 1e-9)
        var h = 0.0
        if maxC == c.r {
            h = 60 * (((c.g - c.b) / delta).truncatingRemainder(dividingBy: 6))
        } else if maxC == c.g {
            h = 60 * (((c.b - c.r) / delta) + 2)
        } else {
            h = 60 * (((c.r - c.g) / delta) + 4)
        }
        return (wrapDegrees(h), clamp01(s), clamp01(l))
    }

    public static func hslToRGB(h: Double, s: Double, l: Double) -> RGB {
        let s = clamp01(s.finiteOr(0))
        let l = clamp01(l.finiteOr(0))
        let c = (1 - abs(2 * l - 1)) * s
        let hPrime = wrapDegrees(h.finiteOr(0)) / 60.0
        let x = c * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))
        let m = l - 0.5 * c
        let (r1, g1, b1): (Double, Double, Double)
        switch hPrime {
        case 0..<1: (r1, g1, b1) = (c, x, 0)
        case 1..<2: (r1, g1, b1) = (x, c, 0)
        case 2..<3: (r1, g1, b1) = (0, c, x)
        case 3..<4: (r1, g1, b1) = (0, x, c)
        case 4..<5: (r1, g1, b1) = (x, 0, c)
        default:    (r1, g1, b1) = (c, 0, x)
        }
        return RGB(r: r1 + m, g: g1 + m, b: b1 + m)
    }

    // MARK: Gamut mapping in OKLCh (preserve hue & lightness, reduce chroma)

    /// True if all linear sRGB components lie within `[0, 1]` up to `tolerance`.
    @inline(__always)
    public static func inSRGBGamut(_ c: LinearRGB, tolerance: Double = 1e-6) -> Bool {
        c.r >= -tolerance && c.r <= 1 + tolerance &&
        c.g >= -tolerance && c.g <= 1 + tolerance &&
        c.b >= -tolerance && c.b <= 1 + tolerance
    }

    /// Maps an OKLCh color into the `[0, 1]` linear sRGB gamut by preserving `L` and `h`
    /// and bisecting chroma `C` (CSS Color 4 / lighting gamut reduction).
    public static func gamutMapOKLCh(L: Double, C: Double, h: Double) -> LinearRGB {
        let L = clamp01(L.finiteOr(0))
        if L <= 1e-7 { return .black }
        if L >= 1 - 1e-7 { return .white }
        let cMax = max(0, C.finiteOr(0))
        let candidate = okLChToLinear(L: L, C: cMax, h: h)
        if inSRGBGamut(candidate) {
            return candidate.clamped
        }
        var lo = 0.0
        var hi = cMax
        for _ in 0..<16 {
            let mid = 0.5 * (lo + hi)
            let rgb = okLChToLinear(L: L, C: mid, h: h)
            if inSRGBGamut(rgb, tolerance: 1e-5) {
                lo = mid
            } else {
                hi = mid
            }
        }
        return okLChToLinear(L: L, C: lo, h: h).clamped
    }

    /// Maps an OKLab color into the `[0, 1]` linear sRGB gamut by preserving `L` and hue angle
    /// while reducing chroma.
    public static func gamutMapOKLab(L: Double, a: Double, b: Double) -> LinearRGB {
        let lch = okLabToOKLCh(L: L, a: a, b: b)
        return gamutMapOKLCh(L: lch.L, C: lch.C, h: lch.h)
    }

    /// Maps an arbitrary `LinearRGB` color into the `[0, 1]` sRGB gamut by reducing chroma in OKLCh.
    public static func gamutMap(_ c: LinearRGB) -> LinearRGB {
        if inSRGBGamut(c) { return c.clamped }
        let lch = linearToOKLCh(c)
        return gamutMapOKLCh(L: lch.L, C: lch.C, h: lch.h)
    }

    /// Perceptual interpolation in OKLab with chroma restoration (prevents grey dips on
    /// complementary fades such as red → cyan, per `docs/research/music_reactive.md` §4.5).
    public static func mixOKLab(_ a: LinearRGB, _ b: LinearRGB, _ t: Double) -> LinearRGB {
        let t = clamp01(t.finiteOr(0))
        if t <= 0 { return a }
        if t >= 1 { return b }
        let la = linearToOKLab(a)
        let lb = linearToOKLab(b)
        let ca = hypot(la.a, la.b)
        let cb = hypot(lb.a, lb.b)
        let Lm = lerp(la.L, lb.L, t)

        // When either endpoint is nearly neutral/white, interpolate directly along the OKLab line.
        if min(ca, cb) < 0.02 {
            let am = lerp(la.a, lb.a, t)
            let bm = lerp(la.b, lb.b, t)
            return gamutMapOKLab(L: Lm, a: am, b: bm)
        }

        let ha = wrapDegrees(atan2(la.b, la.a) * 180.0 / .pi)
        let hb = wrapDegrees(atan2(lb.b, lb.a) * 180.0 / .pi)
        var dh = hb - ha
        if dh > 180 { dh -= 360 }
        if dh < -180 { dh += 360 }
        let ct = lerp(ca, cb, t)

        if abs(dh) <= 150 {
            var am = lerp(la.a, lb.a, t)
            var bm = lerp(la.b, lb.b, t)
            let cm = hypot(am, bm)
            if cm > 1e-4 {
                let scale = ct / cm
                am *= scale
                bm *= scale
            }
            return gamutMapOKLab(L: Lm, a: am, b: bm)
        } else {
            // Near-complementary hues (e.g. red ↔ cyan): traverse the hue arc whose midpoint has
            // higher gamut-cusp chroma so the midpoint stays vivid instead of dipping through grey.
            let hShort = wrapDegrees(ha + dh * t)
            let dhAlt = dh > 0 ? dh - 360 : dh + 360
            let hMid1 = wrapDegrees(ha + 0.5 * dh)
            let hMid2 = wrapDegrees(ha + 0.5 * dhAlt)
            let c1 = gamutMapOKLCh(L: Lm, C: ct, h: hMid1)
            let c2 = gamutMapOKLCh(L: Lm, C: ct, h: hMid2)
            let lch1 = linearToOKLCh(c1)
            let lch2 = linearToOKLCh(c2)
            let hChosen = lch1.C >= lch2.C - 0.01 ? hShort : wrapDegrees(ha + dhAlt * t)
            return gamutMapOKLCh(L: Lm, C: ct, h: hChosen)
        }
    }

    // MARK: CIE 1976 L*a*b* and Color Difference (ΔE2000 & ΔE OKLab)

    /// Converts CIE 1931 XYZ (relative to D65 with Y_n = 1) to CIE 1976 L*a*b*.
    public static func xyzToCIELab(X: Double, Y: Double, Z: Double) -> (L: Double, a: Double, b: Double) {
        let epsilon = 216.0 / 24389.0 // (6/29)^3 ≈ 0.00885645
        let kappa = 24389.0 / 27.0    // (29/3)^3 ≈ 903.2963
        @inline(__always)
        func f(_ u: Double) -> Double {
            let u = max(0, u.finiteOr(0))
            return u > epsilon ? cbrt(u) : (kappa * u + 16.0) / 116.0
        }
        let fx = f(X / d65XYZ.X)
        let fy = f(Y / d65XYZ.Y)
        let fz = f(Z / d65XYZ.Z)
        return (
            L: 116.0 * fy - 16.0,
            a: 500.0 * (fx - fy),
            b: 200.0 * (fy - fz)
        )
    }

    /// Converts CIE 1976 L*a*b* to CIE 1931 XYZ (relative to D65 with Y_n = 1).
    public static func cieLabToXYZ(L: Double, a: Double, b: Double) -> (X: Double, Y: Double, Z: Double) {
        let epsilon = 216.0 / 24389.0
        let kappa = 24389.0 / 27.0
        let fy = (L + 16.0) / 116.0
        let fx = fy + a / 500.0
        let fz = fy - b / 200.0
        @inline(__always)
        func fInv(_ t: Double) -> Double {
            let t3 = t * t * t
            return t3 > epsilon ? t3 : (116.0 * t - 16.0) / kappa
        }
        let xr = fInv(fx)
        let yr = L > kappa * epsilon ? fy * fy * fy : L / kappa
        let zr = fInv(fz)
        return (max(0, xr * d65XYZ.X), max(0, yr * d65XYZ.Y), max(0, zr * d65XYZ.Z))
    }

    public static func linearToCIELab(_ c: LinearRGB) -> (L: Double, a: Double, b: Double) {
        let xyz = linearSRGBToXYZ(c)
        return xyzToCIELab(X: xyz.X, Y: xyz.Y, Z: xyz.Z)
    }

    public static func rgbToCIELab(_ c: RGB) -> (L: Double, a: Double, b: Double) {
        linearToCIELab(c.linear)
    }

    /// Euclidean distance in OKLab space.
    @inline(__always)
    public static func deltaEOKLab(L1: Double, a1: Double, b1: Double, L2: Double, a2: Double, b2: Double) -> Double {
        let dL = L1 - L2, da = a1 - a2, db = b1 - b2
        return sqrt(dL * dL + da * da + db * db)
    }

    public static func deltaEOKLab(_ c1: LinearRGB, _ c2: LinearRGB) -> Double {
        let l1 = linearToOKLab(c1), l2 = linearToOKLab(c2)
        return deltaEOKLab(L1: l1.L, a1: l1.a, b1: l1.b, L2: l2.L, a2: l2.a, b2: l2.b)
    }

    public static func deltaEOKLab(_ c1: RGB, _ c2: RGB) -> Double {
        deltaEOKLab(c1.linear, c2.linear)
    }

    public static func deltaEOKLab(_ c1: LightColor, _ c2: LightColor) -> Double {
        deltaEOKLab(c1.linearRGB, c2.linearRGB)
    }

    /// CIEDE2000 color difference (Sharma, Wu, Dalal 2005) for two CIE L*a*b* colors.
    public static func deltaE2000(L1: Double, a1: Double, b1: Double, L2: Double, a2: Double, b2: Double) -> Double {
        let c1 = hypot(a1, b1)
        let c2 = hypot(a2, b2)
        let cBar = 0.5 * (c1 + c2)
        let cBar7 = pow(cBar, 7)
        let twentyFive7 = 6_103_515_625.0 // 25^7
        let g = 0.5 * (1.0 - sqrt(cBar7 / (cBar7 + twentyFive7)))

        let a1Prime = (1.0 + g) * a1
        let a2Prime = (1.0 + g) * a2
        let c1Prime = hypot(a1Prime, b1)
        let c2Prime = hypot(a2Prime, b2)

        @inline(__always)
        func hueDeg(_ aPrime: Double, _ bVal: Double) -> Double {
            if abs(aPrime) < 1e-12 && abs(bVal) < 1e-12 { return 0 }
            let deg = atan2(bVal, aPrime) * 180.0 / .pi
            return deg < 0 ? deg + 360.0 : deg
        }
        let h1Prime = hueDeg(a1Prime, b1)
        let h2Prime = hueDeg(a2Prime, b2)

        let dLPrime = L2 - L1
        let dCPrime = c2Prime - c1Prime

        let cProd = c1Prime * c2Prime
        let dhPrime: Double
        if cProd < 1e-12 {
            dhPrime = 0
        } else {
            let diff = h2Prime - h1Prime
            if abs(diff) <= 180.0 {
                dhPrime = diff
            } else if diff > 180.0 {
                dhPrime = diff - 360.0
            } else {
                dhPrime = diff + 360.0
            }
        }
        let dHPrime = 2.0 * sqrt(cProd) * sin((dhPrime * 0.5) * .pi / 180.0)

        let lBarPrime = 0.5 * (L1 + L2)
        let cBarPrime = 0.5 * (c1Prime + c2Prime)

        let hBarPrime: Double
        if cProd < 1e-12 {
            hBarPrime = h1Prime + h2Prime
        } else if abs(h1Prime - h2Prime) <= 180.0 {
            hBarPrime = 0.5 * (h1Prime + h2Prime)
        } else if h1Prime + h2Prime < 360.0 {
            hBarPrime = 0.5 * (h1Prime + h2Prime + 360.0)
        } else {
            hBarPrime = 0.5 * (h1Prime + h2Prime - 360.0)
        }

        let t = 1.0
            - 0.17 * cos((hBarPrime - 30.0) * .pi / 180.0)
            + 0.24 * cos((2.0 * hBarPrime) * .pi / 180.0)
            + 0.32 * cos((3.0 * hBarPrime + 6.0) * .pi / 180.0)
            - 0.20 * cos((4.0 * hBarPrime - 63.0) * .pi / 180.0)

        let dTheta = 30.0 * exp(-pow((hBarPrime - 275.0) / 25.0, 2))
        let cBarPrime7 = pow(cBarPrime, 7)
        let rC = 2.0 * sqrt(cBarPrime7 / (cBarPrime7 + twentyFive7))

        let lBarMinus50Sq = (lBarPrime - 50.0) * (lBarPrime - 50.0)
        let sL = 1.0 + (0.015 * lBarMinus50Sq) / sqrt(20.0 + lBarMinus50Sq)
        let sC = 1.0 + 0.045 * cBarPrime
        let sH = 1.0 + 0.015 * cBarPrime * t
        let rT = -sin((2.0 * dTheta) * .pi / 180.0) * rC

        let termL = dLPrime / sL
        let termC = dCPrime / sC
        let termH = dHPrime / sH
        return sqrt(max(0, termL * termL + termC * termC + termH * termH + rT * termC * termH))
    }

    public static func deltaE2000(_ c1: LinearRGB, _ c2: LinearRGB) -> Double {
        let lab1 = linearToCIELab(c1)
        let lab2 = linearToCIELab(c2)
        return deltaE2000(L1: lab1.L, a1: lab1.a, b1: lab1.b, L2: lab2.L, a2: lab2.a, b2: lab2.b)
    }

    public static func deltaE2000(_ c1: RGB, _ c2: RGB) -> Double {
        deltaE2000(c1.linear, c2.linear)
    }

    public static func deltaE2000(_ c1: LightColor, _ c2: LightColor) -> Double {
        deltaE2000(c1.linearRGB, c2.linearRGB)
    }

    /// CIEDE2000 between two CIE 1931 xy chromaticities at equal luminance `Y`.
    public static func deltaE2000(xy1: (x: Double, y: Double), xy2: (x: Double, y: Double), Y: Double = 1.0) -> Double {
        let xyz1 = xyYToXYZ(x: xy1.x, y: xy1.y, Y: Y)
        let xyz2 = xyYToXYZ(x: xy2.x, y: xy2.y, Y: Y)
        let lab1 = xyzToCIELab(X: xyz1.X, Y: xyz1.Y, Z: xyz1.Z)
        let lab2 = xyzToCIELab(X: xyz2.X, Y: xyz2.Y, Z: xyz2.Z)
        return deltaE2000(L1: lab1.L, a1: lab1.a, b1: lab1.b, L2: lab2.L, a2: lab2.a, b2: lab2.b)
    }
}

extension LinearRGB {
    var clampedNonNegative: LinearRGB {
        LinearRGB(r: max(0, r.finiteOr(0)), g: max(0, g.finiteOr(0)), b: max(0, b.finiteOr(0)))
    }
}
