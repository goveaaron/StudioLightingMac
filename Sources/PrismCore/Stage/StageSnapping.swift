import Foundation

/// Something the moving selection can snap to.
public struct StageSnapTarget: Hashable, Sendable {
    public var rect: StageRect
    /// Whether the rectangle's edges are real edges (axis-aligned bodies). Centers always snap.
    public var snapsEdges: Bool

    public init(rect: StageRect, snapsEdges: Bool = true) {
        self.rect = rect; self.snapsEdges = snapsEdges
    }
}

/// A smart-guide line drawn while dragging (meters).
public struct StageGuide: Hashable, Sendable {
    public enum Axis: String, Hashable, Sendable {
        /// A vertical line at x = `position`.
        case vertical
        /// A horizontal line at y = `position`.
        case horizontal
    }

    public var axis: Axis
    public var position: Double
    /// Extent along the other axis.
    public var start: Double
    public var end: Double

    public init(axis: Axis, position: Double, start: Double, end: Double) {
        self.axis = axis; self.position = position
        self.start = min(start, end); self.end = max(start, end)
    }

    public var from: StageVec { axis == .vertical ? StageVec(position, start) : StageVec(start, position) }
    public var to: StageVec { axis == .vertical ? StageVec(position, end) : StageVec(end, position) }
}

/// A distance measurement between the moving selection and a neighbor (meters).
public struct StageSpacing: Hashable, Sendable {
    public var from: StageVec
    public var to: StageVec

    public init(from: StageVec, to: StageVec) { self.from = from; self.to = to }

    public var distance: Double { from.distance(to: to) }
    public var midpoint: StageVec { StageVec.lerp(from, to, 0.5) }
}

/// Result of snapping a drag.
public struct StageSnapResult: Hashable, Sendable {
    /// The delta to apply (the proposed delta plus snapping corrections).
    public var delta: StageVec
    public var guides: [StageGuide]
    public var spacings: [StageSpacing]
    public var snappedX: Bool
    public var snappedY: Bool

    public init(delta: StageVec, guides: [StageGuide] = [], spacings: [StageSpacing] = [],
                snappedX: Bool = false, snappedY: Bool = false) {
        self.delta = delta; self.guides = guides; self.spacings = spacings
        self.snappedX = snappedX; self.snappedY = snappedY
    }
}

/// Figma-style snapping: the moving selection's edges and center snap to other fixtures' edges
/// and centers, the room's edges and center lines, and (optionally) the grid. Produces smart
/// guides and distance labels to the nearest neighbors.
public struct StageSnapper: Sendable {
    public var targets: [StageSnapTarget]
    /// Room bounds: its edges and center lines are snap lines too.
    public var stage: StageRect?
    /// Grid spacing in meters when grid snapping is on.
    public var gridSize: Double?
    /// Snap distance in meters (derive from points: `viewport.meters(6)`).
    public var threshold: Double
    /// Spacing labels are only shown for neighbors closer than this (meters).
    public var maxSpacing: Double

    public init(targets: [StageSnapTarget], stage: StageRect? = nil, gridSize: Double? = nil,
                threshold: Double, maxSpacing: Double = 4) {
        self.targets = targets; self.stage = stage
        self.gridSize = gridSize.flatMap { $0.isFinite && $0 > 0.001 ? $0 : nil }
        self.threshold = max(threshold.finiteOr(0), 0)
        self.maxSpacing = maxSpacing
    }

    private enum Role { case low, mid, high }
    private struct Line { var value: Double; var span: (Double, Double)?; var role: Role }

    /// Snaps `moving` (the selection's bounds at the start of the drag) moved by `delta`.
    /// - Parameters:
    ///   - movingSnapsEdges: whether the selection's own edges should snap (false for rotated tubes).
    ///   - lockX/lockY: skip snapping on an axis (e.g. shift-constrained drags).
    public func snap(moving: StageRect, delta: StageVec, movingSnapsEdges: Bool = true,
                     lockX: Bool = false, lockY: Bool = false) -> StageSnapResult {
        let d0 = delta.finiteOr(.zero)
        let moved = moving.offsetBy(d0)

        // Candidate lines from targets (with the target's extent on the other axis) and the room.
        var xLines: [Line] = [], yLines: [Line] = []
        for t in targets {
            let r = t.rect
            xLines.append(Line(value: r.midX, span: (r.minY, r.maxY), role: .mid))
            yLines.append(Line(value: r.midY, span: (r.minX, r.maxX), role: .mid))
            if t.snapsEdges {
                xLines.append(Line(value: r.minX, span: (r.minY, r.maxY), role: .low))
                xLines.append(Line(value: r.maxX, span: (r.minY, r.maxY), role: .high))
                yLines.append(Line(value: r.minY, span: (r.minX, r.maxX), role: .low))
                yLines.append(Line(value: r.maxY, span: (r.minX, r.maxX), role: .high))
            }
        }
        if let s = stage {
            xLines.append(Line(value: s.minX, span: (s.minY, s.maxY), role: .low))
            xLines.append(Line(value: s.midX, span: (s.minY, s.maxY), role: .mid))
            xLines.append(Line(value: s.maxX, span: (s.minY, s.maxY), role: .high))
            yLines.append(Line(value: s.minY, span: (s.minX, s.maxX), role: .low))
            yLines.append(Line(value: s.midY, span: (s.minX, s.maxX), role: .mid))
            yLines.append(Line(value: s.maxY, span: (s.minX, s.maxX), role: .high))
        }

        func anchors(_ lo: Double, _ mid: Double, _ hi: Double) -> [(Double, Role)] {
            movingSnapsEdges ? [(mid, .mid), (lo, .low), (hi, .high)] : [(mid, .mid)]
        }

        // Like-for-like matches win ties: center↔center, then same-side edges, then abutting
        // edges, then mixed — so a thin tube's center doesn't grab a neighbor's edge.
        func bias(_ a: Role, _ b: Role) -> Double {
            if a == .mid && b == .mid { return 0 }
            if a == b { return threshold * 0.12 }
            if a != .mid && b != .mid { return threshold * 0.2 }
            return threshold * 0.35
        }

        func bestCorrection(_ anchorValues: [(Double, Role)], _ lines: [Line]) -> Double? {
            var best: (c: Double, score: Double)?
            for (a, role) in anchorValues {
                for l in lines {
                    let c = l.value - a
                    guard abs(c) <= threshold else { continue }
                    let score = abs(c) + bias(role, l.role)
                    if score < (best?.score ?? .infinity) - 1e-12 { best = (c, score) }
                }
            }
            return best?.c
        }

        func gridCorrection(_ value: Double) -> Double? {
            guard let g = gridSize else { return nil }
            return (value / g).rounded() * g - value
        }

        var dx = 0.0, dy = 0.0
        var snappedX = false, snappedY = false
        if !lockX {
            if let c = bestCorrection(anchors(moved.minX, moved.midX, moved.maxX), xLines) {
                dx = c; snappedX = true
            } else if let c = gridCorrection(moved.midX) {
                dx = c
            }
        }
        if !lockY {
            if let c = bestCorrection(anchors(moved.minY, moved.midY, moved.maxY), yLines) {
                dy = c; snappedY = true
            } else if let c = gridCorrection(moved.midY) {
                dy = c
            }
        }

        let finalDelta = StageVec(d0.x + dx, d0.y + dy)
        let final = moving.offsetBy(finalDelta)
        return StageSnapResult(delta: finalDelta,
                               guides: guides(for: final, xLines: xLines, yLines: yLines, edges: movingSnapsEdges),
                               spacings: spacings(for: final),
                               snappedX: snappedX, snappedY: snappedY)
    }

