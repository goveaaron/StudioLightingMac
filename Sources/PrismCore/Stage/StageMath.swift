import Foundation

// Portable 2D math for the stage visualizer. PrismCore stays free of CoreGraphics so all of the
// geometry (fit, zoom, hit testing, snapping, label placement, pixel painting) is unit tested on
// Linux; the app converts to CGPoint/CGRect at the edges.

/// A 2D vector: stage meters or view points depending on context.
public struct StageVec: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    public static let zero = StageVec(0, 0)

    public static func + (a: StageVec, b: StageVec) -> StageVec { StageVec(a.x + b.x, a.y + b.y) }
    public static func - (a: StageVec, b: StageVec) -> StageVec { StageVec(a.x - b.x, a.y - b.y) }
    public static func * (a: StageVec, s: Double) -> StageVec { StageVec(a.x * s, a.y * s) }
    public static func / (a: StageVec, s: Double) -> StageVec { s == 0 ? a : StageVec(a.x / s, a.y / s) }
    public static prefix func - (a: StageVec) -> StageVec { StageVec(-a.x, -a.y) }
    public static func += (a: inout StageVec, b: StageVec) { a = a + b }
    public static func -= (a: inout StageVec, b: StageVec) { a = a - b }

    public var length: Double { (x * x + y * y).squareRoot() }
    public var lengthSquared: Double { x * x + y * y }
    public func dot(_ o: StageVec) -> Double { x * o.x + y * o.y }
    public func distance(to o: StageVec) -> Double { (self - o).length }

    /// Unit vector (or zero when the vector has no length).
    public var normalized: StageVec {
        let l = length
        return l > 1e-12 ? StageVec(x / l, y / l) : .zero
    }

    /// Rotated clockwise by `degrees` in a y-down coordinate system (the screen convention).
    public func rotated(byDegrees degrees: Double) -> StageVec {
        let r = degrees * .pi / 180
        let c = cos(r), s = sin(r)
        return StageVec(x * c - y * s, x * s + y * c)
    }

    /// Both components finite (NaN/inf replaced by `fallback`).
    public func finiteOr(_ fallback: StageVec) -> StageVec {
        StageVec(x.isFinite ? x : fallback.x, y.isFinite ? y : fallback.y)
    }

    /// Linear interpolation between two points.
    public static func lerp(_ a: StageVec, _ b: StageVec, _ t: Double) -> StageVec {
        StageVec(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
    }
}

/// An axis-aligned rectangle (min/max form, y grows downward).
public struct StageRect: Hashable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = Swift.min(minX, maxX); self.maxX = Swift.max(minX, maxX)
        self.minY = Swift.min(minY, maxY); self.maxY = Swift.max(minY, maxY)
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(minX: x, minY: y, maxX: x + width, maxY: y + height)
    }

    public init(center: StageVec, width: Double, height: Double) {
        self.init(minX: center.x - width / 2, minY: center.y - height / 2,
                  maxX: center.x + width / 2, maxY: center.y + height / 2)
    }

    /// Rectangle spanned by two corner points (e.g. a marquee drag).
    public init(corner a: StageVec, _ b: StageVec) {
        self.init(minX: a.x, minY: a.y, maxX: b.x, maxY: b.y)
    }

    /// Smallest rectangle containing all points (nil when empty).
    public static func bounding(_ points: [StageVec]) -> StageRect? {
        guard let first = points.first else { return nil }
        var r = StageRect(minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
        for p in points.dropFirst() {
            r.minX = Swift.min(r.minX, p.x); r.maxX = Swift.max(r.maxX, p.x)
            r.minY = Swift.min(r.minY, p.y); r.maxY = Swift.max(r.maxY, p.y)
        }
        return r
    }

    /// Union of several rectangles (nil when empty).
    public static func union(_ rects: [StageRect]) -> StageRect? {
        guard var r = rects.first else { return nil }
        for o in rects.dropFirst() { r = r.union(o) }
        return r
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var midX: Double { (minX + maxX) / 2 }
    public var midY: Double { (minY + maxY) / 2 }
    public var center: StageVec { StageVec(midX, midY) }
    public var area: Double { width * height }
    public var size: StageVec { StageVec(width, height) }
    public var topLeft: StageVec { StageVec(minX, minY) }
    public var isFinite: Bool { minX.isFinite && minY.isFinite && maxX.isFinite && maxY.isFinite }

    public func union(_ o: StageRect) -> StageRect {
        StageRect(minX: Swift.min(minX, o.minX), minY: Swift.min(minY, o.minY),
                  maxX: Swift.max(maxX, o.maxX), maxY: Swift.max(maxY, o.maxY))
    }

    /// Grows (positive) or shrinks (negative) the rectangle on every side.
    public func insetBy(_ d: Double) -> StageRect {
        let c = center
        let w = Swift.max(width - 2 * d, 0), h = Swift.max(height - 2 * d, 0)
        return StageRect(center: c, width: w, height: h)
    }

    public func expanded(by d: Double) -> StageRect { insetBy(-d) }

    public func offsetBy(_ v: StageVec) -> StageRect {
        StageRect(minX: minX + v.x, minY: minY + v.y, maxX: maxX + v.x, maxY: maxY + v.y)
    }

    public func contains(_ p: StageVec) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }

    public func contains(_ r: StageRect) -> Bool {
        r.minX >= minX && r.maxX <= maxX && r.minY >= minY && r.maxY <= maxY
    }

    public func intersects(_ r: StageRect) -> Bool {
        r.minX <= maxX && r.maxX >= minX && r.minY <= maxY && r.maxY >= minY
    }

    /// Overlapping area with another rectangle (0 when disjoint).
    public func overlapArea(_ r: StageRect) -> Double {
        let w = Swift.min(maxX, r.maxX) - Swift.max(minX, r.minX)
        let h = Swift.min(maxY, r.maxY) - Swift.max(minY, r.minY)
        return w > 0 && h > 0 ? w * h : 0
    }

    /// Closest point inside the rectangle.
    public func clamped(_ p: StageVec) -> StageVec {
        StageVec(Swift.min(Swift.max(p.x, minX), maxX), Swift.min(Swift.max(p.y, minY), maxY))
    }

    /// Distance from a point to the rectangle (0 when inside).
    public func distance(to p: StageVec) -> Double { clamped(p).distance(to: p) }
}

