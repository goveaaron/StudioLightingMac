import Foundation

/// AGC behaviour presets (§1.5): how quickly the auto-range forgets loud moments.
public enum AGCPreset: String, Codable, CaseIterable, Sendable {
    /// Lively: quieter parts look brighter.
    case vivid
    /// Default.
    case normal
    /// Most dynamic, cinematic.
    case lazy

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AGCPreset(rawValue: raw) ?? .normal
    }

    /// Peak-follower release time constant (s).
    var peakRelease: Double {
        switch self { case .vivid: return 2; case .normal: return 4; case .lazy: return 8 }
    }

    /// Loudness-reference release time constant (s).
    var referenceRelease: Double {
        switch self { case .vivid: return 15; case .normal: return 30; case .lazy: return 60 }
    }

    public var displayName: String {
        switch self { case .vivid: return "Vivid"; case .normal: return "Balanced"; case .lazy: return "Cinematic" }
    }
}

/// Precomputed fractional-overlap weights of FFT bins for one frequency band.
struct BandWeights {
    let start: Int
    let weights: [Float]

    init(lo: Double, hi: Double, binHz: Double, bins: Int) {
        var s = Int.max
        var w: [Float] = []
        for k in 1..<bins {
            let f0 = (Double(k) - 0.5) * binHz, f1 = (Double(k) + 0.5) * binHz
            let overlap = max(0, min(f1, hi) - max(f0, lo)) / binHz
            if overlap > 0 {
                if s == Int.max { s = k }
                // Fill any gap (cannot happen for contiguous bands, kept for safety).
                while s + w.count < k { w.append(0) }
                w.append(Float(overlap))
            }
        }
        start = s == Int.max ? 0 : s
        weights = w
    }

    @inline(__always)
    func energy(_ power: UnsafePointer<Float>) -> Double {
        var e: Float = 0
        weights.withUnsafeBufferPointer { wp in
            for i in 0..<wp.count { e += wp[i] * power[start + i] }
        }
        return Double(e)
    }
}

/// Per-band auto-range in the dB domain: fast peak follower + slow floor follower (§1.5).
struct AutoRange {
    var peak = 0.0
    var floor = 0.0
    var initialized = false

    mutating func normalize(_ db: Double, dt: Double, peakRelease: Double, frozen: Bool) -> Double {
        if !initialized {
            if frozen { return 0 }
            peak = db + 3
            floor = db - 15
            initialized = true
        }
        if !frozen {
            peak += onePoleAlpha(dt: dt, tau: db > peak ? 0.15 : peakRelease) * (db - peak)
            floor += onePoleAlpha(dt: dt, tau: db < floor ? 0.5 : 8.0) * (db - floor)
        }
        let range = clamp(peak - floor, 12, 40)
        return clamp01((db - floor) / range)
    }
}

/// Spectral path (§1.3, §1.5, §1.11): N = 4096, hop 1024 → 6 AGC'd bands (three smoothings),
/// 16 log bands, brightness, flatness, raw low-end energy and the dominant bass pitch.
final class SpectralAnalyzer {
    static let size = 4096
    static let dt = 1024.0 / 48_000.0

    private let fft: RealFFT
    private let window: FloatBuffer
    private let frame: FloatBuffer
    private let power: FloatBuffer
    private let bandW: [BandWeights]
    private let specW: [BandWeights]
    private var bandRange = [AutoRange](repeating: AutoRange(), count: 6)
    private var specRange = [AutoRange](repeating: AutoRange(), count: 16)
    private var euro = [OneEuroFilter](repeating: OneEuroFilter(minCutoff: 1.0, beta: 0.3), count: 6)
    private var fast = [AttackRelease](repeating: AttackRelease(), count: 6)
    private var slow = [EMA](repeating: EMA(), count: 6)
    private var spec = [AttackRelease](repeating: AttackRelease(), count: 16)
    private var brightFilter = OneEuroFilter(minCutoff: 0.3, beta: 0.05)
    private var flatEMA = EMA()
    private let centroidRange: Range<Int>
    private let flatRange: Range<Int>
    private let bassRange: Range<Int>
    private let binHz: Double

