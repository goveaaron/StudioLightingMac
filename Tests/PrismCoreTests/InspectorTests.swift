import XCTest
@testable import PrismCore

/// Portable logic behind the inspector: exact-entry formatting/parsing, the smart colour
/// field, mixed-value aggregation, pixel operations, palette extraction and colour history.
final class InspectorTests: XCTestCase {
    private let nb = InspectorFormat.nbsp

    // MARK: - Percent & DMX

    func testPercentFormatting() {
        XCTAssertEqual(InspectorFormat.percent(0.724), "72.4%")
        XCTAssertEqual(InspectorFormat.percent(1), "100%")
        XCTAssertEqual(InspectorFormat.percent(0), "0%")
        XCTAssertEqual(InspectorFormat.percent(0.5), "50%")
        XCTAssertEqual(InspectorFormat.percent(.nan), "0%")
        XCTAssertEqual(InspectorFormat.percent(0.0006), "0.1%")
        XCTAssertEqual(InspectorFormat.percent(2), "100%")
    }

    func testPercentParsing() {
        XCTAssertEqual(InspectorFormat.parsePercent("72.4") ?? -1, 0.724, accuracy: 1e-9)
        XCTAssertEqual(InspectorFormat.parsePercent("72,4 %") ?? -1, 0.724, accuracy: 1e-9)
        XCTAssertEqual(InspectorFormat.parsePercent("72.4%") ?? -1, 0.724, accuracy: 1e-9)
        XCTAssertEqual(InspectorFormat.parsePercent("full"), 1)
        XCTAssertEqual(InspectorFormat.parsePercent("Half"), 0.5)
        XCTAssertEqual(InspectorFormat.parsePercent("off"), 0)
        XCTAssertEqual(InspectorFormat.parsePercent("184/255") ?? -1, 184.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(InspectorFormat.parsePercent("dmx 255"), 1)
        XCTAssertEqual(InspectorFormat.parsePercent("150"), 1)
        XCTAssertNil(InspectorFormat.parsePercent("abc"))
        XCTAssertNil(InspectorFormat.parsePercent("-5"))
        XCTAssertNil(InspectorFormat.parsePercent(""))
        XCTAssertEqual(InspectorFormat.dmx(0.5), 128)
        XCTAssertEqual(InspectorFormat.dmx(1), 255)
        // Every 0.1% step survives format → parse.
        for tenth in 0...1000 {
            let v = Double(tenth) / 1000
            let back = InspectorFormat.parsePercent(InspectorFormat.percent(v)) ?? -1
            XCTAssertEqual(back, v, accuracy: 1e-9, "\(tenth)")
        }
    }

    // MARK: - Stops

    func testStopsMath() {
        XCTAssertEqual(InspectorFormat.intensity(fromStops: -1), 0.5, accuracy: 1e-12)
        XCTAssertEqual(InspectorFormat.intensity(fromStops: 2), 1)
        XCTAssertEqual(InspectorFormat.stops(fromIntensity: 0.25), -2, accuracy: 1e-12)
        XCTAssertEqual(InspectorFormat.stops(fromIntensity: 0), InspectorFormat.minStops)
        XCTAssertEqual(InspectorFormat.nudge(0.5, stops: 1.0 / 3), 0.5 * pow(2, 1.0 / 3), accuracy: 1e-12)
        XCTAssertEqual(InspectorFormat.nudge(0, stops: 1.0 / 3), 0.01)
        XCTAssertEqual(InspectorFormat.nudge(0, stops: -1.0 / 3), 0)
        XCTAssertEqual(InspectorFormat.nudge(1, stops: 1.0 / 3), 1)
        // Three −⅓ nudges = one stop = half.
        var v = 0.8
        for _ in 0..<3 { v = InspectorFormat.nudge(v, stops: -1.0 / 3) }
        XCTAssertEqual(v, 0.4, accuracy: 1e-12)
    }

    func testStopsText() {
        XCTAssertEqual(InspectorFormat.stopsText(0), "0\(nb)st")
        XCTAssertEqual(InspectorFormat.stopsText(-1), "\u{2212}1\(nb)st")
        XCTAssertEqual(InspectorFormat.stopsText(-4.0 / 3), "\u{2212}1⅓\(nb)st")
        XCTAssertEqual(InspectorFormat.stopsText(1.0 / 3), "+⅓\(nb)st")
        XCTAssertEqual(InspectorFormat.stopsText(-2.0 / 3), "\u{2212}⅔\(nb)st")
        XCTAssertEqual(InspectorFormat.stopsText(-2.4), "\u{2212}2.4\(nb)st")
        XCTAssertEqual(InspectorFormat.stopsLabel(0), "Off")
        XCTAssertEqual(InspectorFormat.stopsLabel(0.5), "\u{2212}1\(nb)st")
    }

    func testStopsParsing() {
        XCTAssertEqual(InspectorFormat.parseStops("-1 1/3") ?? 0, -4.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(InspectorFormat.parseStops("\u{2212}⅔") ?? 0, -2.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(InspectorFormat.parseStops("-2 stops") ?? 0, -2, accuracy: 1e-12)
        XCTAssertEqual(InspectorFormat.parseStops("+⅓") ?? 0, 1.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(InspectorFormat.parseStops("-1.5 st") ?? 0, -1.5, accuracy: 1e-12)
        XCTAssertNil(InspectorFormat.parseStops(""))
        XCTAssertNil(InspectorFormat.parseStops("abc"))
        for third in -30...3 {
            let s = Double(third) / 3
            let back = InspectorFormat.parseStops(InspectorFormat.stopsText(s)) ?? 99
            XCTAssertEqual(back, s, accuracy: 1e-9, "\(third)/3")
        }
    }

    // MARK: - Kelvin & tint

    func testKelvinFormattingAndParsing() {
        XCTAssertEqual(InspectorFormat.kelvin(3200), "3,200\(nb)K")
        XCTAssertEqual(InspectorFormat.kelvin(12000), "12,000\(nb)K")
        XCTAssertEqual(InspectorFormat.kelvin(2700), "2,700\(nb)K")
        XCTAssertEqual(InspectorFormat.kelvinCompact(5600), "5600K")
        XCTAssertEqual(InspectorFormat.parseKelvin("3200"), 3200)
        XCTAssertEqual(InspectorFormat.parseKelvin("3,200 K"), 3200)
        XCTAssertEqual(InspectorFormat.parseKelvin("3.2k"), 3200)
        XCTAssertEqual(InspectorFormat.parseKelvin("5.6"), 5600)
        XCTAssertEqual(InspectorFormat.parseKelvin("4300 kelvin"), 4300)
        XCTAssertEqual(InspectorFormat.parseKelvin(InspectorFormat.kelvin(5600)), 5600)
        XCTAssertNil(InspectorFormat.parseKelvin("999"))
        XCTAssertNil(InspectorFormat.parseKelvin("25000"))
        XCTAssertNil(InspectorFormat.parseKelvin("warm"))
    }

    func testTintFormattingAndParsing() {
        XCTAssertEqual(InspectorFormat.tint(0.12), "12\(nb)M")
        XCTAssertEqual(InspectorFormat.tint(-0.3), "30\(nb)G")
        XCTAssertEqual(InspectorFormat.tint(0), "0")
        XCTAssertEqual(InspectorFormat.parseTint("12m") ?? 9, 0.12, accuracy: 1e-12)
        XCTAssertEqual(InspectorFormat.parseTint("M12") ?? 9, 0.12, accuracy: 1e-12)
        XCTAssertEqual(InspectorFormat.parseTint("+12") ?? 9, 0.12, accuracy: 1e-12)
        XCTAssertEqual(InspectorFormat.parseTint("-30") ?? 9, -0.3, accuracy: 1e-12)
        XCTAssertEqual(InspectorFormat.parseTint("30 g") ?? 9, -0.3, accuracy: 1e-12)
        XCTAssertEqual(InspectorFormat.parseTint("g30") ?? 9, -0.3, accuracy: 1e-12)
        XCTAssertEqual(InspectorFormat.parseTint("neutral"), 0)
        XCTAssertNil(InspectorFormat.parseTint("150"))
        XCTAssertNil(InspectorFormat.parseTint("abc"))
        for step in -100...100 {
            let t = Double(step) / 100
            let back = InspectorFormat.parseTint(InspectorFormat.tint(t)) ?? 9
            XCTAssertEqual(back, t, accuracy: 1e-9, "tint \(step)")
        }
    }

    /// Typing a white into the fields and reading it back gives exactly the same Kelvin and tint.
    func testKelvinTintRoundTripThroughFields() throws {
        for k in [1700.0, 2700, 3200, 4300, 5600, 6500, 10000] {
            for t in [-0.5, -0.1, 0, 0.12, 0.3] {
                let typed = InspectorFormat.kelvinCompact(k) + " " + InspectorFormat.tint(t)
                let match = try XCTUnwrap(ColorInput.parse(typed), typed)
                XCTAssertEqual(match.source, .kelvin)
                let fields = ColorFieldValues(match.color)
                XCTAssertTrue(fields.isKelvinExact)
                XCTAssertEqual(fields.kelvin ?? 0, k, accuracy: 1e-9, typed)
                XCTAssertEqual(fields.tint ?? 9, t, accuracy: 1e-9, typed)
                XCTAssertEqual(InspectorFormat.parseKelvin(InspectorFormat.kelvin(fields.kelvin ?? 0)), k)
            }
        }
    }

    // MARK: - Degrees, bytes, chromaticity

    func testSmallParsers() {
        XCTAssertEqual(InspectorFormat.degrees(186.4), "186°")
        XCTAssertEqual(InspectorFormat.degrees(359.6), "0°")
        XCTAssertEqual(InspectorFormat.parseDegrees("186°"), 186)
        XCTAssertEqual(InspectorFormat.parseDegrees("-10"), 350)
        XCTAssertEqual(InspectorFormat.parseDegrees("370 deg"), 10)
        XCTAssertEqual(InspectorFormat.parseByte("194"), 194)
        XCTAssertEqual(InspectorFormat.parseByte("300"), 255)
        XCTAssertEqual(InspectorFormat.parseByte("-5"), 0)
        XCTAssertNil(InspectorFormat.parseByte("x"))
        XCTAssertEqual(InspectorFormat.chromaticity(0.31271), "0.3127")
        XCTAssertEqual(InspectorFormat.parseChromaticity("0.3127"), 0.3127)
        XCTAssertNil(InspectorFormat.parseChromaticity("1.2"))
        XCTAssertEqual(InspectorFormat.grouped(1234567), "1,234,567")
        XCTAssertEqual(InspectorFormat.grouped(999), "999")
    }

    // MARK: - Smart colour field

    private func assertRGB(_ text: String, _ r: Int, _ g: Int, _ b: Int, source: ColorInput.Source,
                           file: StaticString = #filePath, line: UInt = #line) {
        guard let m = ColorInput.parse(text) else {
            return XCTFail("\(text) did not parse", file: file, line: line)
        }
        XCTAssertEqual(m.source, source, text, file: file, line: line)
        guard case .rgb(let c) = m.color else {
            return XCTFail("\(text) is not RGB: \(m.color)", file: file, line: line)
        }
        XCTAssertEqual([c.r255, c.g255, c.b255], [r, g, b], text, file: file, line: line)
    }

    func testColorInputHexAndTriples() {
        assertRGB("#00C2B8", 0, 194, 184, source: .hex)
        assertRGB("00c2b8", 0, 194, 184, source: .hex)
        assertRGB("  #00c2b8  ", 0, 194, 184, source: .hex)
        assertRGB("rgb(0,194,184)", 0, 194, 184, source: .hex)
        assertRGB("rgb(0, 194, 184)", 0, 194, 184, source: .hex)
        assertRGB("#0CB", 0, 204, 187, source: .hex)
        assertRGB("0x00C2B8", 0, 194, 184, source: .hex)
        assertRGB("#00C2B8FF", 0, 194, 184, source: .hex)
        assertRGB("0, 194, 184", 0, 194, 184, source: .rgbTriple)
        assertRGB("0 194 184", 0, 194, 184, source: .rgbTriple)
        assertRGB("hsl(180, 100%, 50%)", 0, 255, 255, source: .hsl)
        assertRGB("hsb(0, 100%, 100%)", 255, 0, 0, source: .hsb)
        XCTAssertEqual(ColorInput.parse("#00C2B8")?.label, "#00C2B8")
    }

    func testColorInputWhitesAndOthers() throws {
        let k = try XCTUnwrap(ColorInput.parse("3200K"))
        XCTAssertEqual(k.color, .kelvin(3200, tint: 0))
        XCTAssertEqual(k.source, .kelvin)
        XCTAssertEqual(ColorInput.parse("3200")?.color, .kelvin(3200, tint: 0))
        XCTAssertEqual(ColorInput.parse("3,200 K")?.color, .kelvin(3200, tint: 0))
        let tinted = try XCTUnwrap(ColorInput.parse("3200K +10M"))
        guard case .kelvin(let k1, let t1) = tinted.color else { return XCTFail("not kelvin") }
        XCTAssertEqual(k1, 3200)
        XCTAssertEqual(t1, 0.1, accuracy: 1e-12)
        guard case .kelvin(_, let t2) = try XCTUnwrap(ColorInput.parse("5600k 20 g")).color else { return XCTFail("not kelvin") }
        XCTAssertEqual(t2, -0.2, accuracy: 1e-12)

        let gel = try XCTUnwrap(ColorInput.parse("L201"))
        XCTAssertEqual(gel.source, .gel)
        XCTAssertTrue(gel.label.hasPrefix("L201"), gel.label)
        XCTAssertEqual(ColorInput.parse("R02")?.source, .gel)
        XCTAssertEqual(ColorInput.parse("LEE 201")?.label, gel.label)

        XCTAssertEqual(ColorInput.parse("teal")?.source, .named)
        let tungsten = try XCTUnwrap(ColorInput.parse("tungsten"))
        XCTAssertTrue([.named, .lightSource].contains(tungsten.source))
        XCTAssertEqual(ColorFieldValues(tungsten.color).kelvin ?? 0, 3200, accuracy: 150)

        let hsi = try XCTUnwrap(ColorInput.parse("H186° S100%"))
        XCTAssertEqual(hsi.color, .hsi(hue: 186, saturation: 1))
        // Our own labels paste back in.
        XCTAssertEqual(ColorInput.parse(LightColor.hsi(hue: 20, saturation: 0.5).label)?.color, .hsi(hue: 20, saturation: 0.5))
        let xy = try XCTUnwrap(ColorInput.parse("0.3127, 0.3290"))
        XCTAssertEqual(xy.source, .xy)
        XCTAssertEqual(xy.color, .xy(x: 0.3127, y: 0.3290))
        XCTAssertEqual(ColorInput.parse(LightColor.xy(x: 0.45, y: 0.41).label)?.color, .xy(x: 0.45, y: 0.41))
    }

    func testColorInputRejectsGarbage() {
        for junk in ["", "   ", "asdfgh", "#12", "zz", "300, 0, 0", "hsl(1,2)", "hello world", "12345678901",
                     String(repeating: "a", count: 65), "0.5", "-", "#GGGGGG"] {
            XCTAssertNil(ColorInput.parse(junk), "\(junk) should not parse")
        }
    }

    // MARK: - Field values & edits

    func testFieldValuesForExactColor() {
        let teal = ColorFieldValues(.rgb(RGB(r255: 0, g255: 194, b255: 184)))
        XCTAssertEqual(teal.mode, .color)
        XCTAssertEqual(teal.hex, "#00C2B8")
        XCTAssertTrue(teal.isHexExact)
        XCTAssertEqual([teal.red, teal.green, teal.blue], [0, 194, 184])
        XCTAssertNil(teal.kelvin, "a saturated colour has no meaningful Kelvin")
        XCTAssertNil(teal.tint)

        let white = ColorFieldValues(.kelvin(3200, tint: 0.1))
        XCTAssertEqual(white.mode, .white)
        XCTAssertEqual(white.kelvin, 3200)
        XCTAssertEqual(white.tint, 0.1)
        XCTAssertTrue(white.isKelvinExact)
        XCTAssertFalse(white.isHexExact)

        let warmish = ColorFieldValues(.rgb(RGB(r255: 255, g255: 236, b255: 214)))
        XCTAssertNotNil(warmish.kelvin)
        XCTAssertFalse(warmish.isKelvinExact)

        let hsi = ColorFieldValues(.hsi(hue: 200, saturation: 0.5))
        XCTAssertEqual(hsi.hue, 200, accuracy: 1e-9)
        XCTAssertEqual(hsi.saturation, 0.5, accuracy: 1e-9)

        let dark = ColorFieldValues(.rgb(RGB(r255: 0, g255: 122, b255: 115)))
        XCTAssertTrue(dark.isDarkStoredColor)
        XCTAssertEqual(dark.matchingIntensity() ?? 0, ColorMath.srgbToLinear(122.0 / 255), accuracy: 1e-9)
        XCTAssertEqual(dark.matchingIntensity(accurateColor: false) ?? 0, 122.0 / 255, accuracy: 1e-9)
        XCTAssertNil(teal.matchingIntensity())
        XCTAssertEqual(ColorModeKind(.xy(x: 0.3, y: 0.3)), .xy)
    }

    func testColorEdits() {
        let grey = LightColor.rgb(RGB(r255: 128, g255: 128, b255: 128))
        XCTAssertEqual(ColorEdit.hueSaturation(180, 1, from: grey).hex, "#008080")
        XCTAssertEqual(ColorEdit.hueSaturation(180, 1, from: .kelvin(3200)).hex, "#00FFFF")
        XCTAssertEqual(ColorEdit.hueSaturation(0, 1, from: .rgb(.black)).hex, "#FF0000")
        let teal = LightColor.rgb(RGB(r255: 0, g255: 194, b255: 184))
        XCTAssertEqual(ColorEdit.withChannel(.green, 200, from: teal).hex, "#00C8B8")
        XCTAssertEqual(ColorEdit.withChannel(.red, 999, from: teal).hex, "#FFC2B8")
        XCTAssertEqual(ColorEdit.withHue(0, from: grey, saturationIfGrey: 1).hex, "#800000")
        XCTAssertEqual(ColorEdit.withSaturation(0, from: teal).hex, "#C2C2C2")

        XCTAssertEqual(ColorEdit.hueRotated(.rgb(.red), by: 120).hex, "#00FF00")
        XCTAssertEqual(ColorEdit.hueRotated(.kelvin(3200), by: 90), .kelvin(3200))
        XCTAssertEqual(ColorEdit.hueRotated(grey, by: 90), grey)
        XCTAssertEqual(ColorEdit.hueRotated(.hsi(hue: 350, saturation: 1), by: 20), .hsi(hue: 10, saturation: 1))
        var state = FixtureState(intensity: 1, color: .rgb(.red))
        state.cells = [CellState(intensity: 0.5, color: .rgb(.blue)), CellState(intensity: 1, color: .kelvin(3200))]
        let rotated = ColorEdit.hueRotated(state, by: 120)
        XCTAssertEqual(rotated.color.hex, "#00FF00")
        XCTAssertEqual(rotated.cells?[0].color.hex, "#FF0000")
        XCTAssertEqual(rotated.cells?[0].intensity, 0.5)
        XCTAssertEqual(rotated.cells?[1].color, .kelvin(3200))

        XCTAssertEqual(ColorEdit.fullValue(.rgb(RGB(r255: 0, g255: 122, b255: 115))).hex, "#00FFF0")
        XCTAssertEqual(ColorEdit.fullValue(.kelvin(3200)), .kelvin(3200))
    }

    func testFixtureKindsAndKelvinRange() throws {
        let lib = TestResources.library()
        let resolved = DemoRig.londonStudio().resolvedFixtures(library: lib.definition)
        let byID = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, $0) })
        let dimmer = try XCTUnwrap(byID[DemoRig.IDs.p1])
        let tube = try XCTUnwrap(byID[DemoRig.IDs.tube(1)])
        let panel = try XCTUnwrap(byID[DemoRig.IDs.pn1])
        XCTAssertEqual(dimmer.inspectorKind, .dimmerOnly)
        XCTAssertEqual(tube.inspectorKind, .pixel)
        XCTAssertEqual(panel.inspectorKind, .color)
        var limited = panel
        limited.fixture.limits.minKelvin = 3000
        limited.fixture.limits.maxKelvin = 6000
        XCTAssertEqual(limited.inspectorKelvinRange, 3000...6000)
        XCTAssertGreaterThanOrEqual(panel.inspectorKelvinRange.lowerBound, 1000)
        XCTAssertLessThanOrEqual(panel.inspectorKelvinRange.upperBound, 20000)
    }

    // MARK: - Mixed values

    func testMixedNumbers() {
        XCTAssertEqual(MixedNumber([0.5, 0.5]), .uniform(0.5))
        XCTAssertEqual(MixedNumber([0.3, 0.8]), .mixed(min: 0.3, max: 0.8))
        XCTAssertEqual(MixedNumber([Double]()), MixedNumber.none)
        XCTAssertEqual(MixedNumber([.nan]), MixedNumber.none)
        XCTAssertEqual(MixedNumber([0.3, 0.8]).representative ?? 0, 0.55, accuracy: 1e-12)
        XCTAssertEqual(MixedNumber([0.5, 0.5002], tolerance: 0.001).value, 0.5)
        XCTAssertTrue(MixedNumber([1, 2]).isMixed)
        XCTAssertEqual(MixedValue(["a", "a"]), .uniform("a"))
        XCTAssertEqual(MixedValue(["a", "b"]), .mixed)
        XCTAssertEqual(MixedValue([String]()), MixedValue<String>.none)
    }

    func testSelectionSummary() {
        let mixed = InspectorSelectionSummary(states: [
            FixtureState(intensity: 1, color: .rgb(.red)),
            FixtureState(intensity: 0.5, color: .kelvin(3200)),
            FixtureState(intensity: 0.5, color: .rgb(.red)),
        ])
        XCTAssertEqual(mixed.count, 3)
        XCTAssertEqual(mixed.intensity, .mixed(min: 0.5, max: 1))
        XCTAssertEqual(mixed.intensityText, "Mixed · 50–100%")
        XCTAssertTrue(mixed.mode.isMixed)
        XCTAssertTrue(mixed.color.isMixed)
        XCTAssertEqual(mixed.kelvin, MixedNumber.none, "Kelvin is only shown when every light is white")
        XCTAssertEqual(mixed.distinctColors.count, 2)
        XCTAssertEqual(mixed.lightsOn, 3)

        let whites = InspectorSelectionSummary(states: [
            FixtureState(intensity: 0.8, color: .kelvin(3200)),
            FixtureState(intensity: 0.8, color: .kelvin(5600, tint: 0.1)),
        ])
        XCTAssertEqual(whites.intensity, .uniform(0.8))
        XCTAssertEqual(whites.intensityText, "80%")
        XCTAssertEqual(whites.mode, .uniform(.white))
        XCTAssertEqual(whites.kelvin, .mixed(min: 3200, max: 5600))
        XCTAssertEqual(whites.tint, .mixed(min: 0, max: 0.1))

        let same = InspectorSelectionSummary(states: Array(repeating: FixtureState(intensity: 0, color: .rgb(.blue)), count: 4))
        XCTAssertEqual(same.hex, .uniform("#0000FF"))
        XCTAssertEqual(same.lightsOn, 0)
        XCTAssertEqual(InspectorSelectionSummary(states: []).intensityText, "—")
    }

    func testRigSummary() {
        let project = DemoRig.londonStudio()
        var states: [UUID: FixtureState] = [:]
        for (i, f) in project.fixtures.enumerated() {
            states[f.id] = FixtureState(intensity: i == 0 ? 0 : 0.5, color: .rgb(i % 2 == 0 ? .red : .blue))
        }
        let summary = RigSummary(fixtures: project.fixtures, states: states)
        XCTAssertEqual(summary.total, project.fixtures.filter { !$0.hidden }.count)
        XCTAssertEqual(summary.lightsOn, summary.total - 1)
        XCTAssertEqual(summary.averageOnIntensity ?? 0, 0.5, accuracy: 1e-12)
        XCTAssertEqual(summary.colors.count, 2)
        XCTAssertGreaterThanOrEqual(summary.protectedCount, 1, "the key panel is protected")
        XCTAssertTrue(summary.headline.contains("on"), summary.headline)
        XCTAssertEqual(RigSummary(fixtures: [], states: [:]).headline, "No lights yet")
    }

    // MARK: - Pixels

    private let A = CellState(intensity: 1, color: .rgb(.red))
    private let B = CellState(intensity: 1, color: .rgb(.green))
    private let C = CellState(intensity: 1, color: .rgb(.blue))
    private let D = CellState(intensity: 0.5, color: .kelvin(3200))
    private let E = CellState(intensity: 1, color: .rgb(.white))

    private func state(_ cells: [CellState]) -> FixtureState {
        FixtureState(intensity: 1, color: .rgb(.black), cells: cells)
    }

    func testGradients() {
        let g = PixelOps.gradient([.rgb(.red), .rgb(.blue)], count: 16)
        XCTAssertEqual(g.count, 16)
        XCTAssertEqual(g.first, .rgb(.red))
        XCTAssertEqual(g.last, .rgb(.blue))
        XCTAssertEqual(PixelOps.gradient([.rgb(.red), .rgb(.blue)], count: 1).count, 1)
        XCTAssertTrue(PixelOps.gradient([.rgb(.red), .rgb(.blue)], count: 0).isEmpty)
        XCTAssertTrue(PixelOps.gradient([], count: 8).isEmpty)
        let three = PixelOps.gradient([.rgb(.red), .rgb(.green), .rgb(.blue)], count: 5)
        XCTAssertEqual(three[2], .rgb(.green))
        XCTAssertEqual(PixelOps.color(at: 0.5, stops: [.rgb(.red)]), .rgb(.red))

        let base = FixtureState(intensity: 0.7, color: .rgb(.green))
        let painted = PixelOps.applyGradient([.rgb(.red), .rgb(.blue)], to: base, count: 16, selection: [2, 3, 4])
        XCTAssertEqual(painted.cells?.count, 16)
        XCTAssertEqual(painted.cells?[0], CellState(intensity: 1, color: .rgb(.green)))
        XCTAssertEqual(painted.cells?[2].color, .rgb(.red))
        XCTAssertEqual(painted.cells?[4].color, .rgb(.blue))
        XCTAssertEqual(painted.intensity, 0.7, "master brightness is untouched")
        let all = PixelOps.applyGradient([.rgb(.red), .rgb(.blue)], to: base, count: 16)
        XCTAssertEqual(all.cells?[15].color, .rgb(.blue))
    }

    func testPixelEdits() {
        let s = state([A, B, C, D])
        XCTAssertEqual(PixelOps.reversed(s, count: 4).cells, [D, C, B, A])
        XCTAssertEqual(PixelOps.reversed(s, count: 4, selection: [1, 2]).cells, [A, C, B, D])
        XCTAssertEqual(PixelOps.mirrored(s, count: 4).cells, [A, B, B, A])
        XCTAssertEqual(PixelOps.mirrored(state([A, B, C, D, E]), count: 5).cells, [A, B, C, B, A])
        XCTAssertEqual(PixelOps.rotated(s, by: 1, count: 4).cells, [D, A, B, C])
        XCTAssertEqual(PixelOps.rotated(s, by: -1, count: 4).cells, [B, C, D, A])
        XCTAssertEqual(PixelOps.rotated(s, by: 5, count: 4).cells, [D, A, B, C])
        let filled = PixelOps.fill(.rgb(.white), to: s, count: 4, selection: [0, 3])
        XCTAssertEqual(filled.cells, [E, B, C, E])
        let dimmed = PixelOps.setCellIntensity(0.25, to: s, count: 4, selection: [1])
        XCTAssertEqual(dimmed.cells?[1], CellState(intensity: 0.25, color: .rgb(.green)))
        XCTAssertNil(PixelOps.cleared(s).cells)
        XCTAssertFalse(PixelOps.isUniform(s, count: 4))
        XCTAssertTrue(PixelOps.isUniform(state([A, A, A]), count: 3))
        XCTAssertTrue(PixelOps.isUniform(FixtureState(intensity: 1), count: 16))
        // Fixtures without a pattern behave as if every cell had the light's colour.
        let plain = FixtureState(intensity: 1, color: .rgb(.blue))
        XCTAssertEqual(PixelOps.fill(.rgb(.red), to: plain, count: 3, selection: [1]).cells, [C, A, C])
        XCTAssertEqual(PixelOps.cells(of: plain, count: 2), [C, C])
    }

    func testCellSelectionHelpers() {
        XCTAssertEqual(PixelOps.targetIndices([], count: 4), [0, 1, 2, 3])
        XCTAssertEqual(PixelOps.targetIndices([7, 2], count: 4), [2])
        XCTAssertEqual(PixelOps.range(5, 2, count: 16), [2, 3, 4, 5])
        XCTAssertEqual(PixelOps.range(10, 20, count: 16), Set(10...15))
        XCTAssertEqual(PixelOps.range(0, 3, count: 0), [])
        XCTAssertEqual(PixelOps.alternate(count: 5, startingAt: 0), [0, 2, 4])
        XCTAssertEqual(PixelOps.alternate(count: 5, startingAt: 1), [1, 3])
        XCTAssertEqual(PixelOps.inverted([0, 1], count: 4), [2, 3])
    }

    // MARK: - Palette from image

    private func blocksImage() -> (bytes: [UInt8], width: Int, height: Int) {
        // 64×64: four 32×32 quadrants (red, green, blue, yellow) with a black bar across the top.
        let w = 64, h = 64
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                var rgb: (UInt8, UInt8, UInt8)
                switch (x < 32, y < 32) {
                case (true, true): rgb = (255, 0, 0)
                case (false, true): rgb = (0, 255, 0)
                case (true, false): rgb = (0, 0, 255)
                case (false, false): rgb = (255, 255, 0)
                }
                if y < 4 { rgb = (0, 0, 0) }
                bytes[o] = rgb.0
                bytes[o + 1] = rgb.1
                bytes[o + 2] = rgb.2
                bytes[o + 3] = 255
            }
        }
        return (bytes, w, h)
    }

    func testPaletteFindsDistinctColors() {
        let img = blocksImage()
        let palette = PaletteExtractor.palette(rgba: img.bytes, width: img.width, height: img.height, count: 5)
        XCTAssertEqual(palette.count, 4, "\(palette.map(\.hex))")
        for target in [RGB.red, RGB.green, RGB.blue, RGB(r: 1, g: 1, b: 0)] {
            let best = palette.map { ColorMath.deltaEOKLab(target, $0) }.min() ?? 1
            XCTAssertLessThan(best, 0.02, "missing \(target.hex) in \(palette.map(\.hex))")
        }
        let again = PaletteExtractor.palette(rgba: img.bytes, width: img.width, height: img.height, count: 5)
        XCTAssertEqual(palette, again, "deterministic")
        XCTAssertEqual(PaletteExtractor.palette(rgba: img.bytes, width: img.width, height: img.height, count: 2).count, 2)
    }

    func testPaletteEdgeCases() {
        XCTAssertTrue(PaletteExtractor.palette(rgba: [], width: 0, height: 0).isEmpty)
        XCTAssertTrue(PaletteExtractor.palette(rgba: [UInt8](repeating: 0, count: 16 * 4), width: 4, height: 4).isEmpty)
        XCTAssertTrue(PaletteExtractor.palette(rgba: [255, 0, 0], width: 10, height: 10).isEmpty, "truncated buffer")
        let transparent = [UInt8](repeating: 255, count: 4 * 4).enumerated().map { $0.offset % 4 == 3 ? 0 : $0.element }
        XCTAssertTrue(PaletteExtractor.palette(rgba: transparent, width: 2, height: 2).isEmpty)
        XCTAssertEqual(PaletteExtractor.palette(colors: [.red], count: 5).map(\.hex), ["#FF0000"])
    }

    func testSpreadByStagePosition() {
        let ids = (0..<8).map { _ in UUID() }
        let palette: [LightColor] = [.rgb(.red), .rgb(.green), .rgb(.blue)]
        let three = PaletteExtractor.spread(palette, over: [(ids[0], 3, 0), (ids[1], 1, 0), (ids[2], 2, 0)])
        XCTAssertEqual(three.map { $0.id }, [ids[1], ids[2], ids[0]])
        XCTAssertEqual(three.map { $0.color }, palette)

        let five: [LightColor] = (0..<5).map { .hsi(hue: Double($0) * 60, saturation: 1) }
        let lights = ids.enumerated().map { (id: $0.element, x: Double($0.offset), y: 0.0) }
        let spread = PaletteExtractor.spread(five, over: lights)
        XCTAssertEqual(spread.map { five.firstIndex(of: $0.color) ?? -1 }, [0, 0, 1, 1, 2, 3, 3, 4])
        XCTAssertEqual(PaletteExtractor.spread(five, over: [(ids[0], 0, 0)]).first?.color, five[0])
        XCTAssertTrue(PaletteExtractor.spread([], over: lights).isEmpty)
    }

    // MARK: - History

    func testColorHistory() throws {
        let red = LightColor.rgb(.red), blue = LightColor.rgb(.blue), warm = LightColor.kelvin(3200)
        var h = ColorHistory()
        h.push(red)
        h.push(blue)
        h.push(red)
        XCTAssertEqual(h.colors, [red, blue])
        h.push(warm)
        XCTAssertEqual(h.colors.first, warm)
        h.remove(blue)
        XCTAssertEqual(h.colors, [warm, red])

        var small = ColorHistory(limit: 3)
        for i in 0..<5 { small.push(.hsi(hue: Double(i * 10), saturation: 1)) }
        XCTAssertEqual(small.colors.count, 3)
        XCTAssertEqual(small.colors.first, .hsi(hue: 40, saturation: 1))

        let restored = ColorHistory.decode(h.encoded())
        XCTAssertEqual(restored, h)
        XCTAssertTrue(ColorHistory.decode(Data("garbage".utf8)).colors.isEmpty)
        XCTAssertTrue(ColorHistory.decode(nil).colors.isEmpty)
        h.clear()
        XCTAssertTrue(h.colors.isEmpty)
    }
}