/// Insets around the visible area (points), e.g. for floating toolbars.
public struct StageInsets: Hashable, Sendable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }

    public init(all v: Double) { self.init(top: v, left: v, bottom: v, right: v) }
}

/// Maps stage meters ↔ view points: `view = viewSize/2 + (meters − center) × scale`.
///
/// `scale` is points per meter, `center` is the stage point shown at the middle of the view.
public struct StageViewport: Hashable, Sendable {
    public var scale: Double
    public var center: StageVec
    public var viewSize: StageVec

    /// Absolute zoom limits (points per meter).
    public static let minScale = 2.0
    public static let maxScale = 4000.0

    public init(scale: Double, center: StageVec, viewSize: StageVec) {
        self.scale = clamp(scale.finiteOr(60), StageViewport.minScale, StageViewport.maxScale)
        self.center = center.finiteOr(.zero)
        self.viewSize = StageVec(max(viewSize.x.finiteOr(1), 1), max(viewSize.y.finiteOr(1), 1))
    }

    public var viewCenter: StageVec { viewSize / 2 }

    public func toView(_ m: StageVec) -> StageVec { viewCenter + (m - center) * scale }
    public func toStage(_ p: StageVec) -> StageVec { center + (p - viewCenter) / scale }

    public func toView(_ r: StageRect) -> StageRect {
        StageRect(corner: toView(r.topLeft), toView(StageVec(r.maxX, r.maxY)))
    }

    public func toStage(_ r: StageRect) -> StageRect {
        StageRect(corner: toStage(r.topLeft), toStage(StageVec(r.maxX, r.maxY)))
    }

    /// Converts a length in points to meters at this zoom.
    public func meters(_ points: Double) -> Double { points / scale }

    /// The part of the stage currently visible (meters).
    public var visibleStageRect: StageRect { toStage(StageRect(x: 0, y: 0, width: viewSize.x, height: viewSize.y)) }

    /// Fits `content` (meters) inside the view minus `insets`, centered. `maxScale` keeps tiny
    /// content (one light) from being blown up absurdly.
    public static func fitting(_ content: StageRect, viewSize: StageVec, insets: StageInsets = StageInsets(),
                               maxScale: Double = 400) -> StageViewport {
        let size = StageVec(max(viewSize.x, 1), max(viewSize.y, 1))
        let ins = effectiveInsets(insets, viewSize: size)
        let availW = max(size.x - ins.left - ins.right, 1)
        let availH = max(size.y - ins.top - ins.bottom, 1)
        let cw = max(content.width, 0.05), ch = max(content.height, 0.05)
        let s = min(min(availW / cw, availH / ch), maxScale)
        // Center the content in the inset area (which may be off-center).
        let insetCenter = StageVec(ins.left + availW / 2, ins.top + availH / 2)
        let shift = (insetCenter - size / 2) / s
        return StageViewport(scale: s, center: content.center - shift, viewSize: size)
    }

    /// Insets that never take more than 60 % of a dimension (tiny windows still show the room).
    public static func effectiveInsets(_ insets: StageInsets, viewSize size: StageVec) -> StageInsets {
        var ins = StageInsets(top: max(insets.top, 0), left: max(insets.left, 0),
                              bottom: max(insets.bottom, 0), right: max(insets.right, 0))
        let hx = ins.left + ins.right, hy = ins.top + ins.bottom
        if hx > size.x * 0.6, hx > 0 { let k = size.x * 0.6 / hx; ins.left *= k; ins.right *= k }
        if hy > size.y * 0.6, hy > 0 { let k = size.y * 0.6 / hy; ins.top *= k; ins.bottom *= k }
        return ins
    }

