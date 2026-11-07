import Foundation

// The 16 moods as pure shaders (docs/research/music_reactive.md §3.3): each returns an OKLab
// colour and a perceptual intensity for one pixel. Everything time-varying comes from the
// per-frame `MoodFrame` (clocks, latency-compensated beat phases, events, palette cross-fade),
// built by `MusicRenderSession`. Moods never write DMX and never bypass `MusicSafety`.

/// One shaded pixel.
struct MoodSample {
    var lab: MusicLab
    var I: Double
}

/// Per-pixel geometry in the stage plane (x → right, y ↑ up, both 0…1), built when the rig changes.
struct MoodPixel {
    var x: Double
    var y: Double
    /// 0…1 along the fixture (cell 0 → last), 0.5 for single-cell fixtures.
    var u: Double
    /// "Upward" tube coordinate: bottom → top for vertical tubes, left → right for horizontal.
    var uUp: Double
    /// Distance from the focal point (0 at the focus, 1 at the farthest pixel).
    var r: Double
    /// Angle around the focal point, 0…1.
    var theta: Double
    var seedF: Double
    var seedP: UInt64
    var seedPUnit: Double
    /// Fixture rank along x (0 = leftmost) and its parity group.
    var rank: Int
    var group: Int
    var fixtureCount: Int
    var fixtureIndex: Int
    var pixelIndex: Int
    var pixelCount: Int
    var horizontal: Bool
    /// Synthwave: this fixture is part of the "sun" (horizontal tubes) and its height among them.
    var isSun: Bool
    var sunQ: Double
    var accent: Bool
    var nearSubject: Bool
}

/// A recent pulse on the lighting grid: predicted time, measured kick strength (0.55 = unknown).
struct PulseRecord {
    var time: Double = -1_000
    var strength: Double = 0.55
    var index: Int64 = Int64.min
}

/// A recent onset (for star births).
struct OnsetRecord {
    var time: Double = -1_000
    var strength: Double = 0
    var index: UInt64 = 0
}

/// Everything a mood needs for one frame. Built once per frame per active mood.
struct MoodFrame {
    var mood: MusicMood
    var f: AudioFeatures
    /// Musical time: render time + latency offset (the time whose light we are computing).
    var t: Double
    var dt: Double
    /// Reactivity after presence, flash-guard depth gain and breakdown.
    var rho: Double
    /// Beat trust: smoothstep(0.3, 0.7, confidence).
    var cb: Double
    /// Pulse tempo (includes half/double time) and seconds per pulse beat.
    var bpm: Double
    var T: Double
    /// Lighting pulse divisor for this mood (1, 2 or 4 beats).
    var d: Int
    /// Pulse beats since the grid origin, aligned so pulse k·d lands on bar starts.
    var pulseBeats: Double
    /// Continuous bar position (virtual 4 s bars when there is no tempo yet) and seconds per bar.
    var barPos: Double
    var Tbar: Double
    var dDrop: Double
    var dSec: Double
    var tau: Double
    var tauBar: Double
    var L: Double
    var Ls: Double
    var B: Bands6
    var Bf: Bands6
    var BS: Bands6
    var K: Double
    var Hh: Double
    var O: Double
    var energy: Double
    var buildup: Double
    var tierCalm: Double
    var tierGroove: Double
    var tierPeak: Double
    var palA: MoodPalette
    var palB: MoodPalette
    var palW: Double
    var pulses: (PulseRecord, PulseRecord, PulseRecord, PulseRecord)
    var onsets: (OnsetRecord, OnsetRecord, OnsetRecord, OnsetRecord)
    var focalX: Double
    var focalY: Double
    var sunsetHorizon: Double
    var prismOffset: Double
    var harmonic: Double
    var lsVerySlow: Double
    var top3: (Int, Int, Int)
    var sectionParity: Int
    var safeMode: Bool

    // MARK: Palette access (with the palette cross-fade)

    @inline(__always) func pal(_ q: Double) -> MusicLab {
        palW <= 0 ? palA.cyclic(q) : (palW >= 1 ? palB.cyclic(q) : MusicLab.mix(palA.cyclic(q), palB.cyclic(q), palW))
    }

    @inline(__always) func palClamp(_ q: Double) -> MusicLab {
        palW <= 0 ? palA.clamped(q) : (palW >= 1 ? palB.clamped(q) : MusicLab.mix(palA.clamped(q), palB.clamped(q), palW))
    }

