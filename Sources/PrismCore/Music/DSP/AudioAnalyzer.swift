import Foundation

/// Fixed-capacity ring of 16-lane vectors with timestamps (chroma history for downbeats).
final class VectorRing {
    private var items: [SIMD16<Double>]
    let times: History
    private var head = -1
    private(set) var count = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        items = [SIMD16<Double>](repeating: SIMD16<Double>(repeating: 0), count: self.capacity)
        times = History(capacity: self.capacity)
    }

    func push(_ v: SIMD16<Double>, time: Double) {
        head = (head + 1) % capacity
        items[head] = v
        times.push(time)
        count = min(capacity, count + 1)
    }

    /// Mean of the vectors whose time lies in `[t0, t1]` (zero vector when none).
    func mean(from t0: Double, to t1: Double) -> SIMD16<Double> {
        var s = SIMD16<Double>(repeating: 0)
        var n = 0.0
        for ago in 0..<count {
            let t = times[ago]
            if t < t0 { break }
            if t <= t1 {
                var i = head - ago
                if i < 0 { i += capacity }
                s += items[i]
                n += 1
            }
        }
        return n > 0 ? s / n : s
    }

    func reset() { head = -1; count = 0; times.reset() }
}

/// Musical structure (§1.9, §1.12, §1.13): downbeat accumulator, phrases, novelty and section
/// changes, build-ups, drops, breakdowns and the energy tier.
final class StructureTracker {
    // Novelty.
    private var muS = [Double](repeating: 0, count: 20)
    private var muL = [Double](repeating: 0, count: 20)
    private var noveltyInit = false
    private let dHist = History(capacity: 240)
    private var lastZ = 0.0
    private var lastUpdate = -Double.infinity
    private(set) var novelty = 0.0
    private(set) var sectionCount: UInt32 = 0
    private(set) var lastSectionChangeTime = -1_000.0
    private var pendingSectionSince: Double?

    // Low end.
    private var eLow2 = EMA(), eLow16 = EMA()
    private(set) var bassRatioLong = 1.0
    let lowEnergy = History(capacity: 512)
    let lowTimes = History(capacity: 512)
    let bassPitch = History(capacity: 128)
    let bassTimes = History(capacity: 128)

    // Build-up / breakdown (250 ms samples).
    private let brightHist = History(capacity: 64)
    private let densityHist = History(capacity: 64)
    private let loudSlowHist = History(capacity: 64)
    private let buildHist = History(capacity: 64)
    private let scratch = DoubleBuffer(64)
    private(set) var buildup = 0.0
    private var lowRatioSeconds = 0.0
    private var breakdownSeconds = 0.0
    private(set) var isBreakdown = false

    // Drops.
    private(set) var dropCount: UInt32 = 0
    private(set) var lastDropTime = -1_000.0
    private(set) var lastDropStrength = 0.0

    // Energy.
    private var energyEMA = EMA()
    private(set) var energy = 0.0
    private(set) var tier: EnergyTier = .calm
    private var tierSince = 0.0

    // Downbeats.
    private var acc: (Double, Double, Double, Double) = (0, 0, 0, 0)
    private(set) var downbeatOffset = 0
    private var downbeatAssigned = false
    private var switchVotes = 0
    private(set) var downbeatConfidence = 0.0
    private var evaluatedBeats = 0
    private var pendingK = [Int64](repeating: 0, count: 8)
    private var pendingT = [Double](repeating: 0, count: 8)
    private var pendingCount = 0
    private var lastKickEvalTime = -1_000.0

    // Phrase.
    private(set) var phraseAnchorBar: Int64 = 0

    /// Bar duration used when no beat is trusted.
    private func barDuration(period: Double?, confidence: Double) -> Double {
        if let T = period, confidence > 0.3 { return 4 * T }
        return 2.0
    }

    // MARK: Inputs

    func pushSpectral(lowEnergy e: Double, bassPitch p: Double, time t: Double, dt: Double, silent: Bool) {
        lowEnergy.push(e)
        lowTimes.push(t)
        bassPitch.push(p)
        bassTimes.push(t)
        guard !silent else { return }
        let a = eLow2.step(e, dt: dt, tau: 2)
        let b = eLow16.step(e, dt: dt, tau: 16)
        bassRatioLong = b > 1e-12 ? a / b : 1
    }

