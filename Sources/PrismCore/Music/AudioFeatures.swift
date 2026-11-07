import Foundation

/// Energy tier of the music; selects parameter sets inside a mood (§1.13).
public enum EnergyTier: Int, Sendable, Comparable, CaseIterable, Codable {
    case calm = 0, groove, peak

    public static func < (a: EnergyTier, b: EnergyTier) -> Bool { a.rawValue < b.rawValue }

    public var displayName: String {
        switch self { case .calm: return "Calm"; case .groove: return "Groove"; case .peak: return "Peak" }
    }
}

/// Six perceptual bands, AGC-normalised to 0…1 (edges in Hz: 20–60, 60–250, 250–500,
/// 500–2k, 2k–6k, 6k–16k). Fixed-size value type: no heap allocation per frame.
public struct Bands6: Sendable, Equatable {
    public var sub: Double, bass: Double, lowMid: Double, mid: Double, highMid: Double, high: Double

    public init(sub: Double = 0, bass: Double = 0, lowMid: Double = 0, mid: Double = 0, highMid: Double = 0, high: Double = 0) {
        self.sub = sub; self.bass = bass; self.lowMid = lowMid; self.mid = mid; self.highMid = highMid; self.high = high
    }

    /// Builds from up to six values (missing values are 0; non-finite values become 0).
    public init(_ values: [Double]) {
        func v(_ i: Int) -> Double { i < values.count ? clamp01(values[i]) : 0 }
        self.init(sub: v(0), bass: v(1), lowMid: v(2), mid: v(3), highMid: v(4), high: v(5))
    }

    public static let zero = Bands6()
    public static let count = 6

    /// Safe indexed access (out-of-range reads return 0, writes are ignored).
    public subscript(index: Int) -> Double {
        get {
            switch index {
            case 0: return sub
            case 1: return bass
            case 2: return lowMid
            case 3: return mid
            case 4: return highMid
            case 5: return high
            default: return 0
            }
        }
        set {
            switch index {
            case 0: sub = newValue
            case 1: bass = newValue
            case 2: lowMid = newValue
            case 3: mid = newValue
            case 4: highMid = newValue
            case 5: high = newValue
            default: break
            }
        }
    }

    public var array: [Double] { [sub, bass, lowMid, mid, highMid, high] }
}

/// Real-time musical features computed from the captured audio, consumed by music moods and
/// audio-reactive effects at the engine frame rate (contract: `docs/research/music_reactive.md` §2).
///
/// Values are normalised and smoothed by the analyzer (0…1 unless noted), so consumers can use
/// them directly. Effects must be frame-rate independent: use the event *times* and monotonic
/// counters (or the analytic envelopes and the `clock`) rather than per-frame booleans.
public struct AudioFeatures: Sendable, Equatable {
    // MARK: Core (stable public API)

    /// Capture-timeline time (PrismClock seconds) this snapshot describes.
    public var timestamp: Double
    /// True when meaningful audio is present (not silence). Prefer blending with `presence`.
    public var isActive: Bool
    /// AGC-relative momentary loudness, 0…1.
    public var level: Double
    /// Broadband onset envelope at `timestamp`, 0…1 (see `onsetEvent` for render-time values).
    public var onset: Double
    /// True when a beat occurred since the previous snapshot (prefer `beatCount`).
    public var beat: Bool
    /// Position within the current beat at `timestamp`, 0…1 (0 = on the beat).
    public var beatPhase: Double
    /// Position within the current bar (4/4), 0…1 (0 = downbeat).
    public var barPhase: Double
    /// Tracked tempo in BPM (0 until the first beat lock). Includes the user's half/double setting.
    public var bpm: Double
    /// Confidence in the beat clock, 0…1 (< 0.3 ⇒ don't beat-lock).
    public var tempoConfidence: Double
    /// Log spectral centroid ("brightness" of the sound), 0…1.
    public var brightness: Double
    /// Novelty (section-change likelihood), 0…1.
    public var novelty: Double
    /// True when a section change or drop happened since the previous snapshot (prefer counters).
    public var sectionChange: Bool

    // MARK: Presence / silence (§1.14)

