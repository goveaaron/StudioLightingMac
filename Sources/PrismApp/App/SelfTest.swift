import Foundation
import AppKit
import PrismCore

/// Built-in self test: `Prism --self-test` runs every registered check inside the real app
/// process (CI) and exits 0 on success. The same checks power Help ▸ Run Diagnostics.
/// Each workstream registers checks in its own `<Feature>SelfTest.swift`.
@MainActor
enum SelfTest {
    struct Check {
        let name: String
        /// Returns nil on success or a failure description.
        let run: @MainActor (AppModel) async -> String?
    }

    struct Result: Codable {
        var name: String
        var passed: Bool
        var detail: String?
        var durationMs: Double
    }

    static var allChecks: [Check] {
        coreChecks + OutputSelfTest.checks + MusicSelfTest.checks + RemoteSelfTest.checks
            + AssistantSelfTest.checks + CameraSelfTest.checks + PatchSelfTest.checks
            + StageSelfTest.checks + InspectorSelfTest.checks + LooksSelfTest.checks
            + OnboardingSelfTest.checks + EffectsSelfTest.checks
    }

    static var coreChecks: [Check] {
        [
            Check(name: "library.loaded") { app in
                app.library.count >= 8 ? nil : "Only \(app.library.count) fixture definitions loaded: \(app.library.problems)"
            },
            Check(name: "demo.resolves") { app in
                let n = app.show.resolvedFixtures.count
                return n == app.show.fixtures.count && n > 0 ? nil : "Resolved \(n) of \(app.show.fixtures.count) fixtures"
            },
            Check(name: "engine.running") { app in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let s = app.engine.stats
                return s.measuredFPS > app.engine.frameRate * 0.75 ? nil : "Engine at \(s.measuredFPS) fps"
            },
            Check(name: "engine.frameBudget") { app in
                // Measure the renderer directly (the live max includes app-launch hiccups).
                // Shared CI runners are noisy, so warm up first and keep the best of three batches.
                let snapshot = app.engine.currentSnapshot
                let start = PrismClock.now()
                for i in 0..<20 { _ = EngineCore.renderFrame(snapshot, time: start + Double(i) / 40) }
                var best = (median: Double.infinity, p95: Double.infinity)
                for batch in 0..<3 {
                    var durations: [Double] = []
                    durations.reserveCapacity(120)
                    for i in 0..<120 {
                        let t = start + Double(batch * 120 + i) / 40
                        let t0 = PrismClock.now()
                        _ = EngineCore.renderFrame(snapshot, time: t)
                        durations.append((PrismClock.now() - t0) * 1000)
                    }
                    durations.sort()
                    let median = durations[durations.count / 2]
                    let p95 = durations[min(durations.count - 1, Int(Double(durations.count) * 0.95))]
                    if p95 < best.p95 { best = (median, p95) }
                    await Task.yield()
                }
                #if DEBUG
                let budget = (median: 25.0, p95: 50.0)   // unoptimized build: only catch pathological regressions
                #else
                let budget = (median: 3.0, p95: 6.0)
                #endif
                let ok = best.median < budget.median && best.p95 < budget.p95
                return ok ? nil : String(format: "Frame p95 %.2f ms (median %.2f ms), budget p95 %.0f ms / median %.0f ms",
                                         best.p95, best.median, budget.p95, budget.median)
            },
            Check(name: "look.recall.dmx") { app in
                guard let look = app.show.looks.first(where: { $0.name == "Chill Vibes 4" }) else { return "Demo look missing" }
                app.show.recallLook(look.id, fade: 0)
                app.engine.tick()
                let u = app.engine.latestFrame.universes[1] ?? []
                guard u.count == 512 else { return "Universe 1 missing" }
                return u[0] == 255 && u[1] == 255 ? nil : "Unexpected DMX: \(Array(u.prefix(6)))"
            },
            Check(name: "undo.redo") { app in
                let before = app.show.document.live.base
                app.show.updateStates([DemoRig.IDs.pn1], undoName: "Test") { _, s in s.intensity = 0.42 }
                app.show.undo()
                let restored = app.show.document.live.base == before
                app.show.redo()
                let redone = app.show.state(of: DemoRig.IDs.pn1).intensity == 0.42
                app.show.undo()
                return restored && redone ? nil : "Undo/redo mismatch"
            },
            Check(name: "project.roundtrip") { app in
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-\(UUID().uuidString).prismlights")
                defer { try? FileManager.default.removeItem(at: url) }
                do {
                    try ProjectIO.write(app.show.projectForSaving(), to: url, library: app.library.lookup)
                    let back = try ProjectIO.read(from: url)
                    return back.fixtures.count == app.show.fixtures.count && back.looks.count == app.show.looks.count
                        ? nil : "Round trip lost data"
                } catch {
                    return "Save/load failed: \(error.localizedDescription)"
                }
            },
            Check(name: "commands.roleColor") { app in
                let r = app.show.apply(.setColor(.role(.background), .hex("#00C2A8")!))
                return r.affectedFixtureIDs.count >= 1 ? nil : "No background fixtures affected"
            },
        ]
    }

    static func runAll(app: AppModel) async -> [Result] {
        var results: [Result] = []
        for check in allChecks {
            let start = Date()
            let failure = await check.run(app)
            results.append(Result(name: check.name, passed: failure == nil, detail: failure,
                                  durationMs: Date().timeIntervalSince(start) * 1000))
        }
        return results
    }

    static func runAndExit(app: AppModel) async {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let results = await runAll(app: app)
        for r in results {
            print("\(r.passed ? "PASS" : "FAIL") \(r.name)\(r.detail.map { " — \($0)" } ?? "") (\(Int(r.durationMs)) ms)")
        }
        let failed = results.filter { !$0.passed }.count
        print("SELFTEST \(failed == 0 ? "PASSED" : "FAILED"): \(results.count - failed)/\(results.count)")
        fflush(stdout)
        app.shutdown()
        exit(failed == 0 ? 0 : 1)
    }
}