    /// Guides for every snap line the final rectangle coincides with (merged per position).
    private func guides(for r: StageRect, xLines: [Line], yLines: [Line], edges: Bool) -> [StageGuide] {
        let eps = max(threshold * 1e-3, 1e-7)
        var vertical: [Double: (Double, Double)] = [:]
        var horizontal: [Double: (Double, Double)] = [:]
        let xAnchors = edges ? [r.minX, r.midX, r.maxX] : [r.midX]
        let yAnchors = edges ? [r.minY, r.midY, r.maxY] : [r.midY]
        for l in xLines {
            guard xAnchors.contains(where: { abs($0 - l.value) <= eps }), let span = l.span else { continue }
            let key = (l.value / eps).rounded() * eps
            let lo = min(span.0, r.minY), hi = max(span.1, r.maxY)
            if let e = vertical[key] { vertical[key] = (min(e.0, lo), max(e.1, hi)) } else { vertical[key] = (lo, hi) }
        }
        for l in yLines {
            guard yAnchors.contains(where: { abs($0 - l.value) <= eps }), let span = l.span else { continue }
            let key = (l.value / eps).rounded() * eps
            let lo = min(span.0, r.minX), hi = max(span.1, r.maxX)
            if let e = horizontal[key] { horizontal[key] = (min(e.0, lo), max(e.1, hi)) } else { horizontal[key] = (lo, hi) }
        }
        var out: [StageGuide] = []
        for (pos, span) in vertical { out.append(StageGuide(axis: .vertical, position: pos, start: span.0, end: span.1)) }
        for (pos, span) in horizontal { out.append(StageGuide(axis: .horizontal, position: pos, start: span.0, end: span.1)) }
        return out.sorted { ($0.axis.rawValue, $0.position) < ($1.axis.rawValue, $1.position) }
    }

    /// Distance labels to the nearest neighbor on each side that overlaps on the other axis.
    private func spacings(for r: StageRect) -> [StageSpacing] {
        var left: (gap: Double, s: StageSpacing)?, right: (gap: Double, s: StageSpacing)?
        var up: (gap: Double, s: StageSpacing)?, down: (gap: Double, s: StageSpacing)?
        for t in targets {
            let o = t.rect
            let yLo = max(r.minY, o.minY), yHi = min(r.maxY, o.maxY)
            if yHi >= yLo {
                let y = (yLo + yHi) / 2
                let gl = r.minX - o.maxX
                if gl > 1e-6, gl <= maxSpacing, gl < (left?.gap ?? .infinity) {
                    left = (gl, StageSpacing(from: StageVec(o.maxX, y), to: StageVec(r.minX, y)))
                }
                let gr = o.minX - r.maxX
                if gr > 1e-6, gr <= maxSpacing, gr < (right?.gap ?? .infinity) {
                    right = (gr, StageSpacing(from: StageVec(r.maxX, y), to: StageVec(o.minX, y)))
                }
            }
            let xLo = max(r.minX, o.minX), xHi = min(r.maxX, o.maxX)
            if xHi >= xLo {
                let x = (xLo + xHi) / 2
                let gu = r.minY - o.maxY
                if gu > 1e-6, gu <= maxSpacing, gu < (up?.gap ?? .infinity) {
                    up = (gu, StageSpacing(from: StageVec(x, o.maxY), to: StageVec(x, r.minY)))
                }
                let gd = o.minY - r.maxY
                if gd > 1e-6, gd <= maxSpacing, gd < (down?.gap ?? .infinity) {
                    down = (gd, StageSpacing(from: StageVec(x, r.maxY), to: StageVec(x, o.minY)))
                }
            }
        }
        return [left, right, up, down].compactMap { $0?.s }
    }
}
