import Foundation

/// Pure per-pixel edits for the inspector's pixel editor.
///
/// Every operation takes the light's current state and the editor's cell selection; an empty
/// selection means "all cells". Cells outside the selection are left exactly as they were, and
/// a light without a per-pixel pattern behaves as if every cell had the light's colour.
public enum PixelOps {
    /// Upper bound on cells handled (defensive; real fixtures have ≤ 256).
    public static let maxCells = 1024

    /// The per-cell states of a light with `count` cells (missing cells use the light's colour).
    public static func cells(of state: FixtureState, count: Int) -> [CellState] {
        let n = clamp(count, 0, maxCells)
        return (0..<n).map { state.cell($0) }
    }

    /// Indices an operation touches, ascending: the in-range selection, or every cell when empty.
    public static func targetIndices(_ selection: Set<Int>, count: Int) -> [Int] {
        let n = clamp(count, 0, maxCells)
        let picked = selection.filter { $0 >= 0 && $0 < n }.sorted()
        return picked.isEmpty ? Array(0..<n) : picked
    }

    /// `count` colours spread evenly from the first stop to the last. A single cell gets the middle.
    public static func gradient(_ stops: [LightColor], count: Int) -> [LightColor] {
        let n = clamp(count, 0, maxCells)
        guard n > 0, !stops.isEmpty else { return [] }
        if n == 1 { return [color(at: 0.5, stops: stops)] }
        return (0..<n).map { color(at: Double($0) / Double(n - 1), stops: stops) }
    }

    /// The colour at position `t` (0…1) along evenly spaced stops (perceptual mixing).
    public static func color(at t: Double, stops: [LightColor]) -> LightColor {
        guard let first = stops.first else { return .white }
        guard stops.count > 1 else { return first }
        let p = clamp01(t.finiteOr(0)) * Double(stops.count - 1)
        let i = min(Int(p), stops.count - 2)
        return LightColor.mix(stops[i], stops[i + 1], p - Double(i))
    }

    /// Paints a gradient across the target cells (in index order) at full cell brightness.
    public static func applyGradient(_ stops: [LightColor], to state: FixtureState, count: Int,
                                     selection: Set<Int> = []) -> FixtureState {
        let n = clamp(count, 0, maxCells)
        guard n > 0, !stops.isEmpty else { return state }
        var out = cells(of: state, count: n)
        let idx = targetIndices(selection, count: n)
        let colors = gradient(stops, count: idx.count)
        for (k, i) in idx.enumerated() where k < colors.count {
            out[i] = CellState(intensity: 1, color: colors[k])
        }
        var s = state
        s.cells = out
        return s
    }

    /// Paints one colour onto the target cells at full cell brightness.
    public static func fill(_ color: LightColor, to state: FixtureState, count: Int,
                            selection: Set<Int> = []) -> FixtureState {
        let n = clamp(count, 0, maxCells)
        guard n > 0 else { return state }
        var out = cells(of: state, count: n)
        for i in targetIndices(selection, count: n) {
            out[i] = CellState(intensity: 1, color: color)
        }
        var s = state
        s.cells = out
        return s
    }

    /// Sets the brightness of the target cells (0…1), keeping their colours.
    public static func setCellIntensity(_ intensity: Double, to state: FixtureState, count: Int,
                                        selection: Set<Int> = []) -> FixtureState {
        let n = clamp(count, 0, maxCells)
        guard n > 0 else { return state }
        var out = cells(of: state, count: n)
        let v = clamp01(intensity.finiteOr(1))
        for i in targetIndices(selection, count: n) {
            out[i] = CellState(intensity: v, color: out[i].color)
        }
        var s = state
        s.cells = out
        return s
    }

    /// Reverses the order of the target cells among themselves.
    public static func reversed(_ state: FixtureState, count: Int, selection: Set<Int> = []) -> FixtureState {
        let n = clamp(count, 0, maxCells)
        guard n > 1 else { return state }
        var out = cells(of: state, count: n)
        let idx = targetIndices(selection, count: n)
        let values = idx.map { out[$0] }
        for (k, i) in idx.enumerated() {
            out[i] = values[values.count - 1 - k]
        }
        var s = state
        s.cells = out
        return s
    }

    /// Mirrors the first half of the target cells onto the second half (a symmetric pattern).
    public static func mirrored(_ state: FixtureState, count: Int, selection: Set<Int> = []) -> FixtureState {
        let n = clamp(count, 0, maxCells)
        guard n > 1 else { return state }
        var out = cells(of: state, count: n)
        let idx = targetIndices(selection, count: n)
        let m = idx.count
        for k in 0..<(m / 2) {
            out[idx[m - 1 - k]] = out[idx[k]]
        }
        var s = state
        s.cells = out
        return s
    }

    /// Shifts the target cells by `offset` positions (wrapping); positive moves toward the end.
    public static func rotated(_ state: FixtureState, by offset: Int, count: Int,
                               selection: Set<Int> = []) -> FixtureState {
        let n = clamp(count, 0, maxCells)
        guard n > 1 else { return state }
        var out = cells(of: state, count: n)
        let idx = targetIndices(selection, count: n)
        let m = idx.count
        guard m > 1 else { return state }
        let values = idx.map { out[$0] }
        let shift = ((offset % m) + m) % m
        for (k, i) in idx.enumerated() {
            out[i] = values[(k - shift + m) % m]
        }
        var s = state
        s.cells = out
        return s
    }

    /// Removes the per-pixel pattern so the whole light shows its main colour again.
    public static func cleared(_ state: FixtureState) -> FixtureState {
        var s = state
        s.cells = nil
        return s
    }

    /// True when every cell has the same colour and brightness (or there is no pattern).
    public static func isUniform(_ state: FixtureState, count: Int) -> Bool {
        guard let cells = state.cells, !cells.isEmpty else { return true }
        let all = Self.cells(of: state, count: count)
        guard let first = all.first else { return true }
        return all.allSatisfy { $0 == first }
    }

    // MARK: - Selection helpers

    /// Cells from `a` to `b` inclusive (either order), clipped to the fixture.
    public static func range(_ a: Int, _ b: Int, count: Int) -> Set<Int> {
        let n = clamp(count, 0, maxCells)
        guard n > 0 else { return [] }
        let lo = clamp(min(a, b), 0, n - 1)
        let hi = clamp(max(a, b), 0, n - 1)
        return Set(lo...hi)
    }

    /// Every other cell, starting at `start` (0 = odd-numbered cells 1, 3, 5… as people count them).
    public static func alternate(count: Int, startingAt start: Int) -> Set<Int> {
        let n = clamp(count, 0, maxCells)
        let first = clamp(start, 0, 1)
        guard n > first else { return [] }
        return Set(stride(from: first, to: n, by: 2))
    }

    /// The cells not in `selection`.
    public static func inverted(_ selection: Set<Int>, count: Int) -> Set<Int> {
        let n = clamp(count, 0, maxCells)
        return Set(0..<n).subtracting(selection)
    }
}
