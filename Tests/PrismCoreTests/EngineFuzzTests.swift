import XCTest
import Foundation
@testable import PrismCore

/// Fuzz, soak and performance tests for the show engine: hostile commands and files must never crash,
/// never produce NaN / out-of-range values, and frames must stay inside the budget.
final class EngineFuzzTests: XCTestCase {

    private func caseName(_ command: LightingCommand) -> String {
        String(String(describing: command).prefix { $0 != "(" })
    }

    // MARK: - Commands

    func testHostileCommandSequencesNeverCrashOrProduceInvalidOutput() {
        let lib = TestResources.library()
        var kindsSeen = Set<String>()
        for seed in 0..<100 {
            var doc = ShowDocument(project: DemoRig.londonStudio())
            var t = 100.0
            let exec = CommandExecutor(library: lib.definition, now: { t }, defaultFade: seed % 3 == 0 ? 0 : 0.4)
            var fuzzer = CommandFuzzer(seed: UInt64(seed) &* 0x9E37_79B9 &+ 17, mode: seed % 2 == 0 ? .hostile : .realistic)
            var last = RenderedFrame.empty
            let selection = Array(doc.project.fixtures.prefix(2).map(\.id))
            for step in 0..<25 {
                let batch = fuzzer.nextBatch(in: doc, maxCount: 4)
                batch.forEach { kindsSeen.insert(caseName($0)) }
                let origin = fuzzer.nextOrigin()
                exec.apply(batch, to: &doc, selection: selection, currentRendered: last.preMasterStates, origin: origin)
                t += step % 7 == 0 ? 1.5 : 0.05
                if let v = EngineInvariants.violation(in: doc) {
                    return XCTFail("seed \(seed) step \(step) (\(origin.displayName)): \(v)\nbatch: \(batch)")
                }
                let frame = EngineCore.renderFrame(ShowSnapshot(document: doc, library: lib.definition),
                                                   time: t, frameNumber: UInt64(step))
                if let v = EngineInvariants.violation(in: frame) {
                    return XCTFail("seed \(seed) step \(step) (\(origin.displayName)): \(v)\nbatch: \(batch)")
                }
                last = frame
                if doc.project.looks.count > 60 { doc.project.looks.removeLast(doc.project.looks.count - 60) }
                doc.live.pruneExpired(at: t)
            }
        }
        XCTAssertEqual(kindsSeen.count, CommandFuzzer.commandKindCount, "fuzzer must cover every command: \(kindsSeen.sorted())")
    }

    func testEveryCommandKindRoundTripsThroughJSON() throws {
        let doc = ShowDocument(project: DemoRig.londonStudio())
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var names = Set<String>()
        for mode in [CommandFuzzer.Mode.realistic, .hostile] {
            var fuzzer = CommandFuzzer(seed: mode == .realistic ? 1 : 2, mode: mode)
            for kind in 0..<CommandFuzzer.commandKindCount {
                for _ in 0..<12 {
                    let cmd = fuzzer.command(kind: kind, in: doc)
                    names.insert(caseName(cmd))
                    guard let data = try? encoder.encode(cmd) else {
                        XCTAssertEqual(mode, .hostile, "realistic command failed to encode: \(cmd)")
                        continue // non-finite numbers can't be JSON
                    }
                    let decoded: LightingCommand
                    do { decoded = try decoder.decode(LightingCommand.self, from: data) } catch {
                        XCTAssertEqual(mode, .hostile, "realistic command failed to decode: \(cmd) – \(error)")
                        continue
                    }
                    XCTAssertEqual(caseName(decoded), caseName(cmd))
                    // Decoding normalizes at most once: a second round trip is stable.
                    let again = try decoder.decode(LightingCommand.self, from: encoder.encode(decoded))
                    XCTAssertEqual(again, decoded, "unstable round trip for \(cmd)")
                }
            }
        }
        XCTAssertEqual(names.count, CommandFuzzer.commandKindCount)
    }

    func testHostileCommandJSONNeverCrashesDecoderOrExecutor() throws {
        let lib = TestResources.library()
        let encoder = JSONEncoder()
        var doc = ShowDocument(project: DemoRig.londonStudio())
        let exec = CommandExecutor(library: lib.definition, now: { 50 })
        var fuzzer = CommandFuzzer(seed: 99, mode: .realistic)
        var rng = SplitMix64(seed: 0xBAD_C0DE)
        var decodedCount = 0
        for i in 0..<400 {
            let cmd = fuzzer.command(kind: i % CommandFuzzer.commandKindCount, in: doc)
            let data = try encoder.encode(cmd)
            let tree = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let mutated = mutate(tree, rng: &rng)
            guard JSONSerialization.isValidJSONObject(mutated),
                  let hostile = try? JSONSerialization.data(withJSONObject: mutated) else { continue }
            guard let decoded = try? JSONDecoder().decode(LightingCommand.self, from: hostile) else { continue }
            decodedCount += 1
            exec.apply(decoded, to: &doc, origin: .remote(clientID: "fuzz", linkID: UUID()))
            XCTAssertNil(EngineInvariants.violation(in: doc), "after \(decoded)")
            if doc.project.looks.count > 60 { doc.project.looks.removeLast(doc.project.looks.count - 60) }
        }
        let frame = EngineCore.renderFrame(ShowSnapshot(document: doc, library: lib.definition), time: 51)
        XCTAssertNil(EngineInvariants.violation(in: frame))
        XCTAssertGreaterThan(decodedCount, 0)
    }