    /// Queues a beat for evaluation 0.26 s later (when the post-beat chroma window is complete).
    func queueBeat(_ k: Int64, time t: Double) {
        if pendingCount == pendingK.count {
            for i in 1..<pendingCount { pendingK[i - 1] = pendingK[i]; pendingT[i - 1] = pendingT[i] }
            pendingCount -= 1
        }
        pendingK[pendingCount] = k
        pendingT[pendingCount] = t
        pendingCount += 1
    }

    struct Context {
        var time: Double
        var silent: Bool
        var period: Double?
        var beatConfidence: Double
        var locked: Bool
        var bands: Bands6
        var bandsSlowBass: Double
        var brightness: Double
        var flatness: Double
        var chromaColor: SIMD16<Double>
        var onsetDensity: Double
        var loudness: Double
        var loudnessSlow: Double
        var kick: OnsetEvent
    }

    /// Per-hop update: novelty/build-up/energy every 250 ms plus due beat evaluations.
    func update(_ c: Context, rhythm: RhythmTracker, chroma: VectorRing) {
        // Due beat evaluations.
        while pendingCount > 0 && c.time >= pendingT[0] + 0.26 {
            let k = pendingK[0], tb = pendingT[0]
            for i in 1..<max(1, pendingCount) { pendingK[i - 1] = pendingK[i]; pendingT[i - 1] = pendingT[i] }
            pendingCount -= 1
            evaluateBeat(k, at: tb, c, rhythm: rhythm, chroma: chroma)
        }
        // Without a trusted beat, drops are checked on kick onsets instead.
        if !c.locked, c.kick.time > lastKickEvalTime + 0.4, c.time >= c.kick.time + 0.26 {
            lastKickEvalTime = c.kick.time
            checkDrop(at: c.kick.time, c, kickNear: true)
        }
        guard c.time - lastUpdate >= 0.25 else { return }
        let dt = lastUpdate.isFinite ? min(1.0, c.time - lastUpdate) : 0.25
        lastUpdate = c.time
        guard !c.silent else { return }
        updateNovelty(c, dt: dt)
        updateBuildup(c, dt: dt)
        updateEnergy(c, dt: dt)
        // A pending section change fires on the next downbeat, or after one bar at the latest.
        if let since = pendingSectionSince, c.time - since > barDuration(period: c.period, confidence: c.beatConfidence) + 0.3 {
            fireSection(at: c.time, anchorPhraseBar: nil)
        }
    }

    private func updateNovelty(_ c: Context, dt: Double) {
        // Build the 20-dim vector in place (no allocation): 6 bands, brightness, flatness, 12 × ½ chroma.
        let aS = onePoleAlpha(dt: dt, tau: 1), aL = onePoleAlpha(dt: dt, tau: 8)
        var d2 = 0.0
        for i in 0..<20 {
            let x: Double
            switch i {
            case 0..<6: x = c.bands[i]
            case 6: x = c.brightness
            case 7: x = c.flatness
            default: x = 0.5 * c.chromaColor[i - 8]
            }
            if !noveltyInit { muS[i] = x; muL[i] = x }
            muS[i] += aS * (x - muS[i])
            muL[i] += aL * (x - muL[i])
            let d = muS[i] - muL[i]
            d2 += d * d
        }
        noveltyInit = true
        let d = sqrt(d2 / 20)
        let (mean, std) = dHist.meanStd(last: 240)
        dHist.push(d)
        guard dHist.count >= 16 else { novelty = 0; lastZ = 0; return }
        let z = (d - mean) / max(std, 1e-4)
        novelty = clamp01(z / 4)
        let rising = z > lastZ
        lastZ = z
        if z > 2.5 && rising && c.time - lastSectionChangeTime >= 8 && pendingSectionSince == nil {
            if c.beatConfidence > 0.5 && c.locked {
                pendingSectionSince = c.time
            } else {
                fireSection(at: c.time, anchorPhraseBar: nil)
            }
        }
    }

    private func fireSection(at t: Double, anchorPhraseBar: Int64?) {
        pendingSectionSince = nil
        guard t - lastSectionChangeTime >= 8 else { return }
        sectionCount &+= 1
        lastSectionChangeTime = t
        if let bar = anchorPhraseBar { phraseAnchorBar = bar }
    }

