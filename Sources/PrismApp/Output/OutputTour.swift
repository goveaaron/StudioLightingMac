import Foundation
import PrismCore

/// Screenshot-tour scenes for this feature (see App/ScreenshotTour.swift). Add scenes that put
/// the UI into interesting states; CI renders each one to a PNG artifact.
///
/// Every scene uses simulated devices (the tour never touches real hardware). Sheets remove
/// them again when they close (`OutputManager.sheetClosed`), so the last scene here is a sheet
/// and later scenes see the normal "Simulation" state.
@MainActor
enum OutputTour {
    static var scenes: [ScreenshotTour.Scene] {
        [
            ScreenshotTour.Scene(name: "outputs-toolbar-live", setup: { app in
                app.ui.selectedTab = .stage
                app.outputs.installSimulatedDevices([box()])
                toast(app, for: .live)
            }, settle: 1.2),
            ScreenshotTour.Scene(name: "outputs-toolbar-unplugged", setup: { app in
                app.ui.selectedTab = .stage
                let device = box()
                app.outputs.installSimulatedDevices([device])
                device.setState(.searching)
                toast(app, for: .searching)
            }, settle: 1.2),
            ScreenshotTour.Scene(name: "hardware-test-1-connected", setup: { app in
                app.outputs.installSimulatedDevices([box()])
                present(app, step: .connection)
            }, settle: 1.5),
            ScreenshotTour.Scene(name: "hardware-test-1-busy", setup: { app in
                app.outputs.installSimulatedDevices([box(.busy)])
                present(app, step: .connection)
            }, settle: 1.5),
            ScreenshotTour.Scene(name: "hardware-test-1-no-box", setup: { app in
                app.outputs.removeSimulatedDevices()
                present(app, step: .connection)
            }, settle: 1.5),
            ScreenshotTour.Scene(name: "hardware-test-2-test-lights", setup: { app in
                app.outputs.installSimulatedDevices([box()])
                present(app, step: .testLights, lightIndex: 2, answers: answers(app, yes: 0..<2))
            }, settle: 1.5),
            ScreenshotTour.Scene(name: "hardware-test-2-dark-light", setup: { app in
                app.outputs.installSimulatedDevices([box()])
                var a = answers(app, yes: 0..<3)
                if let dark = app.outputs.hardwareTest.fixtures.dropFirst(3).first { a[dark.id] = false }
                present(app, step: .testLights, lightIndex: 3, answers: a)
            }, settle: 1.5),
            ScreenshotTour.Scene(name: "hardware-test-3-channels", setup: { app in
                app.outputs.installSimulatedDevices([box()])
                ScreenshotTour.recall(app, "Chill Vibes 4")
                present(app, step: .channels)
            }, settle: 1.5),
            ScreenshotTour.Scene(name: "hardware-test-3-channel-selected", setup: { app in
                app.outputs.installSimulatedDevices([box()])
                ScreenshotTour.recall(app, "Teal Left, Blue Right, Pink Above")
                present(app, step: .channels)
                try? await Task.sleep(nanoseconds: 500_000_000)
                app.outputs.hardwareTest.selectedAddress = 53
            }, settle: 1.2),
            ScreenshotTour.Scene(name: "hardware-test-4-blink", setup: { app in
                app.outputs.installSimulatedDevices([box()])
                present(app, step: .blink)
                try? await Task.sleep(nanoseconds: 500_000_000)
                app.outputs.hardwareTest.blink(DemoRig.IDs.tube(3))
            }, settle: 0.8),
            ScreenshotTour.Scene(name: "hardware-test-5-tips", setup: { app in
                app.outputs.installSimulatedDevices([box()])
                present(app, step: .tips)
            }, settle: 1.5),
            // Last: a sheet, so closing it removes the simulated box before other scenes run.
            ScreenshotTour.Scene(name: "output-settings", setup: { app in
                app.outputs.installSimulatedDevices([box()])
                app.ui.activeSheet = .outputSettings
            }, settle: 1.5),
        ]
    }

    /// A simulated ENTTEC DMX USB Pro, like the one in the studio.
    private static func box(_ state: DMXDeviceState = .live) -> SimulatedDMXDevice {
        SimulatedDMXDevice(id: "usb:EN055555", name: "ENTTEC DMX USB Pro", shortName: "DMX USB Pro",
                           serialNumber: "01234567", firmware: "1.44", timing: "Break 96 µs · MAB 11 µs · 40 fps",
                           path: "/dev/cu.usbserial-EN055555", state: state)
    }

    /// Opens the Hardware Test at `step`.
    private static func present(_ app: AppModel, step: HardwareTestModel.Step, lightIndex: Int = 0,
                                answers: [UUID: Bool] = [:]) {
        app.outputs.hardwareTest.prepare(step: step, lightIndex: lightIndex, answers: answers)
        app.ui.activeSheet = .hardwareTest
    }

    /// "Yes, it lit up" for the lights at `indices` (test order).
    private static func answers(_ app: AppModel, yes indices: Range<Int>) -> [UUID: Bool] {
        let fixtures = app.outputs.hardwareTest.fixtures
        var result: [UUID: Bool] = [:]
        for i in indices where i < fixtures.count { result[fixtures[i].id] = true }
        return result
    }

    /// The toast the user sees when the box connects or disconnects.
    private static func toast(_ app: AppModel, for state: DMXDeviceState) {
        guard let t = OutputManager.toast(for: state) else { return }
        app.ui.toast(t.message, style: t.style, systemImage: t.systemImage, duration: 3.5)
    }
}
