import XCTest
@testable import PrismCore

/// Synthetic-audio tests for the music analyzer (docs/research/music_reactive.md §6.1, Appendix A).
final class MusicDSPTests: XCTestCase {

    // MARK: Helpers

    /// Ground truth: t → (beat phase, local period) from beat times (Appendix A `truth_from_beats`).
    private func truth(_ beats: [Double], _ t: Double) -> (phase: Double, period: Double)? {
        var lo = 0, hi = beats.count
        while lo < hi { let m = (lo + hi) / 2; if beats[m] < t { lo = m + 1 } else { hi = m } }
        let k = lo - 1
        guard k >= 0, k + 1 < beats.count else { return nil }
        let T = beats[k + 1] - beats[k]
        return ((t - beats[k]) / T, T)
    }

    struct TrackerRun {
        var bpm: Double?
        var lockTime: Double?
        var confidence: Double
        var phaseErrorsMs: [(t: Double, e: Double)]
        var rephases: Int
        var reseeds: Int
    }

    /// Runs the rhythm path alone over `y` (fast) and samples the phase error like Appendix A.
    private func runTracker(_ y: [Float], beats: [Double]? = nil, from: Double = 10) -> TrackerRun {
        let tracker = RhythmTracker()
        let N = RhythmTracker.frameSize, H = RhythmTracker.hopSize
        var errs: [(Double, Double)] = []
        let frames = (y.count - N) / H
        y.withUnsafeBufferPointer { bp in
            guard let base = bp.baseAddress else { return }
            for i in 0..<max(0, frames) {
                let t = (Double(i * H) + Double(N) / 2) / RhythmTracker.sampleRate
                tracker.process(window: base + i * H, centerTime: t)
                if let beats, tracker.isLocked, t > from, i % RhythmTracker.updateStep == 0,
                   let g = truth(beats, t) {
                    let phi = tracker.beats - tracker.beats.rounded(.down)
                    errs.append((t, wrapHalf(phi - g.phase) * g.period * 1000))
                }
            }
        }
        return TrackerRun(bpm: tracker.period.map { 60 / $0 }, lockTime: tracker.firstLockTime,
                          confidence: tracker.confidence, phaseErrorsMs: errs,
                          rephases: tracker.rephases, reseeds: tracker.reseeds)
    }

    private func p90(_ e: [Double]) -> Double {
        guard !e.isEmpty else { return .infinity }
        let s = e.map { abs($0) }.sorted()
        return s[min(s.count - 1, Int((Double(s.count) * 0.9).rounded(.down)))]
    }

    private func assertFinite(_ f: AudioFeatures, file: StaticString = #filePath, line: UInt = #line) {
        let scalars: [Double] = [f.timestamp, f.level, f.onset, f.beatPhase, f.barPhase, f.bpm, f.tempoConfidence,
                                 f.brightness, f.novelty, f.presence, f.silentSeconds, f.levelDBFS, f.loudnessSlow,
                                 f.flatness, f.kick, f.snare, f.hihat, f.onsetDensity, f.harmonicHue, f.tonalClarity,
                                 f.energy, f.buildup, f.phrasePhase, f.downbeatConfidence, f.keyConfidence]
        for v in scalars { XCTAssertTrue(v.isFinite, "non-finite feature", file: file, line: line) }
        let unit: [Double] = [f.level, f.onset, f.beatPhase, f.barPhase, f.tempoConfidence, f.brightness, f.novelty,
                              f.presence, f.loudnessSlow, f.flatness, f.kick, f.snare, f.hihat, f.onsetDensity,
                              f.energy, f.buildup, f.phrasePhase, f.harmonicHue, f.tonalClarity]
        for v in unit { XCTAssertTrue(v >= 0 && v <= 1, "feature out of 0…1: \(v)", file: file, line: line) }
        for b in 0..<6 {
            XCTAssertTrue(f.bandLevels[b] >= 0 && f.bandLevels[b] <= 1, file: file, line: line)
            XCTAssertTrue(f.bandsFast[b] >= 0 && f.bandsFast[b] <= 1, file: file, line: line)
        }
        for i in 0..<16 { XCTAssertTrue(f.spectrum16[i] >= 0 && f.spectrum16[i] <= 1, file: file, line: line) }
    }

