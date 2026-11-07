import Foundation

/// Small deterministic PRNG (SplitMix64) for reproducible synthetic audio on every platform.
public struct SyntheticRNG: Sendable {
    private var state: UInt64
    private var spare: Double?

    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    public mutating func uniform(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * uniform() }

    /// Standard normal (Box–Muller).
    public mutating func gaussian() -> Double {
        if let s = spare { spare = nil; return s }
        var u = uniform()
        if u < 1e-300 { u = 1e-300 }
        let v = uniform()
        let r = sqrt(-2 * log(u))
        spare = r * sin(2 * Double.pi * v)
        return r * cos(2 * Double.pi * v)
    }

    public mutating func exponential(mean: Double) -> Double { -mean * log(max(1e-300, 1 - uniform())) }
}

/// Deterministic synthetic music for tests, the in-app self-test and demo visuals.
/// A Swift port of the reference material in Appendix A of `docs/research/music_reactive.md`
/// (house / hip-hop / drum & bass loops, tempo ramps, breakdowns, grid jumps, random onsets)
/// plus click tracks, chirps, sweeps, pink noise and a synthetic build-up and drop. All 48 kHz mono.
public enum SyntheticAudio {
    public static let sampleRate = 48_000.0
    public enum Style: Sendable { case house, hiphop, dnb }

    // MARK: Instruments

