import Foundation

/// Statistics for the status bar / diagnostics.
public struct EngineStats: Sendable, Equatable {
    public var framesRendered: UInt64 = 0
    public var measuredFPS: Double = 0
    public var lastFrameDurationMs: Double = 0
    public var maxFrameDurationMs: Double = 0

    public init(framesRendered: UInt64 = 0, measuredFPS: Double = 0, lastFrameDurationMs: Double = 0, maxFrameDurationMs: Double = 0) {
        self.framesRendered = framesRendered
        self.measuredFPS = measuredFPS
        self.lastFrameDurationMs = lastFrameDurationMs
        self.maxFrameDurationMs = maxFrameDurationMs
    }
}

/// The real-time engine. Renders frames at a fixed rate on its own high-priority queue and
/// sends them to all outputs. The UI never blocks it: input arrives as immutable snapshots,
/// output leaves as immutable frames.
public final class EngineCore: @unchecked Sendable {
    /// Precomputed per-snapshot data (resolved selectors) so frames stay cheap.
    struct Prepared: Sendable {
        var snapshot: ShowSnapshot
        var effectTargets: [UUID: [UUID]]
        var fadingEffectTargets: [UUID: [UUID]]
        var musicTargets: [UUID]
        var fadingMusicTargets: [UUID]
    }

    private struct StatsState: Sendable {
        var stats = EngineStats()
        var frameNumber: UInt64 = 0
        var fpsWindowStart: Double = 0
        var fpsWindowFrames: Int = 0
        var lastActiveAudioTime: Double? = nil
    }

    private static let queueKey = DispatchSpecificKey<Bool>()

    private let queue = DispatchQueue(label: "studio.prism.engine", qos: .userInteractive)
    private let timerBox = Locked<DispatchSourceTimer?>(nil)
    private let prepared = Locked<Prepared>(
        Prepared(snapshot: .empty, effectTargets: [:], fadingEffectTargets: [:], musicTargets: [], fadingMusicTargets: [])
    )
    private let audio = Locked<AudioFeatures>(.silent)
    private let frame = Locked<RenderedFrame>(.empty)
    private let outputs = Locked<[DMXOutput]>([])
    private let statsBox = Locked<StatsState>(StatsState())
    private let frameCallback = Locked<(@Sendable (RenderedFrame) -> Void)?>(nil)

    private let frameRateBox: Locked<Double>
    private let running = Locked<Bool>(false)
    public var frameRate: Double { frameRateBox.value }
    public var isRunning: Bool { running.value }

    public init(frameRate: Double = 40) {
        self.frameRateBox = Locked(clamp(frameRate.finiteOr(40), 10, 60))
        self.queue.setSpecific(key: Self.queueKey, value: true)
    }