    /// 0…1, eased: 1 → 0 over 3 s into silence, 0 → 1 over 0.8 s when music returns.
    public var presence: Double
    /// Exact digital zeros (player paused — or capture permission missing).
    public var digitalSilence: Bool
    /// Seconds of continuous silence (0 while music plays).
    public var silentSeconds: Double
    /// Raw input level (dBFS, ≈100 ms RMS), for meters and diagnostics. −120 = nothing.
    public var levelDBFS: Double

    // MARK: Loudness (§1.4–1.5)

    /// AGC-relative short-term loudness (3 s), smoothed τ 1.5 s.
    public var loudnessSlow: Double
    /// Absolute momentary loudness (LUFS, diagnostics only).
    public var loudnessLUFS: Double
    /// Current AGC reference (LUFS, diagnostics only).
    public var agcReferenceLUFS: Double

    // MARK: Spectrum (§1.3)

    /// Six bands (one-euro smoothed) — general use.
    public var bandLevels: Bands6
    /// Six bands, attack 10 ms / release 120 ms — pulses and punch.
    public var bandsFast: Bands6
    /// Six bands, τ 1 s — colour, ambience, swell.
    public var bandsSlow: Bands6
    /// 16 log-spaced bands 40 Hz–16 kHz (attack 15 ms / release 200 ms), for visualizers.
    public var spectrum16: SIMD16<Double>
    /// 0 tonal … 1 noise-like.
    public var flatness: Double

    // MARK: Onsets (§1.6) — envelopes at `timestamp` plus their events for render-time evaluation

    public var kick: Double
    public var snare: Double
    public var hihat: Double
    public var onsetEvent: OnsetEvent
    public var kickEvent: OnsetEvent
    public var snareEvent: OnsetEvent
    public var hihatEvent: OnsetEvent
    /// Broadband onsets per second over the last 4 s ÷ 6, 0…1.
    public var onsetDensity: Double
    /// Monotonic onset counter.
    public var onsetCount: UInt64

    // MARK: Musical clock (§1.7–1.9)

    /// The predicted beat/bar/phrase clock; evaluate it at render time (see `musicalTime(at:)`).
    public var clock: BeatClock
    /// Raw tempo estimate (BPM) even before lock — for "finding the beat…" UI.
    public var tempoEstimate: Double
    /// Unwrapped beat counter at `timestamp` (never decreases while the tempo setting is unchanged).
    public var beatCount: Int64
    /// Lighting pulse grid (1, 2 or 4 beats) for rhythmic looks at this tempo.
    public var pulseDivisor: Int
    /// 0…3 (4/4 assumed).
    public var beatInBar: Int
    public var barCount: Int64
    public var downbeatConfidence: Double
    /// Position within the current 8-bar phrase, 0…1.
    public var phrasePhase: Double

    // MARK: Harmony (§1.10)

    /// Chroma C…B in lanes 0–11 (lanes 12–15 unused), max-normalised, τ 0.5 s.
    public var chromaVector: SIMD16<Double>
    /// 0…1 turn on the circle-of-fifths wheel (smoothed τ 2 s).
    public var harmonicHue: Double
    /// 0…1: 1 = one clear tonal centre, ≈0 = noise/atonal.
    public var tonalClarity: Double
    /// 0–11 major (C…B), 12–23 minor, −1 unknown.
    public var key: Int
    public var keyConfidence: Double

    // MARK: Structure (§1.12–1.13)

    public var energy: Double
    public var energyTier: EnergyTier
    public var buildup: Double
    public var isBreakdown: Bool
    public var sectionCount: UInt32
    public var lastSectionChangeTime: Double
    public var dropCount: UInt32
    public var lastDropTime: Double
    public var lastDropStrength: Double

    // MARK: Timing (§1.15)

    /// Seconds to add to the engine's render time to get the capture-timeline instant to depict
    /// (light latency − audio-output latency + 15 ms lead + user sync offset).
    public var latencyOffset: Double

