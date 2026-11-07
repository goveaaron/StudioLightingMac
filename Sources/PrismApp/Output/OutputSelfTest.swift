import Foundation
import PrismCore

/// In-app self-test checks for this feature (see App/SelfTest.swift). Runs on CI inside the
/// real app process with the demo rig and no hardware.
///
/// The same checks power Help ▸ Run Diagnostics on the user's Mac, so anything that changes
/// state (simulated devices, raw overrides) only runs while hardware is off for the session —
/// Diagnostics must never flash a real rig. The pseudo-terminal check touches no hardware and
/// always runs: it drives the real serial driver against a simulated DMX USB Pro.
@MainActor
enum OutputSelfTest {
    static var checks: [SelfTest.Check] {
        [
            SelfTest.Check(name: "outputs.virtualReceivesFrames") { app in
                let output = app.outputs.virtualOutput
                let before = output.framesSent
                try? await Task.sleep(nanoseconds: 600_000_000)
                let after = output.framesSent
                guard after > before else { return "The virtual output received no frames in 0.6 s (\(before) → \(after))" }
                let count = output.lastFrame.count
                return count == 512 ? nil : "The virtual output's last frame has \(count) channels, expected 512"
            },
            SelfTest.Check(name: "outputs.simulationStatus") { app in
                guard app.outputs.hardwareDisabled else { return nil }
                let s = app.outputs.summary
                return s.level == .simulated && s.title == "Simulation"
                    ? nil : "Toolbar says \"\(s.title)\" (\(s.level.rawValue)), expected \"Simulation\""
            },
            SelfTest.Check(name: "outputs.submitBudget") { _ in
                // The engine tick hands frames to a device without ever waiting — even when the
                // box is missing — and closing a device is quick.
                let device = EnttecProDevice(id: "selftest.none", locate: { nil })
                device.start()
                let routed = RoutedOutput(device: device, port: 1, universe: 1)
                var frame = [UInt8](repeating: 0, count: 512)
                let start = PrismClock.now()
                for i in 0..<2000 {
                    frame[0] = UInt8(truncatingIfNeeded: i)
                    routed.send(universe: 1, data: frame)
                }
                let sendMs = (PrismClock.now() - start) * 1000
                let stopMs = await stopOffMain(device)
                #if DEBUG
                let sendBudget = 400.0 * budgetScale
                #else
                let sendBudget = 100.0 * budgetScale
                #endif
                let stopBudget = 500.0 * budgetScale
                if sendMs > sendBudget { return String(format: "2000 frames took %.1f ms to hand over (budget %.0f ms)", sendMs, sendBudget) }
                if stopMs > stopBudget { return String(format: "Closing a device took %.0f ms (budget %.0f ms)", stopMs, stopBudget) }
                return nil
            },
            SelfTest.Check(name: "outputs.ptyWidgetEndToEnd") { _ in
                await ptyWidgetEndToEnd()
            },
            SelfTest.Check(name: "outputs.deviceLifecycle") { app in
                guard app.outputs.hardwareDisabled else { return nil }
                return await deviceLifecycle(app)
            },
            SelfTest.Check(name: "outputs.hardwareTestSignal") { app in
                guard app.outputs.hardwareDisabled else { return nil }
                return hardwareTestSignal(app)
            },
            SelfTest.Check(name: "outputs.channelMapMatchesPatch") { app in
                let fixtures = app.show.resolvedFixtures
                for universe in HardwareTestPlan.universes(fixtures) {
                    let map = ChannelMap(universe: universe, fixtures: fixtures)
                    for rf in fixtures where rf.fixture.universe == universe {
                        guard let range = rf.addressRange else { continue }
                        for address in range where address >= 1 && address <= 512 && !map.conflicts.contains(address) {
                            guard map.owner(at: address)?.fixtureID == rf.id else {
                                return "The channel monitor doesn't show channel \(address) of universe \(universe) as \(rf.fixture.name)'s"
                            }
                        }
                    }
                }
                return nil
            },
        ]
    }

    // MARK: - Checks

    /// The real ENTTEC driver against a simulated DMX USB Pro on a pseudo-terminal: open with
    /// exclusive access, identify (serial number and firmware), go live, deliver a frame.
    private static func ptyWidgetEndToEnd() async -> String? {
        guard let widget = PseudoWidget(.enttecPro) else { return "Couldn't create a pseudo-terminal for the simulated DMX box" }
        let path = widget.path
        var options = EnttecProDevice.Options()
        options.backoff = [0.05, 0.1, 0.2]
        let device = EnttecProDevice(id: "selftest.pty", options: options, locate: { path })
        device.start()
        let failure = await exercise(device, widget: widget)
        _ = await stopOffMain(device)
        widget.unplug()
        return failure
    }

