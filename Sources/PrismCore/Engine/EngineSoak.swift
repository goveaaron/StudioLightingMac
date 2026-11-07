import Foundation

// MARK: - Deterministic randomness

/// Deterministic fast PRNG for soak and fuzz tests.
public struct SplitMix64: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { self.state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `[0, 1)`.
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Uniform integer in `0..<upperBound` (0 when `upperBound <= 0`).
    public mutating func nextInt(_ upperBound: Int) -> Int {
        upperBound <= 0 ? 0 : Int(next() % UInt64(upperBound))
    }

    public mutating func chance(_ probability: Double) -> Bool {
        nextUnit() < probability
    }

    public mutating func pick<T>(_ items: [T]) -> T? {
        items.isEmpty ? nil : items[nextInt(items.count)]
    }
}

// MARK: - Command fuzzer

/// Generates random `LightingCommand`s covering every case, either realistic (soak) or hostile
/// (NaN/∞/huge/negative values, empty and oversized arrays, bogus ids/names, deep selectors) for fuzzing.
public struct CommandFuzzer: Sendable {
    public enum Mode: Sendable { case realistic, hostile }

    /// Number of distinct command kinds (one per `LightingCommand` case).
    public static let commandKindCount = 30

    public var rng: SplitMix64
    public let mode: Mode
    public let linkID: UUID

    public init(seed: UInt64, mode: Mode = .realistic, linkID: UUID = UUID()) {
        self.rng = SplitMix64(seed: seed)
        self.mode = mode
        self.linkID = linkID
    }

    /// Any of the origins the executor distinguishes.
    public mutating func nextOrigin() -> CommandOrigin {
        switch rng.nextInt(9) {
        case 0: return .ui
        case 1: return .assistant
        case 2: return .voice
        case 3: return .remote(clientID: mode == .hostile && rng.chance(0.3) ? "" : "fuzz-ipad", linkID: linkID)
        case 4: return .midi
        case 5: return .osc
        case 6: return .http
        case 7: return .shortcuts
        default: return .system
        }
    }

    public mutating func nextBatch(in doc: ShowDocument, maxCount: Int = 3) -> [LightingCommand] {
        let count = 1 + rng.nextInt(max(1, maxCount))
        var batch: [LightingCommand] = []
        batch.reserveCapacity(count)
        for _ in 0..<count { batch.append(nextCommand(in: doc)) }
        return batch
    }

    public mutating func nextCommand(in doc: ShowDocument) -> LightingCommand {
        command(kind: rng.nextInt(Self.commandKindCount), in: doc)
    }

    /// A random command of kind `kind` (`0..<commandKindCount`), so tests can cover every case.
    public mutating func command(kind: Int, in doc: ShowDocument) -> LightingCommand {
        let sel = selector(in: doc)
        switch kind {
        case 0: return .setIntensity(sel, value(0...1))
        case 1: return .adjustIntensity(sel, value(-0.3...0.3))
        case 2: return .setColor(sel, color())
        case 3: return .setKelvin(sel, value(2000...10000))
        case 4: return .adjustKelvin(sel, value(-1500...1500))
        case 5: return .setTint(sel, value(-1...1))
        case 6: return .adjustTint(sel, value(-0.3...0.3))
        case 7: return .shiftColor(sel, toward: color(), amount: value(0...1))
        case 8: return .adjustSaturation(sel, value(-0.3...0.3))
        case 9: return .gradient(sel, colors: colors(), axis: rng.pick(GradientAxis.allCases) ?? .horizontal)
        case 10: return .setCells(sel, cells: cells())
        case 11: return .paintCells(sel, cellIndices: cellIndices(), color: color(), intensity: rng.chance(0.5) ? value(0...1) : nil)
        case 12: return .turnOn(sel)
        case 13: return .turnOff(sel)
        case 14: return .recallLook(lookReference(in: doc), fade: rng.chance(0.3) ? nil : value(0...2))
        case 15: return .saveLook(name: name(), selector: sel)
        case 16: return .copyLook(lookReference(in: doc), newName: rng.chance(0.5) ? name() : nil)
        case 17: return .startEffect(effect(in: doc))
        case 18: return .setEffectParameters(effectID: effectID(in: doc), selector: sel, params: params())
        case 19: return .stopEffects(sel)
        case 20: return .stopAllEffects
        case 21: return .setMusicMode(enabled: rng.chance(0.3), mood: rng.chance(0.7) ? rng.pick(MusicMood.allCases) : nil)
        case 22: return .setFixtureProtection(sel, rng.chance(0.5))
        case 23: return .setRecordingMode(rng.chance(0.25))
        case 24: return .freeze(rng.chance(0.15))
        case 25: return .swapColors(sel, rng.chance(0.5) ? selector(in: doc) : nil)
        case 26: return .setGrandMaster(value(0.4...1))
        case 27: return .setBlackout(rng.chance(0.1))
        case 28: return .identify(sel)
        default: return .fadeTime(value(0...3))
        }
    }

