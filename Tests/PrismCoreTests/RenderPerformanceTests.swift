import XCTest
@testable import PrismCore

/// Frame-budget regression tests for the colour pipeline (`FixtureState.mix` → `EmitterMixer` →
/// `FixtureRenderer`) and the full `EngineCore.renderFrame` on the London Studio demo rig.
///
/// The app's self-test gates the demo rig at median < 3 ms / p95 < 6 ms in release builds. These
/// Linux tests run unoptimised (debug) on a small shared VM, so their budgets are deliberately loose:
/// they exist to catch pathological regressions (an un-memoised solver, a per-cell Planckian search,
/// accidental O(n²) work), not to benchmark. Each scenario keeps the best of several batches so a
/// noisy neighbour can't fail the build. Timings are printed as `PERF …` lines.
final class RenderPerformanceTests: XCTestCase {

    #if DEBUG
    /// Unoptimised build: generous, only catches pathological regressions.
    private static let budgetScale = 1.0
    #else
    /// Optimised build: an order of magnitude tighter.
    private static let budgetScale = 0.1
    #endif

    /// Runs `body(frameIndex)` for `batches × iterations` frames; returns the best batch's
    /// median and p95 in milliseconds.
    private func measure(
        _ name: String,
        batches: Int = 3,
        iterations: Int = 60,
        warmup: Int = 10,
        _ body: (Int) -> Void
    ) -> (median: Double, p95: Double) {
        for i in 0..<warmup { body(i) }
        var best = (median: Double.infinity, p95: Double.infinity)
        var frame = warmup
        for _ in 0..<batches {
            var durations: [Double] = []
            durations.reserveCapacity(iterations)
            for _ in 0..<iterations {
                let t0 = PrismClock.now()
                body(frame)
                durations.append((PrismClock.now() - t0) * 1000)
                frame += 1
            }
            durations.sort()
            let median = durations[durations.count / 2]
            let p95 = durations[min(durations.count - 1, Int(Double(durations.count) * 0.95))]
            if p95 < best.p95 { best = (median, p95) }
        }
        print(String(format: "PERF %@: median %.3f ms, p95 %.3f ms", name, best.median, best.p95))
        return best
    }

    // MARK: - Fixtures

    /// amaran PT4c "Light Engine CCT & RGB n Pixels": n × [intensity, cct, tint, crossfade, R, G, B].
    static func pt4cMode(pixels: Int) -> FixtureMode {
        var channels: [ChannelDefinition] = []
        for cell in 0..<pixels {
            channels.append(ChannelDefinition(kind: .intensity, cell: cell))
            channels.append(ChannelDefinition(kind: .cct, cell: cell, physical: PhysicalRange(from: 2700, to: 10000)))
            channels.append(ChannelDefinition(kind: .tint, cell: cell, defaultValue: 128, physical: PhysicalRange(from: -1, to: 1)))
            channels.append(ChannelDefinition(kind: .crossfade, cell: cell, physical: PhysicalRange(from: 0, to: 1)))
            channels.append(ChannelDefinition(kind: .red, cell: cell))
            channels.append(ChannelDefinition(kind: .green, cell: cell))
            channels.append(ChannelDefinition(kind: .blue, cell: cell))
        }
        return FixtureMode(name: "Light Engine CCT & RGB \(pixels) Pixels", shortName: "LE \(pixels)px", channels: channels)
    }

    static func pt4cDefinition(pixels: Int) -> FixtureDefinition {
        FixtureDefinition(id: "test.pt4c", manufacturer: "amaran", model: "PT4c", category: .tube,
                          cctRange: [2700, 10000], modes: [pt4cMode(pixels: pixels)])
    }