    @inline(__always) func palIdx(_ i: Int) -> MusicLab {
        palW <= 0 ? palA.stop(i) : (palW >= 1 ? palB.stop(i) : MusicLab.mix(palA.stop(i), palB.stop(i), palW))
    }

    /// Sub-gradient over stops `range` of both palettes (Synthwave sun).
    func palRange(_ range: Range<Int>, _ q: Double) -> MusicLab {
        func sample(_ p: MoodPalette) -> MusicLab {
            let n = range.count
            guard n > 1 else { return p.stop(range.lowerBound) }
            let x = clamp01(q) * Double(n - 1)
            let k = min(n - 2, Int(x))
            return MusicLab.mix(p.stop(range.lowerBound + k), p.stop(range.lowerBound + k + 1), x - Double(k))
        }
        return palW <= 0 ? sample(palA) : (palW >= 1 ? sample(palB) : MusicLab.mix(sample(palA), sample(palB), palW))
    }

    var paletteCount: Int { max(1, palB.count) }

    // MARK: Rhythm helpers (§3.1)

    @inline(__always) func pulsePhase(_ d: Int) -> Double { MoodMath.fract(pulseBeats / Double(max(1, d))) }
    @inline(__always) func pulsePeriod(_ d: Int) -> Double { Double(max(1, d)) * T }
    var beta: Double { MoodMath.fract(barPos) }

    /// Beat-locked drive that falls back to an energy-driven drive when the beat is not trusted.
    @inline(__always) func beatDrive(a: Double, s: Double, d: Int) -> Double {
        cb * MoodMath.kb(pulsePhase(d), a: a, s: s) + (1 - cb) * Bf.bass
    }

    /// Index that advances every `periodBars` bars with an OKLab cross-fade centred on the downbeat.
    func barSynced(periodBars: Int = 1, half: Double = 0.15) -> (i0: Int, i1: Int, w: Double) {
        let pb = Double(max(1, periodBars))
        let pos = barPos / pb
        guard pos.isFinite else { return (0, 0, 0) }
        let nearest = (pos + 0.5).rounded(.down)
        let tRel = (pos - nearest) * Tbar * pb
        let k = Int(clamp(nearest, -1e15, 1e15))
        return (k &- 1, k, smoothstep(-half, half, tRel))
    }

    @inline(__always) func gauss(_ x: Double, _ w: Double) -> Double { MoodMath.gauss(x, w) }
    @inline(__always) func env(_ dt: Double, _ ta: Double, _ td: Double) -> Double { MoodMath.env(dt, ta: ta, td: td) }
    @inline(__always) func fract(_ x: Double) -> Double { MoodMath.fract(x) }
    @inline(__always) func noise3(_ x: Double, _ y: Double, _ z: Double) -> Double { MoodMath.noise3(x, y, z) }
    @inline(__always) func fbm3(_ x: Double, _ y: Double, _ z: Double, _ o: Int) -> Double { MoodMath.fbm3(x, y, z, octaves: o) }

    // MARK: Shading

    func shade(_ p: MoodPixel) -> MoodSample {
        switch mood {
        case .aurora, .auto: return aurora(p)
        case .neonPulse: return neonPulse(p)
        case .oceanDrift: return oceanDrift(p)
        case .sunset: return sunset(p)
        case .synthwave: return synthwave(p)
        case .lavaLamp: return lavaLamp(p)
        case .spectrum: return spectrum(p)
        case .cinematic: return cinematic(p)
        case .club: return club(p)
        case .chill: return chill(p)
        case .starfield: return starfield(p)
        case .heartbeat: return heartbeat(p)
        case .gradientSweep: return gradientSweep(p)
        case .prismBloom: return prismBloom(p)
        case .ember: return ember(p)
        case .nebula: return nebula(p)
        }
    }

    /// The mood's motion-clock rate (τ units per second, before the user's speed), §3.1.
    static func clockRate(_ mood: MusicMood, frame m: MoodFrame) -> Double {
        switch mood {
        case .aurora, .auto:
            let swell = m.beatDrive(a: 0.30, s: 1, d: max(2, m.d))
            return 0.6 + 0.4 * m.Ls + 0.6 * m.rho * m.cb * swell
        case .oceanDrift:
            return 1 + 0.5 * m.rho * m.cb * m.beatDrive(a: 0.3, s: 1, d: max(2, m.d))
        case .lavaLamp: return 0.7
        case .chill: return 0.5
        case .ember: return 0.6 + 0.6 * m.L
        case .nebula, .starfield, .cinematic: return 0.8 + 0.3 * m.Ls
        default: return 1
        }
    }

