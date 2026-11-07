import XCTest
@testable import PrismCore

/// Stage visualizer geometry: viewport fit/zoom, footprints & hit testing, snapping, arrange,
/// smart labels, pixel painting and the light model.
final class StageTests: XCTestCase {
    // MARK: Helpers

    private func demoResolved() -> (Project, [ResolvedFixture]) {
        let lib = TestResources.library()
        let project = DemoRig.londonStudio()
        return (project, project.resolvedFixtures(library: lib.definition))
    }

    private func approx(_ a: StageVec, _ b: StageVec, _ eps: Double = 1e-9, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: eps, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: eps, file: file, line: line)
    }

    // MARK: Viewport

    func testViewportRoundTrip() {
        let vp = StageViewport(scale: 73, center: StageVec(2.5, 4), viewSize: StageVec(900, 640))
        let m = StageVec(1.25, 7.5)
        approx(vp.toStage(vp.toView(m)), m)
        approx(vp.toView(vp.center), StageVec(450, 320))
        XCTAssertEqual(vp.meters(73), 1, accuracy: 1e-12)
    }

    func testFitContainsContentAndUsesSpace() {
        let content = StageRect(x: 0, y: 0, width: 5.2, height: 9.2)
        for size in [StageVec(830, 640), StageVec(1600, 500), StageVec(320, 900), StageVec(120, 90)] {
            let requested = StageInsets(top: 50, left: 20, bottom: 40, right: 20)
            let insets = StageViewport.effectiveInsets(requested, viewSize: size)
            let vp = StageViewport.fitting(content, viewSize: size, insets: requested)
            let v = vp.toView(content)
            XCTAssertGreaterThanOrEqual(v.minX, insets.left - 1e-6, "\(size)")
            XCTAssertLessThanOrEqual(v.maxX, size.x - insets.right + 1e-6, "\(size)")
            XCTAssertGreaterThanOrEqual(v.minY, insets.top - 1e-6, "\(size)")
            XCTAssertLessThanOrEqual(v.maxY, size.y - insets.bottom + 1e-6, "\(size)")
            // Touches the limiting dimension (no wasted space beyond the aspect constraint).
            let availW = size.x - insets.left - insets.right, availH = size.y - insets.top - insets.bottom
            XCTAssertTrue(abs(v.width - availW) < 1e-6 || abs(v.height - availH) < 1e-6, "\(size)")
        }
    }

    func testFitCapsTinyContent() {
        let vp = StageViewport.fitting(StageRect(center: StageVec(1, 1), width: 0.01, height: 0.01),
                                       viewSize: StageVec(800, 600), maxScale: 300)
        XCTAssertEqual(vp.scale, 300, accuracy: 1e-9)
        approx(vp.center, StageVec(1, 1))
    }

    func testZoomKeepsAnchorFixed() {
        let vp = StageViewport(scale: 60, center: StageVec(3, 4), viewSize: StageVec(800, 600))
        let anchor = StageVec(123, 456)
        let before = vp.toStage(anchor)
        let z = vp.zoomed(by: 2.5, around: anchor)
        XCTAssertEqual(z.scale, 150, accuracy: 1e-9)
        approx(z.toStage(anchor), before, 1e-9)
        // Limits clamp the scale.
        let capped = vp.zoomed(by: 100, around: anchor, limits: 10...200)
        XCTAssertEqual(capped.scale, 200, accuracy: 1e-9)
        approx(capped.toStage(anchor), before, 1e-9)
    }

    func testPanFollowsDrag() {
        let vp = StageViewport(scale: 50, center: StageVec(0, 0), viewSize: StageVec(400, 400))
        let p = vp.toView(StageVec(1, 1))
        let moved = vp.panned(byViewDelta: StageVec(30, -20))
        approx(moved.toView(StageVec(1, 1)), p + StageVec(30, -20))
    }

    func testInterpolateAndConstrain() {
        let a = StageViewport(scale: 10, center: StageVec(0, 0), viewSize: StageVec(100, 100))
        let b = StageViewport(scale: 1000, center: StageVec(10, 10), viewSize: StageVec(100, 100))
        XCTAssertEqual(StageViewport.interpolate(a, b, 0).scale, 10, accuracy: 1e-9)
        XCTAssertEqual(StageViewport.interpolate(a, b, 1).scale, 1000, accuracy: 1e-6)
        XCTAssertEqual(StageViewport.interpolate(a, b, 0.5).scale, 100, accuracy: 1e-6) // geometric
        XCTAssertEqual(StageViewport.ease(1), 1, accuracy: 1e-12)
        XCTAssertEqual(StageViewport.ease(0), 0, accuracy: 1e-12)
        // Panned far away: constrain brings the room back on screen.
        let room = StageRect(x: 0, y: 0, width: 5, height: 9)
        let lost = StageViewport(scale: 50, center: StageVec(100, 100), viewSize: StageVec(800, 600))
        let back = lost.constrained(toKeepVisible: room, margin: 80).toView(room)
        XCTAssertGreaterThanOrEqual(back.maxX, 79.9)
        XCTAssertGreaterThanOrEqual(back.maxY, 79.9)
    }

    func testAngles() {
        XCTAssertEqual(StageAngle.normalized(-90), 270, accuracy: 1e-9)
        XCTAssertEqual(StageAngle.normalized(725), 5, accuracy: 1e-9)
        XCTAssertEqual(StageAngle.normalized(.nan), 0)
        XCTAssertEqual(StageAngle.direction(from: .zero, to: StageVec(0, 1)), 90, accuracy: 1e-9) // y down = clockwise
        XCTAssertEqual(StageAngle.snapped(52, step: 15), 45, accuracy: 1e-9)
        XCTAssertEqual(StageAngle.snapped(359, step: 15), 0, accuracy: 1e-9)
        XCTAssertEqual(StageAngle.difference(10, 350), 20, accuracy: 1e-9)
        XCTAssertEqual(StageAngle.difference(350, 10), -20, accuracy: 1e-9)
        approx(StageVec(1, 0).rotated(byDegrees: 90), StageVec(0, 1), 1e-12)
    }

    // MARK: Footprints & hit testing

    func testDemoFootprints() throws {
        let (_, resolved) = demoResolved()
        let b1 = try XCTUnwrap(resolved.first { $0.id == DemoRig.IDs.tube(1) })
        let fp = StageFootprint(b1)
        XCTAssertEqual(fp.kind, .tube)
        XCTAssertGreaterThan(fp.bounds.height, fp.bounds.width * 5, "B1 stands vertically")
        XCTAssertTrue(fp.contains(StageVec(b1.fixture.transform.x, b1.fixture.transform.y)))
        let pn1 = try XCTUnwrap(resolved.first { $0.id == DemoRig.IDs.pn1 })
        XCTAssertEqual(StageFootprint(pn1).kind, .panel)
        let p1 = try XCTUnwrap(resolved.first { $0.id == DemoRig.IDs.p1 })
        XCTAssertTrue(StageFootprint(p1).kind.isRound)
        // Minimum on-screen sizes make thin tubes clickable.
        let small = StageFootprint(b1, pointsPerMeter: 50)
        XCTAssertGreaterThanOrEqual(small.thickness * 50, StageFootprint.minLinearThicknessPoints - 1e-9)
    }

    func testCellIndexMatchesCellCenters() {
        for reversed in [false, true] {
            for rotation in [0.0, 90, 305] {
                let fp = StageFootprint(kind: .tube, center: StageVec(2, 3), rotation: rotation, length: 1.2,
                                        thickness: 0.05, cellCount: 16, reversePixels: reversed)
                for i in 0..<16 {
                    XCTAssertEqual(fp.cellIndex(at: fp.cellCenter(i)), i, "rot \(rotation) rev \(reversed)")
                }
                XCTAssertNil(fp.cellIndex(at: StageVec(10, 10)))
                let span = fp.cellSpan(0)
                XCTAssertEqual(abs(span.x1 - span.x0), 1.2 / 16, accuracy: 1e-9)
            }
        }
        // Pixel 1 is on the left for an unrotated tube and on the right when reversed.
        let fwd = StageFootprint(kind: .tube, center: .zero, length: 1, thickness: 0.1, cellCount: 4)
        XCTAssertLessThan(fwd.cellCenter(0).x, fwd.cellCenter(3).x)
        let rev = StageFootprint(kind: .tube, center: .zero, length: 1, thickness: 0.1, cellCount: 4, reversePixels: true)
        XCTAssertGreaterThan(rev.cellCenter(0).x, rev.cellCenter(3).x)
    }

    func testMatchesEngineSpatialLayout() throws {
        let (project, resolved) = demoResolved()
        let geo = SpatialLayout.compute(fixtures: resolved, stage: project.stage)
        for rf in resolved where rf.cellCount > 0 {
            let fp = StageFootprint(rf)
            let g = try XCTUnwrap(geo[rf.id])
            for i in 0..<rf.cellCount {
                let c = fp.cellCenter(i)
                XCTAssertEqual(c.x / project.stage.width, g.cellPositions[i].x, accuracy: 1e-9)
                XCTAssertEqual(c.y / project.stage.height, g.cellPositions[i].y, accuracy: 1e-9)
            }
        }
    }

    func testHitTestSelectsEachDemoFixture() {
        let (_, resolved) = demoResolved()
        let ppm = 70.0
        let items = resolved.map { (id: $0.id, footprint: StageFootprint($0, pointsPerMeter: ppm)) }
        for rf in resolved {
            let p = StageVec(rf.fixture.transform.x, rf.fixture.transform.y)
            XCTAssertEqual(StageHitTest.item(at: p, in: items, tolerance: 4 / ppm), rf.id, rf.fixture.stageLabel)
        }
        XCTAssertNil(StageHitTest.item(at: StageVec(4.8, 0.3), in: items, tolerance: 4 / ppm))
        // A near miss beside a thin tube still selects it.
        let b2 = StageVec(1.34, 3.92 + 0.07)
        XCTAssertEqual(StageHitTest.item(at: b2, in: items, tolerance: 6 / ppm), DemoRig.IDs.tube(2))
    }

    func testMarqueeAndRotatedIntersection() {
        let (_, resolved) = demoResolved()
        let items = resolved.map { (id: $0.id, footprint: StageFootprint($0, pointsPerMeter: 70)) }
        let rect = StageRect(minX: 0.5, minY: 3.6, maxX: 4.3, maxY: 5.0)
        XCTAssertEqual(Set(StageHitTest.items(in: rect, from: items)),
                       Set([DemoRig.IDs.tube(2), DemoRig.IDs.tube(3), DemoRig.IDs.tube(4)]))
        // A rotated tube: the marquee near its bounding-box corner (but off the body) misses it.
        let diag = StageFootprint(kind: .tube, center: .zero, rotation: 45, length: 2, thickness: 0.1)
        XCTAssertFalse(diag.intersects(StageRect(minX: 0.55, minY: -0.75, maxX: 0.7, maxY: -0.6)))
        XCTAssertTrue(diag.intersects(StageRect(minX: 0.3, minY: 0.3, maxX: 0.4, maxY: 0.4)))
    }

    func testSegmentDistanceAndOrdering() {
        let a = StageFootprint(kind: .tube, center: StageVec(0, 0), length: 1, thickness: 0.1)
        let b = StageFootprint(kind: .tube, center: StageVec(3, 0), length: 1, thickness: 0.1)
        XCTAssertEqual(a.distance(toSegment: StageVec(-2, 0), StageVec(5, 0)), 0, accuracy: 1e-12)
        XCTAssertEqual(a.distance(toSegment: StageVec(-1, 1), StageVec(1, 1)), 0.95, accuracy: 1e-9)
        let hits = StageHitTest.items(alongSegment: StageVec(4, 0), StageVec(-1, 0),
                                      from: [(id: 1, footprint: a), (id: 2, footprint: b)], tolerance: 0.01)
        XCTAssertEqual(hits, [2, 1])
        XCTAssertTrue(StageGeometry.segment(StageVec(-1, 0.5), StageVec(1, 0.5), intersects: StageRect(x: 0, y: 0, width: 1, height: 1)))
        XCTAssertFalse(StageGeometry.segment(StageVec(-1, 2), StageVec(1, 2), intersects: StageRect(x: 0, y: 0, width: 1, height: 1)))
    }

    // MARK: Snapping

    func testSnapAlignsCentersAndEdgesWithGuides() {
        let target = StageRect(center: StageVec(1, 3.92), width: 1.2, height: 0.1)
        let snapper = StageSnapper(targets: [StageSnapTarget(rect: target)], threshold: 0.08)
        let moving = StageRect(center: StageVec(3.3, 4.2), width: 1.2, height: 0.1)
        // Proposed delta brings the y within 0.03 m of the target's center line.
        let r = snapper.snap(moving: moving, delta: StageVec(0.05, -0.25))
        XCTAssertTrue(r.snappedY)
        XCTAssertEqual(moving.offsetBy(r.delta).midY, 3.92, accuracy: 1e-9)
        XCTAssertTrue(r.guides.contains { $0.axis == .horizontal && abs($0.position - 3.92) < 1e-6 })
        // Spacing label to the left neighbor.
        XCTAssertEqual(r.spacings.count, 1)
        XCTAssertEqual(r.spacings.first?.distance ?? 0, (3.35 - 0.6) - (1 + 0.6), accuracy: 1e-6)
    }

    func testSnapRespectsThresholdLocksAndGrid() {
        let target = StageRect(center: StageVec(0, 0), width: 1, height: 1)
        let snapper = StageSnapper(targets: [StageSnapTarget(rect: target)], threshold: 0.05)
        let moving = StageRect(center: StageVec(3, 0.3), width: 1, height: 1)
        let far = snapper.snap(moving: moving, delta: .zero)
        XCTAssertFalse(far.snappedY)
        approx(far.delta, .zero)
        let near = snapper.snap(moving: moving, delta: StageVec(0, -0.27))
        XCTAssertTrue(near.snappedY)
        XCTAssertEqual(near.delta.y, -0.3, accuracy: 1e-9)
        let locked = snapper.snap(moving: moving, delta: StageVec(0, -0.27), lockY: true)
        XCTAssertFalse(locked.snappedY)
        XCTAssertEqual(locked.delta.y, -0.27, accuracy: 1e-9)
        // Grid: centers land on the grid when nothing else is close.
        let grid = StageSnapper(targets: [], gridSize: 0.25, threshold: 0.05)
        let g = grid.snap(moving: StageRect(center: StageVec(1.1, 2.37), width: 0.2, height: 0.2), delta: .zero)
        XCTAssertEqual(1.1 + g.delta.x, 1.0, accuracy: 1e-9)
        XCTAssertEqual(2.37 + g.delta.y, 2.25, accuracy: 1e-9)
        // Room center line.
        let room = StageSnapper(targets: [], stage: StageRect(x: 0, y: 0, width: 5.2, height: 9.2), threshold: 0.05)
        let c = room.snap(moving: StageRect(center: StageVec(2.63, 7), width: 0.3, height: 0.3), delta: .zero)
        XCTAssertEqual(2.63 + c.delta.x, 2.6, accuracy: 1e-9)
        XCTAssertTrue(c.guides.contains { $0.axis == .vertical && abs($0.position - 2.6) < 1e-6 && $0.end - $0.start >= 9.2 - 1e-9 })
    }

    func testRotatedMoversSnapByCenterOnly() {
        let target = StageRect(center: StageVec(0, 0), width: 1, height: 1)
        let snapper = StageSnapper(targets: [StageSnapTarget(rect: target)], threshold: 0.05)
        // Edge (minX = 0.52) would be within threshold of the target's maxX (0.5), but edges are disabled.
        let moving = StageRect(center: StageVec(1.02, 3), width: 1, height: 1)
        let r = snapper.snap(moving: moving, delta: .zero, movingSnapsEdges: false)
        XCTAssertFalse(r.snappedX)
        let r2 = snapper.snap(moving: moving, delta: .zero, movingSnapsEdges: true)
        XCTAssertTrue(r2.snappedX)
        XCTAssertEqual(moving.offsetBy(r2.delta).minX, 0.5, accuracy: 1e-9)
    }

    // MARK: Arrange

    func testAlignAndDistribute() {
        let ids = (0..<4).map { _ in UUID() }
        let items = [
            StageArrangeItem(id: ids[0], center: StageVec(0, 0), bounds: StageRect(center: StageVec(0, 0), width: 1, height: 0.2)),
            StageArrangeItem(id: ids[1], center: StageVec(1.7, 0.4), bounds: StageRect(center: StageVec(1.7, 0.4), width: 0.4, height: 0.4)),
            StageArrangeItem(id: ids[2], center: StageVec(2.2, -0.3), bounds: StageRect(center: StageVec(2.2, -0.3), width: 0.2, height: 0.2)),
            StageArrangeItem(id: ids[3], center: StageVec(5, 0.1), bounds: StageRect(center: StageVec(5, 0.1), width: 1, height: 0.2)),
        ]
        let left = StageArrange.align(items, .left)
        XCTAssertEqual(left[ids[1]]?.x ?? 0, -0.5 + 0.2, accuracy: 1e-9)
        let mid = StageArrange.align(items, .centerY)
        let unionMid = StageRect.union(items.map(\.bounds))?.midY ?? 0
        for id in ids { XCTAssertEqual(mid[id]?.y ?? .nan, unionMid, accuracy: 1e-9) }
        XCTAssertTrue(StageArrange.align([items[0]], .left).isEmpty, "single item needs a reference")
        XCTAssertEqual(StageArrange.align([items[0]], .left, reference: StageRect(x: -3, y: 0, width: 9, height: 9))[ids[0]]?.x ?? 0,
                       -2.5, accuracy: 1e-9)

        let dist = StageArrange.distribute(items, .horizontal)
        // Outer items stay; inner gaps equal.
        XCTAssertEqual(dist[ids[0]]?.x ?? .nan, 0, accuracy: 1e-9)
        XCTAssertEqual(dist[ids[3]]?.x ?? .nan, 5, accuracy: 1e-9)
        let spans = items.map { it -> (Double, Double) in
            let c = dist[it.id] ?? it.center
            return (c.x - it.bounds.width / 2, c.x + it.bounds.width / 2)
        }.sorted { $0.0 < $1.0 }
        let gaps = zip(spans, spans.dropFirst()).map { $1.0 - $0.1 }
        for g in gaps { XCTAssertEqual(g, gaps[0], accuracy: 1e-9) }
        XCTAssertTrue(StageArrange.distribute(Array(items.prefix(2)), .vertical).isEmpty)
    }

    func testMirrorRotateAndHandles() {
        let t = StageTransform(x: 1, y: 2, rotation: 305)
        let m = StageArrange.mirrored(t, aboutX: 2.6)
        XCTAssertEqual(m.x, 4.2, accuracy: 1e-9)
        XCTAssertEqual(m.rotation, 235, accuracy: 1e-9)
        // Mirroring twice is the identity.
        let mm = StageArrange.mirrored(m, aboutX: 2.6)
        XCTAssertEqual(mm.x, t.x, accuracy: 1e-9)
        XCTAssertEqual(mm.rotation, t.rotation, accuracy: 1e-9)
        // Horizontal tube: pixel 1 moves from the left end to the right end.
        let fp = StageFootprint(kind: .tube, center: .zero, rotation: 0, length: 1, thickness: 0.1, cellCount: 4)
        let fpm = StageFootprint(kind: .tube, center: .zero, rotation: StageArrange.mirrored(StageTransform(), aboutX: 0).rotation,
                                 length: 1, thickness: 0.1, cellCount: 4)
        XCTAssertEqual(fpm.cellCenter(0).x, -fp.cellCenter(0).x, accuracy: 1e-9)

        let r = StageArrange.rotated(StageTransform(x: 2, y: 0, rotation: 10), around: StageVec(1, 0), by: 90)
        XCTAssertEqual(r.x, 1, accuracy: 1e-9)
        XCTAssertEqual(r.y, 1, accuracy: 1e-9)
        XCTAssertEqual(r.rotation, 100, accuracy: 1e-9)

        // Handle straight above → rotation 0; to the right → 90; ⇧ snaps to 15°.
        XCTAssertEqual(StageArrange.handleRotation(center: .zero, pointer: StageVec(0, -1)), 0, accuracy: 1e-9)
        XCTAssertEqual(StageArrange.handleRotation(center: .zero, pointer: StageVec(1, 0)), 90, accuracy: 1e-9)
        let snapped = StageArrange.handleRotation(center: .zero, pointer: StageVec(1, -0.9), snapStep: 15)
        XCTAssertEqual(snapped.truncatingRemainder(dividingBy: 15), 0, accuracy: 1e-9)
        // The handle sits on the −y side and follows rotation.
        let h = StageArrange.handlePosition(for: StageFootprint(kind: .tube, center: .zero, rotation: 90, length: 1, thickness: 0.1), offset: 0.2)
        approx(h, StageVec(0.25, 0), 1e-9)
    }

    // MARK: Labels

    func testFloorTubeLabelsDoNotOverlap() {
        let (project, resolved) = demoResolved()
        let content = StageRect(x: 0, y: 0, width: project.stage.width, height: project.stage.height)
        let vp = StageViewport.fitting(content, viewSize: StageVec(830, 640), insets: StageInsets(all: 40))
        let viewFootprints = resolved.map { rf -> (ResolvedFixture, StageFootprint) in
            var fp = StageFootprint(rf, pointsPerMeter: vp.scale)
            fp.center = vp.toView(fp.center)
            fp.length *= vp.scale; fp.thickness *= vp.scale
            return (rf, fp)
        }
        let obstacles = viewFootprints.map { StageLabelObstacle(viewFootprint: $0.1) }
        let requests = viewFootprints.map { rf, fp -> StageLabelRequest in
            let size = StageLabelLayout.estimatedSize(for: rf.fixture.stageLabel)
            return StageLabelRequest(id: rf.id, size: size, candidates: StageLabelLayout.candidates(for: fp, labelSize: size))
        }
        let placed = StageLabelLayout.place(requests, obstacles: obstacles,
                                            bounds: StageRect(x: 0, y: 0, width: 830, height: 640))
        XCTAssertEqual(placed.count, resolved.count)
        let rects = requests.compactMap { req -> StageRect? in
            placed[req.id].map { StageRect(center: $0, width: req.size.x, height: req.size.y) }
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                XCTAssertEqual(rects[i].overlapArea(rects[j]), 0, accuracy: 1e-6, "labels \(i) and \(j) overlap")
            }
        }
        // No label sits on a fixture body.
        for r in rects {
            for o in obstacles { XCTAssertGreaterThan(o.coreDistance(to: r) - o.radius, -1.0) }
        }
    }

    func testLabelCandidatesPreferUpperEndForVerticalTubes() {
        let fp = StageFootprint(kind: .tube, center: StageVec(100, 300), rotation: 270, length: 90, thickness: 8, cellCount: 16)
        let c = StageLabelLayout.candidates(for: fp, labelSize: StageVec(24, 17))
        XCTAssertLessThan(c[0].y, 300 - 45, "first candidate is above the upper end")
        let h = StageFootprint(kind: .tube, center: StageVec(100, 300), rotation: 0, length: 90, thickness: 8, cellCount: 16)
        let ch = StageLabelLayout.candidates(for: h, labelSize: StageVec(24, 17))
        XCTAssertEqual(ch[0].x, 100, accuracy: 1e-9)
        XCTAssertLessThan(ch[0].y, 296)
    }

    // MARK: Pixel painting

    func testStrokeCellsAndGradient() throws {
        let fp = StageFootprint(kind: .tube, center: StageVec(0, 0), rotation: 0, length: 1.6, thickness: 0.05, cellCount: 16)
        let cells = StagePixelMath.cells(alongStroke: StageVec(-0.75, 0), StageVec(0.05, 0.01), footprint: fp, tolerance: 0.02)
        XCTAssertEqual(cells, Array(0...8))
        XCTAssertEqual(StagePixelMath.cells(alongStroke: StageVec(-1, 1), StageVec(1, 1), footprint: fp), [])
        // Reverse stroke reports cells in stroke order.
        XCTAssertEqual(StagePixelMath.cells(alongStroke: StageVec(0.75, 0), StageVec(0.45, 0), footprint: fp).first, 15)

        let pink = try XCTUnwrap(LightColor.hex("#FF2FB4")), cyan = try XCTUnwrap(LightColor.hex("#14D8F0"))
        let fills = StagePixelMath.gradient(from: StageVec(-0.8, 0), to: StageVec(0.8, 0), colors: [pink, cyan],
                                            targets: [(id: DemoRig.IDs.tube(1), footprint: fp)])
        guard case .cells(let states)? = fills[DemoRig.IDs.tube(1)] else { return XCTFail("expected cells") }
        XCTAssertEqual(states.count, 16)
        // Red channel falls monotonically from pink to cyan.
        let reds = states.map { $0.color.sRGB.r }
        for (a, b) in zip(reds, reds.dropFirst()) { XCTAssertGreaterThanOrEqual(a + 1e-9, b) }
        XCTAssertGreaterThan(reds.first ?? 0, reds.last ?? 1)

        // Non-pixel fixtures get one color from their center.
        let panel = StageFootprint(kind: .panel, center: StageVec(0.8, 0), length: 0.6, thickness: 0.6)
        let whole = StagePixelMath.gradient(from: StageVec(-0.8, 0), to: StageVec(0.8, 0), colors: [pink, cyan],
                                            targets: [(id: DemoRig.IDs.pn1, footprint: panel)])
        XCTAssertEqual(whole[DemoRig.IDs.pn1], .whole(cyan))
        XCTAssertEqual(StagePixelMath.color(at: 0.5, stops: [pink]), pink)
        XCTAssertEqual(StagePixelMath.color(at: 1, stops: [pink, cyan]), cyan)
    }

    // MARK: Light model

    func testLightModel() {
        XCTAssertEqual(StageLighting.displayLevel(0), 0)
        XCTAssertGreaterThan(StageLighting.displayLevel(0.1), 0.25, "dim lights stay visible")
        XCTAssertEqual(StageLighting.displayLevel(1), 1, accuracy: 1e-12)
        XCTAssertLessThan(StageLighting.glowLevel(0.5), StageLighting.displayLevel(0.5))
        XCTAssertGreaterThan(StageLighting.spillRadius(kind: .panel, level: 1, size: 0.6),
                             StageLighting.spillRadius(kind: .panel, level: 0.1, size: 0.6))
        XCTAssertEqual(StageLighting.falloff(distance: 0, reach: 2), 1, accuracy: 1e-12)
        XCTAssertEqual(StageLighting.falloff(distance: 2, reach: 2), 0, accuracy: 1e-12)
        let samples = [StageLightSample(position: .zero, color: RGB(r: 1, g: 0, b: 0), level: 1, reach: 2),
                       StageLightSample(position: StageVec(1, 0), color: RGB(r: 0, g: 0, b: 1), level: 0.5, reach: 2)]
        let lit = StageLighting.illumination(at: StageVec(0.5, 0), from: samples)
        XCTAssertGreaterThan(lit.r, lit.b, "the brighter red light dominates")
        XCTAssertEqual(lit.g, 0, accuracy: 1e-12)
    }
}
