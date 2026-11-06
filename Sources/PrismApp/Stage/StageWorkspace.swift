import SwiftUI
import AppKit
import PrismCore

/// Maps stage meters ↔ view points (aspect-fit with padding). y grows downward (toward camera).
struct StageMapping {
    let stageSize: CGSize      // meters
    let viewSize: CGSize       // points
    var padding: CGFloat = 36

    var scale: CGFloat {
        let w = max(viewSize.width - padding * 2, 10), h = max(viewSize.height - padding * 2, 10)
        return min(w / max(stageSize.width, 0.1), h / max(stageSize.height, 0.1))
    }
    var origin: CGPoint {
        CGPoint(x: (viewSize.width - stageSize.width * scale) / 2, y: (viewSize.height - stageSize.height * scale) / 2)
    }
    func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(x) * scale, y: origin.y + CGFloat(y) * scale)
    }
    func meters(_ p: CGPoint) -> (x: Double, y: Double) {
        (Double((p.x - origin.x) / scale), Double((p.y - origin.y) / scale))
    }
    var stageRect: CGRect { CGRect(origin: origin, size: CGSize(width: stageSize.width * scale, height: stageSize.height * scale)) }
}

/// Visual shape class for a fixture.
enum FixtureShape {
    case linear(lengthM: Double, thicknessM: Double)
    case panel(widthM: Double, heightM: Double)
    case round(diameterM: Double)

    init(_ rf: ResolvedFixture) {
        switch rf.definition.category {
        case .tube, .bar, .strip:
            self = .linear(lengthM: max(rf.visualLengthMeters, 0.2), thicknessM: 0.08)
        case .panel, .wash:
            let w = (rf.definition.physical?.widthMM ?? rf.definition.physical?.lengthMM ?? 600) / 1000
            let h = (rf.definition.physical?.heightMM ?? rf.definition.physical?.widthMM ?? 600) / 1000
            self = .panel(widthM: max(w, 0.2), heightM: max(h, 0.2))
        default:
            self = .round(diameterM: 0.38)
        }
    }
}

/// The stage visualizer: live colors from the engine, glow, pixel cells, labels, selection and
/// drag-to-move. OWNER: Stage workstream (adds marquee select, rotate handles, pixel painting,
/// gradient tool, props editing, camera backdrop, zoom/pan, snapping).
struct StageWorkspace: View {
    @Environment(AppModel.self) private var app
    @State private var dragStart: [UUID: StageTransform] = [:]
    @State private var dragOrigin: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let stage = app.show.project.stage
            let mapping = StageMapping(stageSize: CGSize(width: stage.width, height: stage.height), viewSize: geo.size)
            let resolved = app.show.resolvedFixtures
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                let frame = app.engine.latestFrame
                Canvas { ctx, size in
                    StageRenderer.draw(ctx: &ctx, size: size, mapping: mapping, stage: stage, fixtures: resolved,
                                       frame: frame, selection: app.show.selection)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(mapping: mapping, resolved: resolved))
            .overlay(alignment: .topLeading) { StageHint() }
        }
        .accessibilityLabel("Stage view")
    }

    private func dragGesture(mapping: StageMapping, resolved: [ResolvedFixture]) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if dragOrigin == nil {
                    dragOrigin = g.startLocation
                    let hit = StageRenderer.hitTest(g.startLocation, mapping: mapping, fixtures: resolved)
                    let additive = NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command)
                    if let hit {
                        if additive {
                            if app.show.selection.contains(hit) { app.show.selection.remove(hit) } else { app.show.selection.insert(hit) }
                        } else if !app.show.selection.contains(hit) {
                            app.show.selection = [hit]
                        }
                        dragStart = Dictionary(app.show.fixtures
                            .filter { app.show.selection.contains($0.id) && !$0.locked }
                            .map { ($0.id, $0.transform) }, uniquingKeysWith: { a, _ in a })
                    } else {
                        if !additive { app.show.selection = [] }
                        dragStart = [:]
                    }
                }
                guard !dragStart.isEmpty else { return }
                let dx = Double(g.translation.width / mapping.scale)
                let dy = Double(g.translation.height / mapping.scale)
                guard abs(g.translation.width) + abs(g.translation.height) > 2 else { return }
                let stage = app.show.project.stage
                let starts = dragStart
                app.show.editProject("Move Lights", coalesceKey: "move-\(starts.keys.sorted { $0.uuidString < $1.uuidString }.first?.uuidString ?? "")") { p in
                    for i in p.fixtures.indices {
                        guard let s = starts[p.fixtures[i].id] else { continue }
                        var t = s
                        t.x = min(max(s.x + dx, 0), stage.width)
                        t.y = min(max(s.y + dy, 0), stage.height)
                        if stage.snapToGrid, stage.gridSize > 0 {
                            t.x = (t.x / stage.gridSize).rounded() * stage.gridSize
                            t.y = (t.y / stage.gridSize).rounded() * stage.gridSize
                        }
                        p.fixtures[i].transform = t
                    }
                }
            }
            .onEnded { _ in
                dragOrigin = nil
                dragStart = [:]
            }
    }
}

