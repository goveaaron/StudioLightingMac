import Foundation

/// Causal adaptive-threshold peak picker for one onset-detection signal (§1.6).
///
/// `thr[n] = median(W) + k·std(W) + δ` over the last 47 frames, `δ = 0.1·mean₁₀ₛ(x)`.
/// An onset is reported at frame `c = n − 1` iff `x[c] > thr[c] ∧ x[c] ≥ x[c−1] ∧ x[c] > x[n]`
/// and the refractory period has elapsed.
final class OnsetDetector {
    let k: Double
    let refractory: Double
    private let window = SlidingMedian(window: 47)
    private var mean10 = EMA()
    private var xPrev = 0.0     // x[c−1]
    private var xCur = 0.0      // x[c]
    private var thrCur = Double.infinity
    private var medCur = 0.0
    private var stdCur = 0.0
    private var lastOnsetFrame = Int.min / 2
    private var frames = 0

    /// z-score of `x[c]` against its window (valid after `push`).
    private(set) var zAtC = 0.0

    init(k: Double, refractory: Double) {
        self.k = k
        self.refractory = refractory
    }

    /// Pushes `x[n]` for frame `n`. Returns the onset strength (0…1) when frame `n − 1` is an
    /// onset, else nil. Onsets whose z-score is not above `minZ` are vetoed (the snare's
    /// kick-rejection gate passes the low band's z-score here).
    func push(_ raw: Double, frame n: Int, frameDuration: Double, minZ: Double = -Double.infinity) -> Double? {
        let x = raw.isFinite ? max(0, raw) : 0
        var result: Double?
        let c = n - 1
        let std = stdCur + 1e-9
        zAtC = (xCur - medCur) / std
        if frames >= 3, xCur > thrCur, xCur >= xPrev, xCur > x,
           Double(c - lastOnsetFrame) * frameDuration >= refractory - 1e-9 {
            if zAtC > minZ {
                let s = 1 - exp(-max(0, zAtC - k) / 2)
                result = clamp01(s)
                lastOnsetFrame = c
            }
        }
        // Update the window with x[n] and compute thr[n].
        window.push(x)
        let mean = mean10.step(x, dt: frameDuration, tau: 10)
        let ms = window.meanStd
        let med = window.median
        xPrev = xCur
        xCur = x
        medCur = med
        stdCur = ms.std
        thrCur = med + k * ms.std + 0.1 * mean + 1e-4
        frames += 1
        return result
    }

    func reset() {
        window.reset(); mean10.reset()
        xPrev = 0; xCur = 0; thrCur = .infinity; medCur = 0; stdCur = 0
        lastOnsetFrame = Int.min / 2; frames = 0; zAtC = 0
    }
}

/// An onset event: strength jumps up, then decays exponentially (evaluated analytically).
public struct OnsetEvent: Sendable, Equatable {
    /// Capture-timeline time of the onset (PrismClock seconds).
    public var time: Double
    /// Strength at `time`, 0…1.
    public var strength: Double
    public init(time: Double = -1_000, strength: Double = 0) { self.time = time; self.strength = strength }

    /// Envelope value at time `t` with decay constant `tau` (0 before the onset).
    @inline(__always)
    public func envelope(at t: Double, tau: Double) -> Double {
        guard strength > 0, t >= time - 0.005, tau > 0 else { return 0 }
        return strength * exp(-max(0, t - time) / tau)
    }

    /// Registers a new onset of strength `s` at `t` ("jump to strength", never jump down).
    mutating func trigger(at t: Double, strength s: Double, tau: Double) {
        let current = envelope(at: t, tau: tau)
        time = t
        strength = clamp01(max(s, current))
    }
}

/// Rhythm path of the analyzer (§1.6–1.8): log band-flux ODF at 93.75 Hz, onset detectors,
/// tempo estimation every ~0.5 s over a 6 s window, comb-template phase measurement and the
/// gated PLL. A 1:1 port of the reference tracker in Appendix A of
/// `docs/research/music_reactive.md` (its outputs are golden data for the tests).
public final class RhythmTracker {
    public static let sampleRate = 48_000.0
    public static let frameSize = 1024
    public static let hopSize = 512
    public static let fps = sampleRate / Double(hopSize)            // 93.75 Hz
    static let windowFrames = Int(6 * fps)                           // 562
    static let updateStep = Int(fps / 2)                             // 46
    static let lambda: Float = 1000
    static let bpmGridCount = 241                                    // 60 … 180 step 0.5
    static let maxLag = 400

