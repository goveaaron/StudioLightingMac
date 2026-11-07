import Foundation

/// How a fixture's body is drawn and hit-tested on the stage.
public enum StageBodyKind: String, Sendable, Hashable, CaseIterable {
    /// Pixel tube with end caps (amaran PT, Astera Titan…).
    case tube
    /// Rectangular batten / bar with cells.
    case bar
    /// Thin LED strip.
    case strip
    /// Rectangular LED panel.
    case panel
    /// COB light with an octagonal softbox.
    case softbox
    /// Round fresnel (concentric lens rings).
    case fresnel
    /// PAR can.
    case par
    /// Practical bulb.
    case bulb
    /// Generic round light (dimmers, washes, unknown types).
    case round
    /// Moving head (round body with a yoke).
    case movingHead

    /// Long, thin fixtures with cells along their length.
    public var isLinear: Bool { self == .tube || self == .bar || self == .strip }

    /// Circular footprint (rotation doesn't change the outline).
    public var isRound: Bool {
        switch self {
        case .fresnel, .par, .bulb, .round, .movingHead: return true
        default: return false
        }
    }

    public static func kind(for category: FixtureCategory) -> StageBodyKind {
        switch category {
        case .tube: return .tube
        case .bar: return .bar
        case .strip: return .strip
        case .panel: return .panel
        case .spot: return .softbox
        case .fresnel: return .fresnel
        case .par, .wash: return .par
        case .bulb: return .bulb
        case .movingHead: return .movingHead
        case .dimmer, .effect, .other: return .round
        }
    }
}

/// The oriented outline of a fixture on the stage (meters).
///
/// Local coordinates: x runs along the fixture's length (cell 0 at −x unless pixels are
/// reversed), y across it. Rotation is degrees clockwise (y grows downward), matching
/// `StageTransform` and the engine's `SpatialLayout`.
public struct StageFootprint: Hashable, Sendable {
    public var kind: StageBodyKind
    public var center: StageVec
    public var rotation: Double
    /// Extent along local x (meters). For round kinds this is the diameter.
    public var length: Double
    /// Extent along local y (meters). For round kinds this equals `length`.
    public var thickness: Double
    public var cellCount: Int
    public var reversePixels: Bool

    /// Minimum on-screen sizes so thin tubes stay visible and clickable at any zoom (points).
    public static let minLinearThicknessPoints = 7.0
    public static let minRoundDiameterPoints = 16.0
    public static let minPanelSidePoints = 14.0

    public init(kind: StageBodyKind, center: StageVec, rotation: Double = 0, length: Double, thickness: Double,
                cellCount: Int = 0, reversePixels: Bool = false) {
        self.kind = kind
        self.center = center.finiteOr(.zero)
        self.rotation = StageAngle.normalized(rotation)
        let l = max(length.finiteOr(0.3), 0.001)
        let t = max(thickness.finiteOr(0.3), 0.001)
        if kind.isRound {
            let d = max(l, t)
            self.length = d; self.thickness = d
        } else {
            self.length = l; self.thickness = t
        }
        self.cellCount = max(cellCount, 0)
        self.reversePixels = reversePixels
    }

    /// Physical size (meters) of a fixture's body before scaling: (length, thickness).
    public static func physicalSize(of rf: ResolvedFixture) -> (length: Double, thickness: Double) {
        let p = rf.definition.physical
        func mm(_ v: Double?) -> Double? { v.flatMap { $0.isFinite && $0 > 0 ? $0 / 1000 : nil } }
        switch kind(of: rf) {
        case .tube:
            return (rf.visualLengthMeters, mm(p?.diameterMM) ?? mm(p?.widthMM) ?? 0.03)
        case .bar:
            return (rf.visualLengthMeters, mm(p?.heightMM) ?? mm(p?.widthMM) ?? 0.06)
        case .strip:
            return (rf.visualLengthMeters, mm(p?.widthMM) ?? 0.015)
        case .panel:
            let w = mm(p?.widthMM) ?? mm(p?.lengthMM) ?? 0.6
            let h = mm(p?.heightMM) ?? w
            return (w, h)
        case .softbox:
            let d = max(mm(p?.diameterMM) ?? 0.6, 0.45)
            return (d, d)
        case .fresnel:
            let d = mm(p?.diameterMM) ?? mm(p?.widthMM) ?? 0.32
            return (d, d)
        case .par:
            let d = mm(p?.diameterMM) ?? mm(p?.widthMM) ?? 0.26
            return (d, d)
        case .bulb:
            let d = mm(p?.diameterMM) ?? 0.16
            return (d, d)
        case .movingHead:
            let d = mm(p?.widthMM) ?? 0.4
            return (d, d)
        case .round:
            let d = mm(p?.diameterMM) ?? 0.38
            return (d, d)
        }
    }

