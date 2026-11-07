import Foundation
import PrismCore

/// `Prism --soak [SECONDS]`: drives the running app (real engine timer, ShowController, undo history,
/// looks) with random realistic commands from every origin, then checks the engine's frame budget,
/// engine stalls and memory growth. Automated runs never autosave, so the user's session is untouched.
/// Prints one `SOAK PASSED|FAILED …` line and exits 0 (pass) or 1 (fail).
@MainActor
enum SoakRunner {
    /// A gap between engine ticks this long means the engine queue was blocked, not just timer jitter.
    static let maxTickGapMs = 500.0
    /// Command batches per second (a busy operator, a remote and the assistant at once).
    static let batchesPerSecond = 13.0
    /// Looks created by the soak beyond this many are trimmed so the project stays bounded.
    static let maxExtraLooks = 16

    static func runAndExit(app: AppModel, seconds: Double) async {
        let duration = seconds.isFinite ? min(max(seconds, 5), 24 * 3600) : 60
        let warmup = min(3.0, duration * 0.25)
        let seed = UInt64(truncatingIfNeeded: Int64(Date().timeIntervalSince1970 * 1000))
        var fuzzer = CommandFuzzer(seed: seed, mode: .realistic)
        let baseLooks = app.show.looks.count
        let interval = UInt64(1_000_000_000 / batchesPerSecond)

        let start = PrismClock.now()
        var measuringSince: Double?
        var framesAtStart: UInt64 = 0
        var commands = 0
        var iteration = 0
        var looksRecalled = 0
        var rssSamples: [Int64] = []
        var lastSample = start

        while true {
            let now = PrismClock.now()
            let elapsed = now - start
            if elapsed >= warmup + duration { break }
            if measuringSince == nil, elapsed >= warmup {
                // Measure only after caches, allocator pools and the timer have settled.
                app.engine.resetPeakStats()
                framesAtStart = app.engine.stats.framesRendered
                measuringSince = now
                lastSample = now
                rssSamples.append(EngineSoakRunner.currentResidentBytes())
            }

            let batch = fuzzer.nextBatch(in: app.show.document, maxCount: 3)
            app.show.apply(batch, origin: fuzzer.nextOrigin())
            commands += batch.count
            iteration += 1
            if iteration % 26 == 0, let look = fuzzer.rng.pick(app.show.looks) {
                // Every ~2 s: a look recall with a random crossfade, interrupting fades in flight.
                app.show.recallLook(look.id, fade: fuzzer.rng.nextUnit() * 3, origin: fuzzer.nextOrigin())
                looksRecalled += 1
            }

            if app.show.looks.count > baseLooks + maxExtraLooks {
                app.show.editProject("Soak Cleanup", change: [.looks]) { project in
                    let extra = project.looks.count - baseLooks
                    if extra > 0 { project.looks.removeLast(extra) }
                }
            }
            if measuringSince != nil, now - lastSample >= 1 {
                rssSamples.append(EngineSoakRunner.currentResidentBytes())
                lastSample = now
            }
            try? await Task.sleep(nanoseconds: interval)
        }

        rssSamples.append(EngineSoakRunner.currentResidentBytes())
        let stats = app.engine.stats
        let measured = max(0.001, PrismClock.now() - (measuringSince ?? start))
        let frames = stats.framesRendered >= framesAtStart ? stats.framesRendered - framesAtStart : 0
        let growth = memoryGrowth(rssSamples)

        var failures: [String] = []
        if frames == 0 { failures.append("the engine rendered no frames") }
        if stats.peakFrameDurationMs > EngineStats.frameBudgetMs {
            failures.append("a frame took \(format(stats.peakFrameDurationMs)) ms (budget \(format(EngineStats.frameBudgetMs)) ms)")
        }
        if stats.maxTickIntervalMs > maxTickGapMs {
            failures.append("the engine stalled for \(format(stats.maxTickIntervalMs)) ms")
        }
        if growth > EngineSoakRunner.maxMemoryGrowthBytes {
            failures.append("memory grew \(format(megabytes(growth))) MB")
        }

        var line = "SOAK \(failures.isEmpty ? "PASSED" : "FAILED"): \(Int(duration)) s, \(commands) commands, "
            + "\(looksRecalled) look recalls, \(frames) frames (\(format(Double(frames) / measured)) fps), "
            + "peak frame \(format(stats.peakFrameDurationMs)) ms, \(stats.framesOverBudget) over budget, "
            + "max tick gap \(format(stats.maxTickIntervalMs)) ms, memory \(growth >= 0 ? "+" : "")\(format(megabytes(growth))) MB"
        if !failures.isEmpty { line += " — " + failures.joined(separator: "; ") }
        print(line)
        fflush(stdout)
        app.shutdown()
        exit(failures.isEmpty ? 0 : 1)
    }

    /// Resident-memory growth that ignores transient spikes: the lowest of the last few samples minus
    /// the lowest of the first few.
    static func memoryGrowth(_ samples: [Int64]) -> Int64 {
        let valid = samples.filter { $0 > 0 }
        guard valid.count >= 2 else { return 0 }
        let window = max(1, min(3, valid.count / 2))
        let first = valid.prefix(window).min() ?? 0
        let last = valid.suffix(window).min() ?? 0
        return last - first
    }

    private static func megabytes(_ bytes: Int64) -> Double { Double(bytes) / 1_048_576 }

    private static func format(_ value: Double) -> String {
        value.isFinite ? String(format: "%.1f", value) : "?"
    }
}
