import Foundation

/// Color science used across Prism. Pure functions, no state.
///
/// Conventions:
///  - "linear" = linear-light RGB with sRGB/Rec.709 primaries, D65 white.
///  - Tint: -1 = full green … +1 = full magenta, mapped to Duv = -tint × `ColorMath.maxDuv`.
public enum ColorMath {
    /// Duv corresponding to tint = ±1 (≈ the range Aputure/ARRI G/M controls cover).
    public static let maxDuv = 0.02

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

    // MARK: Planckian locus / CCT

    /// CIE 1931 xy of a blackbody at `kelvin` (Kim et al. cubic spline, valid 1667–25000K;
    /// values outside are clamped).
    public static func planckianXY(_ kelvin: Double) -> (x: Double, y: Double) {
        let t = clamp(kelvin.finiteOr(5600), 1667, 25000)
        let t2 = t * t, t3 = t2 * t
        let x: Double
        if t <= 4000 {
            x = -0.2661239e9 / t3 - 0.2343589e6 / t2 + 0.8776956e3 / t + 0.179910
        } else {
            x = -3.0258469e9 / t3 + 2.1070379e6 / t2 + 0.2226347e3 / t + 0.240390
        }
        let x2 = x * x, x3 = x2 * x
        let y: Double
        if t <= 2222 {
            y = -1.1063814 * x3 - 1.34811020 * x2 + 2.18555832 * x - 0.20219683
        } else if t <= 4000 {
            y = -0.9549476 * x3 - 1.37418593 * x2 + 2.09137015 * x - 0.16748867
        } else {
            y = 3.0817580 * x3 - 5.87338670 * x2 + 3.75112997 * x - 0.37001483
        }
        return (x, y)
    }

    /// xy for a CCT plus tint (green/magenta offset perpendicular to the locus in CIE 1960 uv).
    public static func kelvinToXY(_ kelvin: Double, tint: Double) -> (x: Double, y: Double) {
        let base = planckianXY(kelvin)
        let tint = clamp(tint.finiteOr(0), -1, 1)
        guard abs(tint) > 1e-6 else { return base }
        let duv = -tint * maxDuv // positive Duv = above locus = greener
        let (u0, v0) = xyToUV(base.x, base.y)
        // Tangent of the locus (direction of increasing temperature).
        let k = clamp(kelvin.finiteOr(5600), 1667, 25000)
        let p1 = planckianXY(k * 0.99), p2 = planckianXY(min(k * 1.01, 25000))
        let (u1, v1) = xyToUV(p1.x, p1.y), (u2, v2) = xyToUV(p2.x, p2.y)
        var du = u2 - u1, dv = v2 - v1
        let len = max(sqrt(du * du + dv * dv), 1e-12)
        du /= len; dv /= len
        // Normal pointing "above" the locus (toward green, +v).
        var nu = dv, nv = -du
        if nv < 0 { nu = -nu; nv = -nv }
        let u = u0 + duv * nu, v = v0 + duv * nv
        return uvToXY(u, v)
    }

    /// CIE 1960 UCS
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

    /// CCT and tint for a chromaticity: finds the closest point on the Planckian locus in
    /// CIE 1960 uv (coarse scan in mired space + golden-section refinement), then derives the
    /// signed Duv (positive = above the locus = greener) and maps it to tint (−1…+1).
    public static func xyToKelvinAndTint(x: Double, y: Double) -> (kelvin: Double, tint: Double) {
        guard x.isFinite, y.isFinite else { return (5600, 0) }
        let (u, v) = xyToUV(x, y)
        func dist2(_ mired: Double) -> Double {
            let p = planckianXY(1_000_000 / mired)
            let (ul, vl) = xyToUV(p.x, p.y)
            return (u - ul) * (u - ul) + (v - vl) * (v - vl)
        }
        // Mired range covering 1667K…25000K.
        let lo = 40.0, hi = 600.0
        let steps = 112
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
        for _ in 0..<40 {
            if fc < fd { b = d; d = c; fd = fc; c = b - phi * (b - a); fc = dist2(c) }
            else { a = c; c = d; fc = fd; d = a + phi * (b - a); fd = dist2(d) }
        }
        let mired = (a + b) / 2
        let kelvin = 1_000_000 / mired
        let locus = planckianXY(kelvin)
        let (ul, vl) = xyToUV(locus.x, locus.y)
        // Normal pointing above the locus (toward green, +v), as in `kelvinToXY`.
        let p1 = planckianXY(kelvin * 0.99), p2 = planckianXY(min(kelvin * 1.01, 25000))
        let (u1, v1) = xyToUV(p1.x, p1.y), (u2, v2) = xyToUV(p2.x, p2.y)
        var du = u2 - u1, dv = v2 - v1
        let len = max(sqrt(du * du + dv * dv), 1e-12)
        du /= len; dv /= len
        var nu = dv, nv = -du
        if nv < 0 { nu = -nu; nv = -nv }
        let duv = (u - ul) * nu + (v - vl) * nv
        return (clamp(kelvin, 1000, 25000), clamp(-duv / maxDuv, -1, 1))
    }

    // MARK: XYZ / xy <-> linear sRGB

    public static func xyToLinearSRGB(x: Double, y: Double, Y: Double = 1) -> LinearRGB {
        let y = max(y, 1e-6)
        let X = x * Y / y
        let Z = (1 - x - y) * Y / y
        return xyzToLinearSRGB(X: X, Y: Y, Z: Z)
    }

    public static func xyzToLinearSRGB(X: Double, Y: Double, Z: Double) -> LinearRGB {
        LinearRGB(
            r: 3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z,
            g: -0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z,
            b: 0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z
        ).clampedNonNegative
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

    // MARK: OKLab (Björn Ottosson) — for perceptually smooth interpolation

    public static func linearToOKLab(_ c: LinearRGB) -> (L: Double, a: Double, b: Double) {
        let l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b
        let m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b
        let s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b
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
}

extension LinearRGB {
    var clampedNonNegative: LinearRGB {
        LinearRGB(r: max(0, r.finiteOr(0)), g: max(0, g.finiteOr(0)), b: max(0, b.finiteOr(0)))
    }
}
