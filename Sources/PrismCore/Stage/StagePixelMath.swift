import Foundation

/// How a gradient lands on one fixture: per-cell states for pixel fixtures, one color otherwise.
public enum StageGradientFill: Hashable, Sendable {
    case cells([CellState])
    case whole(LightColor)
}

/// Pixel painting math: which cells a brush stroke touches and spatial gradients across cells.
public enum StagePixelMath {
    /// Cells of `footprint` touched by a stroke from `a` to `b` (stage meters), in stroke order,
    /// without duplicates. Samples densely so fast strokes don't skip cells.
    public static func cells(alongStroke a: StageVec, _ b: StageVec, footprint: StageFootprint,
                             tolerance: Double = 0) -> [Int] {
        guard footprint.cellCount > 0 else { return [] }
        let cellLength = footprint.length / Double(footprint.cellCount)
        let step = max(cellLength / 4, 1e-4)
        let n = min(4000, max(1, Int((b - a).length / step) + 1))
        var out: [Int] = []
        var seen = Set<Int>()
        for i in 0...n {
            let p = StageVec.lerp(a, b, Double(i) / Double(n))
            if let c = footprint.cellIndex(at: p, tolerance: tolerance), seen.insert(c).inserted { out.append(c) }
        }
        return out
    }

    /// Multi-stop gradient color at `t` (0…1), stops evenly spaced.
    public static func color(at t: Double, stops: [LightColor]) -> LightColor {
        guard let first = stops.first else { return .white }
        guard stops.count > 1 else { return first }
        let u = clamp01(t.finiteOr(0)) * Double(stops.count - 1)
        let i = min(Int(u.rounded(.down)), stops.count - 2)
        return LightColor.mix(stops[i], stops[i + 1], u - Double(i))
    }

    /// Spatial gradient from `a` to `b` (stage meters): every cell (or the whole fixture when it
    /// has no cells) takes the color at its projection onto the stroke, clamped to the ends.
    /// Dragging along one tube grades that tube; dragging across several grades them together.
    public static func gradient(from a: StageVec, to b: StageVec, colors: [LightColor],
                                targets: [(id: UUID, footprint: StageFootprint)],
                                intensity: Double = 1) -> [UUID: StageGradientFill] {
        guard !colors.isEmpty else { return [:] }
        var out: [UUID: StageGradientFill] = [:]
        let level = clamp01(intensity.finiteOr(1))
        for t in targets {
            let fp = t.footprint
            if fp.cellCount > 0 {
                let cells = (0..<fp.cellCount).map { i -> CellState in
                    let u = StageGeometry.projection(of: fp.cellCenter(i), ontoSegment: a, b)
                    return CellState(intensity: level, color: color(at: u, stops: colors))
                }
                out[t.id] = .cells(cells)
            } else {
                out[t.id] = .whole(color(at: StageGeometry.projection(of: fp.center, ontoSegment: a, b), stops: colors))
            }
        }
        return out
    }
}

/// A light source sample for scene lighting (props, subject rim light).
public struct StageLightSample: Hashable, Sendable {
    public var position: StageVec
    /// Full-value display color.
    public var color: RGB
    /// Output level 0…1 (fixture intensity × cell intensity).
    public var level: Double
    /// Reach in meters (where the contribution falls to zero).
    public var reach: Double

    public init(position: StageVec, color: RGB, level: Double, reach: Double) {
        self.position = position; self.color = color; self.level = clamp01(level.finiteOr(0)); self.reach = max(reach, 0.01)
    }
}

/// The visualizer's light model: how bright things look on screen for a given output level.
public enum StageLighting {
    /// Perceived on-screen brightness for an output level, so 10 % still reads as "on".
    public static func displayLevel(_ intensity: Double) -> Double {
        let i = clamp01(intensity.finiteOr(0))
        return i <= 0.0005 ? 0 : pow(i, 0.55)
    }

    /// Glow (spill) strength for an output level: closer to linear so the room really darkens.
    public static func glowLevel(_ intensity: Double) -> Double {
        let i = clamp01(intensity.finiteOr(0))
        return i <= 0.0005 ? 0 : pow(i, 0.8)
    }

    /// How far a light visibly spills (meters), growing gently with intensity.
    public static func spillRadius(kind: StageBodyKind, level: Double, size: Double) -> Double {
        let l = clamp01(level)
        let base: Double
        switch kind {
        case .tube, .bar, .strip: base = 0.95
        case .panel: base = 1.55
        case .softbox: base = 1.7
        case .fresnel, .par, .movingHead: base = 1.45
        case .bulb: base = 0.9
        case .round: base = 1.3
        }
        return (base + max(size, 0) * 0.35) * (0.62 + 0.38 * l.squareRoot())
    }

    /// Smooth falloff 1 → 0 over `reach` (approximates a soft inverse-square spill).
    public static func falloff(distance d: Double, reach: Double) -> Double {
        guard reach > 0 else { return 0 }
        let x = clamp01(d / reach)
        let s = 1 - x * x
        return s * s
    }

    /// Light arriving at `p` from all samples (linear-ish RGB, can exceed 1).
    public static func illumination(at p: StageVec, from samples: [StageLightSample]) -> (r: Double, g: Double, b: Double) {
        var r = 0.0, g = 0.0, b = 0.0
        for s in samples where s.level > 0 {
            let f = falloff(distance: p.distance(to: s.position), reach: s.reach) * s.level
            guard f > 0 else { continue }
            r += s.color.r * f; g += s.color.g * f; b += s.color.b * f
        }
        return (r, g, b)
    }
}