    // MARK: Values

    private static let hostileDoubles: [Double] = [
        .nan, .infinity, -.infinity, -0.0, 0, 1, -1, 2, 0.5, 1e-320, -1e-320,
        .greatestFiniteMagnitude, -.greatestFiniteMagnitude, .leastNonzeroMagnitude,
        1e9, -1e9, 255, 256, 65_535, 1e15,
    ]

    private var isHostile: Bool { mode == .hostile }

    private mutating func value(_ range: ClosedRange<Double>) -> Double {
        if isHostile && rng.chance(0.6) {
            if rng.chance(0.75), let v = rng.pick(Self.hostileDoubles) { return v }
            return rng.nextUnit() * 2e6 - 1e6
        }
        return range.lowerBound + rng.nextUnit() * (range.upperBound - range.lowerBound)
    }

    private mutating func color() -> LightColor {
        switch rng.nextInt(4) {
        case 0: return .rgb(RGB(r: value(0...1), g: value(0...1), b: value(0...1)))
        case 1: return .kelvin(value(2000...10000), tint: value(-1...1))
        case 2: return .hsi(hue: value(0...360), saturation: value(0...1))
        default: return .xy(x: value(0.15...0.6), y: value(0.15...0.6))
        }
    }

    private mutating func count(realistic: ClosedRange<Int>, hostile: [Int]) -> Int {
        if isHostile && rng.chance(0.4), let n = rng.pick(hostile) { return n }
        return realistic.lowerBound + rng.nextInt(realistic.upperBound - realistic.lowerBound + 1)
    }

    private mutating func colors() -> [LightColor] {
        let n = count(realistic: 2...5, hostile: [0, 1, 300])
        var out: [LightColor] = []
        out.reserveCapacity(n)
        for _ in 0..<n { out.append(color()) }
        return out
    }

    private mutating func cells() -> [CellState] {
        let n = count(realistic: 1...16, hostile: [0, 1, 2000])
        var out: [CellState] = []
        out.reserveCapacity(n)
        for _ in 0..<n { out.append(CellState(intensity: value(0...1), color: color())) }
        return out
    }

    private mutating func cellIndices() -> [Int] {
        let n = count(realistic: 1...6, hostile: [0, 8])
        var out: [Int] = []
        for _ in 0..<n {
            if isHostile && rng.chance(0.5), let v = rng.pick([-1, Int.min, Int.max, 1_000_000, 0, 0, 5]) {
                out.append(v)
            } else {
                out.append(rng.nextInt(16))
            }
        }
        return out
    }

    private static let realisticNames = ["Warm Interview", "Cool Wash", "Soak A", "Soak B", "Podcast", "Sunset"]
    private static let hostileNames = [
        "", "   ", String(repeating: "x", count: 5000), "🎬💡🌈", "\u{0}\u{1}\u{7F}", "\u{202E}evil",
        "../../etc/passwd", "Look\nwith\nnewlines",
    ]

    private mutating func name() -> String {
        if isHostile && rng.chance(0.6), let n = rng.pick(Self.hostileNames) { return n }
        return rng.pick(Self.realisticNames) ?? "Look"
    }

    private mutating func lookReference(in doc: ShowDocument) -> LookReference {
        if isHostile && rng.chance(0.5) {
            switch rng.nextInt(3) {
            case 0: return .id(UUID())
            case 1: return .name("")
            default: return .name(String(repeating: "look ", count: 1000))
            }
        }
        guard let look = rng.pick(doc.project.looks) else { return .name("Nope") }
        return rng.chance(0.7) ? .id(look.id) : .name(look.name)
    }