    /// Zooms by `factor` keeping the stage point under `viewPoint` fixed.
    public func zoomed(by factor: Double, around viewPoint: StageVec, limits: ClosedRange<Double>? = nil) -> StageViewport {
        let f = factor.isFinite && factor > 0 ? factor : 1
        let lo = max(limits?.lowerBound ?? StageViewport.minScale, StageViewport.minScale)
        let hi = min(limits?.upperBound ?? StageViewport.maxScale, StageViewport.maxScale)
        let newScale = clamp(scale * f, lo, max(lo, hi))
        let anchor = toStage(viewPoint)
        // anchor must map to viewPoint at the new scale: viewPoint = vc + (anchor − c') × s'.
        let newCenter = anchor - (viewPoint - viewCenter) / newScale
        return StageViewport(scale: newScale, center: newCenter, viewSize: viewSize)
    }

    /// Pans so content follows a drag of `delta` points.
    public func panned(byViewDelta delta: StageVec) -> StageViewport {
        StageViewport(scale: scale, center: center - delta / scale, viewSize: viewSize)
    }

    /// Same stage framing in a resized view (keeps the center and scale).
    public func resized(to size: StageVec) -> StageViewport {
        StageViewport(scale: scale, center: center, viewSize: size)
    }

    /// Smooth interpolation for animated zooms: scale geometrically, center linearly in view terms.
    public static func interpolate(_ a: StageViewport, _ b: StageViewport, _ t: Double) -> StageViewport {
        let u = clamp01(t)
        let s = exp(log(a.scale) + (log(b.scale) - log(a.scale)) * u)
        let c = StageVec.lerp(a.center, b.center, u)
        return StageViewport(scale: s, center: c, viewSize: b.viewSize)
    }

    /// Ease-out cubic used for viewport animations.
    public static func ease(_ t: Double) -> Double {
        let u = clamp01(t)
        return 1 - pow(1 - u, 3)
    }

    /// Keeps at least `margin` points of `content` on screen so the user can never pan the
    /// room completely out of view.
    public func constrained(toKeepVisible content: StageRect, margin: Double = 80) -> StageViewport {
        let v = toView(content)
        var dx = 0.0, dy = 0.0
        let m = min(margin, min(v.width, v.height) / 2 + 1)
        if v.maxX < m { dx = m - v.maxX } else if v.minX > viewSize.x - m { dx = (viewSize.x - m) - v.minX }
        if v.maxY < m { dy = m - v.maxY } else if v.minY > viewSize.y - m { dy = (viewSize.y - m) - v.minY }
        guard dx != 0 || dy != 0 else { return self }
        return panned(byViewDelta: StageVec(dx, dy))
    }
}

/// Angle helpers (degrees, clockwise, y-down screen convention).
public enum StageAngle {
    /// Normalizes to [0, 360).
    public static func normalized(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        if d >= 360 - 1e-9 { d = 0 }
        return d
    }

    /// Direction of `p` seen from `origin`, clockwise from +x.
    public static func direction(from origin: StageVec, to p: StageVec) -> Double {
        let d = p - origin
        guard d.lengthSquared > 1e-18 else { return 0 }
        return normalized(atan2(d.y, d.x) * 180 / .pi)
    }

    /// Rounds to the nearest multiple of `step` degrees.
    public static func snapped(_ degrees: Double, step: Double) -> Double {
        guard step > 0 else { return normalized(degrees) }
        return normalized((degrees / step).rounded() * step)
    }

    /// Smallest signed difference a − b in (−180, 180].
    public static func difference(_ a: Double, _ b: Double) -> Double {
        var d = normalized(a) - normalized(b)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }
}

/// Small geometric primitives shared by the stage algorithms.
public enum StageGeometry {
    /// Parameter (0…1) of the point on segment a→b closest to `p`.
    public static func projection(of p: StageVec, ontoSegment a: StageVec, _ b: StageVec) -> Double {
        let d = b - a
        let l2 = d.lengthSquared
        guard l2 > 1e-18 else { return 0 }
        return clamp01((p - a).dot(d) / l2)
    }

    /// Distance from `p` to the segment a→b.
    public static func distance(from p: StageVec, toSegment a: StageVec, _ b: StageVec) -> Double {
        let t = projection(of: p, ontoSegment: a, b)
        return p.distance(to: StageVec.lerp(a, b, t))
    }

    /// Whether segment a→b touches the rectangle (Liang–Barsky clipping).
    public static func segment(_ a: StageVec, _ b: StageVec, intersects r: StageRect) -> Bool {
        if r.contains(a) || r.contains(b) { return true }
        let d = b - a
        var t0 = 0.0, t1 = 1.0
        let checks: [(p: Double, q: Double)] = [(-d.x, a.x - r.minX), (d.x, r.maxX - a.x),
                                                 (-d.y, a.y - r.minY), (d.y, r.maxY - a.y)]
        for c in checks {
            if abs(c.p) < 1e-15 {
                if c.q < 0 { return false }
            } else {
                let t = c.q / c.p
                if c.p < 0 { t0 = max(t0, t) } else { t1 = min(t1, t) }
                if t0 > t1 { return false }
            }
        }
        return true
    }
}
