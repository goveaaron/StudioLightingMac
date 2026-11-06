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
        var musicTargets: [UUID]
    }

    private let queue = DispatchQueue(label: "studio.prism.engine", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let prepared = Locked<Prepared>(Prepared(snapshot: .empty, effectTargets: [:], musicTargets: []))
    private let audio = Locked<AudioFeatures>(.silent)
    private let frame = Locked<RenderedFrame>(.empty)
    private let outputs = Locked<[DMXOutput]>([])
    private let statsBox = Locked<EngineStats>(EngineStats())
    private let frameCallback = Locked<(@Sendable (RenderedFrame) -> Void)?>(nil)
    private var frameNumber: UInt64 = 0
    private var fpsWindowStart: Double = 0
    private var fpsWindowFrames: Int = 0

    private let frameRateBox: Locked<Double>
    private let running = Locked<Bool>(false)
    public var frameRate: Double { frameRateBox.value }
    public var isRunning: Bool { running.value }

    public init(frameRate: Double = 40) {
        self.frameRateBox = Locked(clamp(frameRate.finiteOr(40), 10, 60))
    }

    deinit { timer?.cancel() }

    // MARK: Inputs

    /// Replace the show snapshot (call from any thread; cheap).
    public func update(_ snapshot: ShowSnapshot) {
        prepared.value = EngineCore.prepare(snapshot)
    }

    public func setAudioFeatures(_ features: AudioFeatures) {
        audio.value = features
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
    public var stats: EngineStats { statsBox.value }

    // MARK: Lifecycle

    /// Starts the frame loop (idempotent, non-blocking, callable from any thread).
    public func start() {
        running.value = true
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: self.queue)
            let interval = 1.0 / self.frameRateBox.value
            t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.tick() }
            self.timer = t
            t.resume()
        }
    }

    /// Stops the frame loop (idempotent, non-blocking, callable from any thread).
    public func stop() {
        running.value = false
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    public func setFrameRate(_ fps: Double) {
        frameRateBox.value = clamp(fps.finiteOr(40), 10, 60)
        queue.async { [weak self] in
            guard let self, let t = self.timer else { return }
            t.schedule(deadline: .now(), repeating: 1.0 / self.frameRateBox.value, leeway: .milliseconds(1))
        }
    }

    /// Renders and transmits one frame immediately (also used by tests).
    public func tick() {
        let start = PrismClock.now()
        let p = prepared.value
        let a = audio.value
        frameNumber &+= 1
        let f = EngineCore.renderFrame(p, audio: a, time: start, frameNumber: frameNumber)
        frame.value = f
        let outs = outputs.value
        for o in outs {
            let data = f.universes[o.universe] ?? EngineCore.blankUniverse
            o.send(universe: o.universe, data: data)
        }
        frameCallback.value?(f)

        let end = PrismClock.now()
        fpsWindowFrames += 1
        if fpsWindowStart == 0 { fpsWindowStart = start }
        let elapsed = end - fpsWindowStart
        statsBox.mutate { s in
            s.framesRendered = frameNumber
            s.lastFrameDurationMs = (end - start) * 1000
            s.maxFrameDurationMs = max(s.maxFrameDurationMs * 0.999, s.lastFrameDurationMs)
            if elapsed >= 1 {
                s.measuredFPS = Double(fpsWindowFrames) / elapsed
            }
        }
        if elapsed >= 1 { fpsWindowStart = end; fpsWindowFrames = 0 }
    }

    static let blankUniverse = [UInt8](repeating: 0, count: 512)

    // MARK: Pure rendering

    static func prepare(_ snapshot: ShowSnapshot) -> Prepared {
        let resolver = SelectorResolver(snapshot: snapshot)
        var targets: [UUID: [UUID]] = [:]
        for e in snapshot.live.effects { targets[e.id] = resolver.resolve(e.targets) }
        let music = snapshot.live.music.enabled ? resolver.resolve(snapshot.live.music.targets) : []
        return Prepared(snapshot: snapshot, effectTargets: targets, musicTargets: music)
    }

    /// Renders a frame for a snapshot at a given time. Deterministic for given inputs.
    public static func renderFrame(_ snapshot: ShowSnapshot, audio: AudioFeatures = .silent, time: Double, frameNumber: UInt64 = 0) -> RenderedFrame {
        renderFrame(prepare(snapshot), audio: audio, time: time, frameNumber: frameNumber)
    }

    static func renderFrame(_ p: Prepared, audio: AudioFeatures, time: Double, frameNumber: UInt64) -> RenderedFrame {
        let snap = p.snapshot
        let live = snap.live
        var states: [UUID: FixtureState] = [:]
        states.reserveCapacity(snap.fixtures.count)

        // 1. Base look with fades.
        for rf in snap.fixtures {
            let target = live.base[rf.id] ?? .off
            if let fade = live.fades[rf.id], !fade.isFinished(at: time) {
                states[rf.id] = FixtureState.mix(fade.from, target, fade.progress(at: time))
            } else {
                states[rf.id] = target
            }
        }

        // 2. Effects and 3. music layer.
        let ctx = EffectContext(time: time, fixtures: snap.fixtures, geometry: snap.geometry, audio: audio, safety: snap.safety)
        if !live.effects.isEmpty {
            EffectEngine.apply(live.effects, targets: p.effectTargets, context: ctx, states: &states)
        }
        if live.music.enabled {
            MusicEngine.apply(live.music, targetIDs: p.musicTargets, context: ctx, states: &states)
        }

        // 4. Masters.
        let gm = clamp01(live.grandMaster.finiteOr(1))
        for (id, s) in states {
            var s2 = s
            s2.intensity = live.blackout ? 0 : clamp01(s.intensity * gm)
            states[id] = s2
        }

        // 5. Identify flashes override everything (visible even in blackout).
        for (id, start) in live.identify {
            let dt = time - start
            guard dt >= 0, dt < 2.0, states[id] != nil else { continue }
            let on = Int(dt * 4) % 2 == 0
            states[id] = FixtureState(intensity: on ? 1 : 0, color: .kelvin(5600, tint: 0))
        }

        // 6. Render DMX.
        var universes: [Int: [UInt8]] = [:]
        for rf in snap.fixtures {
            guard let address = rf.fixture.address, (1...512).contains(address) else { continue }
            let state = states[rf.id] ?? .off
            let values = FixtureRenderer.render(state, fixture: rf, safety: snap.safety, time: time)
            var buffer = universes[rf.fixture.universe] ?? blankUniverse
            let startIndex = address - 1
            for (offset, v) in values.enumerated() {
                let idx = startIndex + offset
                guard idx < 512 else { break }
                buffer[idx] = v
            }
            universes[rf.fixture.universe] = buffer
        }

        // 7. Raw overrides (channel tester / Light Finder).
        for o in live.rawOverrides where (1...512).contains(o.address) {
            var buffer = universes[o.universe] ?? blankUniverse
            buffer[o.address - 1] = o.value
            universes[o.universe] = buffer
        }

        return RenderedFrame(time: time, frameNumber: frameNumber, states: states, universes: universes)
    }
}
