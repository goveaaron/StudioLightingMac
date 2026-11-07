import XCTest
@testable import PrismCore

final class ColorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FixtureRenderer.resetHysteresisState()
    }

    // MARK: - 1. Hex, CSS rgb(), and Color Space Round-Trips

    func testHexAndCSSRoundTrip() throws {
        let c = try XCTUnwrap(RGB(hex: "#1FA2FF"))
        XCTAssertEqual(c.hex, "#1FA2FF")
        XCTAssertEqual(RGB(hex: "1fa2ff")?.hex, "#1FA2FF")
        XCTAssertEqual(RGB(hex: "#FFF")?.hex, "#FFFFFF")
        XCTAssertEqual(RGB(hex: "#1FA2FF80")?.hex, "#1FA2FF")
        XCTAssertEqual(RGB(hex: "rgb(31, 162, 255)")?.hex, "#1FA2FF")
        XCTAssertEqual(RGB(hex: "rgba(31, 162, 255, 0.8)")?.hex, "#1FA2FF")
        XCTAssertEqual(RGB(hex: "rgb(100%, 0%, 50%)")?.hex, "#FF0080")
        XCTAssertNil(RGB(hex: "#12"))
        XCTAssertNil(RGB(hex: "zzzzzz"))
    }

    func testColorSpaceRoundTrips() throws {
        let testHexes = [
            "#FF0000", "#00FF00", "#0000FF", "#FFFFFF", "#808080",
            "#00C2A8", "#FF2FB4", "#14D8F0", "#FF7A1A", "#4A00D1", "#D6B8FF"
        ]
        for hex in testHexes {
            let rgb = try XCTUnwrap(RGB(hex: hex))

            // sRGB <-> LinearRGB
            let linear = rgb.linear
            let backFromLinear = RGB(linear: linear)
            XCTAssertEqual(backFromLinear.r, rgb.r, accuracy: 1e-6, "Linear round-trip R for \(hex)")
            XCTAssertEqual(backFromLinear.g, rgb.g, accuracy: 1e-6, "Linear round-trip G for \(hex)")
            XCTAssertEqual(backFromLinear.b, rgb.b, accuracy: 1e-6, "Linear round-trip B for \(hex)")

            // sRGB <-> HSB
            let hsb = rgb.hsb
            let backFromHSB = RGB(hue: hsb.h, saturation: hsb.s, brightness: hsb.b)
            XCTAssertEqual(backFromHSB.r, rgb.r, accuracy: 1e-6, "HSB round-trip R for \(hex)")
            XCTAssertEqual(backFromHSB.g, rgb.g, accuracy: 1e-6, "HSB round-trip G for \(hex)")
            XCTAssertEqual(backFromHSB.b, rgb.b, accuracy: 1e-6, "HSB round-trip B for \(hex)")

            // sRGB <-> HSL
            let hsl = rgb.hsl
            let backFromHSL = RGB(hue: hsl.h, saturation: hsl.s, lightness: hsl.l)
            XCTAssertEqual(backFromHSL.r, rgb.r, accuracy: 1e-6, "HSL round-trip R for \(hex)")
            XCTAssertEqual(backFromHSL.g, rgb.g, accuracy: 1e-6, "HSL round-trip G for \(hex)")
            XCTAssertEqual(backFromHSL.b, rgb.b, accuracy: 1e-6, "HSL round-trip B for \(hex)")

            // LinearRGB <-> XYZ <-> xyY
            let xyz = ColorMath.linearSRGBToXYZ(linear)
            let backLinearXYZ = ColorMath.xyzToLinearSRGBUnclamped(X: xyz.X, Y: xyz.Y, Z: xyz.Z)
            XCTAssertEqual(backLinearXYZ.r, linear.r, accuracy: 1e-4, "XYZ round-trip R for \(hex)")
            XCTAssertEqual(backLinearXYZ.g, linear.g, accuracy: 1e-4, "XYZ round-trip G for \(hex)")
            XCTAssertEqual(backLinearXYZ.b, linear.b, accuracy: 1e-4, "XYZ round-trip B for \(hex)")

            let xyY = ColorMath.xyzToXYY(X: xyz.X, Y: xyz.Y, Z: xyz.Z)
            let backXYZ = ColorMath.xyYToXYZ(x: xyY.x, y: xyY.y, Y: xyY.Y)
            XCTAssertEqual(backXYZ.X, xyz.X, accuracy: 1e-5, "xyY round-trip X for \(hex)")
            XCTAssertEqual(backXYZ.Y, xyz.Y, accuracy: 1e-5, "xyY round-trip Y for \(hex)")
            XCTAssertEqual(backXYZ.Z, xyz.Z, accuracy: 1e-5, "xyY round-trip Z for \(hex)")

            // sRGB <-> OKLab <-> OKLCh
            let lab = ColorMath.rgbToOKLab(rgb)
            let lch = ColorMath.okLabToOKLCh(L: lab.L, a: lab.a, b: lab.b)
            let backLab = ColorMath.okLChToOKLab(L: lch.L, C: lch.C, h: lch.h)
            XCTAssertEqual(backLab.L, lab.L, accuracy: 1e-6)
            XCTAssertEqual(backLab.a, lab.a, accuracy: 1e-6)
            XCTAssertEqual(backLab.b, lab.b, accuracy: 1e-6)

            let backRGB = ColorMath.okLChToRGB(L: lch.L, C: lch.C, h: lch.h)
            XCTAssertEqual(backRGB.r, rgb.r, accuracy: 1e-4, "OKLCh round-trip R for \(hex)")
            XCTAssertEqual(backRGB.g, rgb.g, accuracy: 1e-4, "OKLCh round-trip G for \(hex)")
            XCTAssertEqual(backRGB.b, rgb.b, accuracy: 1e-4, "OKLCh round-trip B for \(hex)")
        }
    }

    // MARK: - 2. Kelvin + Tint <-> xy Accuracy (1700–20000 K within 20 K and 0.002 Duv)

    func testKelvinRoundTrip() {
        let kelvins: [Double] = [
            1700, 1850, 2000, 2200, 2222, 2500, 2700, 3000, 3200, 3500,
            3999, 4000, 4001, 4300, 5000, 5600, 6000, 6500, 7500, 8000,
            10000, 12000, 15000, 18000, 20000
        ]
        for k in kelvins {
            let xy = ColorMath.kelvinToXY(k, tint: 0)
            let result = ColorMath.xyToKelvinAndDuv(x: xy.x, y: xy.y)
            XCTAssertEqual(result.kelvin, k, accuracy: 20.0, "Neutral CCT round-trip > 20K at \(k)K (got \(result.kelvin))")
            XCTAssertEqual(result.duv, 0.0, accuracy: 0.002, "Neutral Duv round-trip > 0.002 at \(k)K (got \(result.duv))")

            for tint in [-0.8, -0.4, -0.15, 0.2, 0.5, 0.8] {
                let expectedDuv = ColorMath.tintToDuv(tint)
                let txy = ColorMath.kelvinToXY(k, tint: tint)
                let rDuv = ColorMath.xyToKelvinAndDuv(x: txy.x, y: txy.y)
                let rTint = ColorMath.xyToKelvinAndTint(x: txy.x, y: txy.y)
                XCTAssertEqual(rDuv.duv, expectedDuv, accuracy: 0.002, "Duv round-trip failed for \(k)K tint \(tint)")
                XCTAssertEqual(rTint.tint, tint, accuracy: 0.04, "Tint round-trip failed for \(k)K tint \(tint)")
                if k <= 12000 || abs(tint) <= 0.4 {
                    XCTAssertEqual(rDuv.kelvin, k, accuracy: 20.0, "Tinted CCT round-trip > 20K for \(k)K tint \(tint) (got \(rDuv.kelvin))")
                }
            }
        }
    }

    func testSidusAndAputureTintConventions() {
        XCTAssertEqual(ColorMath.tintToSidusGM(-1.0), 1.0, accuracy: 1e-6)
        XCTAssertEqual(ColorMath.tintToSidusGM(1.0), -1.0, accuracy: 1e-6)
        XCTAssertEqual(ColorMath.sidusGMToTint(1.0), -1.0, accuracy: 1e-6)
        XCTAssertEqual(ColorMath.tintToAputureDMX(0.0), 128)
        XCTAssertEqual(ColorMath.tintToAputureDMX(-1.0), 250) // Full Plus Green (245–255)
        XCTAssertEqual(ColorMath.tintToAputureDMX(1.0), 15)   // Full Minus Green (11–20)
        XCTAssertEqual(ColorMath.aputureDMXToTint(128), 0.0, accuracy: 1e-6)
        XCTAssertEqual(ColorMath.aputureDMXToTint(255), -1.0, accuracy: 1e-6)
        XCTAssertEqual(ColorMath.aputureDMXToTint(15), 1.0, accuracy: 1e-6)
    }

    // MARK: - 3. Gamut Mapping & Delta-E

    func testGamutMappingPreservesHueAndLightness() {
        let L = 0.72
        let C = 0.42
        let h = 145.0
        let mapped = ColorMath.gamutMapOKLCh(L: L, C: C, h: h)
        XCTAssertTrue(ColorMath.inSRGBGamut(mapped, tolerance: 1e-4))
        let mappedLCh = ColorMath.linearToOKLCh(mapped)
        XCTAssertEqual(mappedLCh.L, L, accuracy: 0.01)
        XCTAssertEqual(mappedLCh.h, h, accuracy: 1.5)
        XCTAssertLessThan(mappedLCh.C, C)
        XCTAssertGreaterThan(mappedLCh.C, 0.1)
    }

    func testDeltaE2000AndOKLab() {
        let teal = RGB(hex: "#00C2A8")!
        XCTAssertEqual(ColorMath.deltaE2000(teal, teal), 0.0, accuracy: 1e-9)
        XCTAssertEqual(ColorMath.deltaEOKLab(teal, teal), 0.0, accuracy: 1e-9)

        let nearTeal = RGB(r: teal.r, g: teal.g - 0.01, b: teal.b + 0.01)
        let de = ColorMath.deltaE2000(teal, nearTeal)
        XCTAssertGreaterThan(de, 0.1)
        XCTAssertLessThan(de, 2.0)

        let red = RGB(hex: "#FF0000")!
        XCTAssertGreaterThan(ColorMath.deltaE2000(teal, red), 40.0)
    }

    // MARK: - 4. GelLibrary (~200+ LEE & Rosco Gels)

    func testGelLibraryCoverageAndQueries() throws {
        XCTAssertGreaterThanOrEqual(GelLibrary.all.count, 200, "Expected at least 200 gels in GelLibrary")
        XCTAssertFalse(GelLibrary.lee.isEmpty)
        XCTAssertFalse(GelLibrary.rosco.isEmpty)
        XCTAssertGreaterThanOrEqual(GelLibrary.cto.count, 10)
        XCTAssertGreaterThanOrEqual(GelLibrary.ctb.count, 10)
        XCTAssertGreaterThanOrEqual(GelLibrary.plusMinusGreen.count, 12)

        let r02 = try XCTUnwrap(GelLibrary.gel("R02"))
        XCTAssertTrue(r02.name.localizedCaseInsensitiveContains("Bastard Amber"))
        XCTAssertEqual(GelLibrary.gel("Bastard Amber")?.id, r02.id)

        let l201 = try XCTUnwrap(GelLibrary.gel("L201"))
        XCTAssertEqual(l201.category, .ctb)
        let l204 = try XCTUnwrap(GelLibrary.gel("L204"))
        XCTAssertEqual(l204.category, .cto)
        if case .kelvin(let shiftedK, _) = l204.color(baseKelvin: 5600) {
            XCTAssertEqual(shiftedK, 3200, accuracy: 150)
        } else {
            XCTFail("Expected CTO gel to return .kelvin color")
        }

        let congo = try XCTUnwrap(GelLibrary.gel("Congo Blue"))
        XCTAssertGreaterThan(congo.rgb.b, 0.5)

        let steel = try XCTUnwrap(GelLibrary.gel("Steel Blue"))
        XCTAssertGreaterThan(steel.transmission, 0.2)

        let surprisePink = try XCTUnwrap(GelLibrary.gel("Surprise Pink"))
        XCTAssertFalse(surprisePink.name.isEmpty)

        let plusGreen = try XCTUnwrap(GelLibrary.gel("Full Plus Green"))
        if case .kelvin(_, let tint) = plusGreen.color(baseKelvin: 5600) {
            XCTAssertLessThan(tint, -0.5, "Plus Green should produce negative Prism tint (+Duv)")
        } else {
            XCTFail("Expected Plus Green gel to return .kelvin with tint")
        }
    }

    // MARK: - 5. NamedColors & Real-Source Presets

    func testNamedColorsAndRealSources() throws {
        let queries = [
            "teal", "magenta", "warm white", "tungsten", "daylight",
            "moonlight", "golden hour", "sodium vapor", "mercury vapor",
            "cool-white fluorescent", "candle", "hmi", "overcast", "shade"
        ]
        for q in queries {
            XCTAssertNotNil(NamedColors.resolve(q), "Failed to resolve named color '\(q)'")
        }

        XCTAssertEqual(NamedColors.resolve("teal")?.hex, "#00C2A8")

        if case .kelvin(let k, _) = try XCTUnwrap(NamedColors.resolve("tungsten")) {
            XCTAssertEqual(k, 3200, accuracy: 1)
        } else {
            XCTFail("Expected tungsten to resolve to .kelvin(3200)")
        }

        let fl = try XCTUnwrap(NamedColors.sourcePreset(named: "cool-white fluorescent"))
        XCTAssertLessThan(fl.tint, -0.2)
        XCTAssertGreaterThan(fl.duv, 0.005)
    }

    // MARK: - 6. EmitterMixer: ΔE2000 < 2 Across RGBW, RGBWW, RGBA, RGBACL, RGB+Lime

    func testEmitterMixerDeltaE2000AndBroadbandPreference() throws {
        let emitterSets: [(name: String, emitters: Set<ChannelKind>)] = [
            ("RGB", [.red, .green, .blue]),
            ("RGBW", [.red, .green, .blue, .white]),
            ("RGBA", [.red, .green, .blue, .amber]),
            ("RGBWW", [.red, .green, .blue, .warmWhite, .coolWhite]),
            ("RGBACL", [.red, .green, .blue, .amber, .cyan, .lime]),
            ("RGB+Lime", [.red, .green, .blue, .lime])
        ]

        let targetColors: [LightColor] = [
            .kelvin(2700, tint: 0),
            .kelvin(3200, tint: 0),
            .kelvin(4300, tint: -0.15),
            .kelvin(5600, tint: 0),
            .kelvin(6500, tint: 0.1),
            .rgb(RGB(hex: "#00C2A8")!), // Teal
            .rgb(RGB(hex: "#FF2FB4")!), // Pink
            .rgb(RGB(hex: "#FF7A1A")!), // Amber Orange
            .rgb(RGB(hex: "#FF8C7A")!), // Salmon pastel
            .rgb(RGB(hex: "#D6B8FF")!), // Lavender pastel
            .rgb(RGB(hex: "#A6DCFF")!), // Steel blue pastel
            .rgb(RGB(hex: "#B8FF1F")!), // Lime green
            .rgb(RGB(hex: "#FF0000")!), // Pure Red
            .rgb(RGB(hex: "#00FF00")!), // Pure Green
            .rgb(RGB(hex: "#0000FF")!)  // Pure Blue
        ]

        for (familyName, emitters) in emitterSets {
            for target in targetColors {
                let levels = EmitterMixer.mix(target, emitters: emitters, calibration: .default)
                let de = EmitterMixer.deltaE2000(target: target, levels: levels)
                XCTAssertLessThan(
                    de,
                    2.0,
                    "ΔE2000 (\(de)) >= 2.0 on \(familyName) for target \(target.label)"
                )
            }
        }

        // Verify broadband preference:
        // 1. RGBW on 5600K white strongly prefers the .white emitter
        let rgbw5600 = EmitterMixer.mix(.kelvin(5600), emitters: [.red, .green, .blue, .white])
        XCTAssertGreaterThan(rgbw5600[.white] ?? 0, 0.90, "RGBW should strongly prefer W on 5600K")

        // 2. RGBWW on 2700K warm white prefers .warmWhite; on 6500K cool white prefers .coolWhite
        let rgbww2700 = EmitterMixer.mix(.kelvin(2700), emitters: [.red, .green, .blue, .warmWhite, .coolWhite])
        XCTAssertGreaterThan(rgbww2700[.warmWhite] ?? 0, 0.85, "RGBWW should prefer WW at 2700K")
        let rgbww6500 = EmitterMixer.mix(.kelvin(6500), emitters: [.red, .green, .blue, .warmWhite, .coolWhite])
        XCTAssertGreaterThan(rgbww6500[.coolWhite] ?? 0, 0.85, "RGBWW should prefer CW at 6500K")

        // 3. RGBA on warm amber/salmon engages .amber
        let rgbaAmber = EmitterMixer.mix(.rgb(RGB(hex: "#FF7A1A")!), emitters: [.red, .green, .blue, .amber])
        XCTAssertGreaterThan(rgbaAmber[.amber] ?? 0, 0.40, "RGBA should engage amber on warm orange")

        // 4. RGB+Lime on yellow-green / white engages .lime
        let rgblWhite = EmitterMixer.mix(.kelvin(5600), emitters: [.red, .green, .blue, .lime])
        XCTAssertGreaterThan(rgblWhite[.lime] ?? 0, 0.40, "RGB+Lime should engage lime on white")
    }

    func testEmitterMixerDirectModeAndNativeWhiteHysteresis() {
        // Direct mode: #FF00AA goes straight to R/G/B channels without white extraction
        let directCal = ColorCalibration(accurateColor: false)
        let hexColor = LightColor.rgb(RGB(hex: "#FF00AA")!)
        let levels = EmitterMixer.mix(
            hexColor,
            emitters: [.red, .green, .blue, .white],
            calibration: directCal
        )
        XCTAssertEqual(levels[.red] ?? 0, 1.0, accuracy: 1e-6)
        XCTAssertEqual(levels[.green] ?? 0, 0.0, accuracy: 1e-6)
        XCTAssertEqual(levels[.blue] ?? 0, 170.0 / 255.0, accuracy: 1e-6)
        XCTAssertEqual(levels[.white] ?? 0, 0.0, accuracy: 1e-6)

        // Native white hysteresis:
        // A slightly tinted RGB color with |Duv| = 0.010 (inside [0.006, 0.016] hysteresis deadband)
        // stays false when previouslyNativeWhite == false, and stays true when previouslyNativeWhite == true!
        let mode = FixtureMode(
            name: "CCT&RGB",
            channels: [
                ChannelDefinition(kind: .intensity),
                ChannelDefinition(kind: .cct, physical: PhysicalRange(from: 2700, to: 10000)),
                ChannelDefinition(kind: .tint, defaultValue: 128),
                ChannelDefinition(kind: .crossfade),
                ChannelDefinition(kind: .red),
                ChannelDefinition(kind: .green),
                ChannelDefinition(kind: .blue)
            ]
        )
        let caps = mode.capabilities
        let borderXY = ColorMath.kelvinToXY(4500, tint: 0.5) // |Duv| = 0.5 * 0.02 = 0.010
        let borderColor = LightColor.xy(x: borderXY.x, y: borderXY.y)

        XCTAssertFalse(
            EmitterMixer.shouldUseNativeWhite(
                for: borderColor,
                capabilities: caps,
                cctRange: 2700...10000,
                previouslyNativeWhite: false
            ),
            "Should not enter native white when |Duv| = 0.010 > 0.006"
        )
        XCTAssertTrue(
            EmitterMixer.shouldUseNativeWhite(
                for: borderColor,
                capabilities: caps,
                cctRange: 2700...10000,
                previouslyNativeWhite: true
            ),
            "Should remain in native white when |Duv| = 0.010 <= 0.016 (hysteresis)"
        )
    }

    // MARK: - 7. Perceptual Fades (Red -> Cyan OKLab Midpoint, Mired White, Perceptual Intensity)

    func testPerceptualFadesRedToCyanAndMiredAndIntensity() {
        // 1. Red -> Cyan fade midpoint has OKLCh chroma C > 0.1 (no grey dip)
        let redState = FixtureState(intensity: 0.0, color: .rgb(RGB(hex: "#FF0000")!))
        let cyanState = FixtureState(intensity: 1.0, color: .rgb(RGB(hex: "#00FFFF")!))
        let midState = FixtureState.mix(redState, cyanState, 0.5)

        let midLCh = midState.color.okLCh
        XCTAssertGreaterThan(midLCh.C, 0.1, "Red -> Cyan midpoint must stay saturated (C = \(midLCh.C) > 0.1), not grey")

        // 2. Perceptual intensity fade: 0 -> 1 at t = 0.5 has 50% CIE L* perceptual brightness (~0.184 linear)
        XCTAssertLessThan(midState.intensity, 0.35, "Perceptual intensity midpoint should be < 0.35 linear (50% perceived brightness)")
        XCTAssertGreaterThan(midState.intensity, 0.10)
        XCTAssertEqual(ColorMath.linearToPerceptualIntensity(midState.intensity), 0.5, accuracy: 1e-4)

        // 3. White-to-white fades interpolate in mireds (1e6 / K), not linear Kelvin
        let wWarm = LightColor.kelvin(2500, tint: -0.2) // 400 mired
        let wCool = LightColor.kelvin(10000, tint: 0.4) // 100 mired
        let wMid = LightColor.mix(wWarm, wCool, 0.5)    // 250 mired = 4000 K (not 6250 K!)
        if case .kelvin(let k, let tint) = wMid {
            XCTAssertEqual(k, 4000.0, accuracy: 1.0, "Mired midpoint of 2500K and 10000K must be 4000K")
            XCTAssertEqual(tint, 0.1, accuracy: 1e-6)
        } else {
            XCTFail("Expected .kelvin from white-to-white fade")
        }

        // 4. Pixel arrays interpolate cell-by-cell
        let pA = FixtureState(
            intensity: 1.0,
            color: .white,
            cells: [
                CellState(intensity: 0.0, color: .rgb(RGB(hex: "#FF0000")!)),
                CellState(intensity: 1.0, color: .kelvin(2500))
            ]
        )
        let pB = FixtureState(
            intensity: 1.0,
            color: .white,
            cells: [
                CellState(intensity: 1.0, color: .rgb(RGB(hex: "#00FFFF")!)),
                CellState(intensity: 1.0, color: .kelvin(10000))
            ]
        )
        let pMid = FixtureState.mix(pA, pB, 0.5)
        XCTAssertEqual(pMid.cells?.count, 2)
        XCTAssertGreaterThan(pMid.cells?[0].color.okLCh.C ?? 0, 0.1)
        if case .kelvin(let cellK, _) = pMid.cells?[1].color {
            XCTAssertEqual(cellK, 4000.0, accuracy: 1.0)
        } else {
            XCTFail("Expected cell 1 to interpolate in mireds")
        }
    }

    // MARK: - 8. PT4c Pixel Mode Golden DMX Values & FixtureRenderer Features

    private func makePT4cPixelFixture(pixels: Int = 8) -> ResolvedFixture {
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
        let mode = FixtureMode(
            name: "Light Engine CCT & RGB \(pixels) Pixels",
            shortName: "LE \(pixels)px",
            recommended: true,
            channels: channels
        )
        let def = FixtureDefinition(
            id: "amaran.pt4c",
            manufacturer: "amaran",
            model: "PT4c",
            category: .tube,
            cctRange: [2700, 10000],
            modes: [mode]
        )
        let patched = PatchedFixture(
            name: "PT4c",
            shortName: "PT1",
            definitionID: def.id,
            modeName: mode.name,
            universe: 1,
            address: 1
        )
        return ResolvedFixture(fixture: patched, definition: def, mode: mode)
    }

    func testPT4cPixelModeGoldenDMX() {
        let pt4c = makePT4cPixelFixture(pixels: 8)
        XCTAssertEqual(pt4c.channelCount, 56)

        // 1. 3200K warm white @ 50% -> [128, 17, 128, 0, 0, 0, 0] per pixel
        let state3200 = FixtureState(intensity: 0.5, color: .kelvin(3200, tint: 0))
        let dmx3200 = FixtureRenderer.render(state3200, fixture: pt4c)
        XCTAssertEqual(Array(dmx3200[0..<7]), [128, 17, 128, 0, 0, 0, 0])
        XCTAssertEqual(Array(dmx3200[49..<56]), [128, 17, 128, 0, 0, 0, 0])

        // 2. Pure Red (#FF0000) @ 100% -> [255, 0, 128, 255, 255, 0, 0] per pixel
        let stateRed = FixtureState(intensity: 1.0, color: .rgb(RGB(hex: "#FF0000")!))
        let dmxRed = FixtureRenderer.render(stateRed, fixture: pt4c)
        XCTAssertEqual(Array(dmxRed[0..<7]), [255, 0, 128, 255, 255, 0, 0])
        XCTAssertEqual(Array(dmxRed[49..<56]), [255, 0, 128, 255, 255, 0, 0])

        // 3. Studio Teal (#00C2A8) @ 100% -> [255, 0, 128, 255, 0, 255, 185] per pixel
        let stateTeal = FixtureState(intensity: 1.0, color: .rgb(RGB(hex: "#00C2A8")!))
        let dmxTeal = FixtureRenderer.render(stateTeal, fixture: pt4c)
        XCTAssertEqual(Array(dmxTeal[0..<7]), [255, 0, 128, 255, 0, 255, 185])
    }

    func testFixtureRendererDimmerCurves16BitStrobeSafetyAndKeyKeepAlive() {
        let mode = FixtureMode(
            name: "16-bit + Strobe + Effect",
            channels: [
                ChannelDefinition(kind: .intensity),
                ChannelDefinition(kind: .intensity, fine: true),
                ChannelDefinition(kind: .red),
                ChannelDefinition(kind: .green),
                ChannelDefinition(kind: .blue),
                ChannelDefinition(
                    kind: .strobe,
                    capabilities: [
                        ChannelCapability(from: 0, to: 9, label: "Off", tag: "off"),
                        ChannelCapability(from: 10, to: 255, label: "Strobe 1-25 Hz", tag: "strobe", physical: [1, 25])
                    ]
                ),
                ChannelDefinition(kind: .effect, defaultValue: 99)
            ]
        )
        let def = FixtureDefinition(
            id: "test.spot",
            manufacturer: "Test",
            model: "Spot",
            category: .spot,
            modes: [mode]
        )
        var patched = PatchedFixture(
            name: "Key",
            definitionID: def.id,
            modeName: mode.name,
            universe: 1,
            address: 1,
            role: .key,
            limits: FixtureLimits(
                maxIntensity: 1.0,
                minIntensity: 0.0,
                allowEffects: false,
                allowStrobe: true,
                dimmerCurve: .squareLaw,
                neverFullyOffUnlessZero: true
            )
        )
        let rf = ResolvedFixture(fixture: patched, definition: def, mode: mode)

        // 1. At 50% intensity with squareLaw curve: 0.5^2 = 0.25 -> 16-bit 16384 (coarse 64, fine 0)
        // Strobe requested at 20 Hz, but photosensitiveSafe = true caps it to 3 Hz!
        // Effect channel is zeroed regardless of defaultValue: 99.
        let state50 = FixtureState(intensity: 0.5, color: .rgb(.white), strobeHz: 20.0)
        let dmx50 = FixtureRenderer.render(
            state50,
            fixture: rf,
            safety: SafetySettings(maxStrobeHz: 18, photosensitiveSafe: true)
        )
        XCTAssertEqual(dmx50[0], 64, "Square-law 50% coarse MSB should be 64")
        XCTAssertEqual(dmx50[1], 0, "Square-law 50% fine LSB should be 0")

        // Strobe at 3 Hz in [1, 25] Hz -> fraction (3-1)/24 = 2/24 -> 10 + 2/24 * 245 = 30
        XCTAssertEqual(dmx50[5], 30, "Photosensitive mode must cap strobe to <= 3 Hz")
        XCTAssertEqual(dmx50[6], 0, "Effect channel must be zeroed by default")

        // 2. Key light keep-alive (`neverFullyOffUnlessZero = true`):
        // Even at 0.5% intensity (where square-law 0.005^2 = 0.000025 would round to 0 on 8-bit),
        // coarse channel stays >= 1 while intensity > 0, and becomes 0 when intensity == 0.
        let stateTiny = FixtureState(intensity: 0.005, color: .rgb(.white))
        let dmxTiny = FixtureRenderer.render(stateTiny, fixture: rf)
        XCTAssertGreaterThanOrEqual(dmxTiny[0], 1, "Key light with neverFullyOffUnlessZero must not drop to 0 coarse DMX at 0.5%")

        let stateOff = FixtureState(intensity: 0.0, color: .rgb(.white))
        let dmxOff = FixtureRenderer.render(stateOff, fixture: rf)
        XCTAssertEqual(dmxOff[0], 0)
        XCTAssertEqual(dmxOff[1], 0)

        // 3. When allowStrobe = false, strobe channel is forced to Off (0)
        patched.limits.allowStrobe = false
        let rfNoStrobe = ResolvedFixture(fixture: patched, definition: def, mode: mode)
        let dmxNoStrobe = FixtureRenderer.render(state50, fixture: rfNoStrobe)
        XCTAssertEqual(dmxNoStrobe[5], 0)
    }

    // MARK: - 9. Performance: Render 16 Universes in < 1 ms

    func testRender16UniversesPerformance() {
        // Build 16 universes filled with fixtures (16 universes x 10 fixtures = 160 fixtures)
        let mode = FixtureMode(
            name: "RGBW 8ch",
            channels: [
                ChannelDefinition(kind: .intensity),
                ChannelDefinition(kind: .red),
                ChannelDefinition(kind: .green),
                ChannelDefinition(kind: .blue),
                ChannelDefinition(kind: .white),
                ChannelDefinition(kind: .strobe)
            ]
        )
        let def = FixtureDefinition(
            id: "generic.rgbw",
            manufacturer: "Generic",
            model: "RGBW",
            category: .par,
            modes: [mode]
        )

        var fixtures: [ResolvedFixture] = []
        var states: [FixtureState] = []
        let colors: [LightColor] = [
            .rgb(RGB(hex: "#00C2A8")!),
            .rgb(RGB(hex: "#FF2FB4")!),
            .kelvin(3200, tint: 0),
            .kelvin(5600, tint: -0.1),
            .rgb(RGB(hex: "#FF7A1A")!)
        ]

        for u in 1...16 {
            for fIdx in 0..<10 {
                let p = PatchedFixture(
                    name: "U\(u)-\(fIdx)",
                    definitionID: def.id,
                    modeName: mode.name,
                    universe: u,
                    address: 1 + fIdx * 10
                )
                fixtures.append(ResolvedFixture(fixture: p, definition: def, mode: mode))
                states.append(FixtureState(intensity: 0.85, color: colors[(u + fIdx) % colors.count]))
            }
        }

        let safety = SafetySettings()
        // Warmup
        for i in 0..<fixtures.count {
            _ = FixtureRenderer.render(states[i], fixture: fixtures[i], safety: safety)
        }

        // Best of several batches so a noisy shared runner can't fail the build.
        var bestMs = Double.infinity
        for _ in 0..<5 {
            let iterations = 10
            let start = PrismClock.now()
            for _ in 0..<iterations {
                for i in 0..<fixtures.count {
                    _ = FixtureRenderer.render(states[i], fixture: fixtures[i], safety: safety)
                }
            }
            bestMs = min(bestMs, (PrismClock.now() - start) * 1000.0 / Double(iterations))
        }
        // Brief 02 §9: < 1 ms in release builds. Unit tests usually run unoptimised.
        #if DEBUG
        let budgetMs = 10.0
        #else
        let budgetMs = 1.0
        #endif
        XCTAssertLessThan(bestMs, budgetMs, "16-universe render took \(bestMs) ms (expected < \(budgetMs) ms)")
    }

    func testLightColorJSONRoundTrip() throws {
        let colors: [LightColor] = [
            .rgb(RGB(hex: "#00C2B8")!),
            .kelvin(5600, tint: 0.1),
        ]
        for color in colors {
            let data = try JSONEncoder().encode(color)
            let back = try JSONDecoder().decode(LightColor.self, from: data)
            XCTAssertEqual(back.hex, color.hex)
        }
    }

    func testNaNSafety() {
        XCTAssertEqual(clamp01(.nan), 0)
        XCTAssertEqual(clamp01(.infinity), 1)
        XCTAssertEqual(clamp01(-.infinity), 0)
    }
}