    private mutating func selector(in doc: ShowDocument, depth: Int = 0) -> FixtureSelector {
        if isHostile && rng.chance(0.4) {
            switch rng.nextInt(9) {
            case 0:
                let n = rng.nextInt(4)
                return .fixtures((0..<n).map { _ in UUID() })
            case 1: return .fixtures([])
            case 2: return .none
            case 3: return .named("")
            case 4: return .named(String(repeating: "tube ", count: 2000))
            case 5: return .group(UUID())
            case 6:
                var s: FixtureSelector = .all
                let levels = 16 + rng.nextInt(48)
                for _ in 0..<levels { s = rng.chance(0.5) ? .union([s]) : .excluding(s, .none) }
                return s
            case 7: return .union(Array(repeating: .all, count: 200))
            default: return .intersection([])
            }
        }
        let fixtures = doc.project.fixtures
        switch rng.nextInt(depth < 2 ? 10 : 8) {
        case 0: return .all
        case 1: return .role(rng.pick(FixtureRole.allCases) ?? .other)
        case 2:
            guard !fixtures.isEmpty else { return .all }
            let n = 1 + rng.nextInt(min(4, fixtures.count))
            var ids: [UUID] = []
            for _ in 0..<n { if let f = rng.pick(fixtures) { ids.append(f.id) } }
            return .fixtures(ids)
        case 3:
            if let g = rng.pick(doc.project.groups) { return .group(g.id) }
            return .all
        case 4: return .category(rng.pick(FixtureCategory.allCases) ?? .tube)
        case 5: return .region(rng.pick(StageRegion.allCases) ?? .center)
        case 6: return .named(rng.pick(["tubes", "key", "background", "all lights", "panel", "left"]) ?? "tubes")
        case 7: return .selection
        case 8: return .union([selector(in: doc, depth: depth + 1), selector(in: doc, depth: depth + 1)])
        default: return .excluding(selector(in: doc, depth: depth + 1), selector(in: doc, depth: depth + 1))
        }
    }

    private mutating func params() -> EffectParameters {
        let paletteCount = isHostile && rng.chance(0.1) ? 400 : rng.nextInt(5)
        var palette: [LightColor] = []
        for _ in 0..<paletteCount { palette.append(color()) }
        var extra: [String: Double] = [:]
        if rng.chance(0.2) {
            extra["spread"] = value(0...1)
            if isHostile { extra[""] = value(0...1) }
        }
        return EffectParameters(
            speed: value(0.1...3), size: value(0...1), amount: value(0...1), palette: palette,
            direction: rng.pick(EffectDirection.allCases) ?? .leftToRight, phaseSpread: value(0...1),
            smoothness: value(0...1), minIntensity: value(0...0.3), maxIntensity: value(0.6...1), extra: extra
        )
    }

    private mutating func effectID(in doc: ShowDocument) -> UUID? {
        if isHostile && rng.chance(0.3) { return UUID() }
        return rng.chance(0.5) ? rng.pick(doc.live.effects)?.id : nil
    }

    private mutating func effect(in doc: ShowDocument) -> EffectInstance {
        let reuseID = rng.chance(0.3) ? rng.pick(doc.live.effects)?.id : nil
        return EffectInstance(
            id: reuseID ?? UUID(),
            kind: rng.pick(EffectKind.allCases) ?? .breathe,
            name: rng.chance(0.2) ? name() : nil,
            targets: selector(in: doc),
            params: params(),
            blend: rng.pick(EffectBlend.allCases) ?? .replace,
            enabled: rng.chance(0.9),
            audioReactive: rng.chance(0.3)
        )
    }
}

// MARK: - Invariants

/// Sanity checks shared by the soak runner, fuzz tests and self-tests.
public enum EngineInvariants {
    /// A description of the first violated invariant in `frame`, or nil when it's sane.
    public static func violation(in frame: RenderedFrame) -> String? {
        for (id, state) in frame.states {
            if let v = violation(in: state) { return "Light \(id.uuidString.prefix(8)): \(v)" }
        }
        for (id, state) in frame.preMasterStates {
            if let v = violation(in: state) { return "Light \(id.uuidString.prefix(8)) (pre-master): \(v)" }
        }
        for (universe, bytes) in frame.universes where bytes.count != 512 {
            return "Universe \(universe) has \(bytes.count) channels instead of 512."
        }
        if let p = frame.fadeProgress, !(p.isFinite && p >= 0 && p <= 1) {
            return "Fade progress \(p) is out of range."
        }
        return nil
    }