    public static func kind(of rf: ResolvedFixture) -> StageBodyKind {
        let k = StageBodyKind.kind(for: rf.definition.category)
        // A "bar"/"strip" without pixels still draws as a bar; a non-linear light with many cells
        // (pixel panel) keeps its own kind.
        return k
    }

    /// Footprint for a resolved fixture at an optional override transform (drag preview).
    /// `pointsPerMeter` applies the minimum on-screen sizes; pass 0 for pure physical sizes.
    public init(_ rf: ResolvedFixture, transform: StageTransform? = nil, pointsPerMeter: Double = 0) {
        let t = (transform ?? rf.fixture.transform)
        let k = StageFootprint.kind(of: rf)
        let size = StageFootprint.physicalSize(of: rf)
        let s = clamp(t.scale.finiteOr(1), 0.1, 10)
        var l = size.length * s, th = size.thickness * s
        if pointsPerMeter > 0 {
            let ppm = pointsPerMeter
            if k.isLinear {
                th = max(th, StageFootprint.minLinearThicknessPoints / ppm)
                l = max(l, 3 * StageFootprint.minLinearThicknessPoints / ppm)
            } else if k.isRound || k == .softbox {
                l = max(l, StageFootprint.minRoundDiameterPoints / ppm); th = l
            } else {
                l = max(l, StageFootprint.minPanelSidePoints / ppm)
                th = max(th, StageFootprint.minPanelSidePoints / ppm)
            }
        }
        self.init(kind: k, center: StageVec(t.x, t.y), rotation: t.rotation, length: l, thickness: th,
                  cellCount: rf.cellCount, reversePixels: rf.fixture.reversePixels)
    }

    // MARK: Transforms

    /// Unit vector along the fixture (local +x) in stage space.
    public var axis: StageVec { StageVec(1, 0).rotated(byDegrees: rotation) }
    /// Unit vector across the fixture (local +y) in stage space.
    public var normal: StageVec { StageVec(0, 1).rotated(byDegrees: rotation) }

    public func toLocal(_ p: StageVec) -> StageVec { (p - center).rotated(byDegrees: -rotation) }
    public func toStage(_ local: StageVec) -> StageVec { center + local.rotated(byDegrees: rotation) }

    /// Outline corners in stage space (clockwise from local top-left).
    public var corners: [StageVec] {
        let hl = length / 2, ht = thickness / 2
        return [StageVec(-hl, -ht), StageVec(hl, -ht), StageVec(hl, ht), StageVec(-hl, ht)].map(toStage)
    }

    /// Axis-aligned bounds (meters).
    public var bounds: StageRect {
        if kind.isRound { return StageRect(center: center, width: length, height: length) }
        return StageRect.bounding(corners) ?? StageRect(center: center, width: length, height: thickness)
    }

    /// True when the rotation is (nearly) a multiple of 90°, so the bounds are real edges.
    public var isAxisAligned: Bool {
        if kind.isRound { return true }
        let r = rotation.truncatingRemainder(dividingBy: 90)
        return r < 0.5 || r > 89.5
    }

    // MARK: Hit testing

    /// Distance from `p` to the body outline (0 inside).
    public func distance(to p: StageVec) -> Double {
        if kind.isRound { return max(0, p.distance(to: center) - length / 2) }
        let l = toLocal(p)
        let dx = max(abs(l.x) - length / 2, 0), dy = max(abs(l.y) - thickness / 2, 0)
        return (dx * dx + dy * dy).squareRoot()
    }

    public func contains(_ p: StageVec, tolerance: Double = 0) -> Bool { distance(to: p) <= max(tolerance, 0) }

    /// Whether the body overlaps an axis-aligned rectangle (marquee selection).
    public func intersects(_ r: StageRect) -> Bool {
        if kind.isRound { return r.distance(to: center) <= length / 2 }
        // Separating-axis test between this oriented box and the rectangle.
        let pts = corners
        let rectPts = [StageVec(r.minX, r.minY), StageVec(r.maxX, r.minY), StageVec(r.maxX, r.maxY), StageVec(r.minX, r.maxY)]
        let axes = [StageVec(1, 0), StageVec(0, 1), axis, normal]
        for a in axes {
            let p1 = pts.map { $0.dot(a) }, p2 = rectPts.map { $0.dot(a) }
            guard let min1 = p1.min(), let max1 = p1.max(), let min2 = p2.min(), let max2 = p2.max() else { continue }
            if max1 < min2 || max2 < min1 { return false }
        }
        return true
    }