    /// Per-cell colours for frame `frame`: a moving mix of saturated hues, pastels and whites so
    /// both the RGB and native-white paths (and the hysteresis band between them) are exercised.
    static func movingCells(count: Int, frame: Int, fixture: Int) -> [CellState] {
        (0..<count).map { c in
            let phase = Double(frame) * 0.013 + Double(c) / Double(max(count, 1)) + Double(fixture) * 0.17
            switch (c + fixture) % 4 {
            case 0:
                return CellState(intensity: 1, color: .hsi(hue: (phase * 360).truncatingRemainder(dividingBy: 360), saturation: 1))
            case 1:
                return CellState(intensity: 0.8, color: .kelvin(2700 + 5000 * (0.5 + 0.5 * sin(phase * 6)), tint: 0.2 * sin(phase)))
            case 2:
                let s = 0.5 + 0.5 * sin(phase * 3)
                return CellState(intensity: 0.9, color: .rgb(RGB(hue: (phase * 200).truncatingRemainder(dividingBy: 360), saturation: s, value: 1)))
            default:
                return CellState(intensity: 0.6, color: LightColor.mix(.kelvin(3200), .rgb(RGB(r: 0, g: 0.76, b: 0.66)), 0.5 + 0.5 * sin(phase * 2)))
            }
        }
    }

    // MARK: - Scenarios

    /// The self-test scenario made harder: London Studio mid-crossfade between two pixel looks,
    /// with a rainbow effect on every tube and music mode running on live audio.
    func testDemoRigBusyFrameBudget() throws {
        let lib = TestResources.library()
        var doc = ShowDocument(project: DemoRig.londonStudio())
        guard let target = doc.project.looks.first(where: { $0.name == "New Studio Vibes" }) else {
            return XCTFail("Demo look missing")
        }
        let exec = CommandExecutor(library: lib.definition, now: { 100.0 })
        _ = exec.apply([.recallLook(.id(target.id), fade: 600)], to: &doc)
        doc.live.effects.append(EffectInstance(id: UUID(), kind: .rainbow, targets: .group(doc.project.groups[0].id),
                                               params: EffectParameters(speed: 1, amount: 0.8)))
        doc.live.music.enabled = true
        doc.live.music.targets = .all
        let snap = ShowSnapshot(document: doc, library: lib.definition)
        XCTAssertGreaterThan(snap.fixtures.count, 8)

        let result = measure("demo rig busy renderFrame") { i in
            let t = 101.0 + Double(i) / 40
            let audio = AudioFeatures(timestamp: t, isActive: true, level: 0.6 + 0.3 * sin(Double(i) * 0.3),
                                      bands: [0.7, 0.6, 0.4, 0.3, 0.2, 0.1], onset: 0.2, beat: i % 20 == 0,
                                      beatPhase: Double(i % 20) / 20, bpm: 120, tempoConfidence: 0.8, brightness: 0.5)
            _ = EngineCore.renderFrame(snap, audio: audio, time: t, frameNumber: UInt64(i))
        }
        // Self-test budget for unoptimised builds is 25 ms median / 50 ms p95 on CI Macs.
        XCTAssertLessThan(result.median, 25 * Self.budgetScale)
        XCTAssertLessThan(result.p95, 50 * Self.budgetScale)
    }

    /// The real studio: eight amaran PT4c tubes in the 16-pixel CCT & RGB mode (two universes),
    /// every cell changing colour every frame (no memoisation hits for animated content).
    func testPixelTubeCCTAndRGBRenderBudget() {
        let def = Self.pt4cDefinition(pixels: 16)
        let mode = def.modes[0]
        let fixtures: [ResolvedFixture] = (0..<8).map { i in
            let p = PatchedFixture(name: "PT\(i + 1)", definitionID: def.id, modeName: mode.name,
                                   universe: 1 + i / 4, address: 1 + (i % 4) * 112)
            return ResolvedFixture(fixture: p, definition: def, mode: mode)
        }
        let safety = SafetySettings()
        let result = measure("8 × PT4c 16px animated render") { frame in
            for (i, rf) in fixtures.enumerated() {
                let state = FixtureState(intensity: 0.9, color: .white, cells: Self.movingCells(count: 16, frame: frame, fixture: i))
                _ = FixtureRenderer.render(state, fixture: rf, safety: safety)
            }
        }
        XCTAssertLessThan(result.median, 15 * Self.budgetScale)
        XCTAssertLessThan(result.p95, 30 * Self.budgetScale)
    }

