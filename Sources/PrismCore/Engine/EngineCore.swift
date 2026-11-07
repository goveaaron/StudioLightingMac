import Foundation

/// Statistics for the status bar / diagnostics.
public struct EngineStats: Sendable, Equatable {
    /// A frame that takes longer than this (render + send) counts as over budget.
    public static let frameBudgetMs = 25.0

    public var framesRendered: UInt64 = 0
    public var measuredFPS: Double = 0
    public var lastFrameDurationMs: Double = 0
    /// Slowly decaying maximum (for the status bar).
    public var maxFrameDurationMs: Double = 0
    /// Longest frame since start / `resetPeakStats()` (never decays).
    public var peakFrameDurationMs: Double = 0
    /// Frames slower than `frameBudgetMs` since start / `resetPeakStats()`.
    public var framesOverBudget: UInt64 = 0
    /// Longest gap between two consecutive frame starts since start / `resetPeakStats()` (timer stalls).
    public var maxTickIntervalMs: Double = 0

    public init(framesRendered: UInt64 = 0, measuredFPS: Double = 0, lastFrameDurationMs: Double = 0, maxFrameDurationMs: Double = 0,
                peakFrameDurationMs: Double = 0, framesOverBudget: UInt64 = 0, maxTickIntervalMs: Double = 0) {
        self.framesRendered = framesRendered
        self.measuredFPS = measuredFPS
        self.lastFrameDurationMs = lastFrameDurationMs
        self.maxFrameDurationMs = maxFrameDurationMs
        self.peakFrameDurationMs = peakFrameDurationMs
        self.framesOverBudget = framesOverBudget
        self.maxTickIntervalMs = maxTickIntervalMs
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
        var lastTickStart: Double = 0
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
        let timerRunning = running.value
        statsBox.mutate { state in
            state.fpsWindowFrames += 1
            if state.fpsWindowStart == 0 { state.fpsWindowStart = start }
            let elapsed = end - state.fpsWindowStart
            state.stats.framesRendered = max(state.stats.framesRendered, currentFrame)
            state.stats.lastFrameDurationMs = durationMs
            state.stats.maxFrameDurationMs = max(state.stats.maxFrameDurationMs * 0.999, durationMs)
            state.stats.peakFrameDurationMs = max(state.stats.peakFrameDurationMs, durationMs)
            if durationMs > EngineStats.frameBudgetMs { state.stats.framesOverBudget &+= 1 }
            if timerRunning, state.lastTickStart > 0 {
                state.stats.maxTickIntervalMs = max(state.stats.maxTickIntervalMs, (start - state.lastTickStart) * 1000)
            }
            state.lastTickStart = timerRunning ? start : 0
            if elapsed >= 1 {
                state.stats.measuredFPS = Double(state.fpsWindowFrames) / elapsed
                state.fpsWindowStart = end
                state.fpsWindowFrames = 0
            }
        }
    }

    /// Clears the non-decaying peak statistics (peak frame time, over-budget count, max tick gap),
    /// e.g. after a warm-up period.
    public func resetPeakStats() {
        statsBox.mutate { state in
            state.stats.peakFrameDurationMs = 0
            state.stats.framesOverBudget = 0
            state.stats.maxTickIntervalMs = 0
            state.lastTickStart = 0
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