    public init(timestamp: Double = 0, isActive: Bool = false, level: Double = 0, bands: [Double] = Array(repeating: 0, count: 6),
                onset: Double = 0, beat: Bool = false, beatPhase: Double = 0, barPhase: Double = 0, bpm: Double = 0,
                tempoConfidence: Double = 0, brightness: Double = 0, chroma: [Double] = Array(repeating: 0, count: 12),
                novelty: Double = 0, sectionChange: Bool = false, spectrum: [Double] = []) {
        self.timestamp = timestamp; self.isActive = isActive; self.level = level
        self.onset = onset; self.beat = beat; self.beatPhase = beatPhase; self.barPhase = barPhase
        self.bpm = bpm; self.tempoConfidence = tempoConfidence; self.brightness = brightness
        self.novelty = novelty; self.sectionChange = sectionChange
        presence = isActive ? 1 : 0
        digitalSilence = false
        silentSeconds = 0
        levelDBFS = isActive ? -20 : -120
        loudnessSlow = level
        loudnessLUFS = -70
        agcReferenceLUFS = -18
        let b = Bands6(bands)
        bandLevels = b; bandsFast = b; bandsSlow = b
        var s = SIMD16<Double>(repeating: 0)
        for i in 0..<min(16, spectrum.count) { s[i] = clamp01(spectrum[i]) }
        spectrum16 = s
        flatness = 0
        kick = 0; snare = 0; hihat = 0
        onsetEvent = OnsetEvent(); kickEvent = OnsetEvent(); snareEvent = OnsetEvent(); hihatEvent = OnsetEvent()
        onsetDensity = 0; onsetCount = 0
        tempoEstimate = bpm
        let period = bpm > 0 && bpm.isFinite ? 60 / bpm : 0
        let beatsAtT = floor(clamp01(barPhase) * 4) + clamp01(beatPhase)
        clock = BeatClock(anchorTime: timestamp, anchorBeats: beatsAtT, period: period, multiplier: 1,
                          downbeatOffset: 0, phraseAnchorBar: 0, confidence: tempoConfidence,
                          isLocked: period > 0 && tempoConfidence > 0)
        beatCount = Int64(beatsAtT.rounded(.down))
        pulseDivisor = BeatClock.pulseDivisor(bpm: bpm, cap: 130)
        beatInBar = Int(floor(barPhase.finiteOr(0) * 4)) % 4
        barCount = 0
        downbeatConfidence = 0
        phrasePhase = 0
        var c = SIMD16<Double>(repeating: 0)
        for i in 0..<min(12, chroma.count) { c[i] = clamp01(chroma[i]) }
        chromaVector = c
        harmonicHue = 0; tonalClarity = 0; key = -1; keyConfidence = 0
        energy = level; energyTier = .calm; buildup = 0; isBreakdown = false
        sectionCount = 0; lastSectionChangeTime = -1_000; dropCount = 0; lastDropTime = -1_000; lastDropStrength = 0
        latencyOffset = 0
    }

    public static let silent = AudioFeatures()

    // MARK: Façade over the fixed-size fields

    /// Six bands as an array (sub, bass, lowMid, mid, highMid, high).
    public var bands: [Double] {
        get { bandLevels.array }
        set { bandLevels = Bands6(newValue) }
    }

    /// Chroma C…B as 12 values.
    public var chroma: [Double] {
        get { (0..<12).map { chromaVector[$0] } }
        set {
            var c = SIMD16<Double>(repeating: 0)
            for i in 0..<min(12, newValue.count) { c[i] = clamp01(newValue[i]) }
            chromaVector = c
        }
    }

    /// Reduced log-frequency spectrum for visualizers (16 bands, 0…1).
    public var spectrum: [Double] {
        get { (0..<16).map { spectrum16[$0] } }
        set {
            var s = SIMD16<Double>(repeating: 0)
            for i in 0..<min(16, newValue.count) { s[i] = clamp01(newValue[i]) }
            spectrum16 = s
        }
    }

    public var sub: Double { bandLevels.sub }
    public var bass: Double { max(bandLevels.sub, bandLevels.bass) }
    public var mid: Double { (bandLevels.lowMid + bandLevels.mid) / 2 }
    public var treble: Double { (bandLevels.highMid + bandLevels.high) / 2 }

    // MARK: Render-time helpers

    /// The capture-timeline instant to depict when rendering at engine time `renderTime`.
    @inline(__always)
    public func musicalTime(at renderTime: Double) -> Double { renderTime + latencyOffset }

    /// True when beat-locked visuals should follow the clock.
    public var beatTrusted: Bool { clock.period > 0 && tempoConfidence >= 0.3 }

    /// Seconds between `timestamp` and the depicted instant at `renderTime` (stale audio ⇒ large).
    public func staleness(at renderTime: Double) -> Double { musicalTime(at: renderTime) - timestamp }
}