    public static func violation(in state: FixtureState) -> String? {
        if !state.intensity.isFinite || state.intensity < 0 || state.intensity > 1 { return "intensity \(state.intensity)" }
        if !isFinite(state.color) { return "non-finite color" }
        if let cells = state.cells {
            for (i, cell) in cells.enumerated() {
                if !cell.intensity.isFinite || cell.intensity < 0 || cell.intensity > 1 {
                    return "cell \(i) intensity \(cell.intensity)"
                }
                if !isFinite(cell.color) { return "cell \(i) has a non-finite color" }
            }
        }
        return nil
    }

    public static func isFinite(_ color: LightColor) -> Bool {
        let rgb = color.displayRGB
        return rgb.r.isFinite && rgb.g.isFinite && rgb.b.isFinite
    }

    /// Live-state invariants after commands.
    public static func violation(in doc: ShowDocument) -> String? {
        let live = doc.live
        if !live.grandMaster.isFinite || live.grandMaster < 0 || live.grandMaster > 1 {
            return "grand master \(live.grandMaster)"
        }
        for (id, state) in live.base.storage {
            if let v = violation(in: state) { return "Base state \(id.uuidString.prefix(8)): \(v)" }
        }
        for (id, fade) in live.fades {
            if !fade.startTime.isFinite || !fade.duration.isFinite || fade.duration < 0 || !fade.delay.isFinite || fade.delay < 0 {
                return "Fade \(id.uuidString.prefix(8)) has invalid timing."
            }
            if let v = violation(in: fade.from) { return "Fade \(id.uuidString.prefix(8)) source: \(v)" }
        }
        if live.effects.count > 64 { return "\(live.effects.count) live effects." }
        for effect in live.effects {
            let p = effect.params
            if ![p.speed, p.size, p.amount, p.phaseSpread, p.smoothness, p.minIntensity, p.maxIntensity].allSatisfy(\.isFinite) {
                return "Effect \(effect.displayName) has non-finite parameters."
            }
        }
        return nil
    }
}

// MARK: - Benchmark rig

public enum EngineBenchmark {
    /// A large synthetic rig (default: 16 universes, 200 fixtures, 20 effects) built from the demo
    /// rig's definitions, for performance tests.
    public static func stressDocument(fixtureCount: Int = 200, universes: Int = 16, effectCount: Int = 20) -> ShowDocument {
        var project = Project(name: "\(universes)-Universe Stress Rig")
        let defPairs: [(String, String)] = [
            (DemoRig.panelID, DemoRig.panelMode),
            (DemoRig.pixelTubeID, DemoRig.pixelTubeMode),
            (DemoRig.dimmerID, DemoRig.dimmerMode),
        ]
        let universeCount = max(1, universes)
        let roles = FixtureRole.allCases
        var fixtures: [PatchedFixture] = []
        fixtures.reserveCapacity(max(0, fixtureCount))
        for i in 0..<max(0, fixtureCount) {
            let slot = i / universeCount
            let (defID, modeName) = defPairs[i % defPairs.count]
            fixtures.append(PatchedFixture(
                id: UUID(),
                name: "Fixture \(i + 1)",
                shortName: "F\(i + 1)",
                definitionID: defID,
                modeName: modeName,
                universe: (i % universeCount) + 1,
                address: min(512, 1 + slot * 36),
                role: roles[i % roles.count],
                transform: StageTransform(x: Double(i % 20) * 0.25, y: Double(i / 20) * 0.8, rotation: 0)
            ))
        }
        project.fixtures = fixtures
        var doc = ShowDocument(project: project)
        for f in fixtures {
            doc.live.base[f.id] = FixtureState(intensity: 0.8, color: .rgb(RGB(r: 0.3, g: 0.6, b: 0.9)))
        }
        let kinds = EffectKind.allCases
        doc.live.effects = (0..<max(0, effectCount)).map { idx in
            EffectInstance(
                kind: kinds[idx % kinds.count],
                targets: .role(roles[idx % roles.count]),
                params: EffectParameters(speed: 1.0, amount: 0.6, phaseSpread: 0.5)
            )
        }
        return doc
    }
}