    /// Pitch-swept sine kick (0.35 s).
    public static func kick() -> [Float] {
        let n = Int(0.35 * sampleRate)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let f = 50 + 90 * exp(-t / 0.03)
            phase += 2 * Double.pi * f / sampleRate
            out[i] = Float(sin(phase) * exp(-t / 0.12))
        }
        return out
    }

    /// Noise + 185 Hz body snare (0.25 s). `tone` lets build-ups use a higher, bass-free body.
    public static func snare(_ rng: inout SyntheticRNG, tone: Double = 185) -> [Float] {
        let n = Int(0.25 * sampleRate)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            out[i] = Float(0.6 * rng.gaussian() * exp(-t / 0.06) + 0.5 * sin(2 * Double.pi * tone * t) * exp(-t / 0.05))
        }
        return out
    }

    /// Differentiated-noise hi-hat (60 ms).
    public static func hat(_ rng: inout SyntheticRNG) -> [Float] {
        let n = Int(0.06 * sampleRate)
        var out = [Float](repeating: 0, count: n)
        var prev = 0.0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let x = rng.gaussian()
            out[i] = Float(0.25 * (x - prev) * exp(-t / 0.015))
            prev = x
        }
        return out
    }

    /// Short broadband click (metronome): 2 ms noise burst + decaying 1.5 kHz tone.
    public static func click(_ rng: inout SyntheticRNG, accent: Bool) -> [Float] {
        let n = Int(0.04 * sampleRate)
        var out = [Float](repeating: 0, count: n)
        let f = accent ? 2000.0 : 1500.0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            out[i] = Float(0.8 * rng.gaussian() * exp(-t / 0.002) + 0.6 * sin(2 * Double.pi * f * t) * exp(-t / 0.012))
        }
        return out
    }

    static func place(_ buf: inout [Float], _ sample: [Float], at t0: Double, gain: Double = 1) {
        let i = Int((t0 * sampleRate).rounded())
        guard i >= 0, i < buf.count else { return }
        let j = min(buf.count, i + sample.count)
        let g = Float(gain)
        for k in i..<j { buf[k] += g * sample[k - i] }
    }

    static func normalize(_ y: inout [Float], headroom: Float = 1.1) {
        var m: Float = 0
        for v in y { m = max(m, abs(v)) }
        guard m > 0 else { return }
        let s = 1 / (m * headroom)
        for i in 0..<y.count { y[i] *= s }
    }

    // MARK: Loops

    /// A drum loop with a bass line whose root changes every bar. Returns the samples and the
    /// ground-truth beat times.
    public static func track(bpm: Double, seconds: Double = 40, style: Style = .house, swing: Double = 0,
                             offset: Double = 0.37, seed: UInt64 = 1) -> (samples: [Float], beats: [Double]) {
        var rng = SyntheticRNG(seed: seed)
        let n = Int(seconds * sampleRate)
        var y = [Float](repeating: 0, count: n)
        let T = 60 / bpm
        let nbeats = Int((seconds - offset) / T)
        let k = kick()
        for b in 0..<max(0, nbeats) {
            let tb = offset + Double(b) * T
            let pos = b % 4
            switch style {
            case .house:
                place(&y, k, at: tb, gain: 1.0)
                if pos == 1 || pos == 3 { place(&y, snare(&rng), at: tb, gain: 0.6) }
                place(&y, hat(&rng), at: tb + T / 2 + swing * T / 2, gain: 0.5)
                place(&y, hat(&rng), at: tb, gain: 0.3)
            case .dnb:
                if pos == 0 { place(&y, k, at: tb, gain: 1.0) }
                if pos == 2 { place(&y, k, at: tb + T / 2, gain: 1.0) }
                if pos == 1 || pos == 3 { place(&y, snare(&rng), at: tb, gain: 0.8) }
                for s in 0..<4 { place(&y, hat(&rng), at: tb + Double(s) * T / 4, gain: 0.25) }
            case .hiphop:
                if pos == 0 { place(&y, k, at: tb, gain: 1.0) }
                if pos == 2 { place(&y, k, at: tb + T * (0.5 + swing / 2), gain: 0.8) }
                if pos == 1 || pos == 3 { place(&y, snare(&rng), at: tb, gain: 0.8) }
                for s in 0..<2 { place(&y, hat(&rng), at: tb + Double(s) * T / 2 + (s == 1 ? swing * T / 2 : 0), gain: 0.3) }
            }
        }
        addBassLine(&y, bpm: bpm, offset: offset, gain: 0.15)
        for i in 0..<n { y[i] += Float(0.03 * rng.gaussian()) }
        normalize(&y)
        return (y, (0..<max(0, nbeats)).map { offset + Double($0) * T })
    }

    static func addBassLine(_ y: inout [Float], bpm: Double, offset: Double, gain: Double, from: Int = 0, to: Int? = nil) {
        let roots = [55.0, 43.65, 49.0, 41.2]
        let T = 60 / bpm
        var phase = 0.0
        let end = min(y.count, to ?? y.count)
        for i in 0..<end {
            let t = Double(i) / sampleRate
            var bar = Int(((t - offset) / (4 * T)).rounded(.towardZero)) % 4
            bar = max(0, min(3, bar))
            phase += 2 * Double.pi * roots[bar] / sampleRate
            if i >= from { y[i] += Float(gain * sin(phase)) }
        }
    }

    /// A-major-ish pad with a slow 0.1 Hz swell.
    public static func pad(count n: Int) -> [Float] {
        var out = [Float](repeating: 0, count: max(0, n))
        for i in 0..<out.count {
            let t = Double(i) / sampleRate
            let s = sin(2 * Double.pi * 220 * t) + sin(2 * Double.pi * 277.2 * t) + sin(2 * Double.pi * 329.6 * t)
            out[i] = Float(0.2 * s * (0.6 + 0.4 * sin(2 * Double.pi * 0.1 * t)))
        }
        return out
    }

    /// House track whose drums are replaced by a pad between `start` and `stop`.
    public static func breakdownTrack(bpm: Double = 124, seconds: Double = 45, start: Double = 20, stop: Double = 30,
                                      seed: UInt64 = 1) -> (samples: [Float], beats: [Double]) {
        var (y, beats) = track(bpm: bpm, seconds: seconds, style: .house, seed: seed)
        var rng = SyntheticRNG(seed: seed &+ 77)
        let p = pad(count: y.count)
        for i in 0..<y.count {
            let t = Double(i) / sampleRate
            if t > start && t < stop { y[i] = Float(0.35 * Double(p[i]) + 0.01 * rng.gaussian()) }
        }
        return (y, beats)
    }

    /// Tempo glides linearly from `b0` to `b1` BPM; every beat gets N(0, jitter) timing noise.
    public static func rampTrack(from b0: Double = 120, to b1: Double = 128, seconds: Double = 40, offset: Double = 0.37,
                                 jitter: Double = 0.006, seed: UInt64 = 1) -> (samples: [Float], beats: [Double], endBPM: Double) {
        var rng = SyntheticRNG(seed: seed)
        let n = Int(seconds * sampleRate)
        var y = [Float](repeating: 0, count: n)
        var beats: [Double] = []
        var tb = offset
        var k = 0
        let kk = kick()
        while tb < seconds - 0.5 {
            let bpm = b0 + (b1 - b0) * tb / seconds
            let T = 60 / bpm
            let tj = tb + jitter * rng.gaussian()
            place(&y, kk, at: tj, gain: 1.0)
            if k % 4 == 1 || k % 4 == 3 { place(&y, snare(&rng), at: tj, gain: 0.6) }
            place(&y, hat(&rng), at: tj + T / 2, gain: 0.5)
            beats.append(tb)
            tb += T
            k += 1
        }
        for i in 0..<n { y[i] += Float(0.03 * rng.gaussian()) }
        normalize(&y)
        let last = beats.last ?? 0
        return (y, beats, b0 + (b1 - b0) * last / seconds)
    }

    /// Same tempo, but the beat grid jumps by `shift` beats at `jumpAt` (a hard DJ cut).
    public static func phaseJumpTrack(bpm: Double = 124, seconds: Double = 40, jumpAt: Double = 22, shift: Double = 0.5,
                                      seed: UInt64 = 1) -> (samples: [Float], beats: [Double]) {
        let a = track(bpm: bpm, seconds: seconds, style: .house, seed: seed)
        let b = track(bpm: bpm, seconds: seconds, style: .house, offset: 0.37 + shift * 60 / bpm, seed: seed &+ 1)
        let n = Int(jumpAt * sampleRate)
        var y = Array(a.samples[0..<min(n, a.samples.count)])
        if n < b.samples.count { y += b.samples[n...] }
        return (y, a.beats.filter { $0 < jumpAt } + b.beats.filter { $0 >= jumpAt })
    }

    /// Poisson snare hits (mean spacing 0.35 s): onsets without any tempo.
    public static func randomOnsets(seconds: Double = 30, seed: UInt64 = 1) -> [Float] {
        var rng = SyntheticRNG(seed: seed)
        var y = [Float](repeating: 0, count: Int(seconds * sampleRate))
        var t = 0.2
        while t < seconds - 1 {
            let s = snare(&rng).map { $0 * 0.5 }
            place(&y, s, at: t, gain: rng.uniform(0.3, 1))
            t += rng.exponential(mean: 0.35)
        }
        for i in 0..<y.count { y[i] += Float(0.01 * rng.gaussian()) }
        return y
    }

    /// Metronome clicks at a known tempo (accent on every 4th beat) over a quiet noise floor.
    public static func clickTrack(bpm: Double, seconds: Double = 30, offset: Double = 0.25,
                                  seed: UInt64 = 1) -> (samples: [Float], beats: [Double]) {
        var rng = SyntheticRNG(seed: seed)
        var y = [Float](repeating: 0, count: Int(seconds * sampleRate))
        let T = 60 / bpm
        var beats: [Double] = []
        var b = 0
        while offset + Double(b) * T < seconds - 0.05 {
            let tb = offset + Double(b) * T
            place(&y, click(&rng, accent: b % 4 == 0), at: tb, gain: b % 4 == 0 ? 1.0 : 0.7)
            beats.append(tb)
            b += 1
        }
        for i in 0..<y.count { y[i] += Float(0.003 * rng.gaussian()) }
        normalize(&y)
        return (y, beats)
    }

    /// A short rising chirp (200 Hz → 3 kHz in 80 ms) on every beat at a known tempo.
    public static func chirpTrack(bpm: Double, seconds: Double = 30, offset: Double = 0.3,
                                  seed: UInt64 = 1) -> (samples: [Float], beats: [Double]) {
        var rng = SyntheticRNG(seed: seed)
        var y = [Float](repeating: 0, count: Int(seconds * sampleRate))
        let n = Int(0.08 * sampleRate)
        var chirp = [Float](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<n {
            let u = Double(i) / Double(n)
            let f = 200 * pow(15, u)
            phase += 2 * Double.pi * f / sampleRate
            chirp[i] = Float(sin(phase) * sin(Double.pi * u) * exp(-u * 2))
        }
        let T = 60 / bpm
        var beats: [Double] = []
        var b = 0
        while offset + Double(b) * T < seconds - 0.1 {
            let tb = offset + Double(b) * T
            place(&y, chirp, at: tb, gain: b % 4 == 0 ? 1.0 : 0.75)
            beats.append(tb)
            b += 1
        }
        for i in 0..<y.count { y[i] += Float(0.005 * rng.gaussian()) }
        normalize(&y)
        return (y, beats)
    }

    /// Continuous exponential sine sweep from `f0` to `f1` Hz.
    public static func sweep(from f0: Double, to f1: Double, seconds: Double, amplitude: Double = 0.5) -> [Float] {
        let n = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        let ratio = f1 / f0
        for i in 0..<n {
            let u = Double(i) / Double(max(1, n - 1))
            phase += 2 * Double.pi * f0 * pow(ratio, u) / sampleRate
            out[i] = Float(amplitude * sin(phase))
        }
        return out
    }

    /// Pink noise (Paul Kellet's filter), RMS ≈ `amplitude`.
    public static func pinkNoise(seconds: Double, amplitude: Double = 0.1, seed: UInt64 = 1) -> [Float] {
        var rng = SyntheticRNG(seed: seed)
        let n = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: n)
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
        var sumSq = 0.0
        for i in 0..<n {
            let w = rng.gaussian()
            b0 = 0.99886 * b0 + w * 0.0555179
            b1 = 0.99332 * b1 + w * 0.0750759
            b2 = 0.96900 * b2 + w * 0.1538520
            b3 = 0.86650 * b3 + w * 0.3104856
            b4 = 0.55000 * b4 + w * 0.5329522
            b5 = -0.7616 * b5 - w * 0.0168980
            let p = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362
            b6 = w * 0.115926
            out[i] = Float(p)
            sumSq += p * p
        }
        let rms = sqrt(sumSq / Double(max(1, n)))
        if rms > 0 {
            let g = Float(amplitude / rms)
            for i in 0..<n { out[i] *= g }
        }
        return out
    }

    public static func silence(seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * sampleRate)) }

    /// A synthetic EDM arrangement: 8 bars of groove, an 8-bar build-up (drums and bass removed,
    /// accelerating snare roll, rising noise riser), then an 8-bar drop (heavy kick + sub bass).
    /// Returns the samples, the build start and the drop time.
    public static func buildAndDrop(bpm: Double = 128, offset: Double = 0.37,
                                    seed: UInt64 = 1) -> (samples: [Float], buildStart: Double, dropTime: Double) {
        var rng = SyntheticRNG(seed: seed)
        let T = 60 / bpm
        let bar = 4 * T
        let buildStart = offset + 8 * bar
        let drop = offset + 16 * bar
        let seconds = offset + 24 * bar + 1
        let n = Int(seconds * sampleRate)
        var y = [Float](repeating: 0, count: n)
        let k = kick()
        let totalBeats = 24 * 4
        for b in 0..<totalBeats {
            let tb = offset + Double(b) * T
            let pos = b % 4
            if b < 32 {                                   // groove
                place(&y, k, at: tb, gain: 1.0)
                if pos == 1 || pos == 3 { place(&y, snare(&rng), at: tb, gain: 0.6) }
                place(&y, hat(&rng), at: tb + T / 2, gain: 0.5)
            } else if b < 64 {                            // build-up: snare roll gets denser and louder
                let barInBuild = (b - 32) / 4
                let perBeat = [1, 1, 2, 2, 4, 4, 4, 4][min(7, barInBuild)]
                let gain = 0.25 + 0.06 * Double(barInBuild)
                for s in 0..<perBeat {
                    place(&y, snare(&rng, tone: 330), at: tb + Double(s) * T / Double(perBeat), gain: gain)
                }
            } else {                                      // drop
                place(&y, k, at: tb, gain: 1.3)
                if pos == 1 || pos == 3 { place(&y, snare(&rng), at: tb, gain: 0.7) }
                place(&y, hat(&rng), at: tb + T / 2, gain: 0.6)
                place(&y, hat(&rng), at: tb, gain: 0.35)
            }
        }
        // Bass line in the groove, heavy sub bass in the drop, riser in the build.
        let iBuild = Int(buildStart * sampleRate), iDrop = Int(drop * sampleRate)
        addBassLine(&y, bpm: bpm, offset: offset, gain: 0.15, from: 0, to: iBuild)
        var phase = 0.0
        var prev = 0.0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            if i >= iDrop {
                phase += 2 * Double.pi * 49 / sampleRate
                y[i] += Float(0.35 * sin(phase))
            } else if i >= iBuild {
                let u = (t - buildStart) / (drop - buildStart)
                let w = rng.gaussian()
                y[i] += Float(0.02 + 0.22 * u * u) * Float(w - prev)   // brightening noise riser
                prev = w
            }
            y[i] += Float(0.02 * rng.gaussian())
        }
        normalize(&y)
        return (y, buildStart, drop)
    }
}