    /// Distance from the body to the segment a→b (0 when they touch).
    public func distance(toSegment a: StageVec, _ b: StageVec) -> Double {
        if kind.isRound { return max(0, StageGeometry.distance(from: center, toSegment: a, b) - length / 2) }
        // Work in local space where the body is an axis-aligned box centered at the origin.
        let la = toLocal(a), lb = toLocal(b)
        let box = StageRect(center: .zero, width: length, height: thickness)
        if StageGeometry.segment(la, lb, intersects: box) { return 0 }
        // Disjoint convex shapes: the closest pair involves a segment endpoint or a box corner.
        let boxCorners = [StageVec(box.minX, box.minY), StageVec(box.maxX, box.minY),
                          StageVec(box.maxX, box.maxY), StageVec(box.minX, box.maxY)]
        var best = min(box.distance(to: la), box.distance(to: lb))
        for c in boxCorners { best = min(best, StageGeometry.distance(from: c, toSegment: la, lb)) }
        return best
    }

    // MARK: Cells

    /// Center of cell `i` in stage space (matches `SpatialLayout`). Non-linear fixtures with
    /// cells (pixel panels) lay them out along their width.
    public func cellCenter(_ i: Int) -> StageVec {
        let n = max(cellCount, 1)
        let u = n == 1 ? 0.5 : (Double(i) + 0.5) / Double(n)
        var along = (u - 0.5) * length
        if reversePixels { along = -along }
        return toStage(StageVec(along, 0))
    }

    public var cellCenters: [StageVec] { (0..<max(cellCount, 0)).map(cellCenter) }

    /// Local x-span of cell `i` (start, end), honoring reversed pixels.
    public func cellSpan(_ i: Int) -> (x0: Double, x1: Double) {
        let n = Double(max(cellCount, 1))
        var a = (Double(i) / n - 0.5) * length, b = (Double(i + 1) / n - 0.5) * length
        if reversePixels { (a, b) = (-b, -a) }
        return (a, b)
    }

    /// Cell under a stage point (nil when outside the body or the fixture has no cells).
    public func cellIndex(at p: StageVec, tolerance: Double = 0) -> Int? {
        guard cellCount > 0 else { return nil }
        let l = toLocal(p)
        guard abs(l.x) <= length / 2 + tolerance, abs(l.y) <= thickness / 2 + tolerance else { return nil }
        var along = l.x
        if reversePixels { along = -along }
        let u = along / length + 0.5
        return clamp(Int((u * Double(cellCount)).rounded(.down)), 0, cellCount - 1)
    }
}

/// Selection hit testing over many fixtures.
public enum StageHitTest {
    /// The fixture under `p`: exact hits win (topmost = last in `items`), otherwise the closest
    /// body within `tolerance` (thin tubes are easy to click).
    public static func item<ID: Hashable>(at p: StageVec, in items: [(id: ID, footprint: StageFootprint)],
                                         tolerance: Double) -> ID? {
        for item in items.reversed() where item.footprint.contains(p) { return item.id }
        var best: (id: ID, d: Double)?
        for item in items.reversed() {
            let d = item.footprint.distance(to: p)
            if d <= tolerance, d < (best?.d ?? .infinity) { best = (item.id, d) }
        }
        return best?.id
    }

    /// Everything a marquee rectangle touches, in the order given.
    public static func items<ID: Hashable>(in rect: StageRect, from items: [(id: ID, footprint: StageFootprint)]) -> [ID] {
        items.filter { $0.footprint.intersects(rect) }.map(\.id)
    }

    /// Fixtures touched by a stroke segment (gradient tool), ordered along the stroke.
    public static func items<ID: Hashable>(alongSegment a: StageVec, _ b: StageVec,
                                           from items: [(id: ID, footprint: StageFootprint)],
                                           tolerance: Double) -> [ID] {
        let dir = b - a
        let hits = items.compactMap { item -> (ID, Double)? in
            guard item.footprint.distance(toSegment: a, b) <= tolerance else { return nil }
            let t = dir.lengthSquared > 1e-12 ? (item.footprint.center - a).dot(dir) / dir.lengthSquared : 0
            return (item.id, t)
        }
        return hits.sorted { $0.1 < $1.1 }.map(\.0)
    }
}