    /// Feeds `y` to a full analyzer in 512-sample blocks, calling `inspect` every `every` seconds.
    @discardableResult
    private func analyze(_ y: [Float], analyzer: AudioAnalyzer = AudioAnalyzer(), every: Double = 0.25,
                         inspect: ((AudioFeatures) -> Void)? = nil) -> AudioAnalyzer {
        let block = 512
        var next = 0.0
        y.withUnsafeBufferPointer { bp in
            guard let base = bp.baseAddress else { return }
            var i = 0
            while i < bp.count {
                let n = min(block, bp.count - i)
                analyzer.process(base + i, count: n)
                i += n
                if analyzer.currentTime >= next {
                    next += every
                    let f = analyzer.snapshot()
                    assertFinite(f)
                    inspect?(f)
                }
            }
        }
        return analyzer
    }

    // MARK: FFT, ring buffer, resampler

    func testFFTScalingAndPortableParity() throws {
        let n = 1024
        let fft = try XCTUnwrap(RealFFT(size: n))
        let w = RealFFT.hann(n)
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n { x[i] = Float(sin(2 * Double.pi * 10 * Double(i) / Double(n))) * w[i] }
        var p = [Float](repeating: 0, count: n / 2 + 1)
        var q = [Float](repeating: 0, count: n / 2 + 1)
        x.withUnsafeBufferPointer { xb in
            p.withUnsafeMutableBufferPointer { fft.powerSpectrum(xb.baseAddress!, into: $0.baseAddress!) }
            q.withUnsafeMutableBufferPointer { fft.portablePowerSpectrum(xb.baseAddress!, into: $0.baseAddress!) }
        }
        let amp = Double(p[10].squareRoot()) * 4 / Double(n)
        XCTAssertEqual(amp, 1.0, accuracy: 0.01, "full-scale sine must read amplitude 1 at its bin")
        for k in 0...(n / 2) {
            XCTAssertEqual(Double(p[k]), Double(q[k]), accuracy: 1e-3 * max(1, Double(q[k])), "bin \(k)")
        }
        XCTAssertNil(RealFFT(size: 1000))
    }

