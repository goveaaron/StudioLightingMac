import Foundation

/// A label to place near a fixture (all values in view points).
public struct StageLabelRequest: Sendable {
    public var id: UUID
    public var size: StageVec
    /// Candidate label centers, most preferred first.
    public var candidates: [StageVec]
    /// Higher priority labels are placed first (selected/hovered lights win).
    public var priority: Double

    public init(id: UUID, size: StageVec, candidates: [StageVec], priority: Double = 0) {
        self.id = id; self.size = size; self.candidates = candidates; self.priority = priority
    }
}

/// Something labels should avoid: a capsule (segment + radius) in view points. Discs use a == b.
public struct StageLabelObstacle: Sendable {
    public var a: StageVec
    public var b: StageVec
    public var radius: Double

    public init(a: StageVec, b: StageVec, radius: Double) {
        self.a = a; self.b = b; self.radius = max(radius, 0)
    }

    /// Obstacle approximating a footprint that is already in view points.
    public init(viewFootprint fp: StageFootprint) {
        if fp.kind.isRound {
            self.init(a: fp.center, b: fp.center, radius: fp.length / 2)
        } else if fp.length >= fp.thickness {
            let h = (fp.length - fp.thickness) / 2
            self.init(a: fp.toStage(StageVec(-h, 0)), b: fp.toStage(StageVec(h, 0)), radius: fp.thickness / 2)
        } else {
            let h = (fp.thickness - fp.length) / 2
            self.init(a: fp.toStage(StageVec(0, -h)), b: fp.toStage(StageVec(0, h)), radius: fp.length / 2)
        }
    }

    /// Distance from the capsule's core segment to a rectangle (0 when the segment touches it).
    func coreDistance(to r: StageRect) -> Double {
        if StageGeometry.segment(a, b, intersects: r) { return 0 }
        let corners = [StageVec(r.minX, r.minY), StageVec(r.maxX, r.minY), StageVec(r.maxX, r.maxY), StageVec(r.minX, r.maxY)]
        var best = min(r.distance(to: a), r.distance(to: b))
        for c in corners { best = min(best, StageGeometry.distance(from: c, toSegment: a, b)) }
        return best
    }
}

/// Greedy, collision-aware label placement ("smart labels"): each label takes the best of its
/// candidate spots, avoiding labels already placed, fixture bodies and the view edges.
public enum StageLabelLayout {
    /// Approximate label size for short fixture names (10–11 pt rounded semibold in a pill).
    public static func estimatedSize(for text: String, fontSize: Double = 10.5) -> StageVec {
        let chars = Double(max(text.count, 1))
        return StageVec((chars * fontSize * 0.62 + 12).rounded(), (fontSize + 7).rounded())
    }

    /// Candidate centers around a footprint given in view points, best first.
    /// Horizontal-ish bars prefer above/below; vertical and diagonal ones prefer their upper end.
    public static func candidates(for fp: StageFootprint, labelSize: StageVec, gap: Double = 5) -> [StageVec] {
        let b = fp.bounds
        let w = labelSize.x, h = labelSize.y
        let top = StageVec(b.midX, b.minY - gap - h / 2)
        let bottom = StageVec(b.midX, b.maxY + gap + h / 2)
        let right = StageVec(b.maxX + gap + w / 2, b.midY)
        let left = StageVec(b.minX - gap - w / 2, b.midY)
        let topRight = StageVec(b.maxX + gap * 0.5 + w / 2, b.minY - gap * 0.5 - h / 2)
        let topLeft = StageVec(b.minX - gap * 0.5 - w / 2, b.minY - gap * 0.5 - h / 2)
        let bottomRight = StageVec(b.maxX + gap * 0.5 + w / 2, b.maxY + gap * 0.5 + h / 2)
        let bottomLeft = StageVec(b.minX - gap * 0.5 - w / 2, b.maxY + gap * 0.5 + h / 2)
        guard fp.kind.isLinear || (!fp.kind.isRound && fp.length > fp.thickness * 2.5) else {
            return [top, bottom, right, left, topRight, topLeft, bottomRight, bottomLeft]
        }
        let ax = fp.axis
        if abs(ax.x) >= 0.85 {
            return [top, bottom, right, left, topRight, topLeft, bottomRight, bottomLeft]
        }
        // Beyond each end, along the axis, far enough that the label clears the end cap.
        let e1 = fp.toStage(StageVec(fp.length / 2, 0)), e2 = fp.toStage(StageVec(-fp.length / 2, 0))
        func beyond(_ end: StageVec, _ dir: StageVec) -> StageVec {
            let reach = gap + abs(dir.x) * w / 2 + abs(dir.y) * h / 2 + fp.thickness * 0.3
            return end + dir * reach
        }
        let p1 = beyond(e1, ax), p2 = beyond(e2, -ax)
        let (upper, lower) = p1.y <= p2.y ? (p1, p2) : (p2, p1)
        return [upper, top, lower, bottom, right, left, topRight, topLeft, bottomRight, bottomLeft]
    }

    /// Places labels. Returns the chosen center for every request.
    /// - Parameters:
    ///   - obstacles: fixture bodies (view points) to keep labels off.
    ///   - bounds: the visible area; labels prefer to stay inside it.
    public static func place(_ requests: [StageLabelRequest], obstacles: [StageLabelObstacle],
                             bounds: StageRect? = nil, padding: Double = 2) -> [UUID: StageVec] {
        var placed: [StageRect] = []
        placed.reserveCapacity(requests.count)
        var out: [UUID: StageVec] = [:]
        // Stable order: priority, then top-to-bottom, then left-to-right.
        let order = requests.enumerated().sorted { l, r in
            if l.element.priority != r.element.priority { return l.element.priority > r.element.priority }
            let ly = l.element.candidates.first?.y ?? 0, ry = r.element.candidates.first?.y ?? 0
            if abs(ly - ry) > 0.5 { return ly < ry }
            let lx = l.element.candidates.first?.x ?? 0, rx = r.element.candidates.first?.x ?? 0
            if abs(lx - rx) > 0.5 { return lx < rx }
            return l.offset < r.offset
        }
        for (_, req) in order {
            guard !req.candidates.isEmpty else { continue }
            var bestScore = Double.infinity
            var best = req.candidates[0]
            for (i, c) in req.candidates.enumerated() {
                let rect = StageRect(center: c, width: req.size.x + padding * 2, height: req.size.y + padding * 2)
                var score = Double(i) * 14
                for p in placed { score += p.overlapArea(rect) * 4 }
                for o in obstacles {
                    let pen = o.radius + 1.5 - o.coreDistance(to: rect)
                    if pen > 0 { score += pen * 40 }
                }
                if let b = bounds, !b.contains(rect) {
                    score += 400 + rect.area - rect.overlapArea(b)
                }
                if score < bestScore - 1e-9 { bestScore = score; best = c }
            }
            out[req.id] = best
            placed.append(StageRect(center: best, width: req.size.x + padding * 2, height: req.size.y + padding * 2))
        }
        return out
    }
}