/// The predicted musical clock (§1.8 PLL state): `Φ(t) = Φ₀ + (t − t₀)/T`. Exact at any render
/// rate and latency — the only genuinely *predicted* feature. Effects can use it for tempo sync.
public struct BeatClock: Sendable, Equatable {
    /// Capture-timeline time (PrismClock seconds) of the anchor.
    public var anchorTime: Double
    /// Unwrapped musical beat position at `anchorTime` (before the pulse multiplier).
    public var anchorBeats: Double
    /// Seconds per musical beat (0 = no tempo yet).
    public var period: Double
    /// Pulse multiplier chosen by the user: 0.5 = half time, 1, 2 = double time.
    public var multiplier: Double
    /// Musical beat index (mod 4) that starts a bar, 0…3.
    public var downbeatOffset: Int
    /// Bar index where the 8-bar phrase grid is anchored.
    public var phraseAnchorBar: Int64
    /// 0…1 beat confidence.
    public var confidence: Double
    /// True while the PLL holds a confident lock (the clock also flywheels when unlocked).
    public var isLocked: Bool

    public init(anchorTime: Double = 0, anchorBeats: Double = 0, period: Double = 0, multiplier: Double = 1,
                downbeatOffset: Int = 0, phraseAnchorBar: Int64 = 0, confidence: Double = 0, isLocked: Bool = false) {
        self.anchorTime = anchorTime.finiteOr(0)
        self.anchorBeats = anchorBeats.finiteOr(0)
        self.period = period.isFinite && period > 0 ? period : 0
        self.multiplier = multiplier.isFinite && multiplier > 0 ? multiplier : 1
        self.downbeatOffset = ((downbeatOffset % 4) + 4) % 4
        self.phraseAnchorBar = phraseAnchorBar
        self.confidence = clamp01(confidence)
        self.isLocked = isLocked
    }

    public static let stopped = BeatClock()

    /// Pulse tempo in BPM (includes the multiplier; 0 when unknown).
    public var bpm: Double { period > 0 ? 60 / period * multiplier : 0 }

    /// Unwrapped musical beats at `t` (no multiplier).
    @inline(__always)
    public func musicalBeats(at t: Double) -> Double {
        guard period > 0 else { return anchorBeats }
        let b = anchorBeats + (t - anchorTime) / period
        return b.isFinite ? b : anchorBeats
    }

    /// Unwrapped pulse beats at `t` (includes the multiplier).
    @inline(__always)
    public func beats(at t: Double) -> Double { musicalBeats(at: t) * multiplier }

    /// 0…1 position inside the current pulse beat (0 = on the beat).
    public func beatPhase(at t: Double) -> Double { fractional(beats(at: t)) }

    /// Pulse beat index at `t`.
    public func beatIndex(at t: Double) -> Int64 { safeInt64(beats(at: t).rounded(.down)) }

    /// Unwrapped bar position (bars since the downbeat grid's origin).
    public func barPosition(at t: Double) -> Double { (musicalBeats(at: t) - Double(downbeatOffset)) / 4 }

    public func barPhase(at t: Double) -> Double { fractional(barPosition(at: t)) }

    public func barIndex(at t: Double) -> Int64 { safeInt64(barPosition(at: t).rounded(.down)) }

    /// 0…3 musical beat inside the bar.
    public func beatInBar(at t: Double) -> Int {
        let b = safeInt64(musicalBeats(at: t).rounded(.down)) - Int64(downbeatOffset)
        return Int(((b % 4) + 4) % 4)
    }

    /// 0…1 position inside the current phrase of `bars` bars (default 8).
    public func phrasePhase(at t: Double, bars: Int = 8) -> Double {
        let n = Double(max(1, bars))
        let pos = barPosition(at: t) - Double(phraseAnchorBar)
        let m = pos.truncatingRemainder(dividingBy: n)
        return (m < 0 ? m + n : m) / n
    }

    /// Smallest divisor d ∈ {1, 2, 4} with bpm/d ≤ cap (lighting pulse grid, §3.0).
    public static func pulseDivisor(bpm: Double, cap: Double) -> Int {
        guard bpm.isFinite, bpm > 0, cap > 0 else { return 1 }
        if bpm <= cap { return 1 }
        if bpm / 2 <= cap { return 2 }
        return 4
    }

    @inline(__always)
    private func fractional(_ x: Double) -> Double {
        guard x.isFinite else { return 0 }
        return x - x.rounded(.down)
    }
}