// MARK: - Soak runner

/// Runs a randomized command/look/effect soak test against `EngineCore` and verifies
/// frame budget (< 25 ms max frame time), memory stability, and frame/DMX invariants.
public enum EngineSoakRunner {
    public struct Report: Sendable, Equatable, Codable {
        public var durationSeconds: Double
        public var framesRendered: Int
        public var commandsApplied: Int
        public var looksRecalled: Int
        public var maxFrameDurationMs: Double
        public var medianFrameDurationMs: Double
        public var p95FrameDurationMs: Double
        public var p99FrameDurationMs: Double
        public var memoryGrowthBytes: Int64
        public var passed: Bool
        public var failureReason: String?

        public init(
            durationSeconds: Double,
            framesRendered: Int,
            commandsApplied: Int,
            looksRecalled: Int,
            maxFrameDurationMs: Double,
            medianFrameDurationMs: Double = 0,
            p95FrameDurationMs: Double,
            p99FrameDurationMs: Double = 0,
            memoryGrowthBytes: Int64,
            passed: Bool,
            failureReason: String? = nil
        ) {
            self.durationSeconds = durationSeconds
            self.framesRendered = framesRendered
            self.commandsApplied = commandsApplied
            self.looksRecalled = looksRecalled
            self.maxFrameDurationMs = maxFrameDurationMs
            self.medianFrameDurationMs = medianFrameDurationMs
            self.p95FrameDurationMs = p95FrameDurationMs
            self.p99FrameDurationMs = p99FrameDurationMs
            self.memoryGrowthBytes = memoryGrowthBytes
            self.passed = passed
            self.failureReason = failureReason
        }

        /// One greppable line, e.g. `SOAK PASSED 60.0s frames=2400 commands=800 looks=27 max=1.20ms …`.
        public var summaryLine: String {
            var line = (passed ? "SOAK PASSED" : "SOAK FAILED") + String(
                format: " %.1fs frames=%ld commands=%ld looks=%ld max=%.2fms p99=%.2fms p95=%.2fms median=%.2fms mem=%+.1fMB",
                durationSeconds, framesRendered, commandsApplied, looksRecalled,
                maxFrameDurationMs, p99FrameDurationMs, p95FrameDurationMs, medianFrameDurationMs,
                Double(memoryGrowthBytes) / 1_048_576
            )
            if let failureReason { line += " reason=\(failureReason)" }
            return line
        }
    }

    /// RSS growth tolerated after warm-up (allocator pages, caches).
    public static let maxMemoryGrowthBytes: Int64 = 32 * 1024 * 1024

