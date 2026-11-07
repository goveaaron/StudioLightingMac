import Foundation

/// Picks a small palette of distinct, light-friendly colours from an image (for "drop a photo,
/// get 5 colours, spread them across the selection").
///
/// Deterministic: weighted k-means in OKLab on a fixed-stride subsample, seeded from the most
/// vivid pixel with farthest-point initialisation. Near-black pixels are ignored (a light can't
/// play black) and vivid pixels weigh more than greys, so a sunset photo gives oranges, pinks
/// and purples rather than five browns.
public enum PaletteExtractor {
    /// Most samples considered per image.
    public static let maxSamples = 4096

    struct Sample {
        var L: Double
        var a: Double
        var b: Double
        var weight: Double
    }

    /// Palette from raw RGBA8 pixels (row-major, 4 bytes per pixel, alpha last).
    /// - Parameter count: colours wanted (clamped to 1…8).
    public static func palette(rgba: [UInt8], width: Int, height: Int, count: Int = 5) -> [RGB] {
        guard width > 0, height > 0 else { return [] }
        let total = min(width * height, rgba.count / 4)
        guard total > 0 else { return [] }
        let step = max(1, total / maxSamples)
        var colors: [RGB] = []
        colors.reserveCapacity(min(total, maxSamples + 1))
        var i = 0
        while i < total {
            let o = i * 4
            if o + 3 < rgba.count, rgba[o + 3] >= 128 {
                colors.append(RGB(r255: Int(rgba[o]), g255: Int(rgba[o + 1]), b255: Int(rgba[o + 2])))
            }
            i += step
        }
        return palette(colors: colors, count: count)
    }

    /// Palette from a list of colours (already sampled).
    public static func palette(colors: [RGB], count: Int = 5) -> [RGB] {
        let k = clamp(count, 1, 8)
        let step = max(1, colors.count / maxSamples)
        var samples: [Sample] = []
        samples.reserveCapacity(min(colors.count, maxSamples + 1))
        var idx = 0
        while idx < colors.count {
            let c = colors[idx]
            idx += step
            guard c.hsv.v >= 0.12 else { continue }
            let lab = c.okLab
            guard lab.L.isFinite, lab.a.isFinite, lab.b.isFinite else { continue }
            let chroma = (lab.a * lab.a + lab.b * lab.b).squareRoot()
            samples.append(Sample(L: lab.L, a: lab.a, b: lab.b, weight: 0.2 + chroma * 5))
        }
        guard !samples.isEmpty else { return [] }

        // Farthest-point initialisation from the most vivid sample.
        var centers: [Sample] = []
        if let seed = samples.max(by: { chroma($0) < chroma($1) }) { centers.append(seed) }
        while centers.count < k {
            var best: Sample?
            var bestScore = 0.0
            for s in samples {
                let d = centers.map { distance($0, s) }.min() ?? 0
                let score = d * s.weight
                if score > bestScore + 1e-12 {
                    bestScore = score
                    best = s
                }
            }
            guard let next = best, bestScore > 1e-6 else { break }
            centers.append(next)
        }

        // Weighted k-means.
        var assignment = [Int](repeating: -1, count: samples.count)
        for _ in 0..<16 {
            var changed = false
            for (si, s) in samples.enumerated() {
                var bestIndex = 0
                var bestDistance = Double.infinity
                for (ci, c) in centers.enumerated() {
                    let d = distance(c, s)
                    if d < bestDistance {
                        bestDistance = d
                        bestIndex = ci
                    }
                }
                if assignment[si] != bestIndex {
                    assignment[si] = bestIndex
                    changed = true
                }
            }
            var sums = [Sample](repeating: Sample(L: 0, a: 0, b: 0, weight: 0), count: centers.count)
            for (si, s) in samples.enumerated() {
                let ci = assignment[si]
                guard ci >= 0, ci < sums.count else { continue }
                sums[ci].L += s.L * s.weight
                sums[ci].a += s.a * s.weight
                sums[ci].b += s.b * s.weight
                sums[ci].weight += s.weight
            }
            for ci in centers.indices where sums[ci].weight > 0 {
                let w = sums[ci].weight
                centers[ci] = Sample(L: sums[ci].L / w, a: sums[ci].a / w, b: sums[ci].b / w, weight: w)
            }
            for ci in centers.indices where sums[ci].weight <= 0 {
                centers[ci].weight = 0
            }
            if !changed { break }
        }

        // Merge near-duplicates (heaviest first), then order by hue for a pleasant strip.
        var clusters = centers.filter { $0.weight > 0 }.sorted { $0.weight > $1.weight }
        var merged: [Sample] = []
        for c in clusters {
            if let j = merged.firstIndex(where: { distance($0, c) < 0.05 }) {
                let w = merged[j].weight + c.weight
                merged[j] = Sample(L: (merged[j].L * merged[j].weight + c.L * c.weight) / w,
                                   a: (merged[j].a * merged[j].weight + c.a * c.weight) / w,
                                   b: (merged[j].b * merged[j].weight + c.b * c.weight) / w,
                                   weight: w)
            } else {
                merged.append(c)
            }
        }
        clusters = Array(merged.prefix(k))
        clusters.sort { hue($0) < hue($1) }
        return clusters.map { ColorMath.okLabToRGB(L: $0.L, a: $0.a, b: $0.b) }
    }

    /// Assigns palette colours to lights left-to-right (then front-to-back) across the stage,
    /// spanning the whole palette whether there are more lights or more colours.
    public static func spread(_ palette: [LightColor], over lights: [(id: UUID, x: Double, y: Double)]) -> [(id: UUID, color: LightColor)] {
        guard !palette.isEmpty, !lights.isEmpty else { return [] }
        let ordered = lights.enumerated().sorted { lhs, rhs in
            let a = lhs.element, b = rhs.element
            if abs(a.x - b.x) > 1e-6 { return a.x < b.x }
            if abs(a.y - b.y) > 1e-6 { return a.y < b.y }
            return lhs.offset < rhs.offset
        }.map(\.element)
        let n = ordered.count
        return ordered.enumerated().map { k, light in
            let index: Int
            if n <= palette.count {
                index = n == 1 ? 0 : Int((Double(k) * Double(palette.count - 1) / Double(n - 1)).rounded())
            } else {
                index = k * palette.count / n
            }
            return (id: light.id, color: palette[clamp(index, 0, palette.count - 1)])
        }
    }

    private static func distance(_ p: Sample, _ q: Sample) -> Double {
        let dL = p.L - q.L, da = p.a - q.a, db = p.b - q.b
        return (dL * dL + da * da + db * db).squareRoot()
    }

    private static func chroma(_ s: Sample) -> Double {
        (s.a * s.a + s.b * s.b).squareRoot()
    }

    private static func hue(_ s: Sample) -> Double {
        let h = atan2(s.b, s.a) * 180 / .pi
        return h < 0 ? h + 360 : h
    }
}