    // PLL constants (Appendix A).
    static let kp = 0.25, ki = 0.05, gate = 0.20, rephaseTolerance = 0.08
    static let lockRun = 6, unlockAfter = 15.0

    // MARK: ODF state
    private let fft: RealFFT
    private let window: FloatBuffer
    private let frame: FloatBuffer
    private let power: FloatBuffer
    private let prevY: FloatBuffer
    private let curY: FloatBuffer
    private var havePrev = false
    private let lowBins: Range<Int>, midBins: Range<Int>, highBins: Range<Int>

    // MARK: Tempo scratch
    private let odf = History(capacity: 1024)
    private let seg: DoubleBuffer
    private let xbuf: DoubleBuffer
    private let acf: DoubleBuffer
    private let acfSel: DoubleBuffer   // 3-lag box sum of `acf`, used only to pick the tempo
    private let phaseScore = DoubleBuffer(256)
    private let prior: DoubleBuffer

    // MARK: Onsets
    private let broadband = OnsetDetector(k: 2.0, refractory: 0.100)
    private let low = OnsetDetector(k: 2.0, refractory: 0.150)
    private let mid = OnsetDetector(k: 2.0, refractory: 0.120)
    private let high = OnsetDetector(k: 1.25, refractory: 0.060)
    /// Broadband onset envelope source (τ 150 ms).
    public private(set) var onset = OnsetEvent()
    /// Low-band (kick) envelope source (τ 180 ms).
    public private(set) var kick = OnsetEvent()
    /// Gated mid-band (snare) envelope source (τ 150 ms).
    public private(set) var snare = OnsetEvent()
    /// High-band (hi-hat) envelope source (τ 70 ms).
    public private(set) var hihat = OnsetEvent()
    /// Monotonic count of broadband onsets.
    public private(set) var onsetCount: UInt64 = 0
    private let onsetTimes = History(capacity: 64)
    /// Per-frame low/mid z-scores (frame c = n − 1), used by downbeat detection.
    let zLow = History(capacity: 96)
    let zMid = History(capacity: 96)
    let zTimes = History(capacity: 96)

    // MARK: Clock / PLL state
    /// Index of the newest ODF frame (−1 before the first).
    public private(set) var frameIndex = -1
    /// Capture-timeline time of the newest ODF frame's centre.
    public private(set) var frameTime = 0.0
    /// Unwrapped beat position Φ at `frameTime`.
    public private(set) var beats = 0.0
    /// Locked beat period (s), nil when unlocked.
    public private(set) var period: Double?
    /// Last period ever locked (keeps the clock flywheeling after an unlock).
    public private(set) var lastPeriod: Double?
    /// beatConfidence: EMA (2 s) of the per-update confidence c.
    public private(set) var confidence = 0.0
    /// Raw tempo estimate of the most recent update (BPM, 0 before the first update).
    public private(set) var tempoEstimate = 0.0
    /// Periodicity of the most recent update (ACF value at the tempo lag).
    public private(set) var periodicity = 0.0
    /// Monotonic beat counter (never decreases).
    public private(set) var beatCount: Int64 = 0
    public private(set) var reseeds = 0
    public private(set) var rephases = 0
    /// Frame time of the first lock (nil until locked once).
    public private(set) var firstLockTime: Double?
    private var hist: (Double, Double, Double, Double) = (0, 0, 0, 0)
    private var histCount = 0
    private var outliers: (Double, Double, Double) = (0, 0, 0)
    private var outlierCount = 0
    private var lowConfSeconds = 0.0
    private var eligible = 0

    /// Called when the beat counter increments: (beat index, capture time of the beat).
    var onBeat: ((Int64, Double) -> Void)?