    // Outputs.
    private(set) var bands = Bands6()
    private(set) var bandsFast = Bands6()
    private(set) var bandsSlow = Bands6()
    private(set) var spectrum16 = SIMD16<Double>(repeating: 0)
    private(set) var brightness = 0.0
    private(set) var flatness = 0.0
    /// Linear sub + bass power of the latest frame (for drops / build-ups).
    private(set) var lowEnergy = 0.0
    /// Dominant 30–250 Hz peak (Hz), 0 when none.
    private(set) var bassPitch = 0.0
    /// Normalised bands before smoothing (novelty input).
    private(set) var rawBands = Bands6()

    init() {
        let n = SpectralAnalyzer.size
        guard let f = RealFFT(size: n) else { preconditionFailure("RealFFT(4096) must exist") }
        fft = f
        window = FloatBuffer(n)
        let w = RealFFT.hann(n)
        for i in 0..<n { window[i] = w[i] }
        frame = FloatBuffer(n)
        power = FloatBuffer(n / 2 + 1)
        binHz = 48_000.0 / Double(n)
        let bins = n / 2 + 1
        let edges: [(Double, Double)] = [(20, 60), (60, 250), (250, 500), (500, 2000), (2000, 6000), (6000, 16000)]
        bandW = edges.map { BandWeights(lo: $0.0, hi: $0.1, binHz: 48_000.0 / Double(n), bins: bins) }
        var sw: [BandWeights] = []
        for i in 0..<16 {
            let lo = 40 * pow(400, Double(i) / 16), hi = 40 * pow(400, Double(i + 1) / 16)
            sw.append(BandWeights(lo: lo, hi: hi, binHz: 48_000.0 / Double(n), bins: bins))
        }
        specW = sw
        let hz = 48_000.0 / Double(n)
        centroidRange = Int((40 / hz).rounded(.up))..<min(bins, Int(16000 / hz))
        flatRange = Int((200 / hz).rounded(.up))..<min(bins, Int(16000 / hz))
        bassRange = Int((30 / hz).rounded(.up))..<Int(250 / hz)
    }

    func process(window samples: UnsafePointer<Float>, peakRelease: Double, frozen: Bool) {
        let n = SpectralAnalyzer.size
        for i in 0..<n {
            let v = samples[i]
            frame[i] = v.isFinite ? v * window[i] : 0
        }
        fft.powerSpectrum(frame.p, into: power.p)
        // Amplitude scaling: full-scale sine → 1 at its bin ⇒ power × (4/N)².
        let s = Float(4.0 / Double(n))
        let s2 = s * s
        for k in 0...(n / 2) { power[k] *= s2 }
        let dt = SpectralAnalyzer.dt

        for b in 0..<6 {
            let e = bandW[b].energy(power.p)
            if b == 0 { lowEnergy = e } else if b == 1 { lowEnergy += e }
            let db = 10 * log10(e + 1e-12)
            let nb = bandRange[b].normalize(db, dt: dt, peakRelease: peakRelease, frozen: frozen)
            let target = frozen ? 0 : nb
            rawBands[b] = target
            bands[b] = clamp01(euro[b].filter(target, dt: dt))
            bandsFast[b] = clamp01(fast[b].step(target, dt: dt, attack: 0.010, release: 0.120))
            bandsSlow[b] = clamp01(slow[b].step(target, dt: dt, tau: 1.0))
        }
        for b in 0..<16 {
            let db = 10 * log10(specW[b].energy(power.p) + 1e-12)
            let nb = specRange[b].normalize(db, dt: dt, peakRelease: peakRelease, frozen: frozen)
            spectrum16[b] = clamp01(spec[b].step(frozen ? 0 : nb, dt: dt, attack: 0.015, release: 0.200))
        }

        // Brightness: log spectral centroid, 250 Hz → 0, 8 kHz → 1.
        var num = 0.0, den = 0.0
        for k in centroidRange {
            let m = Double(power[k].squareRoot())
            num += Double(k) * binHz * m
            den += m
        }
        if den > 1e-9 && !frozen {
            let centroid = num / den
            let b = clamp01(log2(max(centroid, 1) / 250) / log2(8000.0 / 250))
            brightness = clamp01(brightFilter.filter(b, dt: dt))
        }
        // Flatness: geometric / arithmetic mean of power, 200 Hz – 16 kHz.
        var lsum = 0.0, psum = 0.0
        for k in flatRange {
            let p = Double(power[k]) + 1e-12
            lsum += log(p)
            psum += p
        }
        let cnt = Double(max(1, flatRange.count))
        let flat = psum > 1e-10 ? clamp01(exp(lsum / cnt) / (psum / cnt)) : 0
        if !frozen { flatness = clamp01(flatEMA.step(flat, dt: dt, tau: 0.3)) }

        // Dominant bass pitch (parabolic interpolation on dB).
        var bestK = -1
        var bestP: Float = 0
        for k in bassRange where power[k] > bestP { bestP = power[k]; bestK = k }
        if bestK > bassRange.lowerBound && bestK + 1 < bassRange.upperBound && bestP > 1e-9 {
            let a = 10 * log10(Double(power[bestK - 1]) + 1e-12)
            let b = 10 * log10(Double(power[bestK]) + 1e-12)
            let c = 10 * log10(Double(power[bestK + 1]) + 1e-12)
            let d = a - 2 * b + c
            let p = d < 0 ? 0.5 * (a - c) / d : 0
            bassPitch = (Double(bestK) + clamp(p, -0.5, 0.5)) * binHz
        } else {
            bassPitch = 0
        }
    }

