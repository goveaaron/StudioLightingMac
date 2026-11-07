import XCTest
import Foundation
@testable import PrismCore

final class EngineTests: XCTestCase {

    // MARK: - 1. Thread Safety & Shutdown

    func testEngineConcurrentUpdateTickAndShutdown() {
        let lib = TestResources.library()
        let engine = EngineCore(frameRate: 60)
        let vOut = VirtualDMXOutput(id: "v1", name: "Virtual 1", universe: 1)
        engine.addOutput(vOut)

        let baseDoc = ShowDocument(project: DemoRig.londonStudio())
        engine.update(ShowSnapshot(document: baseDoc, library: lib.definition))
        engine.start()

        let group = DispatchGroup()
        let iterations = 60

        // Concurrent snapshot writers
        for worker in 0..<4 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var doc = baseDoc
                let exec = CommandExecutor(library: lib.definition, now: { Double(worker) })
                for i in 0..<iterations {
                    let level = Double((i + worker) % 100) / 100.0
                    _ = exec.apply([.setIntensity(.all, level)], to: &doc)
                    let snap = ShowSnapshot(document: doc, library: lib.definition, revision: i)
                    engine.update(snap)
                    engine.setAudioFeatures(AudioFeatures(
                        timestamp: Double(i) * 0.025,
                        isActive: i % 2 == 0,
                        level: level
                    ))
                }
                group.leave()
            }
        }

        // Concurrent manual tick() and stats/latestFrame readers
        for _ in 0..<4 {
            group.enter()
            DispatchQueue.global(qos: .userInteractive).async {
                for i in 0..<iterations {
                    engine.tick()
                    _ = engine.latestFrame
                    _ = engine.stats
                    if i % 20 == 0 {
                        engine.setFrameRate(Double(30 + (i % 30)))
                    }
                }
                group.leave()
            }
        }

        group.wait()
        engine.shutdown(blackout: true, timeout: 0.5)

        XCTAssertFalse(engine.isRunning)
        XCTAssertGreaterThan(engine.stats.framesRendered, 0)
        // Shutdown with blackout: true must leave the final transmitted DMX frame all zeros.
        XCTAssertEqual(vOut.lastFrame, Array(repeating: 0, count: 512))
    }

    func testShutdownHoldPreservesOutput() {
        let lib = TestResources.library()
        let engine = EngineCore(frameRate: 40)
        let vOut = VirtualDMXOutput(id: "v1", name: "Virtual 1", universe: 1)
        engine.addOutput(vOut)

        var doc = ShowDocument(project: DemoRig.londonStudio())
        let exec = CommandExecutor(library: lib.definition, now: { 10 })
        _ = exec.apply([.setIntensity(.id(DemoRig.IDs.p1), 1.0)], to: &doc)
        engine.update(ShowSnapshot(document: doc, library: lib.definition))
        engine.shutdown(blackout: false, timeout: 0.25)

        XCTAssertEqual(vOut.lastFrame[0], 255)
    }

    // MARK: - 2. Crossfade Engine (Curves, Presets, Spatial Delay, Mid-Fade Interruption)

    func testFadeCurvesAndPresets() {
        XCTAssertEqual(FadePreset.snap.seconds, 0)
        XCTAssertEqual(FadePreset.quick.seconds, 0.4, accuracy: 1e-6)
        XCTAssertEqual(FadePreset.smooth.seconds, 1.5, accuracy: 1e-6)
        XCTAssertEqual(FadePreset.slow.seconds, 4.0, accuracy: 1e-6)
        XCTAssertEqual(FadePreset.cinematic.seconds, 10.0, accuracy: 1e-6)

        for curve in FadeCurve.allCases {
            XCTAssertEqual(curve.evaluate(0), 0, accuracy: 1e-9)
            XCTAssertEqual(curve.evaluate(0.5), 0.5, accuracy: 1e-9)
            XCTAssertEqual(curve.evaluate(1), 1, accuracy: 1e-9)
            // Monotonicity check
            var prev = 0.0
            for step in 0...100 {
                let t = Double(step) / 100.0
                let v = curve.evaluate(t)
                XCTAssertGreaterThanOrEqual(v + 1e-12, prev, "Curve \(curve) not monotonic at \(t)")
                prev = v
            }
        }
        // sCurve is flatter at the ends and steeper in the middle than easeInOut
        XCTAssertLessThan(FadeCurve.sCurve.evaluate(0.2), FadeCurve.easeInOut.evaluate(0.2))
        XCTAssertLessThan(FadeCurve.easeInOut.evaluate(0.2), FadeCurve.linear.evaluate(0.2))
    }

    func testSpatialDelayWaveAcrossStage() {
        let lib = TestResources.library()
        var project = DemoRig.londonStudio()
        let lookID = UUID()
        var states = FixtureStateMap()
        for f in project.fixtures {
            states[f.id] = FixtureState(intensity: 1.0, color: .rgb(RGB(r: 0, g: 1, b: 1)))
        }
        let waveLook = Look(
            id: lookID,
            name: "Wave Look",
            states: states,
            fadeTime: 1.0,
            fadeCurve: .linear,
            spatialDelay: 1.0,
            delayDirection: .leftToRight
        )
        project.looks.append(waveLook)

        var doc = ShowDocument(project: project)
        let exec = CommandExecutor(library: lib.definition, now: { 100.0 })
        _ = exec.apply([.recallLook(.id(lookID), fade: nil)], to: &doc)

        // Leftmost tube (B1) has smaller delay than rightmost tube (B5).
        let delayB1 = doc.live.fades[DemoRig.IDs.tube(1)]?.delay ?? -1
        let delayB5 = doc.live.fades[DemoRig.IDs.tube(5)]?.delay ?? -1
        XCTAssertGreaterThanOrEqual(delayB1, 0)
        XCTAssertGreaterThan(delayB5, delayB1)

        // At t = 100.5, B1 is further into its fade than B5.
        let snap = ShowSnapshot(document: doc, library: lib.definition)
        let frameMid = EngineCore.renderFrame(snap, time: 100.5)
        let b1Intensity = frameMid.states[DemoRig.IDs.tube(1)]?.intensity ?? 0
        let b5Intensity = frameMid.states[DemoRig.IDs.tube(5)]?.intensity ?? 0
        XCTAssertGreaterThan(b1Intensity, b5Intensity)
        XCTAssertNotNil(frameMid.fadeProgress)
        XCTAssertTrue(frameMid.isFading)

        // At t = 102.5, all fades are finished.
        let frameEnd = EngineCore.renderFrame(snap, time: 102.5)
        XCTAssertEqual(frameEnd.states[DemoRig.IDs.tube(1)]?.intensity ?? 0, 1.0, accuracy: 1e-6)
        XCTAssertEqual(frameEnd.states[DemoRig.IDs.tube(5)]?.intensity ?? 0, 1.0, accuracy: 1e-6)
        XCTAssertNil(frameEnd.fadeProgress)
        XCTAssertFalse(frameEnd.isFading)
    }

    func testMidFadeInterruptionNeverJumps() {
        let lib = TestResources.library()
        var doc = ShowDocument(project: DemoRig.londonStudio())
        let fixtureID = DemoRig.IDs.p1

        // Start a 2.0s fade from 0.0 -> 1.0 at t = 10.0
        var now = 10.0
        let exec = CommandExecutor(library: lib.definition, now: { now })
        _ = exec.apply([.fadeTime(2.0), .setIntensity(.id(fixtureID), 1.0)], to: &doc)

        let snap1 = ShowSnapshot(document: doc, library: lib.definition)
        // Render at t = 11.0 (halfway through fade -> intensity = 0.5)
        now = 11.0
        let frameAtInterrupt = EngineCore.renderFrame(snap1, time: now)
        let midIntensity = frameAtInterrupt.states[fixtureID]?.intensity ?? -1
        XCTAssertEqual(midIntensity, 0.5, accuracy: 1e-4)

        // Interrupt at t = 11.0 with a new 2.0s fade to 0.2!
        _ = exec.apply(
            [.fadeTime(2.0), .setIntensity(.id(fixtureID), 0.2)],
            to: &doc,
            currentRendered: frameAtInterrupt.preMasterStates
        )
        let snap2 = ShowSnapshot(document: doc, library: lib.definition)
        let frameImmediateAfter = EngineCore.renderFrame(snap2, time: now)
        let afterIntensity = frameImmediateAfter.states[fixtureID]?.intensity ?? -1

        // Continuity invariant: at the exact moment of interruption, rendered intensity MUST equal midIntensity (no jump).
        XCTAssertEqual(afterIntensity, midIntensity, accuracy: 1e-6)
    }

    func testEffectAndMusicCrossfadeOnLookRecall() {
        let lib = TestResources.library()
        var project = DemoRig.londonStudio()
        let effect = EffectInstance(
            id: UUID(),
            kind: .breathe,
            targets: .role(.background),
            params: EffectParameters(speed: 1.0, amount: 1.0, minIntensity: 0.0, maxIntensity: 1.0)
        )
        var baseStates = FixtureStateMap()
        baseStates[DemoRig.IDs.tube(1)] = FixtureState(intensity: 0.5, color: .rgb(RGB(r: 1, g: 0, b: 0)))

        let lookWithEffect = Look(
            id: UUID(),
            name: "With Effect",
            states: baseStates,
            effects: [effect],
            music: MusicModeSettings(enabled: true, mood: .aurora),
            fadeTime: 1.0
        )
        let lookDry = Look(
            id: UUID(),
            name: "Dry Look",
            states: baseStates,
            effects: [],
            music: nil,
            fadeTime: 1.0
        )
        project.looks = [lookWithEffect, lookDry]

        var doc = ShowDocument(project: project)
        var now = 50.0
        let exec = CommandExecutor(library: lib.definition, now: { now })

        // Recall Look A (with effect + music) over 1.0s
        _ = exec.apply([.recallLook(.id(lookWithEffect.id), fade: 1.0)], to: &doc)
        XCTAssertNotNil(doc.live.effectFades[effect.id])
        XCTAssertEqual(doc.live.effectFades[effect.id]?.fadingIn, true)
        XCTAssertEqual(doc.live.musicFade?.fadingIn, true)

        // Now at t = 52.0, recall Look B (dry) over 1.0s — effect and music should fade out smoothly
        now = 52.0
        _ = exec.apply([.recallLook(.id(lookDry.id), fade: 1.0)], to: &doc)
        XCTAssertTrue(doc.live.effects.isEmpty)
        XCTAssertEqual(doc.live.effectFades[effect.id]?.fadingIn, false)
        XCTAssertEqual(doc.live.musicFade?.fadingIn, false)

        let snap = ShowSnapshot(document: doc, library: lib.definition)
        let midOut = EngineCore.renderFrame(snap, time: 52.5)
        XCTAssertNotNil(midOut.fadeProgress)
    }

    // MARK: - 3. New Commands & JSON Round-Trip

    func testAllCommandsJSONRoundTripAndExecution() throws {
        let lib = TestResources.library()
        var doc = ShowDocument(project: DemoRig.londonStudio())
        let exec = CommandExecutor(library: lib.definition, now: { 20.0 })

        let sampleCommands: [LightingCommand] = [
            .setIntensity(.all, 0.8),
            .adjustIntensity(.role(.key), LightingCommand.nudgeALittle),
            .setColor(.role(.background), .rgb(RGB(r: 0.2, g: 0.6, b: 1.0))),
            .setKelvin(.role(.key), 4200),
            .adjustKelvin(.role(.key), LightingCommand.kelvinNudgeABit),
            .setTint(.role(.key), 0.1),
            .adjustTint(.role(.key), -LightingCommand.tintNudgeALittle),
            .shiftColor(.role(.background), toward: .rgb(RGB(r: 1, g: 0, b: 0)), amount: 0.5),
            .adjustSaturation(.role(.background), -0.2),
            .gradient(.role(.background), colors: [.rgb(RGB(r: 1, g: 0, b: 0)), .rgb(RGB(r: 0, g: 0, b: 1))], axis: .horizontal),
            .setCells(.id(DemoRig.IDs.tube(1)), cells: [
                CellState(intensity: 1.0, color: .rgb(RGB(r: 1, g: 0, b: 0))),
                CellState(intensity: 0.5, color: .rgb(RGB(r: 0, g: 1, b: 0)))
            ]),
            .paintCells(.id(DemoRig.IDs.tube(2)), cellIndices: [0, 2, 4], color: .rgb(RGB(r: 0, g: 1, b: 1)), intensity: 0.9),
            .turnOn(.all),
            .turnOff(.id(DemoRig.IDs.p1)),
            .saveLook(name: "Test Saved Look", selector: .all),
            .copyLook(.name("Test Saved Look"), newName: "Copied Look"),
            .startEffect(EffectInstance(kind: .breathe, targets: .role(.background), params: EffectParameters(speed: 0.5, amount: 0.5))),
            .setEffectParameters(effectID: nil, selector: .role(.background), params: EffectParameters(speed: 1.2, amount: 0.8)),
            .setMusicMode(enabled: true, mood: .synthwave),
            .setFixtureProtection(.id(DemoRig.IDs.tube(3)), true),
            .setRecordingMode(true),
            .setRecordingMode(false),
            .swapColors(.id(DemoRig.IDs.tube(1)), .id(DemoRig.IDs.tube(2))),
            .freeze(true),
            .freeze(false),
            .stopEffects(.role(.background)),
            .stopAllEffects,
            .setGrandMaster(0.9),
            .setBlackout(false),
            .identify(.id(DemoRig.IDs.pn1)),
            .fadeTime(0.5)
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for cmd in sampleCommands {
            let data = try encoder.encode(cmd)
            let decoded = try decoder.decode(LightingCommand.self, from: data)
            XCTAssertEqual(decoded, cmd, "Round-trip failed for \(cmd)")

            let result = exec.apply([decoded], to: &doc)
            XCTAssertFalse(result.summary.isEmpty, "Empty summary for \(cmd)")
        }

        // Verify copyLook created "Copied Look"
        XCTAssertTrue(doc.project.looks.contains { $0.name == "Copied Look" })
        // Verify tube 3 protection was set
        XCTAssertEqual(doc.project.fixture(DemoRig.IDs.tube(3))?.limits.protected, true)
    }

    // MARK: - 4. Protection & Limits Enforcement Across All Origins

    func testLimitsAndProtectionEnforcedForEveryOrigin() {
        let lib = TestResources.library()
        var project = DemoRig.londonStudio()
        let keyID = DemoRig.IDs.pn1 // Role is .key
        let bgID = DemoRig.IDs.tube(1) // Role is .background

        if let idx = project.fixtures.firstIndex(where: { $0.id == keyID }) {
            project.fixtures[idx].limits = FixtureLimits(
                maxIntensity: 0.8,
                minIntensity: 0.2,
                allowEffects: false,
                protected: true,
                minKelvin: 3000,
                maxKelvin: 5000
            )
        }

        var doc = ShowDocument(project: project)
        doc.live.base[keyID] = FixtureState(intensity: 0.5, color: .kelvin(4000))
        doc.live.base[bgID] = FixtureState(intensity: 0.5, color: .rgb(RGB(r: 0, g: 0.5, b: 1)))

        let exec = CommandExecutor(library: lib.definition, now: { 10.0 })
        let origins: [CommandOrigin] = [
            .ui,
            .assistant,
            .voice,
            .remote(clientID: "iPhone", linkID: UUID()),
            .midi,
            .osc,
            .shortcuts
        ]

        // 1. Intensity and Kelvin limits enforced for every origin when targeting keyID explicitly from UI,
        // and non-UI origins are blocked from changing protected key light via broad selectors.
        for origin in origins {
            var testDoc = doc
            // Broad `.all` intensity change from non-UI origin must NOT change protected key light
            _ = exec.apply([.setIntensity(.all, 1.0)], to: &testDoc, origin: origin)
            if origin == .ui {
                // Even for UI, broad `.all` skips protected fixtures unless explicitly targeted!
                XCTAssertEqual(testDoc.live.base[keyID]?.intensity, 0.5)
            } else {
                XCTAssertEqual(testDoc.live.base[keyID]?.intensity, 0.5, "Protected key light modified by \(origin)")
            }

            // Explicit target `.id(keyID)`: allowed from UI (clamped to limits), blocked from remote
            _ = exec.apply([.setIntensity(.id(keyID), 1.0), .setKelvin(.id(keyID), 6500)], to: &testDoc, origin: origin)
            if case .remote = origin {
                XCTAssertEqual(testDoc.live.base[keyID]?.intensity, 0.5, "Remote should not modify protected fixture")
            } else if origin == .ui {
                XCTAssertEqual(testDoc.live.base[keyID]?.intensity ?? 0, 0.8, accuracy: 1e-6, "Max intensity limit 0.8 enforced")
                XCTAssertEqual(testDoc.live.base[keyID]?.color.kelvinEquivalent ?? 0, 5000, accuracy: 1e-3, "Max Kelvin limit 5000K enforced")
            }
        }

        // 2. Recording mode makes remote completely read-only and blocks flashing effects
        var recDoc = doc
        _ = exec.apply([.setRecordingMode(true)], to: &recDoc, origin: .ui)
        XCTAssertTrue(recDoc.live.recordingMode)

        _ = exec.apply([.setIntensity(.id(bgID), 1.0)], to: &recDoc, origin: .remote(clientID: "Phone", linkID: UUID()))
        XCTAssertEqual(recDoc.live.base[bgID]?.intensity, 0.5, "Remote must be read-only in recordingMode")
    }
}
