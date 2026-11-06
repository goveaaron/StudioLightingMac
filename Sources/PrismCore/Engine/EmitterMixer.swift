import Foundation

/// Converts a device-independent color into emitter drive levels (0…1) for whatever emitters a
/// fixture has. Baseline implementation: white extraction for RGBW/RGBWW, CCT split for
/// warm/cool whites. (Refined emitter-chromaticity based mixing lives here too.)
public enum EmitterMixer {
    /// Nominal CCT of a "warm white" emitter and a "cool white" emitter.
    public static let warmWhiteK = 2700.0
    public static let coolWhiteK = 6500.0

    /// Returns drive levels keyed by emitter kind, max component ≤ 1.
    /// - Parameters:
    ///   - color: target color (chromaticity; brightness is handled by intensity)
    ///   - emitters: the emitter kinds available on this fixture/cell
    ///   - calibration: per-fixture calibration
    public static func mix(_ color: LightColor, emitters: Set<ChannelKind>, calibration: ColorCalibration = .default) -> [ChannelKind: Double] {
        var out: [ChannelKind: Double] = [:]
        guard !emitters.isEmpty else { return out }

        let hasRGB = emitters.isSuperset(of: [.red, .green, .blue])
        let hasW = emitters.contains(.white)
        let hasWW = emitters.contains(.warmWhite)
        let hasCW = emitters.contains(.coolWhite)

        // Bi-color only fixtures (warm + cool whites, no RGB).
        if !hasRGB {
            if hasWW || hasCW {
                let k = color.approximateKelvin.kelvin
                let mixT = clamp01((1e6 / warmWhiteK - 1e6 / max(k, 1)) / (1e6 / warmWhiteK - 1e6 / coolWhiteK))
                if hasWW && hasCW {
                    // Constant-power-ish split, then normalize to full output.
                    let ww = 1 - mixT, cw = mixT
                    let m = max(ww, cw, 1e-6)
                    out[.warmWhite] = ww / m
                    out[.coolWhite] = cw / m
                } else if hasWW {
                    out[.warmWhite] = 1
                } else {
                    out[.coolWhite] = 1
                }
            }
            if hasW { out[.white] = 1 }
            return applyCalibration(out, calibration)
        }

        // Start from linear (photometric) or direct sRGB values.
        var rgb: LinearRGB
        if calibration.accurateColor {
            rgb = color.linearRGB
        } else {
            let d = color.displayRGB
            rgb = LinearRGB(r: d.r, g: d.g, b: d.b).normalized
        }

        if hasW || hasWW || hasCW {
            // Extract the common white component and send it to the white emitter(s).
            let w = max(0, min(rgb.r, rgb.g, rgb.b))
            rgb = LinearRGB(r: rgb.r - w, g: rgb.g - w, b: rgb.b - w)
            if hasWW && hasCW {
                let k = color.isWhiteish ? color.approximateKelvin.kelvin : 5600
                let t = clamp01((1e6 / warmWhiteK - 1e6 / max(k, 1)) / (1e6 / warmWhiteK - 1e6 / coolWhiteK))
                out[.warmWhite] = w * (1 - t)
                out[.coolWhite] = w * t
            } else if hasW {
                out[.white] = w
            } else if hasWW {
                out[.warmWhite] = w
            } else if hasCW {
                out[.coolWhite] = w
            }
        }
        out[.red] = rgb.r
        out[.green] = rgb.g
        out[.blue] = rgb.b

        // Normalize so the strongest emitter is at full drive (brightness comes from intensity).
        let m = out.values.max() ?? 0
        if m > 1e-9 { for (k, v) in out { out[k] = v / m } }
        return applyCalibration(out, calibration)
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
