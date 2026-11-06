import XCTest
@testable import PrismApp
import PrismCore

final class AppUnitTests: XCTestCase {
    func testLaunchOptionsParsing() {
        let o = LaunchOptions(arguments: ["Prism", "--demo", "--project", "/tmp/a.prismlights", "--no-hardware"])
        XCTAssertTrue(o.demo)
        XCTAssertTrue(o.noHardware)
        XCTAssertEqual(o.projectPath?.path, "/tmp/a.prismlights")
        XCTAssertFalse(o.isAutomated)

        let tour = LaunchOptions(arguments: ["Prism", "--screenshot-tour", "/tmp/shots"])
        XCTAssertTrue(tour.isAutomated)
        XCTAssertTrue(tour.noHardware, "Automated runs must never touch hardware")
        XCTAssertTrue(tour.demo)
    }

    func testSliderParsing() {
        XCTAssertEqual(PrismSlider.defaultParse("72%", range: 0...1)!, 0.72, accuracy: 1e-9)
        XCTAssertEqual(PrismSlider.defaultParse("72", range: 0...1)!, 0.72, accuracy: 1e-9)
        XCTAssertEqual(PrismSlider.defaultParse("0.5", range: 0...1)!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(PrismSlider.defaultParse("5600K", range: 1700...12000)!, 5600, accuracy: 1e-9)
        XCTAssertNil(PrismSlider.defaultParse("abc", range: 0...1))
    }

    func testStageMappingRoundTrip() {
        let m = StageMapping(stageSize: CGSize(width: 5.2, height: 9.2), viewSize: CGSize(width: 900, height: 700))
        let p = m.point(2.5, 6.5)
        let back = m.meters(p)
        XCTAssertEqual(back.x, 2.5, accuracy: 1e-6)
        XCTAssertEqual(back.y, 6.5, accuracy: 1e-6)
        XCTAssertTrue(m.stageRect.width <= 900 && m.stageRect.height <= 700)
    }

    func testUndoHistoryCoalesces() {
        var h = UndoHistory()
        let doc = ShowDocument(project: DemoRig.londonStudio())
        h.record(before: doc, name: "Brightness", coalesceKey: "intensity", now: 1.0)
        h.record(before: doc, name: "Brightness", coalesceKey: "intensity", now: 1.5)
        h.record(before: doc, name: "Brightness", coalesceKey: "intensity", now: 2.0)
        XCTAssertEqual(h.undoStack.count, 1, "A continuous drag must be one undo step")
        h.record(before: doc, name: "Color", coalesceKey: nil, now: 2.1)
        XCTAssertEqual(h.undoStack.count, 2)
    }
}