    func testRingBufferOrderDropsAndAnchor() {
        let ring = AudioRingBuffer(minimumCapacity: 1024)
        XCTAssertEqual(ring.capacity, 1024)
        var src = [Float](repeating: 0, count: 300)
        var expected: Float = 0
        var dst = [Float](repeating: 0, count: 1024)
        for round in 0..<20 {
            for i in 0..<300 { src[i] = Float(round * 300 + i) }
            src.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 300, hostTime: Double(round)) }
            let r = dst.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxCount: 1024) }
            XCTAssertEqual(r.count, 300)
            XCTAssertEqual(r.anchorTime, Double(round))
            for i in 0..<r.count { XCTAssertEqual(dst[i], expected); expected += 1 }
        }
        // Overfill without reading: the newest samples are dropped, nothing is overwritten.
        for _ in 0..<5 { src.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 300, hostTime: 0) } }
        let r = dst.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxCount: 1024) }
        XCTAssertEqual(r.count, 1024)
        XCTAssertEqual(r.droppedSamples, 1500 - 1024)
    }

    func testResamplerPreservesFrequency() {
        var rs = LinearResampler(inputRate: 44_100)
        XCTAssertFalse(rs.isPassthrough)
        let n = 44_100
        let x = (0..<n).map { Float(sin(2 * Double.pi * 1000 * Double($0) / 44_100)) }
        var out = [Float](repeating: 0, count: rs.maxOutputCount(forInput: n))
        var produced = 0
        x.withUnsafeBufferPointer { xb in
            out.withUnsafeMutableBufferPointer { ob in
                // Feed in uneven blocks to exercise the streaming state.
                var i = 0
                var blocks = [97, 512, 1001, 33]
                var bi = 0
                while i < n {
                    let c = min(blocks[bi % blocks.count], n - i)
                    produced += rs.process(xb.baseAddress! + i, count: c, into: ob.baseAddress! + produced)
                    i += c
                    bi += 1
                }
                blocks.removeAll()
            }
        }
        XCTAssertEqual(Double(produced), 48_000, accuracy: 3)
        var crossings = 0
        for i in 1..<produced where out[i - 1] < 0 && out[i] >= 0 { crossings += 1 }
        XCTAssertEqual(Double(crossings), 1000, accuracy: 3)
    }

    // MARK: Tempo and phase (golden behaviour of Appendix A)

    func testTempoLockAndPhaseOnBeatMaterial() {
        let cases: [(Double, SyntheticAudio.Style, Double)] = [
            (124, .house, 0), (128, .house, 0), (100, .house, 0), (90, .hiphop, 0.25),
            (140, .house, 0), (75, .hiphop, 0.2), (160, .house, 0),
        ]
        for (bpm, style, swing) in cases {
            let (y, beats) = SyntheticAudio.track(bpm: bpm, seconds: 30, style: style, swing: swing, seed: 1)
            let run = runTracker(y, beats: beats)
            guard let got = run.bpm else { XCTFail("\(style) \(bpm): never locked"); continue }
            XCTAssertEqual(got, bpm, accuracy: 1.0, "\(style) \(bpm)")
            XCTAssertLessThanOrEqual(run.lockTime ?? 99, 12, "\(style) \(bpm): lock time")
            let e = run.phaseErrorsMs.map(\.e)
            XCTAssertFalse(e.isEmpty)
            XCTAssertLessThan(p90(e), 30, "\(style) \(bpm): phase error p90 \(p90(e)) ms")
            XCTAssertGreaterThan(run.confidence, 0.6)
        }
    }

    func testClickAndChirpTracksAtKnownTempo() {
        for bpm in [96.0, 120.0, 150.0] {
            let (y, beats) = SyntheticAudio.clickTrack(bpm: bpm, seconds: 24)
            let run = runTracker(y, beats: beats)
            XCTAssertEqual(run.bpm ?? 0, bpm, accuracy: 1.0, "clicks \(bpm)")
            XCTAssertLessThan(p90(run.phaseErrorsMs.map(\.e)), 30, "clicks \(bpm)")
        }
        let (y, beats) = SyntheticAudio.chirpTrack(bpm: 110, seconds: 24)
        let run = runTracker(y, beats: beats)
        XCTAssertEqual(run.bpm ?? 0, 110, accuracy: 1.0, "chirps 110")
        XCTAssertLessThan(p90(run.phaseErrorsMs.map(\.e)), 30, "chirps 110")
    }

    func testNoFalseLockOnAmbientOrRandomOnsets() {
        let n = Int(30 * SyntheticAudio.sampleRate)
        var rng = SyntheticRNG(seed: 5)
        let pad = SyntheticAudio.pad(count: n).map { $0 * 1.5 + Float(0.02 * rng.gaussian()) }
        XCTAssertNil(runTracker(pad).lockTime, "ambient pad must never lock")
        for seed in [UInt64(1), 3, 4] {
            XCTAssertNil(runTracker(SyntheticAudio.randomOnsets(seconds: 30, seed: seed)).lockTime,
                         "random onsets (seed \(seed)) must not lock")
        }
    }

    func testTempoRampsAreFollowed() {
        for (b0, b1) in [(120.0, 128.0), (128.0, 120.0)] {
            let (y, beats, end) = SyntheticAudio.rampTrack(from: b0, to: b1, seconds: 40)
            let run = runTracker(y, beats: beats, from: 16)
            XCTAssertEqual(run.bpm ?? 0, end, accuracy: 1.0, "ramp \(b0)→\(b1)")
            XCTAssertLessThan(p90(run.phaseErrorsMs.map(\.e)), 40, "ramp \(b0)→\(b1)")
        }
    }

    func testBreakdownFlywheelAndGridJump() {
        let (y, beats) = SyntheticAudio.breakdownTrack(bpm: 124, seconds: 40, start: 18, stop: 27)
        let run = runTracker(y, beats: beats)
        XCTAssertEqual(run.bpm ?? 0, 124, accuracy: 0.5)
        XCTAssertLessThan(p90(run.phaseErrorsMs.map(\.e)), 30, "breakdown flywheel")

        let (yj, bj) = SyntheticAudio.phaseJumpTrack(bpm: 124, seconds: 36, jumpAt: 20)
        let jr = runTracker(yj, beats: bj)
        XCTAssertGreaterThanOrEqual(jr.rephases + jr.reseeds, 1, "a hard cut must re-phase")
        let late = jr.phaseErrorsMs.filter { $0.t > 26 }.map(\.e)
        XCTAssertLessThan(p90(late), 30, "settled after the cut")
    }

    // MARK: Full analyzer

    func testFullAnalyzerOnHouseTrack() {
        let (y, beats) = SyntheticAudio.track(bpm: 124, seconds: 32, style: .house, seed: 2)
        var sawBeatFlag = false
        var lastBeatCount: Int64 = .min
        let a = analyze(y) { f in
            if f.beat { sawBeatFlag = true }
            XCTAssertGreaterThanOrEqual(f.beatCount, lastBeatCount, "beatCount must never decrease")
            lastBeatCount = f.beatCount
        }
        let f = a.snapshot()
        XCTAssertTrue(f.isActive)
        XCTAssertEqual(f.presence, 1, accuracy: 1e-9)
        XCTAssertEqual(f.bpm, 124, accuracy: 1)
        XCTAssertGreaterThan(f.tempoConfidence, 0.6)
        XCTAssertTrue(sawBeatFlag)
        XCTAssertGreaterThan(f.onsetDensity, 0.2)
        XCTAssertGreaterThan(f.level, 0.3)
        XCTAssertGreaterThan(f.bandLevels.sub + f.bandLevels.bass, 0.2)
        // Clock extrapolation agrees with the ground truth 100 ms into the future.
        let tFuture = f.timestamp + 0.1
        if let g = truth(beats, tFuture) {
            let e = wrapHalf(f.clock.beatPhase(at: tFuture) - g.phase) * g.period
            XCTAssertLessThan(abs(e), 0.03, "extrapolated phase error \(e * 1000) ms")
        }
        // Downbeats: the bass root changes on true bar starts (beat index % 4 == 0).
        if let g = truth(beats, f.timestamp) {
            var k = 0
            while k + 1 < beats.count && beats[k + 1] <= f.timestamp { k += 1 }
            let trueBeatInBar = k % 4
            XCTAssertEqual(f.beatInBar, trueBeatInBar, "downbeat alignment (phase \(g.phase))")
        }
    }

    func testSilenceDetectionAndPresence() {
        let music = SyntheticAudio.track(bpm: 120, seconds: 6, style: .house, seed: 3).samples
        var y = music
        y += SyntheticAudio.silence(seconds: 4)                       // digital zeros (paused player)
        y += SyntheticAudio.track(bpm: 120, seconds: 3, seed: 4).samples
        var rng = SyntheticRNG(seed: 9)
        y += (0..<Int(4 * SyntheticAudio.sampleRate)).map { _ in Float(0.0002 * rng.gaussian()) } // ≈ −74 dBFS hiss
        var trace: [(t: Double, silent: Bool, presence: Double)] = []
        analyze(y, every: 0.05) { f in trace.append((f.timestamp, !f.isActive, f.presence)) }
        func silent(at t: Double) -> Bool { trace.last(where: { $0.t <= t })?.silent ?? true }
        func presence(at t: Double) -> Double { trace.last(where: { $0.t <= t })?.presence ?? 0 }
        XCTAssertFalse(silent(at: 5.5))
        XCTAssertEqual(presence(at: 5.5), 1, accuracy: 1e-6)
        XCTAssertFalse(silent(at: 6.15), "digital zeros need 0.3 s before counting as silence")
        XCTAssertTrue(silent(at: 6.6), "digital zeros → silence within 0.3 s")
        XCTAssertGreaterThan(presence(at: 7.0), 0.4, "presence eases out over 3 s")
        XCTAssertLessThan(presence(at: 9.8), 0.05)
        XCTAssertFalse(silent(at: 10.4), "music return detected within ~0.1 s")
        XCTAssertGreaterThan(presence(at: 11.2), 0.95, "presence back within 0.8 s")
        XCTAssertFalse(silent(at: 13.5), "quiet hiss: needs 1 s below −60 dBFS")
        XCTAssertTrue(silent(at: 14.8), "hiss below −60 dBFS → silence after 1 s")
    }

    func testAutoGainIsStableAndAdapts() {
        var y = SyntheticAudio.pinkNoise(seconds: 14, amplitude: 0.05, seed: 2)
        y += SyntheticAudio.pinkNoise(seconds: 14, amplitude: 0.2, seed: 3)  // +12 dB step
        var early: [Double] = [], late: [Double] = [], steady: [Double] = []
        analyze(y, every: 0.1) { f in
            if f.timestamp > 8 && f.timestamp < 14 { early.append(f.level); steady.append(f.bandLevels.mid) }
            if f.timestamp > 24 && f.timestamp < 28 { late.append(f.level) }
            XCTAssertTrue(f.isActive || f.timestamp < 0.5)
        }
        let mean = { (v: [Double]) in v.reduce(0, +) / Double(max(1, v.count)) }
        let sd = { (v: [Double]) -> Double in
            let m = mean(v); return sqrt(v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(max(1, v.count)))
        }
        XCTAssertLessThan(sd(steady), 0.08, "steady noise must not pump")
        XCTAssertEqual(mean(early), mean(late), accuracy: 0.12, "AGC compensates a +12 dB level change")
        XCTAssertGreaterThan(mean(early), 0.4)
        XCTAssertLessThan(mean(early), 0.95)
    }

    func testBuildUpAndDropDetected() {
        let (y, buildStart, dropTime) = SyntheticAudio.buildAndDrop(bpm: 128)
        var earlyDrops: UInt32 = 0
        var maxBuild = 0.0
        let a = analyze(y, every: 0.25) { f in
            if f.timestamp < dropTime - 0.5 { earlyDrops = f.dropCount }
            if f.timestamp > buildStart + 4 && f.timestamp < dropTime { maxBuild = max(maxBuild, f.buildup) }
        }
        let f = a.snapshot()
        XCTAssertEqual(earlyDrops, 0, "no drop before the drop")
        XCTAssertGreaterThanOrEqual(f.dropCount, 1, "the drop must be detected")
        XCTAssertGreaterThanOrEqual(f.lastDropTime, dropTime - 0.1)
        XCTAssertLessThanOrEqual(f.lastDropTime, dropTime + 2.0)
        XCTAssertGreaterThan(f.lastDropStrength, 0.2)
        XCTAssertGreaterThan(maxBuild, 0.3, "build-up likelihood rises before the drop")
        XCTAssertGreaterThanOrEqual(f.sectionCount, 1)
    }

    func testBrightnessFollowsASweepAndKeyFromPad() {
        var bright: [(Double, Double)] = []
        let sweep = SyntheticAudio.sweep(from: 150, to: 9000, seconds: 10, amplitude: 0.3)
        analyze(sweep, every: 0.5) { f in bright.append((f.timestamp, f.brightness)) }
        let early = bright.filter { $0.0 > 1.5 && $0.0 < 3 }.map(\.1)
        let late = bright.filter { $0.0 > 8.5 }.map(\.1)
        XCTAssertLessThan(early.max() ?? 1, late.min() ?? 0, "brightness rises with the sweep")

        // A-major pad (A, C#, E) → key A major (index 9) or its relative minor (F# minor = 18).
        let pad = SyntheticAudio.pad(count: Int(14 * SyntheticAudio.sampleRate))
        let a = analyze(pad, every: 1)
        let f = a.snapshot()
        XCTAssertTrue([9, 18].contains(f.key), "key \(f.key)")
        XCTAssertGreaterThan(f.tonalClarity, 0.2)
        XCTAssertGreaterThan(f.chromaVector[9], 0.5, "A is strong")
        XCTAssertGreaterThan(f.chromaVector[1], 0.3, "C# is present")
        XCTAssertLessThan(f.chromaVector[0], 0.3, "C is absent")
    }

    func testTapTempoAndMultiplier() {
        let (y, _) = SyntheticAudio.track(bpm: 120, seconds: 4, seed: 6)
        let a = analyze(y)
        a.applyTap(bpm: 100, lastTapTime: a.currentTime - 0.2)
        var f = a.snapshot()
        XCTAssertEqual(f.bpm, 100, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(f.tempoConfidence, 0.69)
        a.configuration.tempoMultiplier = 2
        f = a.snapshot()
        XCTAssertEqual(f.bpm, 200, accuracy: 0.01)
        a.configuration.tempoMultiplier = 0.5
        f = a.snapshot()
        XCTAssertEqual(f.bpm, 50, accuracy: 0.01)
    }

    func testGarbageInputNeverProducesNaN() {
        var y = [Float](repeating: .nan, count: 4800)
        y += [Float](repeating: .infinity, count: 4800)
        y += (0..<48_000).map { Float($0 % 2 == 0 ? 1e30 : -1e30) }
        y += SyntheticAudio.track(bpm: 128, seconds: 3, seed: 8).samples
        analyze(y, every: 0.1)
    }

    func testBeatClockMath() {
        let c = BeatClock(anchorTime: 10, anchorBeats: 100.25, period: 0.5, multiplier: 1, downbeatOffset: 2,
                          phraseAnchorBar: 3, confidence: 1, isLocked: true)
        XCTAssertEqual(c.bpm, 120, accuracy: 1e-9)
        XCTAssertEqual(c.beats(at: 10.5), 101.25, accuracy: 1e-9)
        XCTAssertEqual(c.beatPhase(at: 10.5), 0.25, accuracy: 1e-9)
        XCTAssertEqual(c.beatIndex(at: 10.5), 101)
        XCTAssertEqual(c.beatInBar(at: 10.5), (101 - 2) % 4)
        XCTAssertEqual(c.barPosition(at: 10), (100.25 - 2) / 4, accuracy: 1e-9)
        let d = BeatClock(anchorTime: 0, anchorBeats: 0, period: 0.5, multiplier: 2)
        XCTAssertEqual(d.bpm, 240, accuracy: 1e-9)
        XCTAssertEqual(d.beats(at: 1), 4, accuracy: 1e-9)
        XCTAssertEqual(d.barPosition(at: 1), 0.5, accuracy: 1e-9, "bars follow the music, not the multiplier")
        XCTAssertEqual(BeatClock.pulseDivisor(bpm: 128, cap: 90), 2)
        XCTAssertEqual(BeatClock.pulseDivisor(bpm: 174, cap: 90), 2)
        XCTAssertEqual(BeatClock.pulseDivisor(bpm: 190, cap: 90), 4)
        XCTAssertEqual(BeatClock.pulseDivisor(bpm: 120, cap: 130), 1)
    }

    func testSettingsDecodeLegacyAndGarbage() throws {
        let legacy = #"{"enabled":true,"mood":"oceanDrift","reactivity":0.4,"silenceFadeSeconds":4,"source":"input"}"#
        let s = try JSONDecoder().decode(MusicModeSettings.self, from: Data(legacy.utf8))
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.mood, .oceanDrift)
        XCTAssertEqual(s.reactivity, 0.4, accuracy: 1e-9)
        XCTAssertEqual(s.silenceFadeSeconds, 4)
        XCTAssertEqual(s.source, .input)
        XCTAssertTrue(s.photosensitiveSafe)
        XCTAssertFalse(s.allowStrobe)
        let junk = #"{"mood":"disco-inferno","speed":99,"tempoMultiplier":3,"pulseRate":"warp","agc":"loud","paletteIndex":-4}"#
        let j = try JSONDecoder().decode(MusicModeSettings.self, from: Data(junk.utf8))
        XCTAssertEqual(j.mood, .aurora)
        XCTAssertEqual(j.speed, 2)
        XCTAssertEqual(j.tempoMultiplier, 1)
        XCTAssertEqual(j.pulseRate, .auto)
        XCTAssertEqual(j.agc, .normal)
        XCTAssertEqual(j.paletteIndex, 0)
        let round = try JSONDecoder().decode(MusicModeSettings.self, from: JSONEncoder().encode(MusicModeSettings()))
        XCTAssertEqual(round, MusicModeSettings())
        XCTAssertEqual(MusicModeSettings().mood, .auto)
        XCTAssertEqual(MusicMood.concrete.count, 16)
    }
}