    public init() {
        let n = RhythmTracker.frameSize
        guard let f = RealFFT(size: n) else { preconditionFailure("RealFFT(1024) must exist") }
        fft = f
        window = FloatBuffer(n)
        let w = RealFFT.hann(n)
        for i in 0..<n { window[i] = w[i] }
        frame = FloatBuffer(n)
        power = FloatBuffer(n / 2 + 1)
        prevY = FloatBuffer(n / 2 + 1)
        curY = FloatBuffer(n / 2 + 1)
        let binHz = RhythmTracker.sampleRate / Double(n)
        func bins(_ lo: Double, _ hi: Double) -> Range<Int> {
            var a = Int.max, b = Int.min
            for k in 0...(n / 2) {
                let f = Double(k) * binHz
                if f >= lo && f < hi { a = min(a, k); b = max(b, k) }
            }
            return a <= b ? a..<(b + 1) : 0..<0
        }
        lowBins = bins(30, 200)
        midBins = bins(200, 2500)
        highBins = bins(2500, 16000)
        seg = DoubleBuffer(RhythmTracker.windowFrames)
        xbuf = DoubleBuffer(RhythmTracker.windowFrames)
        acf = DoubleBuffer(RhythmTracker.maxLag + 1)
        acfSel = DoubleBuffer(RhythmTracker.maxLag + 1)
        prior = DoubleBuffer(RhythmTracker.bpmGridCount)
        for i in 0..<RhythmTracker.bpmGridCount {
            let bpm = 60.0 + 0.5 * Double(i)
            let l = log2(bpm / 120.0)
            prior[i] = exp(-0.5 * l * l)
        }
    }

    /// Clears all state (e.g. when the audio source changes).
    public func reset() {
        havePrev = false
        odf.reset()
        broadband.reset(); low.reset(); mid.reset(); high.reset()
        onset = OnsetEvent(); kick = OnsetEvent(); snare = OnsetEvent(); hihat = OnsetEvent()
        onsetTimes.reset(); zLow.reset(); zMid.reset(); zTimes.reset()
        frameIndex = -1; frameTime = 0; period = nil; lastPeriod = nil
        confidence = 0; tempoEstimate = 0; periodicity = 0
        reseeds = 0; rephases = 0; firstLockTime = nil
        histCount = 0; outlierCount = 0; lowConfSeconds = 0; eligible = 0
        // `beats`/`beatCount` intentionally continue across resets (consumers track the counter).
    }

    /// True once the PLL holds a confident lock.
    public var isLocked: Bool { period != nil }

    /// Beat period currently driving the clock (locked, else the last locked one).
    public var clockPeriod: Double? { period ?? lastPeriod }

    /// Broadband onsets per second over the last 4 s, ÷ 6, clamped to 0…1.
    public func onsetDensity(at t: Double) -> Double {
        var n = 0
        for i in 0..<onsetTimes.count where t - onsetTimes[i] <= 4.0 { n += 1 }
        return min(1, Double(n) / 4.0 / 6.0)
    }

    /// Processes one rhythm hop. `samples` points at the newest `frameSize` samples; `centerTime`
    /// is the capture time of the window centre.
    public func process(window samples: UnsafePointer<Float>, centerTime: Double) {
        let n = RhythmTracker.frameSize
        for i in 0..<n {
            let v = samples[i]
            frame[i] = v.isFinite ? v * window[i] : 0
        }
        fft.powerSpectrum(frame.p, into: power.p)
        let scale: Float = 4.0 / Float(n)
        let bins = n / 2 + 1
        for k in 0..<bins {
            let mag = power[k].squareRoot() * scale
            curY[k] = log10(1 + RhythmTracker.lambda * mag)
        }
        var o = 0.0, sfLow = 0.0, sfMid = 0.0, sfHigh = 0.0
        if havePrev {
            sfLow = meanFlux(lowBins)
            sfMid = meanFlux(midBins)
            sfHigh = meanFlux(highBins)
            o = 0.5 * sfLow + 0.3 * sfMid + 0.2 * sfHigh
        }
        prevY.p.update(from: curY.p, count: bins)
        havePrev = true
        pushODF(o, low: sfLow, mid: sfMid, high: sfHigh, time: centerTime)
    }

    private func meanFlux(_ r: Range<Int>) -> Double {
        guard !r.isEmpty else { return 0 }
        var s: Float = 0
        for k in r { s += max(0, curY[k] - prevY[k]) }
        return Double(s) / Double(r.count)
    }