    // MARK: - Project files

    func testHostileProjectFilesNeverCrashAndAlwaysRenderSaneFrames() throws {
        let lib = TestResources.library()
        var base = DemoRig.londonStudio()
        base.folders = [LookFolder(name: "Interviews"), LookFolder(name: "Music")]
        base.lastLive = ShowDocument(project: base).live.snapshot
        let baseData = try ProjectIO.data(for: base, library: lib.definition)
        let baseTree = try JSONSerialization.jsonObject(with: baseData)
        var rng = SplitMix64(seed: 0xF022_1E57)
        var decoded = 0
        var rejected = 0

        for iteration in 0..<160 {
            var data: Data
            switch iteration % 5 {
            case 0: // random byte corruption
                var bytes = [UInt8](baseData)
                for _ in 0..<(1 + rng.nextInt(8)) {
                    bytes[rng.nextInt(bytes.count)] = UInt8(truncatingIfNeeded: rng.next())
                }
                data = Data(bytes)
            case 1: // truncated file (crash mid-write without atomic saves)
                data = baseData.prefix(rng.nextInt(baseData.count))
            default: // structural JSON mutations
                var tree: Any = baseTree
                for _ in 0..<(1 + rng.nextInt(4)) { tree = mutate(tree, rng: &rng) }
                guard JSONSerialization.isValidJSONObject(tree),
                      let mutated = try? JSONSerialization.data(withJSONObject: tree) else { continue }
                data = mutated
            }
            do {
                let report = try ProjectIO.decodeWithReport(data)
                decoded += 1
                try assertUsable(report.project, lib: lib, context: "iteration \(iteration)")
            } catch let error as ProjectIOError {
                rejected += 1
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
        XCTAssertGreaterThan(decoded, 50, "most structural corruption should be repaired, not rejected")
        XCTAssertGreaterThan(rejected, 0)
    }

    /// A repaired project must render sane frames, accept commands, and save/reopen.
    private func assertUsable(_ project: Project, lib: FixtureLibrary, context: String) throws {
        var doc = ShowDocument(project: project)
        if let snap = project.lastLive { doc.live = LiveState(snapshot: snap) }
        let frame = EngineCore.renderFrame(ShowSnapshot(document: doc, library: lib.definition), time: 5, frameNumber: 1)
        XCTAssertNil(EngineInvariants.violation(in: frame), context)

        let exec = CommandExecutor(library: lib.definition, now: { 5 })
        exec.apply([.setIntensity(.all, 0.7), .recallLook(.name(project.looks.first?.name ?? "x"), fade: 0)], to: &doc)
        XCTAssertNil(EngineInvariants.violation(in: doc), context)
        let after = EngineCore.renderFrame(ShowSnapshot(document: doc, library: lib.definition), time: 6, frameNumber: 2)
        XCTAssertNil(EngineInvariants.violation(in: after), context)

        let saved = try ProjectIO.data(for: project, library: lib.definition)
        let reopened = try ProjectIO.decodeWithReport(saved)
        XCTAssertEqual(reopened.project.fixtures.count, project.fixtures.count, context)
        XCTAssertEqual(reopened.project.looks.count, project.looks.count, context)
    }

    /// Replaces / deletes / duplicates a random node in a JSON tree.
    private func mutate(_ node: Any, rng: inout SplitMix64, depth: Int = 0) -> Any {
        if depth > 12 || (depth > 0 && rng.chance(0.25)) { return hostileValue(&rng) }
        if var dict = node as? [String: Any], !dict.isEmpty {
            let keys = dict.keys.sorted()
            let key = keys[rng.nextInt(keys.count)]
            if rng.chance(0.15) {
                dict[key] = nil
                return dict
            }
            dict[key] = mutate(dict[key] ?? NSNull(), rng: &rng, depth: depth + 1)
            return dict
        }
        if var array = node as? [Any], !array.isEmpty {
            let i = rng.nextInt(array.count)
            if rng.chance(0.1) {
                array.append(contentsOf: Array(repeating: array[i], count: 50))
                return array
            }
            if rng.chance(0.1) {
                array.remove(at: i)
                return array
            }
            array[i] = mutate(array[i], rng: &rng, depth: depth + 1)
            return array
        }
        return hostileValue(&rng)
    }

    private func hostileValue(_ rng: inout SplitMix64) -> Any {
        switch rng.nextInt(12) {
        case 0: return NSNull()
        case 1: return "💥 not what you expected"
        case 2: return -1
        case 3: return 1e308
        case 4: return Int.max
        case 5: return [Any]()
        case 6: return [String: Any]()
        case 7: return true
        case 8:
            var deep: Any = [Any]()
            for _ in 0..<200 { deep = [deep] }
            return deep
        case 9: return String(repeating: "A", count: 100_000)
        case 10: return -1e308
        default: return Int.min
        }
    }

    // MARK: - Soak & performance

    func testSoakRunnerHeadless() {
        let lib = TestResources.library()
        #if DEBUG
        let budget = 250.0 // unoptimized builds on shared CI machines; the release app is held to 25 ms
        #else
        let budget = EngineStats.frameBudgetMs
        #endif
        let report = EngineSoakRunner.run(durationSeconds: 30, library: lib.definition, frameRate: 40,
                                          maxAllowedFrameMs: budget, realTime: false)
        XCTAssertTrue(report.passed, report.summaryLine)
        XCTAssertEqual(report.framesRendered, 1200)
        XCTAssertGreaterThan(report.commandsApplied, 400)
        XCTAssertGreaterThan(report.looksRecalled, 0)
        XCTAssertTrue(report.summaryLine.hasPrefix("SOAK PASSED"), report.summaryLine)
        XCTAssertLessThanOrEqual(report.medianFrameDurationMs, report.p95FrameDurationMs)
        XCTAssertLessThanOrEqual(report.p95FrameDurationMs, report.p99FrameDurationMs)
        XCTAssertLessThanOrEqual(report.p99FrameDurationMs, report.maxFrameDurationMs)
    }

    func testBenchmark16Universes200Fixtures20Effects() {
        let lib = TestResources.library()
        let doc = EngineBenchmark.stressDocument(fixtureCount: 200, universes: 16, effectCount: 20)
        let snap = ShowSnapshot(document: doc, library: lib.definition)
        XCTAssertEqual(snap.fixtures.count, 200)
        let prepared = EngineCore.prepare(snap)
        _ = EngineCore.renderFrame(prepared, audio: .silent, time: 0, frameNumber: 0) // warm up

        var renderMs: [Double] = []
        for frame in 0..<80 {
            let t0 = PrismClock.now()
            let out = EngineCore.renderFrame(prepared, audio: .silent, time: Double(frame) / 40.0, frameNumber: UInt64(frame))
            renderMs.append((PrismClock.now() - t0) * 1000.0)
            XCTAssertEqual(out.universes.count, 16)
            if frame == 0 { XCTAssertNil(EngineInvariants.violation(in: out)) }
        }
        var prepareMs: [Double] = []
        for _ in 0..<10 {
            let t0 = PrismClock.now()
            _ = EngineCore.prepare(ShowSnapshot(document: doc, library: lib.definition))
            prepareMs.append((PrismClock.now() - t0) * 1000.0)
        }
        renderMs.sort()
        prepareMs.sort()
        let median = EngineSoakRunner.percentile(renderMs, 0.5)
        let p95 = EngineSoakRunner.percentile(renderMs, 0.95)
        let prepareMedian = EngineSoakRunner.percentile(prepareMs, 0.5)
        print(String(format: "PERF 16U/200F/20E render median %.3f ms p95 %.3f ms; snapshot+prepare median %.3f ms",
                     median, p95, prepareMedian))
        #if DEBUG
        // Unoptimized debug builds (~6x slower than release) on shared CI VMs get a generous ceiling that
        // still catches O(N²) regressions; the release build is held to the brief's 2 ms.
        let budgetMs = 150.0
        #else
        let budgetMs = 2.0 // brief: < 2 ms per frame in release
        #endif
        XCTAssertLessThan(median, budgetMs, String(format: "render median %.2f ms (p95 %.2f ms) over %.1f ms", median, p95, budgetMs))
        XCTAssertLessThan(prepareMedian, budgetMs * 4, String(format: "snapshot+prepare median %.2f ms", prepareMedian))
    }

    func testCommandApplyStaysFastOnLargeRig() {
        let lib = TestResources.library()
        var doc = EngineBenchmark.stressDocument(fixtureCount: 200, universes: 16, effectCount: 20)
        let exec = CommandExecutor(library: lib.definition, now: { 10 }, defaultFade: 0.5)
        var fuzzer = CommandFuzzer(seed: 7, mode: .realistic)
        var worstMs = 0.0
        for _ in 0..<150 {
            let batch = fuzzer.nextBatch(in: doc, maxCount: 3)
            let t0 = PrismClock.now()
            exec.apply(batch, to: &doc)
            worstMs = max(worstMs, (PrismClock.now() - t0) * 1000)
            if doc.project.looks.count > 20 { doc.project.looks.removeLast(doc.project.looks.count - 20) }
        }
        XCTAssertNil(EngineInvariants.violation(in: doc))
        #if DEBUG
        XCTAssertLessThan(worstMs, 250)
        #else
        XCTAssertLessThan(worstMs, 25)
        #endif
    }
}