    /// Brief 02 §9: 16 full universes. Static looks (the common case) must be nearly free.
    func testSixteenUniversesStaticRenderBudget() {
        let pt4c = Self.pt4cDefinition(pixels: 4) // 28 channels
        let rgbww = FixtureDefinition(id: "test.rgbww", manufacturer: "Test", model: "RGBWW", category: .panel, modes: [
            FixtureMode(name: "8ch", channels: [
                ChannelDefinition(kind: .intensity), ChannelDefinition(kind: .intensity, fine: true),
                ChannelDefinition(kind: .red), ChannelDefinition(kind: .green), ChannelDefinition(kind: .blue),
                ChannelDefinition(kind: .warmWhite), ChannelDefinition(kind: .coolWhite), ChannelDefinition(kind: .strobe),
            ]),
        ])
        let colors: [LightColor] = [
            .rgb(RGB(r: 0, g: 0.76, b: 0.66)), .rgb(RGB(r: 1, g: 0.18, b: 0.7)), .kelvin(3200), .kelvin(5600, tint: -0.1),
            .rgb(RGB(r: 1, g: 0.48, b: 0.1)), .hsi(hue: 220, saturation: 0.7), .xy(x: 0.35, y: 0.36),
        ]
        var work: [(FixtureState, ResolvedFixture)] = []
        for u in 1...16 {
            // 12 PT4c 4px (336 ch) + 21 RGBWW (168 ch) = 504 channels per universe.
            for f in 0..<12 {
                let p = PatchedFixture(name: "T\(u)-\(f)", definitionID: pt4c.id, modeName: pt4c.modes[0].name,
                                       universe: u, address: 1 + f * 28)
                let cells = (0..<4).map { CellState(intensity: 1, color: colors[(u + f + $0) % colors.count]) }
                work.append((FixtureState(intensity: 0.8, color: .white, cells: cells),
                             ResolvedFixture(fixture: p, definition: pt4c, mode: pt4c.modes[0])))
            }
            for f in 0..<21 {
                let p = PatchedFixture(name: "P\(u)-\(f)", definitionID: rgbww.id, modeName: "8ch",
                                       universe: u, address: 337 + f * 8)
                work.append((FixtureState(intensity: 0.7, color: colors[(u * 3 + f) % colors.count]),
                             ResolvedFixture(fixture: p, definition: rgbww, mode: rgbww.modes[0])))
            }
        }
        let safety = SafetySettings()
        let result = measure("16 universes static render") { _ in
            for (state, rf) in work { _ = FixtureRenderer.render(state, fixture: rf, safety: safety) }
        }
        XCTAssertLessThan(result.median, 80 * Self.budgetScale)
        XCTAssertLessThan(result.p95, 160 * Self.budgetScale)
    }

    /// Crossfading pixel states (OKLab per cell + perceptual intensity) for the whole demo rig.
    func testPixelCrossfadeMixBudget() {
        let a = (0..<9).map { f in FixtureState(intensity: 1, color: .white, cells: Self.movingCells(count: 16, frame: 0, fixture: f)) }
        let b = (0..<9).map { f in FixtureState(intensity: 0.4, color: .white, cells: Self.movingCells(count: 16, frame: 500, fixture: f)) }
        let result = measure("demo rig pixel crossfade mix") { frame in
            let t = Double(frame % 100) / 100
            for i in 0..<a.count { _ = FixtureState.mix(a[i], b[i], t) }
        }
        XCTAssertLessThan(result.median, 10 * Self.budgetScale)
        XCTAssertLessThan(result.p95, 20 * Self.budgetScale)
    }
}