    /// Feeds one ODF frame (exposed for tests that bypass the FFT).
    func pushODF(_ o: Double, low sfLow: Double, mid sfMid: Double, high sfHigh: Double, time: Double) {
        frameIndex += 1
        frameTime = time
        let i = frameIndex
        let dtf = 1.0 / RhythmTracker.fps
        odf.push(o)

        // Onsets (peak at frame c = i − 1, i.e. one hop earlier).
        let tc = time - dtf
        if let s = broadband.push(o, frame: i, frameDuration: dtf) {
            onset.trigger(at: tc, strength: s, tau: 0.150)
            onsetCount &+= 1
            onsetTimes.push(tc)
        }
        if let s = low.push(sfLow, frame: i, frameDuration: dtf) { kick.trigger(at: tc, strength: s, tau: 0.180) }
        let zl = low.zAtC
        if let s = mid.push(sfMid, frame: i, frameDuration: dtf, minZ: zl) {
            snare.trigger(at: tc, strength: s, tau: 0.150)
        }
        if let s = high.push(sfHigh, frame: i, frameDuration: dtf) { hihat.trigger(at: tc, strength: s, tau: 0.070) }
        zLow.push(low.zAtC)
        zMid.push(mid.zAtC > low.zAtC ? mid.zAtC : 0)
        zTimes.push(tc)

        // Clock advance (flywheels with the last period after an unlock).
        if let T = clockPeriod {
            advance(by: 1.0 / (RhythmTracker.fps * T), at: time)
        }
        let W = RhythmTracker.windowFrames
        if i >= W && (i - W) % RhythmTracker.updateStep == 0 {
            update(at: time)
        }
    }

    private func advance(by delta: Double, at time: Double) {
        beats += delta
        emitBeats(at: time)
    }

    /// Fires `onBeat` for every integer crossed upward beyond the monotonic counter.
    private func emitBeats(at time: Double) {
        let fl = safeInt64(beats.rounded(.down))
        guard fl > beatCount else { return }
        let T = clockPeriod ?? 0.5
        var k = max(beatCount + 1, fl - 8)   // bounded even after a long gap
        while k <= fl {
            onBeat?(k, time - (beats - Double(k)) * T)
            k += 1
        }
        beatCount = fl
    }

    // MARK: Tempo + phase + PLL (every ~0.5 s)

    private func update(at time: Double) {
        let W = RhythmTracker.windowFrames
        odf.copyChronological(last: W, into: seg.p)
        let fps = RhythmTracker.fps
        let rCount = tempoScores()
        // Grid argmax of S · prior.
        var bestK = 0
        var bestV = -Double.infinity
        for g in 0..<RhythmTracker.bpmGridCount {
            let bpm = 60.0 + 0.5 * Double(g)
            let s = combScore(bpm: bpm, rCount: rCount) * prior[g]
            if s > bestV { bestV = s; bestK = g }
        }
        // Octave-up check with the box-summed ACF: a fast tempo whose period falls between two
        // frames (150 BPM = 37.5 frames) splits its narrow ACF peaks and loses to half time.
        let bpm0 = 60.0 + 0.5 * Double(bestK)
        let upK = 120 + 2 * bestK                     // grid index of 2 × bpm0
        if bpm0 <= 90, upK < RhythmTracker.bpmGridCount {
            let sUp = combScore(bpm: 2 * bpm0, rCount: rCount, box: true) * prior[upK]
            let sBase = combScore(bpm: bpm0, rCount: rCount, box: true) * prior[bestK]
            if sUp > sBase { bestK = upK }
        }
        let tau0 = 60 * fps / (60.0 + 0.5 * Double(bestK))
        let tau = refineTau(tau0, rCount: rCount)
        let bpm = 60 * fps / tau
        let per = interpLinear(acf.p, count: rCount, tau)
        let (pBest, pz) = phaseEstimate(tau: tau)
        var phiMeas = (pBest / tau).truncatingRemainder(dividingBy: 1)
        if phiMeas < 0 { phiMeas += 1 }
        tempoEstimate = bpm.isFinite ? bpm : 0
        periodicity = per.isFinite ? per : 0

        // Stability over the last 4 estimates.
        pushHist(bpm)
        var stable = false
        if histCount >= 3 {
            var lo = Double.infinity, hi = -Double.infinity
            for j in 0..<histCount { let v = histValue(j); lo = min(lo, v); hi = max(hi, v) }
            stable = lo > 0 && (hi / lo - 1) < 0.02
        }
        let c = clamp01((per - 0.12) / 0.18) * (stable ? 1.0 : 0.25)
        confidence += (1 - exp(-0.5 / 2.0)) * (c - confidence)
        lowConfSeconds = c < 0.2 ? lowConfSeconds + 0.5 : 0
        eligible = (stable && c > 0.5) ? eligible + 1 : 0

        if period == nil {
            if eligible >= RhythmTracker.lockRun, bpm.isFinite, bpm > 0 {
                period = 60 / bpm
                lastPeriod = period
                setPhase(phiMeas, at: time)
                outlierCount = 0
                if firstLockTime == nil { firstLockTime = time }
            }
        } else if var T = period {
            if stable && c > 0.6 && abs(60 / bpm - T) / T > 0.03 {
                T = 60 / bpm
                setPhase(phiMeas, at: time)
                outlierCount = 0
                reseeds += 1
            }
            if pz > 3.5 {
                let e = wrapHalf(phiMeas - frac(beats))
                if abs(e) <= RhythmTracker.gate {
                    shiftPhase(RhythmTracker.kp * c * e, at: time)
                    T *= (1 - RhythmTracker.ki * c * e)
                    outlierCount = 0
                } else {
                    pushOutlier(e)
                    if outlierCount == 3 && c > 0.5 {
                        let (o0, o1, o2) = outliers
                        let tp = 2 * Double.pi
                        let ss = sin(tp * o0) + sin(tp * o1) + sin(tp * o2)
                        let cc = cos(tp * o0) + cos(tp * o1) + cos(tp * o2)
                        let m = atan2(ss, cc) / tp
                        let worst = max(abs(wrapHalf(o0 - m)), abs(wrapHalf(o1 - m)), abs(wrapHalf(o2 - m)))
                        if worst < RhythmTracker.rephaseTolerance {
                            shiftPhase(m, at: time)
                            outlierCount = 0
                            rephases += 1
                        }
                    }
                }
            }
            if T.isFinite && T > 0.2 && T < 2.0 {
                period = T
                lastPeriod = T
            }
            if lowConfSeconds >= RhythmTracker.unlockAfter {
                period = nil
                outlierCount = 0
            }
        }
    }