    private func slopePerBar(_ h: History, samplesPerBar: Double, bars: Double) -> Double {
        let n = min(h.count, max(2, Int(samplesPerBar * bars)), scratch.count)
        guard n >= 4 else { return 0 }
        h.copyChronological(last: n, into: scratch.p)
        return leastSquaresSlope(scratch.p, count: n) * samplesPerBar
    }

    private func updateBuildup(_ c: Context, dt: Double) {
        brightHist.push(c.brightness)
        densityHist.push(c.onsetDensity)
        loudSlowHist.push(c.loudnessSlow)
        let bar = barDuration(period: c.period, confidence: c.beatConfidence)
        let spb = bar / 0.25
        let sb = slopePerBar(brightHist, samplesPerBar: spb, bars: 4)
        let sd = slopePerBar(densityHist, samplesPerBar: spb, bars: 4)
        let sl = slopePerBar(loudSlowHist, samplesPerBar: spb, bars: 4)
        let ratio = clamp01(bassRatioLong)
        buildup = clamp01(0.35 * sb / 0.1 + 0.25 * sd / 0.1 + 0.25 * (1 - ratio) + 0.15 * sl / 0.1)
        buildHist.push(buildup)
        lowRatioSeconds = bassRatioLong < 0.3 ? lowRatioSeconds + dt : 0
        breakdownSeconds = bassRatioLong < 0.16 ? breakdownSeconds + dt : 0
        if isBreakdown {
            if bassRatioLong > 0.5 { isBreakdown = false }
        } else if breakdownSeconds >= 2 * bar {
            let maxLoud = loudSlowHist.max(last: 64)
            if maxLoud - c.loudnessSlow >= 0.2 { isBreakdown = true }
        }
    }

    private func updateEnergy(_ c: Context, dt: Double) {
        let raw = 0.45 * c.loudnessSlow + 0.25 * c.onsetDensity + 0.20 * c.bandsSlowBass + 0.10 * c.brightness
        energy = clamp01(energyEMA.step(raw, dt: dt, tau: 3))
        let dwell = barDuration(period: c.period, confidence: c.beatConfidence) * 2
        guard c.time - tierSince >= dwell else { return }
        var next = tier
        switch tier {
        case .calm: if energy >= 0.37 { next = energy >= 0.70 ? .peak : .groove }
        case .groove:
            if energy >= 0.70 { next = .peak } else if energy < 0.29 { next = .calm }
        case .peak: if energy < 0.62 { next = energy < 0.29 ? .calm : .groove }
        }
        if next != tier { tier = next; tierSince = c.time }
    }

    // MARK: Beats

    private func evaluateBeat(_ k: Int64, at tb: Double, _ c: Context, rhythm: RhythmTracker, chroma: VectorRing) {
        // Feature window ±60 ms around the beat.
        var kickS = 0.0, snareS = 0.0
        for ago in 0..<rhythm.zTimes.count {
            let t = rhythm.zTimes[ago]
            if t < tb - 0.06 { break }
            if t <= tb + 0.06 {
                kickS = max(kickS, rhythm.zLow[ago])
                snareS = max(snareS, rhythm.zMid[ago])
            }
        }
        kickS = clamp(kickS, 0, 8)
        snareS = clamp(snareS, 0, 8)
        let before = chroma.mean(from: tb - 0.25, to: tb - 0.001)
        let after = chroma.mean(from: tb + 0.001, to: tb + 0.25)
        let nb = (before * before).sum().squareRoot(), na = (after * after).sum().squareRoot()
        let chordDelta = (nb > 1e-9 && na > 1e-9) ? clamp01(1 - (before * after).sum() / (nb * na)) : 0
        let pb = meanPitch(from: tb - 0.2, to: tb - 0.02), pa = meanPitch(from: tb + 0.02, to: tb + 0.2)
        let bassDelta: Double = (pb > 0 && pa > 0 && abs(12 * log2(pa / pb)) > 1) ? 1 : 0
        let novS: Double = novelty > 0.6 ? 1 : 0
        let score = 1.0 * kickS + 1.5 * chordDelta + 0.5 * bassDelta + 1.0 * novS - 0.7 * snareS
        let slot = Int(((k % 4) + 4) % 4)
        switch slot {
        case 0: acc.0 = 0.9 * acc.0 + score
        case 1: acc.1 = 0.9 * acc.1 + score
        case 2: acc.2 = 0.9 * acc.2 + score
        default: acc.3 = 0.9 * acc.3 + score
        }
        evaluatedBeats += 1
        updateDownbeat(beat: k)

        let isDownbeat = Int(((k - Int64(downbeatOffset)) % 4 + 4) % 4) == 0
        if isDownbeat, pendingSectionSince != nil {
            fireSection(at: tb, anchorPhraseBar: floorDiv(k - Int64(downbeatOffset), 4))
        }
        if c.locked && (isDownbeat || downbeatConfidence < 0.5) {
            checkDrop(at: tb, c, kickNear: kickS > 2 || abs(c.kick.time - tb) <= 0.06)
            if lastDropTime == tb {
                // Drops re-anchor the phrase grid when they land on a downbeat.
                if isDownbeat { phraseAnchorBar = floorDiv(k - Int64(downbeatOffset), 4) }
            }
        }
    }