    // MARK: M01 · Aurora

    private func aurora(_ p: MoodPixel) -> MoodSample {
        let x = p.x, y = p.y, tau = self.tau
        let w = fbm3(1.2 * x + 0.04 * tau, 0.35 * y, 0.06 * tau, 3)
        let rib = smoothstep(0.15, 0.85, 0.5 + 0.5 * w)
        let ray = 0.5 + 0.5 * sin(2 * .pi * (3.0 * x + 0.8 * w + 0.03 * tau))
        let dropE = env(dDrop, 0.15, 2.5)
        let front = 1.0 - 0.6 * dDrop
        let burst = dropE * smoothstep(front - 0.2, front, y)
        let q = clamp01(0.10 + 0.62 * rib + 0.25 * y + 0.08 * BS.high + 0.25 * burst)
        var I = 0.22 + 0.55 * rib * (0.65 + 0.35 * ray)
        I += rho * (0.30 * (Ls - 0.5) + 0.20 * B.mid)
        I += rho * 0.05 * B.high * noise3(6 * x, 6 * y, 1.2 * t)
        I += 0.25 * burst
        return MoodSample(lab: palClamp(q), I: I)
    }

    // MARK: M02 · Neon Pulse

    private func neonPulse(_ p: MoodPixel) -> MoodSample {
        let P = beatDrive(a: 0.10, s: 2, d: d)
        let ph = pulsePhase(d)
        let bars = bpm > 128 ? 2 : 1
        let (i0, i1, w) = barSynced(periodBars: bars, half: 0.15)
        var lab = MusicLab.mix(palIdx(i0 &+ p.group), palIdx(i1 &+ p.group), w)
        let core = 0.85 + 0.15 * cos(2 * .pi * (p.u - 0.5))
        let trav = gauss(abs(p.u - 0.5) - ph, 0.12) * cb
        var I = 0.40 + rho * (0.45 * P * (0.7 + 0.3 * K) + 0.15 * trav)
        I *= core
        I += rho * 0.06 * Hh * MoodMath.sparkle(seed: p.seedP, time: t, rate: 0.6)
        if dDrop < 4 * T {
            let lag = 0.5 * T * Double(p.rank) / 7
            lab = MusicLab.mix(lab, palIdx(i1 &+ 1 &+ p.rank), 0.6 * env(dDrop - lag, 0.06, 0.6))
        }
        return MoodSample(lab: lab, I: I)
    }

    // MARK: M03 · Ocean Drift

    private func oceanDrift(_ p: MoodPixel) -> MoodSample {
        // Three travelling swells: (direction°, wavelength, temporal Hz, amplitude, phase seed).
        func wave(_ angle: Double, _ lambda: Double, _ nu: Double, _ amp: Double, _ seed: Double) -> Double {
            let a = angle * .pi / 180
            let s = p.x * cos(a) + p.y * sin(a)
            return amp * sin(2 * .pi * (s / lambda - nu * tau) + 6.28 * seed)
        }
        let h = wave(-10, 0.90, 0.05, 0.5, 0.13) + wave(5, 0.50, 0.08, 0.3, 0.57) + wave(20, 0.27, 0.13, 0.2, 0.82)
        let swell = 0.5 + 0.5 * h * (0.7 + 0.3 * rho * BS.bass)
        let crest = smoothstep(0.62, 0.92, swell)
        let foam = crest * (0.3 + 0.7 * rho * max(B.high, O))
        var lab = palClamp(0.15 + 0.6 * swell)
        lab = MusicLab.mix(lab, palClamp(1.0), foam * 0.6)
        var I = 0.30 + 0.35 * swell + rho * (0.20 * Ls + 0.12 * B.bass)
        if dDrop < 4 * T {
            let X = dDrop / (4 * T)
            I += 0.30 * gauss(p.x - X, 0.12)
        }
        return MoodSample(lab: lab, I: I)
    }

    // MARK: M04 · Sunset