    func reset() {
        bandRange = [AutoRange](repeating: AutoRange(), count: 6)
        specRange = [AutoRange](repeating: AutoRange(), count: 16)
        for i in 0..<6 { euro[i].reset(); fast[i] = AttackRelease(); slow[i].reset() }
        for i in 0..<16 { spec[i] = AttackRelease() }
        brightFilter.reset(); flatEMA.reset()
        bands = Bands6(); bandsFast = Bands6(); bandsSlow = Bands6(); rawBands = Bands6()
        spectrum16 = SIMD16<Double>(repeating: 0)
        brightness = 0; flatness = 0; lowEnergy = 0; bassPitch = 0
    }
}

/// Silence gate with hysteresis and an eased presence value (§1.14).
public struct SilenceGate: Sendable, Equatable {
    /// Level (dBFS) below which audio counts as silence. Exit threshold is 10 dB higher.
    public var thresholdDB: Double = -60
    public private(set) var isSilent = true
    public private(set) var digitalSilence = true
    /// Capture time silence began (valid while `isSilent`).
    public private(set) var silentSince: Double = 0
    private var belowSeconds = 0.0
    private var zeroSeconds = 0.0
    private var aboveSeconds = 0.0
    private var ramp = 0.0   // linear 0…1, eased into `presence`

    public init(thresholdDB: Double = -60) { self.thresholdDB = thresholdDB }

    /// 0…1: eases 1 → 0 over 3 s into silence and 0 → 1 over 0.8 s when music returns.
    public var presence: Double { 0.5 - 0.5 * cos(Double.pi * clamp01(ramp)) }

    /// Seconds of continuous silence at time `t` (0 while music plays).
    public func silentSeconds(at t: Double) -> Double { isSilent ? max(0, t - silentSince) : 0 }

    public mutating func update(levelDB: Double, exactZeros: Bool, dt: Double, time: Double) {
        let level = levelDB.isFinite ? levelDB : -120
        digitalSilence = exactZeros
        if isSilent {
            if level > thresholdDB + 10 && !exactZeros {
                aboveSeconds += dt
                if aboveSeconds >= 0.1 - 1e-9 { isSilent = false; belowSeconds = 0; zeroSeconds = 0 }
            } else {
                aboveSeconds = 0
            }
        } else {
            zeroSeconds = exactZeros ? zeroSeconds + dt : 0
            belowSeconds = level < thresholdDB ? belowSeconds + dt : 0
            if belowSeconds >= 1.0 - 1e-9 || zeroSeconds >= 0.3 - 1e-9 {
                isSilent = true
                aboveSeconds = 0
                silentSince = time - (zeroSeconds >= 0.3 - 1e-9 ? zeroSeconds : belowSeconds)
            }
        }
        if isSilent { ramp = max(0, ramp - dt / 3.0) } else { ramp = min(1, ramp + dt / 0.8) }
    }