    private static func exercise(_ device: EnttecProDevice, widget: PseudoWidget) async -> String? {
        guard await waitUntil(5, { device.snapshot.state == .live }) else {
            let s = device.snapshot
            return "The simulated DMX USB Pro didn't connect: \(s.state.title) — \(s.message)"
        }
        let s = device.snapshot
        guard s.serialNumber == "01234567", s.firmware == "1.44" else {
            return "Identification read serial \(s.serialNumber ?? "none"), firmware \(s.firmware ?? "none")"
        }
        let frame = (0..<512).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
        RoutedOutput(device: device, port: 1, universe: 1).send(universe: 1, data: frame)
        guard await waitUntil(3, { widget.lastFrame() == frame }) else {
            return "The simulated DMX USB Pro didn't receive the frame (\(widget.frameCount()) frames received)"
        }
        return nil
    }

    /// Connect, unplug, busy and back: the toolbar summary follows a (simulated) DMX box.
    private static func deviceLifecycle(_ app: AppModel) async -> String? {
        let outputs = app.outputs
        defer { outputs.removeSimulatedDevices() }
        let box = SimulatedDMXDevice(id: "selftest.box", name: "ENTTEC DMX USB Pro", shortName: "DMX USB Pro",
                                     serialNumber: "01234567", firmware: "1.44", path: "/dev/cu.usbserial-SELFTEST")
        outputs.installSimulatedDevices([box])
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard outputs.summary.level == .connected, outputs.summary.title == "DMX USB Pro" else {
            return "With a box connected the toolbar says \"\(outputs.summary.title)\""
        }
        let sent = box.snapshot.stats.framesSent
        guard await waitUntil(2, { box.snapshot.stats.framesSent > sent }) else {
            return "The engine sent no frames to the connected box"
        }
        let steps: [(DMXDeviceState, String)] = [(.searching, "DMX box unplugged"), (.busy, "DMX box busy"), (.live, "DMX USB Pro")]
        for (state, title) in steps {
            box.setState(state)
            guard await waitUntil(1, { outputs.summary.title == title }) else {
                return "After \"\(state.title)\" the toolbar says \"\(outputs.summary.title)\", expected \"\(title)\""
            }
        }
        outputs.removeSimulatedDevices()
        guard outputs.summary.title == "Simulation" else {
            return "After removing the box the toolbar says \"\(outputs.summary.title)\""
        }
        guard !app.engine.currentOutputs.contains(where: { $0.outputID.hasPrefix("selftest.box") }) else {
            return "The removed box is still connected to the engine"
        }
        return nil
    }

    /// Step 2 of the Hardware Test lights exactly one fixture and restores everything afterwards.
    private static func hardwareTestSignal(_ app: AppModel) -> String? {
        let model = app.outputs.hardwareTest
        guard !model.isOpen else { return nil } // the user has the sheet open
        let fixtures = model.fixtures
        guard fixtures.count >= 2 else { return "Only \(fixtures.count) patched lights to test" }
        let before = app.show.live.rawOverrides
        model.prepare(step: .testLights, lightIndex: 1)
        model.open()
        app.engine.tick()
        let frame = app.engine.latestFrame.universes[fixtures[1].fixture.universe] ?? []
        let overrides = app.show.live.rawOverrides
        model.end()
        app.engine.tick()

        guard frame.count == 512 else { return "No frame for the light under test" }
        guard let target = model.fixtures.dropFirst().first, let range = target.addressRange else {
            return "The light under test has no address"
        }
        let targetLevels = range.compactMap { $0 >= 1 && $0 <= 512 ? frame[$0 - 1] : nil }
        guard targetLevels.contains(where: { $0 > 0 }) else { return "\(target.fixture.name) stayed dark during its test" }
        for o in overrides where o.universe == target.fixture.universe && o.address >= 1 && o.address <= 512 {
            guard frame[o.address - 1] == o.value else {
                return "Channel \(o.address) sent \(frame[o.address - 1]) during the test, expected \(o.value)"
            }
        }
        // Every other light is held dark (its intensity channels send 0).
        for rf in fixtures where rf.id != target.id && rf.fixture.universe == target.fixture.universe {
            guard let r = rf.addressRange else { continue }
            for (offset, channel) in rf.mode.channels.enumerated() where channel.kind == .intensity {
                let address = r.lowerBound + offset
                guard address >= 1, address <= 512, !range.contains(address) else { continue }
                if frame[address - 1] > 0 { return "\(rf.fixture.name) was lit during the test of \(target.fixture.name)" }
            }
        }
        guard app.show.live.rawOverrides == before else { return "Closing the Hardware Test didn't restore the channel overrides" }
        return nil
    }

    // MARK: - Helpers

    /// Polls `condition` until it holds or `timeout` (seconds) passes, without blocking.
    private static func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = PrismClock.now() + timeout
        while PrismClock.now() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// Stops a device off the main thread; returns how long it took (ms).
    private static func stopOffMain(_ device: DMXDevice) async -> Double {
        await withCheckedContinuation { (continuation: CheckedContinuation<Double, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let start = PrismClock.now()
                device.stop(flushTimeout: 0.1)
                continuation.resume(returning: (PrismClock.now() - start) * 1000)
            }
        }
    }

    /// Sanitizer runs are many times slower: they loosen timing budgets.
    private static var budgetScale: Double {
        guard let text = ProcessInfo.processInfo.environment["PRISM_PERF_BUDGET_SCALE"],
              let scale = Double(text), scale > 0 else { return 1 }
        return scale
    }
}