    deinit {
        timerBox.mutate { timer in
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: Inputs

    /// Replace the show snapshot (call from any thread; cheap).
    public func update(_ snapshot: ShowSnapshot) {
        prepared.value = EngineCore.prepare(snapshot)
    }

    public func setAudioFeatures(_ features: AudioFeatures) {
        audio.value = features
        if features.isActive {
            let ts = features.timestamp > 0 ? features.timestamp : PrismClock.now()
            statsBox.mutate { $0.lastActiveAudioTime = ts }
        }
    }

    public var currentSnapshot: ShowSnapshot { prepared.value.snapshot }

    // MARK: Outputs

    public func addOutput(_ output: DMXOutput) {
        outputs.mutate { list in
            list.removeAll { $0.outputID == output.outputID }
            list.append(output)
        }
    }

    public func removeOutput(id: String) {
        outputs.mutate { $0.removeAll { $0.outputID == id } }
    }

    public var currentOutputs: [DMXOutput] { outputs.value }

    /// Called on the engine queue after every frame. Keep it extremely cheap (e.g. store the
    /// frame for the UI); never block.
    public func setFrameCallback(_ callback: (@Sendable (RenderedFrame) -> Void)?) {
        frameCallback.value = callback
    }

    // MARK: Output

    public var latestFrame: RenderedFrame { frame.value }
    public var stats: EngineStats { statsBox.value.stats }

    // MARK: Lifecycle

    /// Starts the frame loop (idempotent, non-blocking, callable from any thread).
    public func start() {
        running.value = true
        queue.async { [weak self] in
            guard let self, self.running.value else { return }
            self.timerBox.mutate { timer in
                guard timer == nil else { return }
                let t = DispatchSource.makeTimerSource(flags: .strict, queue: self.queue)
                let interval = 1.0 / self.frameRateBox.value
                t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
                t.setEventHandler { [weak self] in self?.tick() }
                timer = t
                t.resume()
            }
        }
    }

    /// Stops the frame loop (idempotent, non-blocking, callable from any thread).
    public func stop() {
        running.value = false
        timerBox.mutate { timer in
            timer?.cancel()
            timer = nil
        }
    }

    /// Cleanly stops the frame loop and transmits a final hold or blackout frame on the engine
    /// queue with a bounded wait, guaranteeing no race with an in-flight `tick()`.
    public func shutdown(blackout: Bool = false, timeout: Double = 0.15) {
        running.value = false
        timerBox.mutate { timer in
            timer?.cancel()
            timer = nil
        }
        let finalWork: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.timerBox.mutate { timer in
                timer?.cancel()
                timer = nil
            }
            if blackout {
                self.prepared.mutate { p in
                    p.snapshot.live.blackout = true
                    p.snapshot.live.identify = [:]
                    p.snapshot.live.rawOverrides = []
                }
            }
            self.tick()
            if blackout {
                self.frame.mutate { f in
                    for u in f.universes.keys {
                        f.universes[u] = EngineCore.blankUniverse
                    }
                }
                for o in self.outputs.value {
                    o.send(universe: o.universe, data: EngineCore.blankUniverse)
                }
            }
        }

        if DispatchQueue.getSpecific(key: Self.queueKey) == true {
            finalWork()
        } else {
            let sem = DispatchSemaphore(value: 0)
            queue.async {
                finalWork()
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + max(0.01, timeout))
        }
    }

    public func setFrameRate(_ fps: Double) {
        let clamped = clamp(fps.finiteOr(40), 10, 60)
        frameRateBox.value = clamped
        queue.async { [weak self] in
            guard let self else { return }
            self.timerBox.mutate { timer in
                timer?.schedule(deadline: .now(), repeating: 1.0 / clamped, leeway: .milliseconds(1))
            }
        }
    }

    /// Renders and transmits one frame immediately (also used by tests).
    /// Safe to call from any thread without data races.
    public func tick() {
        let start = PrismClock.now()
        let p = prepared.value
        var a = audio.value
        let (currentFrame, lastActive) = statsBox.mutate { state -> (UInt64, Double?) in
            state.frameNumber &+= 1
            if a.isActive {
                let ts = a.timestamp > 0 ? a.timestamp : start
                state.lastActiveAudioTime = ts
            }
            return (state.frameNumber, state.lastActiveAudioTime)
        }
        if !a.isActive, a.timestamp == 0, let lastActive {
            a.timestamp = lastActive
        }

        let f = EngineCore.renderFrame(p, audio: a, time: start, frameNumber: currentFrame)
        frame.value = f
        let outs = outputs.value
        for o in outs {
            let data = f.universes[o.universe] ?? EngineCore.blankUniverse
            o.send(universe: o.universe, data: data)
        }
        frameCallback.value?(f)

        let end = PrismClock.now()
        let durationMs = (end - start) * 1000
        statsBox.mutate { state in
            state.fpsWindowFrames += 1
            if state.fpsWindowStart == 0 { state.fpsWindowStart = start }
            let elapsed = end - state.fpsWindowStart
            state.stats.framesRendered = max(state.stats.framesRendered, currentFrame)
            state.stats.lastFrameDurationMs = durationMs
            state.stats.maxFrameDurationMs = max(state.stats.maxFrameDurationMs * 0.999, durationMs)
            if elapsed >= 1 {
                state.stats.measuredFPS = Double(state.fpsWindowFrames) / elapsed
                state.fpsWindowStart = end
                state.fpsWindowFrames = 0
            }
        }
    }

    static let blankUniverse = [UInt8](repeating: 0, count: 512)

    // MARK: Pure rendering

    private static func filterEffectTargets(
        _ rawIDs: [UUID],
        selector: FixtureSelector,
        byID: [UUID: ResolvedFixture],
        recordingMode: Bool
    ) -> [UUID] {
        let explicit = CommandExecutor.isExplicitSelector(selector)
        return rawIDs.filter { id in
            guard let rf = byID[id] else { return false }
            if !rf.fixture.limits.allowEffects || rf.fixture.limits.protected {
                return false
            }
            if recordingMode && rf.fixture.isProtected {
                return false
            }
            if rf.fixture.isProtected && !explicit {
                return false
            }
            return true
        }
    }

    static func prepare(_ snapshot: ShowSnapshot) -> Prepared {
        let resolver = SelectorResolver(snapshot: snapshot)
        let byID = Dictionary(snapshot.fixtures.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let recordingMode = snapshot.live.recordingMode

        var targets: [UUID: [UUID]] = [:]
        targets.reserveCapacity(snapshot.live.effects.count)
        for e in snapshot.live.effects {
            let raw = resolver.resolve(e.targets)
            targets[e.id] = filterEffectTargets(raw, selector: e.targets, byID: byID, recordingMode: recordingMode)
        }

        var fadingTargets: [UUID: [UUID]] = [:]
        fadingTargets.reserveCapacity(snapshot.live.effectFades.count)
        for (efID, ef) in snapshot.live.effectFades {
            let raw = resolver.resolve(ef.effect.targets)
            fadingTargets[efID] = filterEffectTargets(raw, selector: ef.effect.targets, byID: byID, recordingMode: recordingMode)
        }

        let musicTargets: [UUID]
        if snapshot.live.music.enabled {
            let raw = resolver.resolve(snapshot.live.music.targets)
            musicTargets = filterEffectTargets(raw, selector: snapshot.live.music.targets, byID: byID, recordingMode: recordingMode)
        } else {
            musicTargets = []
        }

        let fadingMusicTargets: [UUID]
        if let mf = snapshot.live.musicFade {
            let raw = resolver.resolve(mf.settings.targets)
            fadingMusicTargets = filterEffectTargets(raw, selector: mf.settings.targets, byID: byID, recordingMode: recordingMode)
        } else {
            fadingMusicTargets = []
        }

        return Prepared(
            snapshot: snapshot,
            effectTargets: targets,
            fadingEffectTargets: fadingTargets,
            musicTargets: musicTargets,
            fadingMusicTargets: fadingMusicTargets
        )
    }

    /// Renders a frame for a snapshot at a given time. Deterministic for given inputs.
    public static func renderFrame(_ snapshot: ShowSnapshot, audio: AudioFeatures = .silent, time: Double, frameNumber: UInt64 = 0) -> RenderedFrame {
        renderFrame(prepare(snapshot), audio: audio, time: time, frameNumber: frameNumber)
    }

    private static func isFlashingEffect(_ kind: EffectKind) -> Bool {
        switch kind {
        case .strobe, .lightning, .paparazzi, .chase:
            return true
        default:
            return false
        }
    }

    static func renderFrame(_ p: Prepared, audio: AudioFeatures, time: Double, frameNumber: UInt64) -> RenderedFrame {
        let snap = p.snapshot
        let live = snap.live
        var states: [UUID: FixtureState] = [:]
        states.reserveCapacity(snap.fixtures.count)

        if live.isFrozen {
            // Frozen output holds captured states (or base states if no capture map is present).
            for rf in snap.fixtures {
                states[rf.id] = live.frozenStates?[rf.id] ?? live.base[rf.id] ?? .off
            }
        } else {
            // 1. Base look with per-fixture fades, spatial delays, and curves.
            for rf in snap.fixtures {
                let target = live.base[rf.id] ?? .off
                if let fade = live.fades[rf.id], !fade.isFinished(at: time) {
                    states[rf.id] = FixtureState.mix(fade.from, target, fade.progress(at: time))
                } else {
                    states[rf.id] = target
                }
            }

            // 2. Effects (with smooth fade-in / fade-out transitions).
            var effectiveSafety = snap.safety
            if live.recordingMode {
                effectiveSafety.photosensitiveSafe = true
                effectiveSafety.maxStrobeHz = 0
            }
            let ctx = EffectContext(time: time, fixtures: snap.fixtures, geometry: snap.geometry, audio: audio, safety: effectiveSafety)

            if !live.effects.isEmpty {
                for effect in live.effects where effect.enabled {
                    if live.recordingMode && isFlashingEffect(effect.kind) { continue }
                    guard let ids = p.effectTargets[effect.id], !ids.isEmpty else { continue }
                    if let ef = live.effectFades[effect.id], !ef.isFinished(at: time) {
                        let w = ef.weight(at: time)
                        guard w > 0.0001 else { continue }
                        var temp = states
                        EffectLibrary.apply(effect, fixtureIDs: ids, context: ctx, states: &temp)
                        for id in ids {
                            if let before = states[id], let after = temp[id] {
                                states[id] = FixtureState.mix(before, after, w)
                            }
                        }
                    } else {
                        EffectLibrary.apply(effect, fixtureIDs: ids, context: ctx, states: &states)
                    }
                }
            }

            // Fading-out effects (no longer in live.effects, transitioning to weight 0).
            if !live.effectFades.isEmpty {
                let activeIDs = Set(live.effects.map(\.id))
                for (efID, ef) in live.effectFades where !activeIDs.contains(efID) && !ef.isFinished(at: time) {
                    if live.recordingMode && isFlashingEffect(ef.effect.kind) { continue }
                    let w = ef.weight(at: time)
                    guard w > 0.0001 else { continue }
                    let ids = p.fadingEffectTargets[efID] ?? []
                    guard !ids.isEmpty else { continue }
                    var temp = states
                    EffectLibrary.apply(ef.effect, fixtureIDs: ids, context: ctx, states: &temp)
                    for id in ids {
                        if let before = states[id], let after = temp[id] {
                            states[id] = FixtureState.mix(before, after, w)
                        }
                    }
                }
            }

            // 3. Music layer (with fade-in, fade-out, and silence fade-out).
            if live.music.enabled, !p.musicTargets.isEmpty {
                var musicWeight = 1.0
                if let mf = live.musicFade, !mf.isFinished(at: time) {
                    musicWeight *= mf.weight(at: time)
                }
                // Silence fade: when audio was active at `audio.timestamp` (> 0) and is now silent,
                // fade smoothly back to the base look over `silenceFadeSeconds`.
                if !audio.isActive, audio.timestamp > 0, time > audio.timestamp {
                    let silenceElapsed = time - audio.timestamp
                    let fadeSecs = live.music.silenceFadeSeconds
                    if fadeSecs <= 0 {
                        musicWeight = 0
                    } else {
                        let tNorm = clamp01(silenceElapsed / fadeSecs)
                        musicWeight *= (1.0 - FadeCurve.easeInOut.evaluate(tNorm))
                    }
                }
                if musicWeight >= 0.9999 {
                    MusicEngine.apply(live.music, targetIDs: p.musicTargets, context: ctx, states: &states)
                } else if musicWeight > 0.0001 {
                    var temp = states
                    MusicEngine.apply(live.music, targetIDs: p.musicTargets, context: ctx, states: &temp)
                    for id in p.musicTargets {
                        if let before = states[id], let after = temp[id] {
                            states[id] = FixtureState.mix(before, after, musicWeight)
                        }
                    }
                }
            } else if let mf = live.musicFade, !mf.isFinished(at: time), !p.fadingMusicTargets.isEmpty {
                let w = mf.weight(at: time)
                if w > 0.0001 {
                    var temp = states
                    var enabledConfig = mf.settings
                    enabledConfig.enabled = true
                    MusicEngine.apply(enabledConfig, targetIDs: p.fadingMusicTargets, context: ctx, states: &temp)
                    for id in p.fadingMusicTargets {
                        if let before = states[id], let after = temp[id] {
                            states[id] = FixtureState.mix(before, after, w)
                        }
                    }
                }
            }
        }

        // Capture pre-master states so mid-fade interruption is unaffected by Grand Master / Blackout / Identify.
        let preMasterStates = states
        let fadeProgress = live.isFrozen ? nil : live.fadeProgress(at: time)

        // 4. Masters.
        let gm = clamp01(live.grandMaster.finiteOr(1))
        if live.blackout || gm < 0.999999 {
            for (id, s) in states {
                var s2 = s
                s2.intensity = live.blackout ? 0 : clamp01(s.intensity * gm)
                states[id] = s2
            }
        }

        // 5. Identify flashes override everything (visible even in blackout).
        if !live.identify.isEmpty {
            for (id, start) in live.identify {
                let dt = time - start
                guard dt >= 0, dt < 2.0, states[id] != nil else { continue }
                let on = Int(dt * 4) % 2 == 0
                states[id] = FixtureState(intensity: on ? 1 : 0, color: .kelvin(5600, tint: 0))
            }
        }

        // 6. Render DMX (in-place mutation avoids CoW allocation per fixture).
        var universes: [Int: [UInt8]] = [:]
        for rf in snap.fixtures {
            guard let address = rf.fixture.address, (1...512).contains(address) else { continue }
            let state = states[rf.id] ?? .off
            let values = FixtureRenderer.render(state, fixture: rf, safety: snap.safety, time: time)
            let startIndex = address - 1
            let count = min(values.count, 512 - startIndex)
            guard count > 0 else { continue }
            universes[rf.fixture.universe, default: blankUniverse].withUnsafeMutableBufferPointer { buf in
                for offset in 0..<count {
                    buf[startIndex + offset] = values[offset]
                }
            }
        }

        // 7. Raw overrides (channel tester / Light Finder).
        for o in live.rawOverrides where (1...512).contains(o.address) {
            universes[o.universe, default: blankUniverse][o.address - 1] = o.value
        }

        return RenderedFrame(
            time: time,
            frameNumber: frameNumber,
            states: states,
            preMasterStates: preMasterStates,
            universes: universes,
            fadeProgress: fadeProgress
        )
    }
}

// MARK: - Soak Runner

/// Runs a randomized command/look/effect soak test against `EngineCore` and verifies
/// frame budget (< 25 ms max frame time), memory stability, and DMX invariants.
public enum EngineSoakRunner {
    public struct Report: Sendable, Equatable, Codable {
        public var durationSeconds: Double
        public var framesRendered: Int
        public var commandsApplied: Int
        public var looksRecalled: Int
        public var maxFrameDurationMs: Double
        public var p95FrameDurationMs: Double
        public var memoryGrowthBytes: Int64
        public var passed: Bool
        public var failureReason: String?

        public init(
            durationSeconds: Double,
            framesRendered: Int,
            commandsApplied: Int,
            looksRecalled: Int,
            maxFrameDurationMs: Double,
            p95FrameDurationMs: Double,
            memoryGrowthBytes: Int64,
            passed: Bool,
            failureReason: String? = nil
        ) {
            self.durationSeconds = durationSeconds
            self.framesRendered = framesRendered
            self.commandsApplied = commandsApplied
            self.looksRecalled = looksRecalled
            self.maxFrameDurationMs = maxFrameDurationMs
            self.p95FrameDurationMs = p95FrameDurationMs
            self.memoryGrowthBytes = memoryGrowthBytes
            self.passed = passed
            self.failureReason = failureReason
        }
    }

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

    /// Runs the engine at `frameRate` Hz for `durationSeconds` while randomly applying commands
    /// and recalling looks. If `realTime` is false, simulates the timeline without sleeping.
    public static func run(
        durationSeconds: Double,
        library: @escaping (String) -> FixtureDefinition?,
        frameRate: Double = 40,
        maxAllowedFrameMs: Double = 25.0,
        realTime: Bool = true
    ) -> Report {
        var doc = ShowDocument(project: DemoRig.londonStudio())
        let engine = EngineCore(frameRate: frameRate)
        engine.update(ShowSnapshot(document: doc, library: library))

        let dt = 1.0 / max(10, frameRate)
        let totalFrames = max(1, Int((durationSeconds * frameRate).rounded()))
        var durationsMs: [Double] = []
        durationsMs.reserveCapacity(totalFrames)

        var simTime = 1000.0
        let executor = CommandExecutor(library: library, now: { simTime }, defaultFade: 0.3)
        var rng = SplitMix64(seed: 0x5052_4953_4D5F_534F)
        let soakLinkID = UUID()

        // Warm up 20 frames before measuring baseline RSS.
        for i in 0..<20 {
            let snap = ShowSnapshot(document: doc, library: library, revision: i)
            _ = EngineCore.renderFrame(snap, time: simTime, frameNumber: UInt64(i))
            simTime += dt
        }
        let baselineRSS = currentResidentBytes()

        var commandsApplied = 0
        var looksRecalled = 0
        var failure: String? = nil
        let wallStart = PrismClock.now()

        for frameIdx in 0..<totalFrames {
            if realTime, PrismClock.now() - wallStart >= durationSeconds {
                break
            }

            // Every 3 frames (~13 Hz), apply a random command or look recall.
            if frameIdx % 3 == 0 {
                let cmd = randomCommand(doc: doc, rng: &rng)
                if case .recallLook = cmd { looksRecalled += 1 }
                let origins: [CommandOrigin] = [.ui, .assistant, .remote(clientID: "soak", linkID: soakLinkID), .midi, .osc]
                let origin = origins[Int(rng.next() % UInt64(origins.count))]
                let currentPreMaster = engine.latestFrame.preMasterStates
                _ = executor.apply([cmd], to: &doc, currentRendered: currentPreMaster, origin: origin)
                commandsApplied += 1
                doc.live.pruneExpired(at: simTime)
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
            durationsMs.append(renderMs)

            // Validate invariants on every rendered frame.
            for (_, state) in frame.states {
                if !state.intensity.isFinite || state.intensity < 0 || state.intensity > 1 {
                    failure = failure ?? "Invalid fixture intensity \(state.intensity) at frame \(frameIdx)"
                }
            }
            for (u, bytes) in frame.universes where bytes.count != 512 {
                failure = failure ?? "Universe \(u) had \(bytes.count) bytes instead of 512"
            }

            simTime += dt
            if realTime {
                let sleepSecs = max(0, dt - (PrismClock.now() - t0))
                if sleepSecs > 0 {
                    Thread.sleep(forTimeInterval: min(sleepSecs, 0.025))
                }
            }
        }

        let endRSS = currentResidentBytes()
        let growth = max(0, endRSS - baselineRSS)
        let sorted = durationsMs.sorted()
        let maxMs = sorted.last ?? 0
        let p95Ms = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]

        if maxMs > maxAllowedFrameMs {
            failure = failure ?? String(format: "Max frame time %.2f ms exceeded %.1f ms budget", maxMs, maxAllowedFrameMs)
        }
        // Allow up to 32 MB RSS drift from allocator pages during soak.
        let maxMemoryGrowth: Int64 = 32 * 1024 * 1024
        if baselineRSS > 0 && growth > maxMemoryGrowth {
            failure = failure ?? "Memory grew by \(growth / 1024) KB during soak"
        }

        return Report(
            durationSeconds: realTime ? (PrismClock.now() - wallStart) : durationSeconds,
            framesRendered: durationsMs.count,
            commandsApplied: commandsApplied,
            looksRecalled: looksRecalled,
            maxFrameDurationMs: maxMs,
            p95FrameDurationMs: p95Ms,
            memoryGrowthBytes: growth,
            passed: failure == nil,
            failureReason: failure
        )
    }

    private static func randomCommand(doc: ShowDocument, rng: inout SplitMix64) -> LightingCommand {
        let choice = Int(rng.next() % 14)
        let roles = FixtureRole.allCases
        let selector: FixtureSelector = (rng.next() % 2 == 0)
            ? .all
            : .role(roles[Int(rng.next() % UInt64(roles.count))])
        let val = Double(rng.next() % 100) / 100.0
        let hue = Double(rng.next() % 360)

        switch choice {
        case 0:
            return .setIntensity(selector, val)
        case 1:
            return .adjustIntensity(selector, (rng.next() % 2 == 0) ? LightingCommand.nudgeABit : -LightingCommand.nudgeABit)
        case 2:
            return .setColor(selector, .rgb(RGB(hue: hue, saturation: 0.9, value: 1.0)))
        case 3:
            return .shiftColor(selector, toward: .rgb(RGB(hue: hue, saturation: 1, value: 1)), amount: 0.25)
        case 4:
            return .setKelvin(selector, 3200 + Double(rng.next() % 2400))
        case 5:
            return .gradient(
                selector,
                colors: [
                    .rgb(RGB(hue: hue, saturation: 1, value: 1)),
                    .rgb(RGB(hue: wrapDegrees(hue + 120), saturation: 1, value: 1))
                ],
                axis: .horizontal
            )
        case 6:
            if let look = doc.project.looks.isEmpty ? nil : doc.project.looks[Int(rng.next() % UInt64(doc.project.looks.count))] {
                return .recallLook(.id(look.id), fade: 0.4)
            }
            return .setIntensity(.all, 0.8)
        case 7:
            return .startEffect(EffectInstance(kind: .breathe, targets: .role(.background), params: EffectParameters(speed: 0.5, amount: 0.6)))
        case 8:
            return .setEffectParameters(EffectParameters(speed: 0.3 + val, amount: 0.4 + val * 0.5), for: .role(.background))
        case 9:
            return .stopEffects(.role(.background))
        case 10:
            return .paintCells(.role(.background), cellIndices: [0, 1, 2, 3], color: .rgb(RGB(hue: hue, saturation: 1, value: 1)))
        case 11:
            return .swapColors(.role(.background))
        case 12:
            return .setRecordingMode(rng.next() % 4 == 0)
        default:
            return .freeze(rng.next() % 8 == 0)
        }
    }
}

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
}