    private func meanPitch(from t0: Double, to t1: Double) -> Double {
        var s = 0.0, n = 0.0
        for ago in 0..<bassTimes.count {
            let t = bassTimes[ago]
            if t < t0 { break }
            if t <= t1, bassPitch[ago] > 0 { s += bassPitch[ago]; n += 1 }
        }
        return n > 0 ? s / n : 0
    }

    private func accValue(_ i: Int) -> Double {
        switch i { case 0: return acc.0; case 1: return acc.1; case 2: return acc.2; default: return acc.3 }
    }

    private func updateDownbeat(beat k: Int64) {
        var best = 0
        for i in 1..<4 where accValue(i) > accValue(best) { best = i }
        var second = -Double.infinity
        for i in 0..<4 where i != best { second = max(second, accValue(i)) }
        let top = accValue(best)
        downbeatConfidence = clamp01((top - second) / (abs(top) + 1e-9))
        if !downbeatAssigned {
            if evaluatedBeats >= 8 { downbeatOffset = best; downbeatAssigned = true }
            return
        }
        // Consider switching once per bar (at the last beat of the current bar).
        let posInBar = Int(((k - Int64(downbeatOffset)) % 4 + 4) % 4)
        guard posInBar == 3 else { return }
        if best != downbeatOffset && top > 1.2 * accValue(downbeatOffset) && top > 0 {
            switchVotes += 1
            if switchVotes >= 2 { downbeatOffset = best; switchVotes = 0 }
        } else {
            switchVotes = 0
        }
    }

    private func checkDrop(at tb: Double, _ c: Context, kickNear: Bool) {
        guard kickNear, tb - lastDropTime >= 16, c.loudness >= 0.7 else { return }
        let bar = barDuration(period: c.period, confidence: c.beatConfidence)
        var post = 0.0, postN = 0.0, pre = 0.0, preN = 0.0
        for ago in 0..<lowTimes.count {
            let t = lowTimes[ago]
            if t < tb - 2 * bar { break }
            if t >= tb && t <= tb + 0.25 { post += lowEnergy[ago]; postN += 1 }
            else if t < tb { pre += lowEnergy[ago]; preN += 1 }
        }
        guard postN > 0, preN > 0 else { return }
        let deltaB = 10 * log10(post / postN + 1e-12) - 10 * log10(pre / preN + 1e-12)
        let barsBack = max(2, Int((2 * bar / 0.25).rounded()))
        let maxBuild = buildHist.max(last: barsBack)
        let primed = maxBuild > 0.4 || lowRatioSeconds >= 2 * bar || bassRatioLong < 0.3
        guard deltaB >= 6, primed else { return }
        dropCount &+= 1
        lastDropTime = tb
        lastDropStrength = clamp01((deltaB - 6) / 6 + 0.5 * maxBuild)
        isBreakdown = false
        // A drop is also a section boundary.
        if tb - lastSectionChangeTime >= 4 {
            sectionCount &+= 1
            lastSectionChangeTime = tb
            pendingSectionSince = nil
        }
    }