    private func setPhase(_ phi: Double, at time: Double) {
        shiftPhase(wrapHalf(phi - frac(beats)), at: time)
    }

    private func shiftPhase(_ d: Double, at time: Double) {
        guard d.isFinite else { return }
        beats += d
        if d > 0 { emitBeats(at: time) }
    }

    private func pushHist(_ v: Double) {
        let x = v.isFinite ? v : 0
        switch histCount {
        case 0: hist.0 = x
        case 1: hist.1 = x
        case 2: hist.2 = x
        case 3: hist.3 = x
        default: hist = (hist.1, hist.2, hist.3, x)
        }
        histCount = min(4, histCount + 1)
    }

    private func histValue(_ j: Int) -> Double {
        switch j { case 0: return hist.0; case 1: return hist.1; case 2: return hist.2; default: return hist.3 }
    }

    private func pushOutlier(_ e: Double) {
        switch outlierCount {
        case 0: outliers.0 = e
        case 1: outliers.1 = e
        case 2: outliers.2 = e
        default: outliers = (outliers.1, outliers.2, e)
        }
        outlierCount = min(3, outlierCount + 1)
    }

    /// Unbiased, normalised ACF of the mean-removed, half-wave-rectified ODF (`tempo_scores`).
    /// Returns the number of valid lags written to `acf`.
    private func tempoScores() -> Int {
        let L = RhythmTracker.windowFrames
        // ±8-frame moving average with zero padding ('same' convolution).
        var running = 0.0
        for q in 0..<min(L, 9) { running += seg[q] }   // window for j = 0 covers q ∈ [−8, 8]
        var mean = 0.0
        for j in 0..<L {
            let m = running / 17.0
            let v = max(0, seg[j] - m)
            xbuf[j] = v
            mean += v
            // Slide: add q = j + 9, remove q = j − 8.
            let add = j + 9, rem = j - 8
            if add < L { running += seg[add] }
            if rem >= 0 { running -= seg[rem] }
        }
        mean /= Double(L)
        for j in 0..<L { xbuf[j] -= mean }
        let lags = min(L, RhythmTracker.maxLag + 1)
        for k in 0..<lags {
            var s = 0.0
            var n = 0
            let p = xbuf.p
            while n + k < L { s += p[n] * p[n + k]; n += 1 }
            acf[k] = s / Double(L - k)
        }
        let r0 = acf[0] + 1e-12
        for k in 0..<lags { acf[k] /= r0 }
        // Selection copy: a 3-lag box sum. A period that falls between two frames (150 BPM =
        // 37.5 frames) splits its ACF peak across two lags; summing neighbours lets it score like
        // an integer period, so the octave choice is left to the tempo prior.
        for k in 0..<lags {
            let a = k > 0 ? acf[k - 1] : (lags > 1 ? acf[1] : acf[0])   // the ACF is symmetric
            let c = k + 1 < lags ? acf[k + 1] : acf[k]
            acfSel[k] = a + acf[k] + c
        }
        return lags
    }

