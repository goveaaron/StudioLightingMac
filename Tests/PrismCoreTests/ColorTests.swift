import XCTest
@testable import PrismCore

final class ColorTests: XCTestCase {

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
                // Across 1700–20000K, verify Duv accuracy < 0.002 and Kelvin accuracy < 20K (for standard range)
                XCTAssertEqual(rDuv.duv, expectedDuv, accuracy: 0.002, "Duv round-trip failed for \(k)K tint \(tint)")
                XCTAssertEqual(rTint.tint, tint, accuracy: 0.04, "Tint round-trip failed for \(k)K tint \(tint)")
                if k <= 12000 || abs(tint) <= 0.4 {
                    XCTAssertEqual(rDuv.kelvin, k, accuracy: 20.0, "Tinted CCT round-trip > 20K for \(k)K tint \(tint) (got \(rDuv.kelvin))")
                }
            }
        }
    }

    func testSidusAndAputureTintConventions() {
        // Negative Prism tint = Green (+Duv, +Sidus G/M, DMX 245...255)
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
        // Out-of-gamut high-chroma OKLCh color
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

        // Slightly perturbed color should have small ΔE2000 (< 2)
        let nearTeal = RGB(r: teal.r, g: teal.g - 0.01, b: teal.b + 0.01)
        let de = ColorMath.deltaE2000(teal, nearTeal)
        XCTAssertGreaterThan(de, 0.1)
        XCTAssertLessThan(de, 2.0)

        // Opposite colors should have large ΔE2000
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

        // Classic theatrical & correction gels must resolve by code, number, and name
        let r02 = try XCTUnwrap(GelLibrary.gel("R02"))
        XCTAssertTrue(r02.name.localizedCaseInsensitiveContains("Bastard Amber"))
        XCTAssertEqual(GelLibrary.gel("Bastard Amber")?.id, r02.id)

        let l201 = try XCTUnwrap(GelLibrary.gel("L201"))
        XCTAssertEqual(l201.category, .ctb)
        let l204 = try XCTUnwrap(GelLibrary.gel("L204"))
        XCTAssertEqual(l204.category, .cto)
        // L204 Full CTO on 5600K daylight shifts to ~3200K tungsten
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

        // Optional JSON export when EXPORT_GELS_JSON=1
        if ProcessInfo.processInfo.environment["EXPORT_GELS_JSON"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(GelLibrary.all)
            let url = URL(fileURLWithPath: "/home/antigravity/wt/color/Resources/Gels/gels.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }

    // MARK: - 5. NamedColors & Real-Source Presets

    func testNamedColorsAndRealSources() throws {
        // Studio & film words
        let queries = [
            "teal", "magenta", "warm white", "tungsten", "daylight",
            "moonlight", "golden hour", "sodium vapor", "mercury vapor",
            "cool-white fluorescent", "candle", "hmi", "overcast", "shade"
        ]
        for q in queries {
            XCTAssertNotNil(NamedColors.resolve(q), "Failed to resolve named color '\(q)'")
        }

        // Studio teal matches DemoRig swatch #00C2A8
        XCTAssertEqual(NamedColors.resolve("teal")?.hex, "#00C2A8")

        // Tungsten resolves to 3200K
        if case .kelvin(let k, _) = try XCTUnwrap(NamedColors.resolve("tungsten")) {
            XCTAssertEqual(k, 3200, accuracy: 1)
        } else {
            XCTFail("Expected tungsten to resolve to .kelvin(3200)")
        }

        // Cool-white fluorescent has green shift (negative Prism tint / positive Duv)
        let fl = try XCTUnwrap(NamedColors.sourcePreset(named: "cool-white fluorescent"))
        XCTAssertLessThan(fl.tint, -0.2)
        XCTAssertGreaterThan(fl.duv, 0.005)
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