    public mutating func reset() {
        isSilent = true; digitalSilence = true; silentSince = 0
        belowSeconds = 0; zeroSeconds = 0; aboveSeconds = 0; ramp = 0
    }
}

/// K-weighted loudness (BS.1770 momentary / short-term), AGC reference and raw level (§1.4–1.5).
final class LoudnessMeter {
    static let blockSize = 1024
    private var stage1 = Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
                                a1: -1.69065929318241, a2: 0.73248077421585)
    private var stage2 = Biquad(b0: 1.0, b1: -2.0, b2: 1.0, a1: -1.99004745483398, a2: 0.99007225036621)
    private var sumK = 0.0
    private var sumRaw = 0.0
    private var peak: Float = 0
    private var count = 0
    private let kBlocks = History(capacity: 141)    // 3 s of 21.3 ms blocks
    private let rawBlocks = History(capacity: 5)    // ≈ 107 ms
    private var euro = OneEuroFilter(minCutoff: 1.0, beta: 0.3)
    private var slowEMA = EMA()

    private(set) var momentaryLUFS = -70.0
    private(set) var shortTermLUFS = -70.0
    private(set) var reference = -18.0
    private(set) var levelDB = -120.0
    private(set) var lastBlockAllZero = true
    private(set) var loudness = 0.0
    private(set) var loudnessSlow = 0.0
    /// Non-silent seconds since the last reset or long silence. For the first few seconds the
    /// reference converges fast in both directions so a new source looks right within ~2 s.
    private var activeSeconds = 0.0
    private var silentSeconds = 0.0
    private var activeBlocks = 0       // consecutive non-silent blocks (capped at 141)
    static let acquisitionSeconds = 6.0

    @inline(__always)
    func process(_ x: Float) {
        let d = Double(x)
        let y = stage2.process(stage1.process(d))
        sumK += y * y
        sumRaw += d * d
        let a = abs(x)
        if a > peak { peak = a }
        count += 1
    }

    /// Closes the current block (call every 1024 samples) and updates all loudness values.
    func finishBlock(silent: Bool, referenceRelease: Double) {
        let n = Double(max(1, count))
        kBlocks.push(sumK / n)
        rawBlocks.push(sumRaw / n)
        lastBlockAllZero = peak == 0
        sumK = 0; sumRaw = 0; peak = 0; count = 0
        let dt = Double(LoudnessMeter.blockSize) / 48_000.0

        // +3.01 dB: the mono mix stands in for two identical channels (G_L = G_R = 1).
        func lufs(_ blocks: Int) -> Double {
            let m = min(blocks, kBlocks.count)
            guard m > 0 else { return -70 }
            var s = 0.0
            for i in 0..<m { s += kBlocks[i] }
            let ms = s / Double(m)
            return max(-70, -0.691 + 10 * log10(ms + 1e-14) + 3.01)
        }
        momentaryLUFS = lufs(19)
        shortTermLUFS = lufs(141)
        var raw = 0.0
        for i in 0..<rawBlocks.count { raw += rawBlocks[i] }
        raw /= Double(max(1, rawBlocks.count))
        levelDB = max(-120, 10 * log10(raw + 1e-14))

        if silent {
            silentSeconds += dt
            activeBlocks = 0
            if silentSeconds > 20 { activeSeconds = 0 }   // long pause / new source: re-acquire
        } else {
            silentSeconds = 0
            activeBlocks = min(activeBlocks + 1, 141)
            activeSeconds += dt
            let acquiring = activeSeconds < LoudnessMeter.acquisitionSeconds
            // While acquiring, measure only blocks that are certainly music (not the silence before).
            let s = acquiring ? lufs(max(4, activeBlocks)) : shortTermLUFS
            let tau = s > reference ? (acquiring ? 1.0 : 3.0) : (acquiring ? 1.5 : referenceRelease)
            reference += onePoleAlpha(dt: dt, tau: tau) * (s - reference)
            reference = clamp(reference, -45, -5)
        }
        let mNorm = silent ? 0 : clamp01((momentaryLUFS - reference + 18) / 24)
        let sNorm = silent ? 0 : clamp01((shortTermLUFS - reference + 18) / 24)
        loudness = clamp01(euro.filter(mNorm, dt: dt))
        loudnessSlow = clamp01(slowEMA.step(sNorm, dt: dt, tau: 1.5))
    }

    func reset() {
        stage1.reset(); stage2.reset()
        sumK = 0; sumRaw = 0; peak = 0; count = 0
        kBlocks.reset(); rawBlocks.reset()
        euro.reset(); slowEMA.reset()
        momentaryLUFS = -70; shortTermLUFS = -70; levelDB = -120; lastBlockAllZero = true
        loudness = 0; loudnessSlow = 0
        activeSeconds = 0; silentSeconds = 0; activeBlocks = 0
    }
}