    func reset() {
        for i in 0..<20 { muS[i] = 0; muL[i] = 0 }
        noveltyInit = false
        dHist.reset(); lastZ = 0; lastUpdate = -.infinity; novelty = 0; pendingSectionSince = nil
        eLow2.reset(); eLow16.reset(); bassRatioLong = 1
        lowEnergy.reset(); lowTimes.reset(); bassPitch.reset(); bassTimes.reset()
        brightHist.reset(); densityHist.reset(); loudSlowHist.reset(); buildHist.reset()
        buildup = 0; lowRatioSeconds = 0; breakdownSeconds = 0; isBreakdown = false
        energyEMA.reset(); energy = 0; tier = .calm; tierSince = 0
        acc = (0, 0, 0, 0); downbeatAssigned = false; switchVotes = 0; downbeatConfidence = 0
        evaluatedBeats = 0; pendingCount = 0; lastKickEvalTime = -1_000
        // Counters (sections, drops) keep increasing so consumers' "last seen" logic stays valid.
    }
}

@inline(__always)
func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
}

/// The real-time music analyzer: push mono samples at 48 kHz, read `AudioFeatures` snapshots.
///
/// Runs the rhythm (1024/512), spectral (4096/1024), tonal (8192/2048) and loudness paths of
/// `docs/research/music_reactive.md` §1. Single-threaded by design: call it from one analysis
/// thread only. Every buffer is allocated in `init`, so steady-state processing never
/// allocates and never locks.
public final class AudioAnalyzer {
    /// Analysis tuning that can change while running.
    public struct Configuration: Sendable, Equatable {
        public var agc: AGCPreset
        /// Silence threshold (dBFS); music returns 10 dB above it.
        public var silenceThresholdDB: Double
        /// 0.5 = half time, 1 = as detected, 2 = double time.
        public var tempoMultiplier: Double
        /// Seconds added to render time to find the capture instant to depict (§1.15).
        public var latencyOffset: Double

        public init(agc: AGCPreset = .normal, silenceThresholdDB: Double = -60, tempoMultiplier: Double = 1,
                    latencyOffset: Double = 0.075) {
            self.agc = agc; self.silenceThresholdDB = silenceThresholdDB
            self.tempoMultiplier = tempoMultiplier; self.latencyOffset = latencyOffset
        }
    }

    public static let sampleRate = 48_000.0
    static let historySize = 8192
    static let hop = 512

    public var configuration: Configuration {
        didSet { silence.thresholdDB = clamp(configuration.silenceThresholdDB.finiteOr(-60), -90, -30) }
    }

    let rhythm = RhythmTracker()
    let spectral = SpectralAnalyzer()
    let loudness = LoudnessMeter()
    let tonal = TonalAnalyzer()
    let structure = StructureTracker()
    let chroma = VectorRing(capacity: 64)
    public private(set) var silence = SilenceGate()

    private let buffer: FloatBuffer
    private var fill = AudioAnalyzer.historySize
    private var samplesSinceHop = 0
    private var hopCounter = 0
    /// Total samples processed since `reset`.
    public private(set) var totalSamples: Int64 = 0
    private var baseTime = 0.0
    private var baseSample: Int64 = 0
    private var timeSynced = false
    private var lastPublishedBeatCount: Int64 = .min
    private var lastSnapshotBeat: Int64 = .min
    private var lastSnapshotSections: UInt64 = 0
    private var lastMultiplier = 1.0

    /// - Parameter startTime: capture time of the first sample when the caller supplies no host
    ///   times (tests, synthetic input).
    public init(configuration: Configuration = Configuration(), startTime: Double = 0) {
        self.configuration = configuration
        buffer = FloatBuffer(AudioAnalyzer.historySize * 3)
        baseTime = startTime
        silence.thresholdDB = clamp(configuration.silenceThresholdDB.finiteOr(-60), -90, -30)
        rhythm.onBeat = { [unowned self] k, t in self.structure.queueBeat(k, time: t) }
    }

    /// Clears all analysis state (new source). Counters keep increasing.
    public func reset(startTime: Double = 0) {
        rhythm.reset(); spectral.reset(); loudness.reset(); tonal.reset(); structure.reset(); chroma.reset()
        silence.reset()
        buffer.fill(0)
        fill = AudioAnalyzer.historySize
        samplesSinceHop = 0
        hopCounter = 0
        totalSamples = 0
        baseTime = startTime
        baseSample = 0
        timeSynced = false
    }

    /// Capture time of absolute sample index `s`.
    @inline(__always)
    func time(ofSample s: Int64) -> Double { baseTime + Double(s - baseSample) / AudioAnalyzer.sampleRate }

    /// Capture time of the newest processed sample.
    public var currentTime: Double { time(ofSample: totalSamples) }