    private func sunset(_ p: MoodPixel) -> MoodSample {
        let hz = sunsetHorizon
        let sx = focalX + 0.15 * sin(0.013 * tau)
        let size = 0.18 * (1 + 0.6 * env(dDrop, 0.3, 4))
        let dx = p.x - sx, dy = p.y - hz
        let glow = exp(-(dx * dx + dy * dy) / (2 * size * size))
        let q = clamp01(0.85 - (p.y - hz) * 0.9 + 0.05 * noise3(1.5 * p.x, 0.5 * p.y, 0.03 * tau))
        var lab = palClamp(q).hueShifted(-8 * BS.bass)
        lab = MusicLab.mix(lab, palClamp(1.0), 0.45 * glow)
        let glint = MoodMath.sparkle(seed: p.seedP, time: t, rate: 0.15 + 0.6 * rho * B.high, ta: 0.08, td: 0.6)
        if glint > 0.001 { lab = lab.hueShifted(20 * glint) }
        var I = 0.35 + 0.30 * glow
        I += rho * (0.25 * Ls + 0.10 * B.lowMid + 0.10 * cb * MoodMath.kb(pulsePhase(max(2, d)), a: 0.3, s: 1.5))
        I += 0.08 * glint * rho
        return MoodSample(lab: lab, I: I)
    }

    // MARK: M05 · Synthwave

    private func synthwave(_ p: MoodPixel) -> MoodSample {
        if p.isSun {
            let stripes = smoothstep(0.25, 0.45, fract(4 * p.u + 0.5 * tauBar))
            var I = (0.55 + 0.30 * rho * BS.bass) * (0.75 + 0.25 * stripes)
            I += rho * 0.20 * beatDrive(a: 0.12, s: 2, d: d)
            return MoodSample(lab: palRange(SynthwaveStops.sun, clamp01(0.15 + 0.8 * p.sunQ)), I: I)
        }
        let (i0, i1, w) = barSynced(periodBars: 2)
        let g0 = SynthwaveStops.grid.lowerBound
        func grid(_ i: Int) -> MusicLab { palIdx(g0 + ((i % 2) + 2) % 2) }
        var lab = MusicLab.mix(grid(i0 &+ p.rank), grid(i1 &+ p.rank), w)
        var I = 0.20
        let speedUp: Double = dDrop < 8 * T ? 2 : 1
        let width = 0.06 + 0.04 * B.high
        func run(_ k: PulseRecord) -> Double {
            let age = t - k.time
            guard age >= 0, age < 3 else { return 0 }
            let pos = age / (2 * pulsePeriod(d)) * speedUp
            return (0.35 + 0.35 * k.strength) * gauss(p.uUp - pos, width) * exp(-age / 0.9)
        }
        let pulseSum = run(pulses.0) + run(pulses.1) + run(pulses.2)
        I += rho * pulseSum * (0.4 + 0.6 * cb)
        lab = MusicLab.mix(palIdx(SynthwaveStops.night), lab, clamp01(0.55 + 0.9 * pulseSum))
        return MoodSample(lab: lab, I: I)
    }

    // MARK: M06 · Lava Lamp

    private func lavaLamp(_ p: MoodPixel) -> MoodSample {
        let R = 0.16 * (1 + 0.25 * rho * BS.bass + 0.08 * rho * cb * MoodMath.kb(beta, a: 0.4, s: 1))
        let R2 = R * R
        var F = 0.0
        let fx = (0.011, 0.017, 0.023, 0.029, 0.013), fy = (0.019, 0.007, 0.015, 0.021, 0.026)
        func blob(_ i: Double, _ ax: Double, _ ay: Double) -> Double {
            let cx = 0.5 + 0.38 * sin(2 * .pi * (ax * tau + 0.13 * i))
            let cy = 0.5 + 0.42 * sin(2 * .pi * (ay * tau + 0.29 * i))
            let dx = p.x - cx, dy = p.y - cy
            return R2 / (dx * dx + dy * dy + 0.002)
        }
        F += blob(0, fx.0, fy.0) + blob(1, fx.1, fy.1) + blob(2, fx.2, fy.2) + blob(3, fx.3, fy.3) + blob(4, fx.4, fy.4)
        if dDrop < 16 * T {
            let cy = -0.2 + 1.4 * dDrop / (16 * T)
            let dx = p.x - focalX, dy = p.y - cy
            F += 1.6 * R2 / (dx * dx + dy * dy + 0.002)
        }
        let q = smoothstep(0.6, 2.5, F)
        let I = 0.18 + 0.70 * smoothstep(0.5, 1.5, F) + rho * 0.15 * Ls
        return MoodSample(lab: palClamp(q), I: I)
    }

