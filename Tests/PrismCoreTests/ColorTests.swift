import XCTest
@testable import PrismCore

final class ColorTests: XCTestCase {
    func testHexRoundTrip() throws {
        let c = try XCTUnwrap(RGBColor(hex: "#1FA2FF"))
        XCTAssertEqual(c.hex, "#1FA2FF")
        XCTAssertEqual(RGBColor(hex: "1fa2ff")?.hex, "#1FA2FF")
        XCTAssertEqual(RGBColor(hex: "#FFF")?.hex, "#FFFFFF")
        XCTAssertNil(RGBColor(hex: "#12"))
        XCTAssertNil(RGBColor(hex: "zzzzzz"))
    }

    func testKelvinRoundTrip() {
        for k in stride(from: 2000.0, through: 10000.0, by: 500) {
            let xy = ColorMath.kelvinToXY(k, tint: 0)
            let result = ColorMath.xyToKelvinAndTint(x: xy.x, y: xy.y)
            XCTAssertEqual(result.kelvin, k, accuracy: k * 0.03, "CCT round-trip failed for \(k)")
            XCTAssertEqual(result.tint, 0, accuracy: 0.05, "Tint round-trip failed for \(k)")
            for tint in [-0.6, -0.2, 0.3, 0.8] {
                let txy = ColorMath.kelvinToXY(k, tint: tint)
                let r = ColorMath.xyToKelvinAndTint(x: txy.x, y: txy.y)
                XCTAssertEqual(r.kelvin, k, accuracy: k * 0.02, "CCT (tinted \(tint)) failed for \(k)")
                XCTAssertEqual(r.tint, tint, accuracy: 0.03, "Tint \(tint) failed for \(k)")
            }
        }
    }

    func testLightColorJSONRoundTrip() throws {
        let colors: [LightColor] = [
            .rgb(RGBColor(hex: "#00C2B8")!),
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