private struct StageHint: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        if app.show.fixtures.isEmpty {
            EmptyStateView(systemImage: "light.panel", title: "No lights yet",
                           message: "Add your lights and Prism will walk you through connecting each one.",
                           actionTitle: "Add Light…") { app.ui.activeSheet = .addFixture }
        }
    }
}

/// Pure drawing + hit testing so it can be reused by thumbnails and the screenshot tour.
enum StageRenderer {
    static func draw(ctx: inout GraphicsContext, size: CGSize, mapping: StageMapping, stage: StageSettings,
                     fixtures: [ResolvedFixture], frame: RenderedFrame, selection: Set<UUID>) {
        let rect = mapping.stageRect
        // Floor
        ctx.fill(Path(roundedRect: rect, cornerRadius: 18), with: .color(Color(hex: 0x0E1016)))
        if stage.background == .grid || stage.snapToGrid {
            var grid = Path()
            let step = max(stage.gridSize, 0.25) * 2
            var x = 0.0
            while x <= stage.width { grid.move(to: mapping.point(x, 0)); grid.addLine(to: mapping.point(x, stage.height)); x += step }
            var y = 0.0
            while y <= stage.height { grid.move(to: mapping.point(0, y)); grid.addLine(to: mapping.point(stage.width, y)); y += step }
            ctx.stroke(grid, with: .color(Color.white.opacity(0.035)), lineWidth: 1)
        }

        // Light glow (additive feel)
        if stage.showGlow {
            var glow = ctx
            glow.blendMode = .plusLighter
            for rf in fixtures {
                guard let st = frame.states[rf.id], st.intensity > 0.01 else { continue }
                let c = mapping.point(rf.fixture.transform.x, rf.fixture.transform.y)
                let radius = mapping.scale * 1.5
                let col = Color(st.color.displayRGB)
                glow.fill(Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)),
                          with: .radialGradient(Gradient(colors: [col.opacity(0.42 * st.intensity), col.opacity(0)]),
                                                center: c, startRadius: 0, endRadius: radius))
            }
        }

        // Props (subject silhouette)
        for prop in stage.props where prop.kind == .person {
            let c = mapping.point(prop.transform.x, prop.transform.y)
            let h = mapping.scale * 1.7
            let body = Path(roundedRect: CGRect(x: c.x - h * 0.13, y: c.y - h * 0.32, width: h * 0.26, height: h * 0.62), cornerRadius: h * 0.1)
            let head = Path(ellipseIn: CGRect(x: c.x - h * 0.08, y: c.y - h * 0.5, width: h * 0.16, height: h * 0.16))
            ctx.fill(body, with: .color(Color.black.opacity(0.85)))
            ctx.fill(head, with: .color(Color.black.opacity(0.85)))
            ctx.stroke(body, with: .color(Color.white.opacity(0.08)))
            ctx.stroke(head, with: .color(Color.white.opacity(0.08)))
        }

        // Fixtures
        for rf in fixtures {
            let st = frame.states[rf.id] ?? .off
            let t = rf.fixture.transform
            let c = mapping.point(t.x, t.y)
            let selected = selection.contains(rf.id)
            var fx = ctx
            fx.translateBy(x: c.x, y: c.y)
            fx.rotate(by: .degrees(t.rotation))
            let shape = FixtureShape(rf)
            switch shape {
            case .linear(let len, let thick):
                let w = CGFloat(len * t.scale) * mapping.scale
                let h = max(CGFloat(thick) * mapping.scale, 9)
                let body = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
                fx.fill(Path(roundedRect: body, cornerRadius: h / 2), with: .color(Color(hex: 0x15171D)))
                let n = max(rf.cellCount, 1)
                let cw = (w - 4) / CGFloat(n)
                for i in 0..<n {
                    let idx = rf.fixture.reversePixels ? (n - 1 - i) : i
                    let cell = st.cells.flatMap { $0.indices.contains(idx) ? $0[idx] : nil }
                    let color = cell?.color ?? st.color
                    let level = st.intensity * (cell?.intensity ?? 1)
                    let r = CGRect(x: -w / 2 + 2 + CGFloat(i) * cw + 0.5, y: -h / 2 + 2, width: max(cw - 1, 1), height: h - 4)
                    fx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(cellColor(color, level)))
                }
                fx.stroke(Path(roundedRect: body, cornerRadius: h / 2),
                          with: .color(selected ? Theme.accent : Color.white.opacity(0.35)), lineWidth: selected ? 2.5 : 1)
            case .panel(let pw, let ph):
                let w = CGFloat(pw * t.scale) * mapping.scale, h = CGFloat(ph * t.scale) * mapping.scale
                let r = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
                fx.fill(Path(roundedRect: r, cornerRadius: 6), with: .color(cellColor(st.color, st.intensity)))
                fx.stroke(Path(roundedRect: r, cornerRadius: 6),
                          with: .color(selected ? Theme.accent : Color.white.opacity(0.5)), lineWidth: selected ? 2.5 : 1.2)
            case .round(let d):
                let s = CGFloat(d * t.scale) * mapping.scale
                let r = CGRect(x: -s / 2, y: -s / 2, width: s, height: s)
                fx.fill(Path(ellipseIn: r), with: .color(cellColor(st.color, st.intensity)))
                fx.stroke(Path(ellipseIn: r), with: .color(selected ? Theme.accent : Color.white.opacity(0.7)), lineWidth: selected ? 2.5 : 1.5)
            }

            if stage.showLabels {
                let label = Text(rf.fixture.stageLabel)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(selected ? .white : Color.white.opacity(0.75))
                ctx.draw(label, at: CGPoint(x: c.x, y: c.y - labelOffset(shape, mapping, t) ), anchor: .bottom)
            }
        }
    }

    private static func labelOffset(_ shape: FixtureShape, _ m: StageMapping, _ t: StageTransform) -> CGFloat {
        switch shape {
        case .linear(let len, _):
            let half = CGFloat(len * t.scale) * m.scale / 2
            return abs(sin(t.rotation * .pi / 180)) * half + 12
        case .panel(_, let h): return CGFloat(h * t.scale) * m.scale / 2 + 6
        case .round(let d): return CGFloat(d * t.scale) * m.scale / 2 + 6
        }
    }

    /// On-screen color for a light at a level: dark when off, full color when on.
    static func cellColor(_ color: LightColor, _ level: Double) -> Color {
        let rgb = color.displayRGB
        let l = max(0, min(level, 1))
        let base = 0.09
        let k = base + (1 - base) * pow(l, 0.6)
        return Color(.sRGB, red: 0.06 + (rgb.r - 0.06) * k * (l > 0.004 ? 1 : 0),
                     green: 0.065 + (rgb.g - 0.065) * k * (l > 0.004 ? 1 : 0),
                     blue: 0.08 + (rgb.b - 0.08) * k * (l > 0.004 ? 1 : 0), opacity: 1)
    }

    /// Topmost fixture under a point.
    static func hitTest(_ p: CGPoint, mapping: StageMapping, fixtures: [ResolvedFixture]) -> UUID? {
        for rf in fixtures.reversed() {
            let t = rf.fixture.transform
            let c = mapping.point(t.x, t.y)
            // Into fixture-local coordinates.
            let dx = p.x - c.x, dy = p.y - c.y
            let a = -t.rotation * .pi / 180
            let lx = dx * cos(a) - dy * sin(a)
            let ly = dx * sin(a) + dy * cos(a)
            switch FixtureShape(rf) {
            case .linear(let len, let thick):
                let w = CGFloat(len * t.scale) * mapping.scale, h = max(CGFloat(thick) * mapping.scale, 9) + 10
                if abs(lx) <= w / 2 + 4 && abs(ly) <= h / 2 { return rf.id }
            case .panel(let pw, let ph):
                let w = CGFloat(pw * t.scale) * mapping.scale, h = CGFloat(ph * t.scale) * mapping.scale
                if abs(lx) <= w / 2 + 4 && abs(ly) <= h / 2 + 4 { return rf.id }
            case .round(let d):
                let r = CGFloat(d * t.scale) * mapping.scale / 2 + 6
                if lx * lx + ly * ly <= r * r { return rf.id }
            }
        }
        return nil
    }
}