    /// Processes mono samples at 48 kHz. `time` is the capture time (PrismClock seconds) of the
    /// first sample when known; gaps and slow clock drift are absorbed automatically.
    public func process(_ samples: UnsafePointer<Float>, count: Int, time: Double? = nil) {
        guard count > 0 else { return }
        if let t = time, t.isFinite { sync(firstSampleTime: t) }
        var i = 0
        while i < count {
            let n = min(AudioAnalyzer.hop - samplesSinceHop, count - i)
            if fill + n > buffer.count {
                // Compact: keep the last `historySize` samples at the front.
                let keep = AudioAnalyzer.historySize
                memmove(buffer.p, buffer.p + (fill - keep), keep * MemoryLayout<Float>.stride)
                fill = keep
            }
            let dst = buffer.p + fill
            for j in 0..<n {
                var x = samples[i + j]
                if !x.isFinite { x = 0 }
                x = max(-4, min(4, x))
                dst[j] = x
                loudness.process(x)
            }
            fill += n
            samplesSinceHop += n
            totalSamples += Int64(n)
            i += n
            if samplesSinceHop == AudioAnalyzer.hop {
                samplesSinceHop = 0
                runHop()
            }
        }
    }

    /// Convenience for arrays (tests, self-test).
    public func process(_ samples: [Float], time: Double? = nil) {
        samples.withUnsafeBufferPointer { bp in
            if let base = bp.baseAddress { process(base, count: bp.count, time: time) }
        }
    }

    private func sync(firstSampleTime t: Double) {
        let expected = time(ofSample: totalSamples)
        let err = t - expected
        if !timeSynced || abs(err) > 0.25 {
            if timeSynced, err > 0, let T = rhythm.clockPeriod {
                rhythm.skip(seconds: err, period: T)
            }
            baseTime = t
            baseSample = totalSamples
            timeSynced = true
        } else {
            baseTime += 0.02 * err   // absorb slow device-clock drift
        }
    }

    private func runHop() {
        hopCounter &+= 1
        let s = totalSamples
        let end = buffer.p + fill
        rhythm.process(window: UnsafePointer(end - RhythmTracker.frameSize), centerTime: time(ofSample: s - 512))
        let cfg = configuration
        if hopCounter % 2 == 0 {
            loudness.finishBlock(silent: silence.isSilent, referenceRelease: cfg.agc.referenceRelease)
            silence.update(levelDB: loudness.levelDB, exactZeros: loudness.lastBlockAllZero,
                           dt: Double(LoudnessMeter.blockSize) / AudioAnalyzer.sampleRate, time: time(ofSample: s))
            spectral.process(window: UnsafePointer(end - SpectralAnalyzer.size), peakRelease: cfg.agc.peakRelease,
                             frozen: silence.isSilent)
            structure.pushSpectral(lowEnergy: spectral.lowEnergy, bassPitch: spectral.bassPitch,
                                   time: time(ofSample: s - 2048), dt: SpectralAnalyzer.dt, silent: silence.isSilent)
        }
        if hopCounter % 4 == 0 {
            tonal.process(window: UnsafePointer(end - TonalAnalyzer.size), frozen: silence.isSilent)
            chroma.push(tonal.raw, time: time(ofSample: s - 4096))
        }
        let t = time(ofSample: s - 512)
        let ctx = StructureTracker.Context(
            time: t, silent: silence.isSilent, period: rhythm.clockPeriod, beatConfidence: rhythm.confidence,
            locked: rhythm.isLocked, bands: spectral.rawBands, bandsSlowBass: spectral.bandsSlow.bass,
            brightness: spectral.brightness, flatness: spectral.flatness, chromaColor: tonal.color,
            onsetDensity: rhythm.onsetDensity(at: t), loudness: loudness.loudness,
            loudnessSlow: loudness.loudnessSlow, kick: rhythm.kick)
        structure.update(ctx, rhythm: rhythm, chroma: chroma)
    }

    // MARK: Manual tempo

    /// Seeds the beat clock from tap tempo. `lastTapTime` is the capture-timeline time of the last
    /// tap (subtract the latency offset from the render-time tap).
    public func applyTap(bpm: Double, lastTapTime: Double) {
        let m = configuration.tempoMultiplier > 0 ? configuration.tempoMultiplier : 1
        rhythm.applyTap(bpm: bpm / m, beatTime: lastTapTime)
    }