    // MARK: M07 · Spectrum

    /// Colour of a position on the circle of fifths (0…1 turn) from the pitch-class table.
    private func fifthsWheel(_ hue: Double) -> MusicLab {
        let k = fract(hue) * 12
        let q0 = Int(k) % 12, q1 = (q0 + 1) % 12
        return MusicLab.mix(palIdx((7 * q0) % 12), palIdx((7 * q1) % 12), k - Double(Int(k)))
    }

    private func spectrum(_ p: MoodPixel) -> MoodSample {
        let (i0, i1, w) = barSynced()
        func topPC(_ i: Int) -> Int {
            switch ((i % 3) + 3) % 3 { case 0: return top3.0; case 1: return top3.1; default: return top3.2 }
        }
        var lab = MusicLab.mix(palIdx(topPC(p.rank &+ i0)), palIdx(topPC(p.rank &+ i1)), w)
        lab = MusicLab.mix(fifthsWheel(f.harmonicHue), lab, 0.65)
        lab = lab.chromaScaled(0.35 + 0.65 * f.tonalClarity)
        let s = f.spectrum16
        let x = clamp01(p.uUp) * 15
        let k = min(14, Int(x))
        let band = s[k] + (s[k + 1] - s[k]) * (x - Double(k))
        var I = 0.30 + 0.35 * L
        I += rho * (0.25 * clamp01(band) + 0.15 * cb * MoodMath.kb(pulsePhase(d), a: 0.12, s: 2))
        if dDrop < 4 * T {
            lab = MusicLab.mix(lab, palIdx((p.rank * 7) % 12), env(dDrop, 0.1, 1.5))
        }
        return MoodSample(lab: lab, I: I)
    }

    // MARK: M08 · Cinematic

    private func cinematic(_ p: MoodPixel) -> MoodSample {
        let alpha = 2 * .pi * tau / 120
        let xr = 0.5 + (p.x - 0.5) * cos(alpha) + (p.y - 0.5) * sin(alpha)
        var q = clamp01(0.15 + 0.55 * xr)
        if p.accent || p.nearSubject { q = 0.9 }
        let cloud = 0.85 + 0.15 * fbm3(0.8 * p.x + 0.01 * tau, 0.8 * p.y, 0.02 * tau, 2)
        var I = (0.30 + 0.50 * lsVerySlow) * cloud + rho * 0.15 * clamp01(f.novelty)
        let de = min(dSec, dDrop)
        if de < 30 {
            let front = de / 6 * 1.3 - 0.15
            let xs = sectionParity == 0 ? p.x : 1 - p.x
            I += 0.35 * smoothstep(0, 1, (front - xs) / 0.3) * exp(-de / 8)
        }
        if p.nearSubject { I = min(I, 0.7) }
        return MoodSample(lab: palClamp(q), I: I)
    }

    // MARK: M09 · Club

    private func club(_ p: MoodPixel) -> MoodSample {
        let G = 4
        let g = min(G - 1, p.rank * G / max(1, p.fixtureCount))
        func active(_ k: PulseRecord) -> Double {
            guard k.index != Int64.min else { return 0 }
            let step = Int(((k.index % 8) + 8) % 8)
            let pattern = step < 4 ? step : 7 - step                  // 0 1 2 3 3 2 1 0 ping-pong
            guard pattern == g else { return 0 }
            return (0.6 + 0.4 * k.strength) * env(t - k.time, 0.04, 0.35)
        }
        let chase = min(1, active(pulses.0) + active(pulses.1) + active(pulses.2)) * cb
        let P = beatDrive(a: 0.08, s: 2, d: d)
        let (i0, i1, w) = barSynced(half: 0.12)
        var lab = MusicLab.mix(palIdx(i0 &+ g / 2), palIdx(i1 &+ g / 2), w)
        let run = gauss(fract(p.uUp - pulsePhase(d)) - 0.5, 0.15)
        let calm = 0.40 + rho * 0.30 * P
        let groove = 0.30 + rho * (0.25 * P + 0.45 * chase + 0.20 * (1 - cb) * Bf.bass)
        let peak = 0.30 + rho * (0.20 * P + 0.45 * chase + 0.15 * run * cb + 0.20 * (1 - cb) * Bf.bass)
        var I = tierCalm * calm + tierGroove * groove + tierPeak * peak
        I += 0.15 * buildup
        if dDrop < 16 * T {
            lab = MusicLab.mix(lab, palIdx(0), 0.8 * env(dDrop, 0.15, 3.0))
            let ripple = gauss(p.r - pulsePhase(d) * 1.2, 0.10)
            I = max(I, 0.35 + 0.45 * rho * ripple)
        }
        return MoodSample(lab: lab, I: I)
    }