    private func combScore(bpm: Double, rCount: Int, box: Bool = false) -> Double {
        let tau = 60 * RhythmTracker.fps / bpm
        let acf = box ? acfSel : self.acf
        var s = interpLinear(acf.p, count: rCount, tau)
        for h in 2...4 {
            var best = -Double.infinity
            var j = -(h - 1)
            while j <= h - 1 {
                best = max(best, interpLinear(acf.p, count: rCount, Double(h) * tau + Double(j)))
                j += 1
            }
            s += best / Double(h)
        }
        return max(s, 0)
    }

    /// Harmonic + parabolic lag refinement (`refine_tau`).
    private func refineTau(_ tau0: Double, rCount: Int) -> Double {
        var num = 0.0, den = 0.0
        for h in 1...4 {
            var k = Int((Double(h) * tau0).rounded(.toNearestOrEven))
            if k + 2 >= rCount { break }
            if k < 1 { continue }
            // max((k−1, k, k+1), key=r): first maximum in that order.
            var best = k - 1
            if acf[k] > acf[best] { best = k }
            if acf[k + 1] > acf[best] { best = k + 1 }
            k = best
            guard k >= 1, k + 1 < rCount else { continue }
            let a = acf[k - 1], b = acf[k], c = acf[k + 1]
            let d = a - 2 * b + c
            let fracPart = d < 0 ? 0.5 * (a - c) / d : 0
            if b <= 0 { continue }
            num += b * Double(h) * (Double(k) + fracPart) / Double(h)
            den += b * Double(h)
        }
        return den > 0 ? num / den : tau0
    }

    /// Comb-template phase measurement (`phase_estimate`): offset ψ (frames back from the newest
    /// frame) of the most recent beat, and its z-score.
    private func phaseEstimate(tau: Double) -> (Double, Double) {
        let L = RhythmTracker.windowFrames
        let npsi = min(phaseScore.count, max(1, Int(tau.rounded(.up))))
        var sum = 0.0
        for p in 0..<npsi {
            var s = 0.0
            var w = 1.0
            for m in 0..<6 {
                let idx = Double(L - 1 - p) - Double(m) * tau
                if idx < 1 { break }
                s += w * interpLinear(seg.p, count: L, idx)
                w *= 0.8
            }
            phaseScore[p] = s
            sum += s
        }
        var pb = 0
        for p in 1..<max(1, npsi) where phaseScore[p] > phaseScore[pb] { pb = p }
        let mean = sum / Double(npsi)
        var v = 0.0
        for p in 0..<npsi { let d = phaseScore[p] - mean; v += d * d }
        let std = sqrt(v / Double(npsi))
        let z = (phaseScore[pb] - mean) / (std + 1e-9)
        let a = phaseScore[(pb - 1 + npsi) % npsi], b = phaseScore[pb], c = phaseScore[(pb + 1) % npsi]
        let den = a - 2 * b + c
        return (Double(pb) + (den < 0 ? 0.5 * (a - c) / den : 0), z)
    }

    /// Advances the clock across a capture gap so beat-locked looks stay on the grid.
    func skip(seconds: Double, period T: Double) {
        guard seconds.isFinite, seconds > 0, seconds < 3600, T > 0 else { return }
        beats += seconds / T
        if frameIndex >= 0 { frameTime += seconds }
        // Skipped beats are counted but not evaluated (no audio exists for them).
        beatCount = max(beatCount, safeInt64(beats.rounded(.down)))
    }

    // MARK: Manual tempo

    /// Seeds the clock from tapped beats (user-provided tempo and the capture time of a beat).
    public func applyTap(bpm: Double, beatTime: Double) {
        guard bpm.isFinite, bpm >= 40, bpm <= 220, frameIndex >= 0 else { return }
        let T = 60 / bpm
        period = T
        lastPeriod = T
        var phi = ((frameTime - beatTime) / T).truncatingRemainder(dividingBy: 1)
        if phi < 0 { phi += 1 }
        setPhase(phi, at: frameTime)
        confidence = max(confidence, 0.7)
        eligible = RhythmTracker.lockRun
        histCount = 0
        outlierCount = 0
        lowConfSeconds = 0
        if firstLockTime == nil { firstLockTime = frameTime }
    }
}

@inline(__always)
func frac(_ x: Double) -> Double { x - x.rounded(.down) }

/// Wraps to [−0.5, 0.5).
@inline(__always)
func wrapHalf(_ x: Double) -> Double {
    guard x.isFinite else { return 0 }
    let y = (x + 0.5) - (x + 0.5).rounded(.down)
    return y - 0.5
}