    public static func currentResidentBytes() -> Int64 {
        #if os(Linux)
        if let status = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) {
            let parts = status.split(separator: " ")
            if parts.count > 1, let residentPages = Int64(parts[1]) {
                return residentPages * 4096
            }
        }
        return 0
        #elseif os(macOS)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kerr == KERN_SUCCESS ? Int64(info.resident_size) : 0
        #else
        return 0
        #endif
    }

    /// Value at quantile `q` (0…1) of an ascending array (0 when empty).
    public static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = Int((Double(sorted.count - 1) * clamp(q.finiteOr(0.5), 0, 1)).rounded())
        return sorted[min(sorted.count - 1, max(0, idx))]
    }

    /// Runs the engine at `frameRate` Hz for `durationSeconds` while randomly applying commands (~13 Hz)
    /// and recalling looks. If `realTime` is false, simulates the timeline without sleeping.
    public static func run(
        durationSeconds: Double,
        library: @escaping (String) -> FixtureDefinition?,
        frameRate: Double = 40,
        maxAllowedFrameMs: Double = EngineStats.frameBudgetMs,
        realTime: Bool = true,
        seed: UInt64 = 0x5052_4953_4D5F_534F,
        project: Project? = nil
    ) -> Report {
        var doc = ShowDocument(project: project ?? DemoRig.londonStudio())
        let baseLookCount = doc.project.looks.count
        let rate = clamp(frameRate.finiteOr(40), 10, 60)
        let engine = EngineCore(frameRate: rate)
        engine.update(ShowSnapshot(document: doc, library: library))

        let dt = 1.0 / rate
        let duration = clamp(durationSeconds.finiteOr(1), 0, 86_400)
        let totalFrames = max(1, Int((duration * rate).rounded()))
        var durationsMs: [Double] = []
        durationsMs.reserveCapacity(min(totalFrames, 4_000_000))

        var simTime = 1000.0
        let executor = CommandExecutor(library: library, now: { simTime }, defaultFade: 0.3)
        var fuzzer = CommandFuzzer(seed: seed, mode: .realistic)
        var lastFrame = RenderedFrame.empty

        // Warm up before measuring baseline RSS.
        for i in 0..<20 {
            let snap = ShowSnapshot(document: doc, library: library, revision: i)
            lastFrame = EngineCore.renderFrame(snap, time: simTime, frameNumber: UInt64(i))
            simTime += dt
        }
        let baselineRSS = currentResidentBytes()

        var commandsApplied = 0
        var looksRecalled = 0
        var failure: String? = nil
        let wallStart = PrismClock.now()

        for frameIdx in 0..<totalFrames {
            if realTime, PrismClock.now() - wallStart >= duration { break }

            // Every 3 frames (~13 Hz at 40 fps), apply a random command batch.
            if frameIdx % 3 == 0 {
                let batch = fuzzer.nextBatch(in: doc, maxCount: 2)
                for cmd in batch { if case .recallLook = cmd { looksRecalled += 1 } }
                let origin = fuzzer.nextOrigin()
                _ = executor.apply(batch, to: &doc, currentRendered: lastFrame.preMasterStates, origin: origin)
                commandsApplied += batch.count
                // Keep the look list bounded (a user deleting old looks) so memory stays flat.
                if doc.project.looks.count > baseLookCount + 16 {
                    doc.project.looks.removeSubrange(baseLookCount..<(doc.project.looks.count - 8))
                }
                doc.live.pruneExpired(at: simTime)
                if failure == nil, let v = EngineInvariants.violation(in: doc) {
                    failure = "Invalid live state after \(batch.count) command(s) at frame \(frameIdx): \(v)"
                }
                engine.update(ShowSnapshot(document: doc, library: library, revision: frameIdx))
            }

            let t0 = PrismClock.now()
            let frame = EngineCore.renderFrame(
                engine.currentSnapshot,
                audio: AudioFeatures(timestamp: simTime, isActive: (frameIdx % 40) < 30, level: 0.65),
                time: simTime,
                frameNumber: UInt64(frameIdx + 1)
            )
            let renderMs = (PrismClock.now() - t0) * 1000.0
            if durationsMs.count < 4_000_000 { durationsMs.append(renderMs) }
            lastFrame = frame

            if failure == nil, let v = EngineInvariants.violation(in: frame) {
                failure = "Invalid frame \(frameIdx): \(v)"
            }

            simTime += dt
            if realTime {
                let sleepSecs = dt - (PrismClock.now() - t0)
                if sleepSecs > 0 { Thread.sleep(forTimeInterval: min(sleepSecs, 0.025)) }
            }
        }

        let endRSS = currentResidentBytes()
        let growth = baselineRSS > 0 && endRSS > 0 ? endRSS - baselineRSS : 0
        let sorted = durationsMs.sorted()
        let maxMs = sorted.last ?? 0

        if maxMs > maxAllowedFrameMs {
            failure = failure ?? String(format: "Max frame time %.2f ms exceeded %.1f ms budget", maxMs, maxAllowedFrameMs)
        }
        if growth > maxMemoryGrowthBytes {
            failure = failure ?? "Memory grew by \(growth / 1024) KB during soak"
        }

        return Report(
            durationSeconds: realTime ? (PrismClock.now() - wallStart) : duration,
            framesRendered: durationsMs.count,
            commandsApplied: commandsApplied,
            looksRecalled: looksRecalled,
            maxFrameDurationMs: maxMs,
            medianFrameDurationMs: percentile(sorted, 0.5),
            p95FrameDurationMs: percentile(sorted, 0.95),
            p99FrameDurationMs: percentile(sorted, 0.99),
            memoryGrowthBytes: growth,
            passed: failure == nil,
            failureReason: failure
        )
    }
}
