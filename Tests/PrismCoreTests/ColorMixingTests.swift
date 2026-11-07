import XCTest
@testable import PrismCore

/// Brief 02 M2–M4: mixing modes, calibration, the native-white crossfade, fast CCT + analysis
/// memo, non-RGB topologies and renderer details.
final class ColorMixingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FixtureRenderer.resetHysteresisState()
    }

    // MARK: - Helpers

    /// amaran PT4c "Light Engine CCT & RGB" pixel mode: n × [intensity, cct, tint, crossfade, R, G, B].
    private func pt4c(pixels: Int = 1, calibration: ColorCalibration = .default) -> ResolvedFixture {
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
        let mode = FixtureMode(name: "LE \(pixels)px", channels: channels)
        let def = FixtureDefinition(id: "test.pt4c", manufacturer: "amaran", model: "PT4c", category: .tube,
                                    cctRange: [2700, 10000], modes: [mode])
        var patched = PatchedFixture(name: "PT4c", definitionID: def.id, modeName: mode.name, universe: 1, address: 1)
        patched.calibration = calibration
        return ResolvedFixture(fixture: patched, definition: def, mode: mode)
    }

    private func fixture(_ id: String, _ channels: [ChannelDefinition], cctRange: [Double]? = nil) -> ResolvedFixture {
        let mode = FixtureMode(name: id, channels: channels)
        let def = FixtureDefinition(id: "test.\(id)", manufacturer: "Test", model: id, category: .panel,
                                    cctRange: cctRange, modes: [mode])
        let patched = PatchedFixture(name: id, definitionID: def.id, modeName: mode.name, universe: 1, address: 1)
        return ResolvedFixture(fixture: patched, definition: def, mode: mode)
    }

    // MARK: - Fast CCT and the analysis memo

    func testFastCCTAgreesWithReferenceSearch() {
        var k = 1700.0
        while k <= 20000 {
            for tint in [-1.0, -0.5, 0, 0.5, 1.0] {
                let xy = ColorMath.kelvinToXY(k, tint: tint)
                let fast = ColorMath.xyToKelvinAndDuv(x: xy.x, y: xy.y)
                let ref = ColorMath.xyToKelvinAndDuvReference(x: xy.x, y: xy.y)
                XCTAssertEqual(1e6 / fast.kelvin, 1e6 / ref.kelvin, accuracy: 0.01, "mired at \(k) K, tint \(tint)")
                XCTAssertEqual(fast.duv, ref.duv, accuracy: 1e-5, "Duv at \(k) K, tint \(tint)")
            }
            k *= 1.07
        }
        // Saturated colours still give finite, clamped answers.
        for hex in ["#FF0000", "#00FF00", "#0000FF", "#00C2A8", "#FF2FB4"] {
            let xy = LightColor.rgb(RGB(hex: hex)!).xy
            let r = ColorMath.xyToKelvinAndDuv(x: xy.x, y: xy.y)
            XCTAssertTrue(r.kelvin.isFinite && r.duv.isFinite && r.kelvin >= 1000 && r.kelvin <= 25000, hex)
        }
    }

    func testColorAnalysisMemoIsDeterministic() throws {
        let cache = ColorAnalysisCache.shared
        cache.removeAll()
        let colors: [LightColor] = [
            .rgb(RGB(hex: "#3A7BD5")!), .kelvin(4300, tint: -0.2), .hsi(hue: 200, saturation: 0.6), .xy(x: 0.35, y: 0.36)
        ]
        for c in colors {
            let before = cache.stats
            let miss = ColorAnalysis.of(c)
            let hit = ColorAnalysis.of(c)
            XCTAssertEqual(miss, hit)
            XCTAssertGreaterThan(cache.stats.hits, before.hits, "second lookup must hit (\(c.label))")
            let q = try XCTUnwrap(ColorAnalysis.quantize(c))
            XCTAssertEqual(hit, ColorAnalysis.compute(q.canonical, includeCCT: true))
            XCTAssertTrue(hit.hasCCT)
            XCTAssertEqual(hit.linear.maxComponent, 1, accuracy: 1e-9)
        }
        // CCT is computed on demand when an earlier lookup skipped it.
        cache.removeAll()
        let pink = LightColor.rgb(RGB(hex: "#FF2FB4")!)
        XCTAssertFalse(ColorAnalysis.of(pink, includeCCT: false).hasCCT)
        XCTAssertTrue(ColorAnalysis.of(pink, includeCCT: true).hasCCT)
        XCTAssertTrue(ColorAnalysis.of(.rgb(.black)).isBlack)
        XCTAssertFalse(ColorAnalysis.of(.xy(x: .nan, y: 0.3)).linear.r.isNaN)
    }

    // MARK: - Calibration

    func testCalibrationGainsGammaAndWhitePointTrim() {
        let rgbw: Set<ChannelKind> = [.red, .green, .blue, .white]
        let base = EmitterMixer.mix(.kelvin(3200), emitters: rgbw)
        let trimmed = EmitterMixer.mix(.kelvin(3200), emitters: rgbw, calibration: ColorCalibration(gains: ["red": 0.5]))
        let baseR = base[.red] ?? 0, baseW = base[.white] ?? 0
        XCTAssertGreaterThan(baseR, 0.05)
        XCTAssertGreaterThan(baseW, 0.5)
        XCTAssertEqual((trimmed[.red] ?? 0) / max(trimmed[.white] ?? 0, 1e-9), 0.5 * baseR / baseW, accuracy: 1e-6)
        XCTAssertEqual(trimmed.values.max() ?? 0, 1, accuracy: 1e-9, "still peak-normalised")

        // Gamma shapes the levels (Direct keeps the numbers easy to check).
        let shaped = EmitterMixer.mix(.rgb(RGB(r: 1, g: 0.5, b: 0)), emitters: [.red, .green, .blue],
                                      calibration: ColorCalibration(gamma: 2, mixingMode: .direct))
        XCTAssertEqual(shaped[.red] ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(shaped[.green] ?? 0, 0.25, accuracy: 1e-9)

        // White-point trim moves the native CCT/tint channels: +300 K and +0.5 tint (magenta).
        let trimmedPT4c = pt4c(calibration: ColorCalibration(whitePointKelvinTrim: 300, whitePointTintTrim: 0.5))
        let dmx = FixtureRenderer.render(FixtureState(intensity: 0.5, color: .kelvin(3200)), fixture: trimmedPT4c)
        XCTAssertEqual(dmx, [128, 28, 64, 0, 0, 0, 0])

        // …and shifts RGB-rendered colours the same way (warmer = less blue).
        let rgb: Set<ChannelKind> = [.red, .green, .blue]
        let grey = LightColor.rgb(RGB(hex: "#E0E0E0")!)
        let neutral = EmitterMixer.mix(grey, emitters: rgb)
        let warmer = EmitterMixer.mix(grey, emitters: rgb, calibration: ColorCalibration(whitePointKelvinTrim: -1500))
        XCTAssertLessThan(warmer[.blue] ?? 1, (neutral[.blue] ?? 0) - 0.05)
    }

    // MARK: - Native white path

    func testNativeWhiteShareIsSmoothAndRangeAware() {
        let range: ClosedRange<Double> = 2700...10000
        XCTAssertEqual(EmitterMixer.nativeWhiteShare(kelvin: 3200, duv: 0, cctRange: range), 1)
        XCTAssertEqual(EmitterMixer.nativeWhiteShare(kelvin: 3200, duv: 0.02, cctRange: range), 1, "full tint range stays native")
        XCTAssertEqual(EmitterMixer.nativeWhiteShare(kelvin: 3200, duv: -0.03, cctRange: range), 0)
        let mid = EmitterMixer.nativeWhiteShare(kelvin: 3200, duv: 0.024, cctRange: range)
        XCTAssertTrue(mid > 0 && mid < 1)
        XCTAssertEqual(EmitterMixer.nativeWhiteShare(kelvin: 2000, duv: 0, cctRange: range), 0)
        let edge = EmitterMixer.nativeWhiteShare(kelvin: 2600, duv: 0, cctRange: range)
        XCTAssertTrue(edge > 0 && edge < 1)
        var last = 1.0
        for i in 0...100 {
            let s = EmitterMixer.nativeWhiteShare(kelvin: 4500, duv: Double(i) * 0.0004, cctRange: range)
            XCTAssertLessThanOrEqual(s, last + 1e-12)
            XCTAssertLessThanOrEqual(last - s, 0.1)
            last = s
        }
        XCTAssertEqual(EmitterMixer.nativeWhiteShare(for: .rgb(.black)), 0)
    }

    func testCCTToRGBCrossfadeHasNoVisibleJumps() {
        let tube = pt4c()
        let start = LightColor.kelvin(3200)
        let end = LightColor.rgb(RGB(hex: "#00C2A8")!)
        let steps = 200
        var lastXF = 0.0
        var lastEff = [0.0, 0.0, 0.0]
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let dmx = FixtureRenderer.render(FixtureState(intensity: 1, color: LightColor.mix(start, end, t)), fixture: tube)
            let xf = Double(dmx[3]) / 255
            // Light from the RGB engine is (crossfade × RGB level); from the CCT engine (1 − crossfade).
            let eff = (4...6).map { xf * Double(dmx[$0]) / 255 }
            if i == 0 { XCTAssertEqual(dmx, [255, 17, 128, 0, 0, 0, 0]) }
            if i == steps { XCTAssertEqual(dmx, [255, 0, 128, 255, 0, 255, 185]) }
            if i > 0 {
                XCTAssertGreaterThanOrEqual(xf, lastXF - 1.0 / 255, "crossfade reversed at t=\(t)")
                XCTAssertLessThan(abs(xf - lastXF), 0.12, "crossfade jump at t=\(t)")
                for c in 0..<3 {
                    XCTAssertLessThan(abs(eff[c] - lastEff[c]), 0.12, "RGB engine jump (channel \(c)) at t=\(t)")
                }
            }
            lastXF = xf
            lastEff = eff
        }
    }

    func testTintChannelFollowsFixtureConvention() {
        let tube = pt4c()
        let magenta = FixtureRenderer.render(FixtureState(intensity: 1, color: .kelvin(5600, tint: 0.5)), fixture: tube)
        let green = FixtureRenderer.render(FixtureState(intensity: 1, color: .kelvin(5600, tint: -0.5)), fixture: tube)
        XCTAssertEqual(magenta[2], 64, "Prism +0.5 (magenta) = channel −0.5 (minus green)")
        XCTAssertEqual(green[2], 191, "Prism −0.5 (green) = channel +0.5 (plus green)")
        XCTAssertEqual(magenta[3], 0)
        XCTAssertEqual(green[3], 0)
    }

    func testBlackStaysOnTheRGBEngine() {
        XCTAssertEqual(FixtureRenderer.render(FixtureState(intensity: 1, color: .rgb(.black)), fixture: pt4c()),
                       [255, 0, 128, 255, 0, 0, 0])
    }

    func testSwitchingFixturesUseHysteresis() {
        let caps = [ChannelCapability(from: 0, to: 127, label: "CCT", tag: "cct"),
                    ChannelCapability(from: 128, to: 255, label: "RGB", tag: "rgb")]
        let rf = fixture("switch", [
            ChannelDefinition(kind: .intensity),
            ChannelDefinition(kind: .colorMode, capabilities: caps),
            ChannelDefinition(kind: .cct, physical: PhysicalRange(from: 2700, to: 6500)),
            ChannelDefinition(kind: .tint, defaultValue: 128),
            ChannelDefinition(kind: .red), ChannelDefinition(kind: .green), ChannelDefinition(kind: .blue)
        ], cctRange: [2700, 6500])
        let xy = ColorMath.kelvinToXY(4500, tint: 0.5) // |Duv| = 0.010, inside the 0.006…0.016 deadband
        let border = LightColor.xy(x: xy.x, y: xy.y)
        func colorMode(_ c: LightColor) -> UInt8 { FixtureRenderer.render(FixtureState(intensity: 1, color: c), fixture: rf)[1] }
        XCTAssertEqual(colorMode(.kelvin(4500)), 63)
        XCTAssertEqual(colorMode(border), 63, "stays on native white inside the deadband")
        XCTAssertEqual(colorMode(.rgb(RGB(hex: "#00C2A8")!)), 191)
        XCTAssertEqual(colorMode(border), 191, "stays on RGB inside the deadband")
    }

    // MARK: - Modes

    func testDirectModeIsExactAndContinuous() {
        let rgbw: Set<ChannelKind> = [.red, .green, .blue, .white]
        let direct = ColorCalibration(mixingMode: .direct)
        let exact = EmitterMixer.mix(.rgb(RGB(hex: "#FF00AA")!), emitters: rgbw, calibration: direct)
        XCTAssertEqual(exact[.red] ?? 0, 1, accuracy: 1e-12)
        XCTAssertEqual(exact[.blue] ?? 0, 170.0 / 255.0, accuracy: 1e-12)
        var last: [ChannelKind: Double]?
        for i in 0...100 {
            let c = LightColor.mix(.kelvin(5600), .rgb(RGB(hex: "#FF8800")!), Double(i) / 100)
            let l = EmitterMixer.mix(c, emitters: rgbw, calibration: direct)
            XCTAssertEqual(l[.white] ?? 1, 0, accuracy: 1e-12)
            if let last {
                for k in [ChannelKind.red, .green, .blue] {
                    XCTAssertLessThan(abs((l[k] ?? 0) - (last[k] ?? 0)), 0.06, "\(k) jumps at step \(i)")
                }
            }
            last = l
        }
        // An explicit mode wins over the calibration's.
        let accurate = EmitterMixer.mix(.kelvin(5600), emitters: rgbw, emitterSpecs: nil, calibration: direct, mode: .accurate)
        XCTAssertGreaterThan(accurate[.white] ?? 0, 0.9)
    }

    func testMixingModeProjectDefaultOverrideAndLegacyFiles() throws {
        let mode = FixtureMode(name: "RGBW", channels: [ChannelKind.intensity, .red, .green, .blue, .white].map { ChannelDefinition(kind: $0) })
        let def = FixtureDefinition(id: "test.rgbw", manufacturer: "Test", model: "RGBW", category: .par, modes: [mode])
        let plain = PatchedFixture(name: "A", definitionID: def.id, modeName: mode.name, universe: 1, address: 1)
        var pinned = PatchedFixture(name: "B", definitionID: def.id, modeName: mode.name, universe: 1, address: 10)
        pinned.calibration.mixingMode = .accurate
        let project = Project(fixtures: [plain, pinned], definitions: [def], colorMixingMode: .direct)
        let resolved = project.resolvedFixtures()
        XCTAssertEqual(resolved.map(\.mixingMode), [.direct, .accurate])
        let pink = FixtureState(intensity: 1, color: .rgb(RGB(hex: "#FF00AA")!))
        XCTAssertEqual(FixtureRenderer.render(pink, fixture: resolved[0]), [255, 255, 0, 170, 0])
        XCTAssertEqual(Project(fixtures: [plain], definitions: [def]).resolvedFixtures().first?.mixingMode, .accurate)

        // Project round trip keeps the default; Accurate (the default) isn't written.
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(back.colorMixingMode, .direct)
        XCTAssertEqual(back.fixtures.map(\.calibration.mixingMode), [nil, .accurate])
        let plainJSON = String(decoding: try JSONEncoder().encode(Project()), as: UTF8.self)
        XCTAssertFalse(plainJSON.contains("colorMixingMode"))

        // Calibration: legacy `accurateColor` files and round trips.
        func decode(_ json: String) throws -> ColorCalibration {
            try JSONDecoder().decode(ColorCalibration.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"gamma":1,"gains":{},"accurateColor":false}"#).mixingMode, .direct)
        XCTAssertNil(try decode(#"{"gamma":1,"gains":{},"accurateColor":true}"#).mixingMode)
        XCTAssertNil(try decode("{}").mixingMode)
        XCTAssertEqual(try decode(#"{"mixingMode":"direct"}"#).mixingMode, .direct)
        XCTAssertNil(try decode(#"{"mixingMode":"sparkly"}"#).mixingMode)
        let direct = ColorCalibration(mixingMode: .direct)
        let data = try JSONEncoder().encode(direct)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""accurateColor":false"#))
        XCTAssertEqual(try JSONDecoder().decode(ColorCalibration.self, from: data), direct)
        XCTAssertFalse(direct.accurateColor)
        XCTAssertEqual(ColorCalibration(accurateColor: true).mixingMode, .accurate)
        XCTAssertNil(ColorCalibration().mixingMode)
        XCTAssertTrue(ColorCalibration().accurateColor)
    }

    // MARK: - Emitter specs and topologies

    func testDefinitionEmitterSpecsStayAccurate() throws {
        var specs: [ChannelKind: EmitterSpec] = [:]
        for kind in [ChannelKind.red, .green, .blue, .white] {
            specs[kind] = try XCTUnwrap(EmitterSpec.standard(for: kind))
        }
        let rgbw: Set<ChannelKind> = [.red, .green, .blue, .white]
        let targets: [LightColor] = [
            .kelvin(2700), .kelvin(4300, tint: -0.15), .kelvin(5600), .kelvin(6500, tint: 0.1),
            .rgb(RGB(hex: "#FFB0A0")!), .rgb(RGB(hex: "#D6B8FF")!), .rgb(RGB(hex: "#A6DCFF")!), .rgb(RGB(hex: "#C8E6C9")!)
        ]
        for target in targets {
            XCTAssertLessThanOrEqual(ColorAnalysis.of(target).saturation, 0.5, "precondition: \(target.label) is a pastel")
            let levels = EmitterMixer.mix(target, emitters: rgbw, emitterSpecs: specs)
            let de = EmitterMixer.deltaE2000(target: target, levels: levels, emitterSpecs: specs)
            XCTAssertLessThan(de, 2, "ΔE2000 \(de) for \(target.label)")
            XCTAssertGreaterThan(levels[.white] ?? 0, 0.15, "the white LED should carry \(target.label)")
            XCTAssertTrue(levels.values.allSatisfy { $0 >= 0 && $0 <= 1 })
        }
        let red = EmitterMixer.mix(.rgb(RGB(hex: "#FF0000")!), emitters: rgbw, emitterSpecs: specs)
        XCTAssertEqual(red[.red] ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(red[.green] ?? 1, 0, accuracy: 1e-9)
        XCTAssertEqual(red[.blue] ?? 1, 0, accuracy: 1e-9)
        XCTAssertEqual(red[.white] ?? 1, 0, accuracy: 1e-9)
        XCTAssertTrue(MixerProfile.profile(for: specs) === MixerProfile.profile(for: specs), "profiles are cached")
        XCTAssertTrue(MixerProfile.profile(for: nil) === MixerProfile.standard)

        // Per-channel `emitter` overrides are honoured by the renderer.
        let channels = [ChannelDefinition(kind: .intensity)] + [ChannelKind.red, .green, .blue, .white].map {
            ChannelDefinition(kind: $0, emitter: specs[$0])
        }
        let rf = fixture("specs", channels)
        let expected = EmitterMixer.mix(.kelvin(4300), emitters: rgbw, emitterSpecs: specs)
        let dmx = FixtureRenderer.render(FixtureState(intensity: 1, color: .kelvin(4300)), fixture: rf)
        XCTAssertEqual(dmx[4], UInt8(((expected[.white] ?? 0) * 255).rounded()))
        XCTAssertEqual(dmx[1], UInt8(((expected[.red] ?? 0) * 255).rounded()))
    }

    func testNonRGBTopologies() {
        // CMY flags: pastels stay pastel (no re-normalisation).
        let cmy = EmitterMixer.mix(.rgb(RGB(hex: "#FFC0CB")!), emitters: [.cyan, .magenta, .yellow])
        XCTAssertEqual(cmy[.cyan] ?? 1, 0, accuracy: 1e-9)
        XCTAssertLessThan(cmy[.magenta] ?? 1, 0.5)
        XCTAssertLessThan(cmy[.yellow] ?? 1, 0.5)

        // Bi-colour: mired blend between the warm and cool whites.
        let bi: Set<ChannelKind> = [.warmWhite, .coolWhite]
        XCTAssertEqual(EmitterMixer.mix(.kelvin(2700), emitters: bi), [.warmWhite: 1, .coolWhite: 0])
        XCTAssertEqual(EmitterMixer.mix(.kelvin(6500), emitters: bi), [.warmWhite: 0, .coolWhite: 1])
        XCTAssertEqual(EmitterMixer.mix(.kelvin(1800), emitters: bi), [.warmWhite: 1, .coolWhite: 0])
        let mid = EmitterMixer.mix(.kelvin(1e6 / ((1e6 / 2700 + 1e6 / 6500) / 2)), emitters: bi)
        XCTAssertEqual(mid[.warmWhite] ?? 0, 1, accuracy: 1e-6)
        XCTAssertEqual(mid[.coolWhite] ?? 0, 1, accuracy: 1e-6)
        var lastWW = 1.0
        for k in stride(from: 2700.0, through: 6500, by: 100) {
            let ww = EmitterMixer.mix(.kelvin(k), emitters: bi)[.warmWhite] ?? 0
            XCTAssertLessThanOrEqual(ww, lastWW + 1e-9)
            lastWW = ww
        }
        let warmRGB = EmitterMixer.mix(.rgb(RGB(hex: "#FFB46B")!), emitters: bi) // ≈ 3000 K
        XCTAssertGreaterThan(warmRGB[.warmWhite] ?? 0, warmRGB[.coolWhite] ?? 1)
        XCTAssertEqual(EmitterMixer.mix(.kelvin(5600), emitters: [.warmWhite, .white, .coolWhite])[.white] ?? 0, 1, accuracy: 1e-9)

        // No RGB, no whites: NNLS; targets outside the gamut fall back to the closest emitter.
        let alc = EmitterMixer.mix(.kelvin(4000), emitters: [.amber, .lime, .cyan])
        XCTAssertEqual(alc.values.max() ?? 0, 1, accuracy: 1e-9)
        XCTAssertTrue(alc.values.allSatisfy { $0 >= 0 })
        XCTAssertEqual(EmitterMixer.mix(.rgb(RGB(hex: "#0000FF")!), emitters: [.amber, .lime])[.lime] ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(EmitterMixer.mix(.rgb(RGB(hex: "#123456")!), emitters: [.amber])[.amber], 1)
        XCTAssertEqual(EmitterMixer.mix(.rgb(.black), emitters: [.red, .green, .blue, .white]).values.max(), 0)
    }

    func testHSIAndXYNativeChannels() {
        let hsi = fixture("hsi", [ChannelDefinition(kind: .intensity), ChannelDefinition(kind: .hue), ChannelDefinition(kind: .saturation)])
        XCTAssertEqual(FixtureRenderer.render(FixtureState(intensity: 1, color: .hsi(hue: 200, saturation: 0.8)), fixture: hsi),
                       [255, 142, 204])
        let xy = fixture("xy", [
            ChannelDefinition(kind: .intensity),
            ChannelDefinition(kind: .cieX, physical: PhysicalRange(from: 0, to: 0.8)),
            ChannelDefinition(kind: .cieY, physical: PhysicalRange(from: 0, to: 0.8))
        ])
        XCTAssertEqual(FixtureRenderer.render(FixtureState(intensity: 1, color: .xy(x: 0.3, y: 0.4)), fixture: xy), [255, 96, 128])
    }

    // MARK: - Renderer

    func testRenderIntoBufferMatchesArrayAndToleratesShortBuffers() {
        let tube = pt4c(pixels: 4)
        let state = FixtureState(intensity: 0.7, color: .white, cells: [
            CellState(intensity: 1, color: .rgb(RGB(hex: "#00C2A8")!)),
            CellState(intensity: 0.5, color: .kelvin(3200)),
            CellState(intensity: 1, color: .kelvin(3200)),
            CellState(intensity: 0.2, color: .rgb(RGB(hex: "#FF2FB4")!))
        ])
        let expected = FixtureRenderer.render(state, fixture: tube)
        XCTAssertEqual(expected.count, 28)
        var buffer = [UInt8](repeating: 7, count: 40)
        let written = buffer.withUnsafeMutableBufferPointer { FixtureRenderer.render(state, fixture: tube, into: $0) }
        XCTAssertEqual(written, 28)
        XCTAssertEqual(Array(buffer[0..<28]), expected)
        XCTAssertEqual(buffer[28], 7, "must not write past the fixture")
        var short = [UInt8](repeating: 0, count: 10)
        let n = short.withUnsafeMutableBufferPointer { FixtureRenderer.render(state, fixture: tube, into: $0) }
        XCTAssertEqual(n, 10)
        XCTAssertEqual(short, Array(expected[0..<10]))
        // Identical neighbouring cells share one solve but keep their own intensity.
        XCTAssertEqual(Array(expected[8..<14]), Array(expected[15..<21]))
        XCTAssertLessThan(expected[7], expected[14])
        // A uniform colour renders exactly like the same colour on every cell.
        let uniform = FixtureRenderer.render(FixtureState(intensity: 1, color: .kelvin(4300)), fixture: tube)
        let perCell = FixtureRenderer.render(
            FixtureState(intensity: 1, color: .white, cells: Array(repeating: CellState(intensity: 1, color: .kelvin(4300)), count: 4)),
            fixture: tube
        )
        XCTAssertEqual(uniform, perCell)
    }
}
