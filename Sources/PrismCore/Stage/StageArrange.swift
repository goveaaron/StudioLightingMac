import Foundation

/// Align commands (Keynote/Figma semantics: align to the selection's bounds, or to the room
/// when a single item is selected).
public enum StageAlignment: String, CaseIterable, Sendable {
    case left, centerX, right, top, centerY, bottom

    public var title: String {
        switch self {
        case .left: return "Align Left"
        case .centerX: return "Align Centers"
        case .right: return "Align Right"
        case .top: return "Align Top"
        case .centerY: return "Align Middles"
        case .bottom: return "Align Bottom"
        }
    }
}

public enum StageDistribution: String, CaseIterable, Sendable {
    case horizontal, vertical

    public var title: String { self == .horizontal ? "Distribute Horizontally" : "Distribute Vertically" }
}

/// One movable thing for arrange operations.
public struct StageArrangeItem: Hashable, Sendable {
    public var id: UUID
    public var center: StageVec
    public var bounds: StageRect

    public init(id: UUID, center: StageVec, bounds: StageRect) {
        self.id = id; self.center = center; self.bounds = bounds
    }
}

/// Arrange math: align, distribute, flip/mirror, rotate around a pivot, rotation handles.
public enum StageArrange {
    /// New centers that align the items. `reference` defaults to the items' union (or must be
    /// given, e.g. the room, when aligning a single item).
    public static func align(_ items: [StageArrangeItem], _ alignment: StageAlignment,
                             reference: StageRect? = nil) -> [UUID: StageVec] {
        guard let ref = reference ?? (items.count > 1 ? StageRect.union(items.map(\.bounds)) : nil) else { return [:] }
        var out: [UUID: StageVec] = [:]
        for it in items {
            var c = it.center
            let b = it.bounds
            switch alignment {
            case .left: c.x += ref.minX - b.minX
            case .centerX: c.x += ref.midX - b.midX
            case .right: c.x += ref.maxX - b.maxX
            case .top: c.y += ref.minY - b.minY
            case .centerY: c.y += ref.midY - b.midY
            case .bottom: c.y += ref.maxY - b.maxY
            }
            out[it.id] = c
        }
        return out
    }

    /// Equal gaps between neighbors along an axis; the outermost items stay put. Falls back to
    /// evenly spaced centers when the items overlap. Needs at least three items.
    public static func distribute(_ items: [StageArrangeItem], _ axis: StageDistribution) -> [UUID: StageVec] {
        guard items.count >= 3 else { return [:] }
        let horizontal = axis == .horizontal
        func lo(_ i: StageArrangeItem) -> Double { horizontal ? i.bounds.minX : i.bounds.minY }
        func hi(_ i: StageArrangeItem) -> Double { horizontal ? i.bounds.maxX : i.bounds.maxY }
        func mid(_ i: StageArrangeItem) -> Double { horizontal ? i.center.x : i.center.y }
        let sorted = items.sorted { mid($0) < mid($1) }
        guard let first = sorted.first, let last = sorted.last else { return [:] }
        let span = hi(last) - lo(first)
        let sizes = sorted.reduce(0) { $0 + (hi($1) - lo($1)) }
        let gap = (span - sizes) / Double(sorted.count - 1)
        var out: [UUID: StageVec] = [:]
        if gap >= 0 {
            var cursor = lo(first)
            for it in sorted {
                let shift = cursor - lo(it)
                var c = it.center
                if horizontal { c.x += shift } else { c.y += shift }
                out[it.id] = c
                cursor += (hi(it) - lo(it)) + gap
            }
        } else {
            let a = mid(first), b = mid(last)
            for (i, it) in sorted.enumerated() {
                let v = a + (b - a) * Double(i) / Double(sorted.count - 1)
                var c = it.center
                if horizontal { c.x = v } else { c.y = v }
                out[it.id] = c
            }
        }
        return out
    }

    /// Mirror image of a transform about the vertical line x = `axisX`. Rotation is mirrored too
    /// (θ → 180° − θ) so pixel 1 ends up on the mirrored side.
    public static func mirrored(_ t: StageTransform, aboutX axisX: Double) -> StageTransform {
        var m = t
        m.x = 2 * axisX - t.x
        m.rotation = StageAngle.normalized(180 - t.rotation)
        return m
    }

    /// Rotates a transform's position around `pivot` and adds the same angle to its rotation.
    public static func rotated(_ t: StageTransform, around pivot: StageVec, by delta: Double) -> StageTransform {
        var r = t
        let p = (StageVec(t.x, t.y) - pivot).rotated(byDegrees: delta) + pivot
        r.x = p.x; r.y = p.y
        r.rotation = StageAngle.normalized(t.rotation + delta)
        return r
    }

    /// Rotation that points a fixture's rotation handle (which sits on its local −y side) at
    /// `pointer`. With `snapStep` (e.g. 15 for ⇧) the result is rounded.
    public static func handleRotation(center: StageVec, pointer: StageVec, snapStep: Double? = nil) -> Double {
        let r = StageAngle.normalized(StageAngle.direction(from: center, to: pointer) + 90)
        if let step = snapStep { return StageAngle.snapped(r, step: step) }
        return r
    }

    /// Where a rotation handle sits for a footprint: `offset` meters beyond the body on its −y side.
    public static func handlePosition(for fp: StageFootprint, offset: Double) -> StageVec {
        fp.toStage(StageVec(0, -(fp.thickness / 2 + offset)))
    }

    /// Keeps a point inside the room with a small margin (positions are clamped on drop so lights
    /// can't be lost off-stage).
    public static func clampToStage(_ p: StageVec, stage: StageRect, margin: Double = 0) -> StageVec {
        StageVec(min(max(p.x, stage.minX - margin), stage.maxX + margin),
                 min(max(p.y, stage.minY - margin), stage.maxY + margin))
    }
}