    // MARK: M10 · Chill / Lo-fi

    private func chill(_ p: MoodPixel) -> MoodSample {
        let q = fract(0.025 * tau + 0.35 * p.x + 0.15 * p.seedF + 0.05 * noise3(2 * p.x, 2 * p.y, 0.05 * tau))
        let dapple = 0.9 + 0.1 * fbm3(3 * p.x + 0.02 * tau, 3 * p.y, 0.04 * tau, 2)
        var I = (0.35 + 0.25 * Ls) * dapple
        let dq = bpm < 90 ? 2 : 4
        I += rho * 0.12 * cb * MoodMath.kb(pulsePhase(dq), a: 0.35, s: 1)
        I += 0.06 * MoodMath.sparkle(seed: p.seedP &+ 0xC4AC, time: t, rate: 0.3 / Double(max(1, p.pixelCount / max(1, p.fixtureCount))),
                                     ta: 0.05, td: 0.3)
        return MoodSample(lab: pal(q), I: I)
    }

    // MARK: M11 · Starfield

    /// Star brightness (0…1) and colour slot for a pixel, from deterministic births.
    private func stars(_ p: MoodPixel, density: Double, seedSalt: UInt64) -> (Double, Int) {
        var best = 0.0, slot = 0
        // Background births: Poisson at λ per pixel per second, ≥ 1 s refractory slots.
        let lambda = 0.03 * density * (0.3 + rho * (1.2 * B.high + 0.8 * O)) * (1 + 0.5 * energy)
        let amp = 0.4 + 0.6 * MoodMath.hash01(p.seedP, 0xA11 &+ seedSalt)
        let bg = amp * (0.6 + 0.4 * L) * MoodMath.sparkle(seed: p.seedP &+ seedSalt, time: t, rate: lambda, ta: 0.12, td: 0.9)
        if bg > best { best = bg; slot = Int(MoodMath.hash01(p.seedP, 3) * 3) }
        // Onset-synced births: ~3 random pixels per strong onset.
        let share = min(1, 3 * density / Double(max(1, p.pixelCount)))
        func onsetStar(_ o: OnsetRecord) {
            guard o.strength >= 0.5, t - o.time < 6 else { return }
            guard MoodMath.hash01(o.index &+ seedSalt, UInt64(p.pixelIndex)) < share else { return }
            let v = o.strength * env(t - o.time, 0.12, 0.9)
            if v > best { best = v; slot = Int(o.index % 3) }
        }
        onsetStar(onsets.0); onsetStar(onsets.1); onsetStar(onsets.2); onsetStar(onsets.3)
        // One bright star per bar (the last two bars).
        let kb = barPos.rounded(.down)
        for j in 0..<2 {
            let bar = kb - Double(j)
            let tb = t - (barPos - bar) * Tbar
            let ub = UInt64(bitPattern: Int64(clamp(bar, -1e15, 1e15)))
            if Int(MoodMath.hash01(ub &+ seedSalt, 0xBA) * Double(max(1, p.pixelCount))) == p.pixelIndex {
                let v = density * env(t - tb, 0.12, 1.5)
                if v > best { best = v; slot = Int(ub % 3) }
            }
        }
        return (min(1, best), slot)
    }