/// Tonal path (§1.10): N = 8192 chroma (65 Hz–2.1 kHz peaks, cos² semitone window), key via
/// Krumhansl–Kessler profiles, and the circle-of-fifths harmonic hue.
final class TonalAnalyzer {
    static let size = 8192
    static let dt = 2048.0 / 48_000.0
    static let major: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    private let fft: RealFFT
    private let window: FloatBuffer
    private let frame: FloatBuffer
    private let power: FloatBuffer
    private let range: Range<Int>
    private let binHz = 48_000.0 / Double(TonalAnalyzer.size)

    private(set) var raw = SIMD16<Double>(repeating: 0)
    private(set) var display = SIMD16<Double>(repeating: 0)
    private(set) var color = SIMD16<Double>(repeating: 0)
    private(set) var keyChroma = SIMD16<Double>(repeating: 0)
    private var displayInit = false
    private(set) var harmonicHue = 0.0
    private(set) var tonalClarity = 0.0
    private(set) var key = -1
    private(set) var keyConfidence = 0.0
    private var candidateKey = -1
    private var candidateSeconds = 0.0
    private var keyUpdateClock = 0.0

    init() {
        let n = TonalAnalyzer.size
        guard let f = RealFFT(size: n) else { preconditionFailure("RealFFT(8192) must exist") }
        fft = f
        window = FloatBuffer(n)
        let w = RealFFT.hann(n)
        for i in 0..<n { window[i] = w[i] }
        frame = FloatBuffer(n)
        power = FloatBuffer(n / 2 + 1)
        let hz = 48_000.0 / Double(n)
        range = Int((65 / hz).rounded(.up))..<Int(2100 / hz)
    }