    // MARK: Snapshot

    /// Builds the features for the newest analysed instant (cheap; no allocation).
    public func snapshot() -> AudioFeatures {
        var f = AudioFeatures()
        let t = rhythm.frameIndex >= 0 ? rhythm.frameTime : currentTime
        f.timestamp = t
        f.latencyOffset = configuration.latencyOffset.finiteOr(0)
        f.isActive = !silence.isSilent
        f.presence = silence.presence
        f.digitalSilence = silence.digitalSilence
        f.silentSeconds = silence.silentSeconds(at: t)
        f.levelDBFS = loudness.levelDB

        f.level = loudness.loudness
        f.loudnessSlow = loudness.loudnessSlow
        f.loudnessLUFS = loudness.momentaryLUFS
        f.agcReferenceLUFS = loudness.reference

        f.bandLevels = spectral.bands
        f.bandsFast = spectral.bandsFast
        f.bandsSlow = spectral.bandsSlow
        f.spectrum16 = spectral.spectrum16
        f.brightness = spectral.brightness
        f.flatness = spectral.flatness

        f.onsetEvent = rhythm.onset
        f.kickEvent = rhythm.kick
        f.snareEvent = rhythm.snare
        f.hihatEvent = rhythm.hihat
        f.onset = rhythm.onset.envelope(at: t, tau: 0.150)
        f.kick = rhythm.kick.envelope(at: t, tau: 0.180)
        f.snare = rhythm.snare.envelope(at: t, tau: 0.150)
        f.hihat = rhythm.hihat.envelope(at: t, tau: 0.070)
        f.onsetDensity = rhythm.onsetDensity(at: t)
        f.onsetCount = rhythm.onsetCount

        let requested = configuration.tempoMultiplier
        let m = (requested == 0.5 || requested == 2) ? requested : 1.0
        if m != lastMultiplier { lastPublishedBeatCount = .min; lastMultiplier = m }
        let period = rhythm.clockPeriod ?? 0
        f.clock = BeatClock(anchorTime: rhythm.frameTime, anchorBeats: rhythm.beats, period: period,
                            multiplier: m, downbeatOffset: structure.downbeatOffset,
                            phraseAnchorBar: structure.phraseAnchorBar, confidence: rhythm.confidence,
                            isLocked: rhythm.isLocked)
        f.tempoEstimate = rhythm.tempoEstimate * m
        f.bpm = period > 0 ? f.clock.bpm : 0
        f.tempoConfidence = period > 0 ? rhythm.confidence : 0
        f.beatPhase = f.clock.beatPhase(at: t)
        var bc = f.clock.beatIndex(at: t)
        if bc < lastPublishedBeatCount { bc = lastPublishedBeatCount }
        lastPublishedBeatCount = bc
        f.beatCount = bc
        f.beat = lastSnapshotBeat != .min && bc > lastSnapshotBeat
        lastSnapshotBeat = bc
        f.barPhase = f.clock.barPhase(at: t)
        f.beatInBar = f.clock.beatInBar(at: t)
        f.barCount = f.clock.barIndex(at: t)
        f.phrasePhase = f.clock.phrasePhase(at: t)
        f.downbeatConfidence = structure.downbeatConfidence
        f.pulseDivisor = BeatClock.pulseDivisor(bpm: f.bpm, cap: 130)

        f.chromaVector = tonal.display
        f.harmonicHue = tonal.harmonicHue
        f.tonalClarity = tonal.tonalClarity
        f.key = tonal.key
        f.keyConfidence = tonal.keyConfidence

        f.novelty = structure.novelty
        f.energy = structure.energy
        f.energyTier = structure.tier
        f.buildup = structure.buildup
        f.isBreakdown = structure.isBreakdown
        f.sectionCount = structure.sectionCount
        f.lastSectionChangeTime = structure.lastSectionChangeTime
        f.dropCount = structure.dropCount
        f.lastDropTime = structure.lastDropTime
        f.lastDropStrength = structure.lastDropStrength
        let sections = UInt64(structure.sectionCount) &+ UInt64(structure.dropCount) << 32
        f.sectionChange = lastSnapshotSections != 0 && sections != lastSnapshotSections
        lastSnapshotSections = sections == 0 ? 1 : sections
        return f
    }
}