    private func starfield(_ p: MoodPixel) -> MoodSample {
        var (star, slot) = stars(p, density: 1, seedSalt: 0)
        star *= 0.9 + 0.1 * sin(2 * .pi * (0.5 + p.seedPUnit) * t)
        let sky = 0.10 + 0.05 * fbm3(2 * p.x, 2 * p.y, 0.02 * tau, 2)
        let starColour = palIdx(StarfieldStops.stars.lowerBound + slot)
        var lab = MusicLab.mix(palIdx(StarfieldStops.sky), starColour, clamp01(star / max(sky + star, 1e-3)))
        var I = sky + 0.85 * star
        // Drop: four shooting stars along random tubes over two bars.
        if dDrop < 2 * Tbar + 1 {
            for j in 0..<4 {
                let start = Double(j) * (2 * Tbar / 4)
                let age = dDrop - start
                guard age >= 0, age < 0.8 else { continue }
                let pick = Int(MoodMath.hash01(UInt64(f.dropCount), UInt64(j)) * Double(max(1, p.fixtureCount)))
                guard pick == p.rank else { continue }
                let head = age * 2.5 - 0.1
                let du = head - p.uUp
                let v = du >= 0 ? exp(-du / 0.15) : gauss(du, 0.03)
                if v > 0.01 {
                    I += 0.8 * v * (1 - age / 0.8)
                    lab = MusicLab.mix(lab, starColour, clamp01(v))
                }
            }
        }
        return MoodSample(lab: lab, I: I)
    }

    // MARK: M12 · Heartbeat

    private func heartbeat(_ p: MoodPixel) -> MoodSample {
        let maxCycles = safeMode ? 45.0 : 75.0
        let dc = bpm / 1 <= maxCycles ? 1 : (bpm / 2 <= maxCycles ? 2 : 4)
        let Tc = pulsePeriod(dc)
        let delta = clamp(0.32 / Tc, 0.18, 0.40)
        func bump(_ x: Double, _ period: Double) -> Double {
            let s = x * period
            return s < 0 ? 0 : env(s, 0.05, 0.18)
        }
        let phc = fract(pulsePhase(dc) - 0.15 * p.r)
        let beatH = bump(phc, Tc) + 0.6 * bump(phc - delta, Tc)
        let rest = fract(t / 1.2 - 0.15 * p.r)                       // resting heart at 50 BPM
        let restH = 0.5 * (bump(rest, 1.2) + 0.6 * bump(rest - 0.27, 1.2))
        let H = clamp01(cb * beatH + (1 - cb) * restH)
        let lab = MusicLab.mix(palClamp(0.35), palClamp(0.9), H)
        let I = 0.30 + rho * 0.55 * H * (0.6 + 0.4 * Bf.bass) + 0.10 * Ls
        return MoodSample(lab: lab, I: I)
    }

    // MARK: M13 · Gradient Sweep

    private func gradientSweep(_ p: MoodPixel) -> MoodSample {
        // Direction cycles per 8-bar phrase with a one-bar glide.
        let angles = (0.0, 180.0, 90.0, 270.0, 45.0, 225.0)
        func angle(_ i: Int) -> Double {
            switch ((i % 6) + 6) % 6 {
            case 0: return angles.0; case 1: return angles.1; case 2: return angles.2
            case 3: return angles.3; case 4: return angles.4; default: return angles.5
            }
        }
        let phraseBars = barPos - Double(f.clock.phraseAnchorBar)
        let phrase = (phraseBars / 8).rounded(.down)
        let inPhrase = phraseBars - phrase * 8
        let pi = Int(clamp(phrase, -1e9, 1e9))
        let a0 = angle(pi &- 1), a1 = angle(pi)
        var da = a1 - a0
        if da > 180 { da -= 360 }
        if da < -180 { da += 360 }
        let theta = (a0 + da * smoothstep(0, 1, inPhrase)) * .pi / 180
        let cx = cos(theta), cy = sin(theta)
        let sMax = 0.5 * (abs(cx) + abs(cy))
        var s = clamp01(((p.x - 0.5) * cx + (p.y - 0.5) * cy) / max(sMax, 1e-3) * 0.5 + 0.5)
        if dDrop < 32 * T { s = mixD(s, p.r, smoothstep(0, 0.5, dDrop) * (1 - smoothstep(28 * T, 32 * T, dDrop))) }
        let pos = pulseBeats / Double(max(1, d))
        let nP = pos.rounded(.down)
        let ph = pos - nP
        let step = 1 / (4 * Double(paletteCount))
        let ease = cb * (1 - pow(1 - ph, 3)) + (1 - cb) * ph
        let kappa = fract(step * fract(nP / (4 * Double(paletteCount))) * 4 * Double(paletteCount) + step * ease) + 0.004 * tau
        let q = fract(0.6 * s + kappa)
        func wave(_ k: PulseRecord) -> Double {
            let age = t - k.time
            guard age >= 0, age < 4 else { return 0 }
            let v = 1 / (1.5 * pulsePeriod(d))
            return (0.35 + 0.40 * k.strength) * gauss(s - v * age, 0.12) * exp(-age / 1.2)
        }
        let wv = (wave(pulses.0) + wave(pulses.1) + wave(pulses.2)) * (0.3 + 0.7 * cb)
        let I = 0.35 + 0.25 * L + rho * wv
        return MoodSample(lab: pal(q), I: I)
    }