    func process(window samples: UnsafePointer<Float>, frozen: Bool) {
        let n = TonalAnalyzer.size
        for i in 0..<n {
            let v = samples[i]
            frame[i] = v.isFinite ? v * window[i] : 0
        }
        fft.powerSpectrum(frame.p, into: power.p)
        var c = SIMD16<Double>(repeating: 0)
        var maxP: Float = 0
        for k in range where power[k] > maxP { maxP = power[k] }
        let dt = TonalAnalyzer.dt
        if maxP > 1e-12 && !frozen {
            let floorP = maxP * 1e-6   // −60 dB re frame max (power)
            var k = range.lowerBound + 1
            while k < range.upperBound - 1 {
                let pk = power[k]
                if pk >= floorP && pk > power[k - 1] && pk >= power[k + 1] {
                    let a = 10 * log10(Double(power[k - 1]) + 1e-20)
                    let b = 10 * log10(Double(pk) + 1e-20)
                    let g = 10 * log10(Double(power[k + 1]) + 1e-20)
                    let d = a - 2 * b + g
                    let p = d < 0 ? clamp(0.5 * (a - g) / d, -0.5, 0.5) : 0
                    let freq = (Double(k) + p) * binHz
                    let ampDB = b - 0.25 * (a - g) * p
                    let a2 = pow(10, ampDB / 10)   // power ∝ amplitude²
                    let pitch = 12 * log2(freq / 440) + 69
                    let nearest = pitch.rounded()
                    let dist = abs(pitch - nearest)
                    if dist < 0.5 {
                        var pc = Int(nearest) % 12
                        if pc < 0 { pc += 12 }
                        let w = cos(Double.pi * dist)
                        c[pc] += a2 * w * w
                    }
                    k += 2
                } else {
                    k += 1
                }
            }
            let m = c.max()
            if m > 0 { c /= m }
            raw = c
            if !displayInit { display = c; color = c; keyChroma = c; displayInit = true }
            display += (c - display) * onePoleAlpha(dt: dt, tau: 0.5)
            color += (c - color) * onePoleAlpha(dt: dt, tau: 2.0)
            keyChroma += (c - keyChroma) * onePoleAlpha(dt: dt, tau: 20.0)
            updateHue()
            keyUpdateClock += dt
            if keyUpdateClock >= 0.25 {
                updateKey(dt: keyUpdateClock)
                keyUpdateClock = 0
            }
        } else if !frozen {
            raw = c
            display += (c - display) * onePoleAlpha(dt: dt, tau: 0.5)
        }
    }

    private func updateHue() {
        var zr = 0.0, zi = 0.0, sum = 0.0
        for pc in 0..<12 {
            let q = Double((7 * pc) % 12)
            let a = 2 * Double.pi * q / 12
            zr += color[pc] * cos(a)
            zi += color[pc] * sin(a)
            sum += color[pc]
        }
        guard sum > 1e-9 else { return }
        var turn = atan2(zi, zr) / (2 * Double.pi)
        if turn < 0 { turn += 1 }
        harmonicHue = turn
        tonalClarity = clamp01(sqrt(zr * zr + zi * zi) / sum)
    }

    private func updateKey(dt: Double) {
        var best = -2.0, second = -2.0, bestK = -1
        let x = keyChroma
        var mx = 0.0
        for i in 0..<12 { mx += x[i] }
        mx /= 12
        var sx = 0.0
        for i in 0..<12 { sx += (x[i] - mx) * (x[i] - mx) }
        guard sx > 1e-12 else { return }
        for k in 0..<24 {
            let prof = k < 12 ? TonalAnalyzer.major : TonalAnalyzer.minor
            let root = k % 12
            var mp = 0.0
            for v in prof { mp += v }
            mp /= 12
            var num = 0.0, sp = 0.0
            for i in 0..<12 {
                let pv = prof[(i - root + 12) % 12] - mp
                num += (x[i] - mx) * pv
                sp += pv * pv
            }
            let r = num / sqrt(sx * sp)
            if r > best { second = best; best = r; bestK = k } else if r > second { second = r }
        }
        let conf = clamp01((best - second) / 0.15)
        if key < 0 {
            key = bestK
            keyConfidence = conf
            candidateKey = bestK
            candidateSeconds = 0
            return
        }
        if bestK == key {
            candidateSeconds = 0
            keyConfidence = conf
        } else {
            if bestK == candidateKey { candidateSeconds += dt } else { candidateKey = bestK; candidateSeconds = dt }
            if candidateSeconds >= 8 { key = bestK; keyConfidence = conf; candidateSeconds = 0 }
            else { keyConfidence = min(keyConfidence, conf) }
        }
    }

    func reset() {
        raw = .init(repeating: 0); display = .init(repeating: 0); color = .init(repeating: 0)
        keyChroma = .init(repeating: 0); displayInit = false
        harmonicHue = 0; tonalClarity = 0; key = -1; keyConfidence = 0
        candidateKey = -1; candidateSeconds = 0; keyUpdateClock = 0
    }
}