    @inline(__always) private func mixD(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    // MARK: M14 · Prism Bloom

    private func prismBloom(_ p: MoodPixel) -> MoodSample {
        let bloom = env(dDrop, 0.2, 6.0)
        let span = 0.65 + 0.35 * bloom
        let h0 = 0.011 * tau + 0.09 * harmonic + prismOffset
        let rCore = (0.12 + 0.10 * Ls + 0.08 * rho * cb * MoodMath.kb(beta, a: 0.2, s: 1)) * (1 + bloom)
        let core = exp(-(p.r * p.r) / max(rCore * rCore, 1e-4))
        let shimmer = 0.07 * sin(2 * .pi * (0.5 * p.u + 0.07 * tau))
        let q = fract(h0 + span * (0.65 * p.r + 0.15 * p.theta) + shimmer)
        var lab = MusicLab.mix(pal(q), MusicLab(0.97, 0, 0), 0.7 * core)
        let ageBar = beta * Tbar
        let ring = gauss(p.r - ageBar / Tbar * 1.2, 0.08) * exp(-ageBar / (0.6 * Tbar))
        var I = 0.30 + 0.30 * pow(max(0, 1 - p.r), 0.7) * (0.5 + 0.5 * L)
        I += rho * ((0.40 + 0.20 * bloom) * ring * cb + 0.15 * cb * MoodMath.kb(pulsePhase(d), a: 0.12, s: 2))
        if f.isBreakdown { lab = lab.chromaScaled(0.5) }
        return MoodSample(lab: lab, I: I)
    }

    // MARK: M15 · Ember

    private func ember(_ p: MoodPixel) -> MoodSample {
        let fl = 0.55 + 0.25 * fbm3(2 * p.uUp + 10 * p.seedF, 0.7 * tau, 0, 2) + 0.10 * fbm3(5 * p.uUp, 1.7 * tau, 3, 1)
        let q = clamp01(0.25 + 0.6 * fl - 0.15 * (1 - Ls))
        let I = fl * (0.65 + 0.35 * Ls) + rho * 0.20 * BS.mid
        return MoodSample(lab: palClamp(q), I: I)
    }

    // MARK: M16 · Nebula

    private func nebula(_ p: MoodPixel) -> MoodSample {
        let x = p.x, y = p.y
        let wx = fbm3(1.3 * x, 1.3 * y, 0.03 * tau, 3)
        let wy = fbm3(1.3 * x + 5.2, 1.3 * y + 1.3, 0.03 * tau, 3)
        let q = clamp01(0.5 + 0.5 * fbm3(1.1 * x + 1.5 * wx, 1.1 * y + 1.5 * wy, 0.02 * tau, 3))
        let den = smoothstep(-0.2, 0.6, fbm3(0.9 * x - 3.1, 0.9 * y + 2.7, 0.025 * tau, 2))
        let (star, _) = stars(p, density: 0.3, seedSalt: 0x5EB)
        var I = 0.15 + 0.55 * den + rho * 0.20 * BS.bass * den + rho * 0.6 * star
        var lab = palClamp(q)
        if star > 0.01 { lab = MusicLab.mix(lab, palClamp(1), clamp01(star)) }
        if dDrop < 8 * T {
            let nx = 0.2 + 0.6 * MoodMath.hash01(UInt64(f.dropCount), 0x0A)
            let ny = 0.3 + 0.5 * MoodMath.hash01(UInt64(f.dropCount), 0x0B)
            let dx = x - nx, dy = y - ny
            let shell = gauss((dx * dx + dy * dy).squareRoot() - 0.5 * dDrop, 0.07) * exp(-dDrop / 3)
            I += 0.5 * shell
            lab = MusicLab.mix(lab, palClamp(1), clamp01(shell))
        }
        return MoodSample(lab: lab, I: I)
    }
}
