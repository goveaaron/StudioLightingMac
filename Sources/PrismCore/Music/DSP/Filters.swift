import Foundation

// Small, allocation-free signal-processing primitives shared by the music analyzer.
// Everything here is a value type or a preallocated buffer so the analysis thread never
// allocates in steady state (docs/research/music_reactive.md §1, §4.4).

/// One-pole smoothing coefficient `a = 1 − e^(−dt/τ)` (τ ≤ 0 → 1, i.e. no smoothing).
@inline(__always)
func onePoleAlpha(dt: Double, tau: Double) -> Double {
    guard tau > 0, dt > 0 else { return 1 }
    return 1 - exp(-dt / tau)
}

/// Double → Int64 that never traps: NaN → 0, out-of-range and infinite values clamp to ±9e18.
@inline(__always)
func safeInt64(_ x: Double) -> Int64 {
    if x.isNaN { return 0 }
    if x >= 9.0e18 { return 9_000_000_000_000_000_000 }
    if x <= -9.0e18 { return -9_000_000_000_000_000_000 }
    return Int64(x)
}

/// Exponential moving average with a fixed time constant.
struct EMA {
    var value: Double
    var initialized = false
    init(_ initial: Double = 0) { value = initial }

    @inline(__always)
    mutating func step(_ x: Double, dt: Double, tau: Double) -> Double {
        guard x.isFinite else { return value }
        if !initialized { value = x; initialized = true; return value }
        value += onePoleAlpha(dt: dt, tau: tau) * (x - value)
        return value
    }

    mutating func reset(_ v: Double = 0) { value = v; initialized = false }
}

/// Asymmetric one-pole envelope follower (separate attack and release time constants).
struct AttackRelease {
    var value: Double = 0

    @inline(__always)
    mutating func step(_ x: Double, dt: Double, attack: Double, release: Double) -> Double {
        guard x.isFinite else { return value }
        let tau = x > value ? attack : release
        value += onePoleAlpha(dt: dt, tau: tau) * (x - value)
        return value
    }
}

/// One-euro filter (Casiez et al. 2012): smooth when slow, responsive when fast (§4.4).
struct OneEuroFilter {
    var minCutoff: Double
    var beta: Double
    var dCutoff: Double
    private var x: Double = 0
    private var dx: Double = 0
    private var initialized = false

    init(minCutoff: Double, beta: Double, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff; self.beta = beta; self.dCutoff = dCutoff
    }

    @inline(__always)
    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2 * Double.pi * max(cutoff, 1e-6))
        return 1.0 / (1.0 + tau / max(dt, 1e-6))
    }

    var value: Double { x }

    mutating func filter(_ v: Double, dt: Double) -> Double {
        guard v.isFinite else { return x }
        if !initialized { x = v; dx = 0; initialized = true; return v }
        let rawDx = (v - x) / max(dt, 1e-6)
        dx += OneEuroFilter.alpha(cutoff: dCutoff, dt: dt) * (rawDx - dx)
        let cutoff = minCutoff + beta * abs(dx)
        x += OneEuroFilter.alpha(cutoff: cutoff, dt: dt) * (v - x)
        return x
    }

    mutating func reset(_ v: Double = 0) { x = v; dx = 0; initialized = false }
}

/// Second-order IIR section, transposed direct form II, `a0 = 1`.
struct Biquad {
    let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var z1: Double = 0, z2: Double = 0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        // Recover from NaN/inf so a single bad sample can't poison the filter forever.
        guard y.isFinite else { z1 = 0; z2 = 0; return 0 }
        return y
    }

    mutating func reset() { z1 = 0; z2 = 0 }
}

/// Fixed-capacity buffer of `Double`s backed by a single allocation (no CoW, no bounds-check
/// surprises, deallocated with its owner). Indexing is unchecked: callers own the bounds.
final class DoubleBuffer {
    let count: Int
    let p: UnsafeMutablePointer<Double>

    init(_ count: Int, value: Double = 0) {
        self.count = max(1, count)
        p = .allocate(capacity: self.count)
        p.initialize(repeating: value, count: self.count)
    }

    deinit { p.deallocate() }

    func fill(_ value: Double) { p.update(repeating: value, count: count) }

    @inline(__always) subscript(i: Int) -> Double {
        get { p[i] }
        set { p[i] = newValue }
    }
}

/// Fixed-capacity buffer of `Float`s (see `DoubleBuffer`).
final class FloatBuffer {
    let count: Int
    let p: UnsafeMutablePointer<Float>

    init(_ count: Int, value: Float = 0) {
        self.count = max(1, count)
        p = .allocate(capacity: self.count)
        p.initialize(repeating: value, count: self.count)
    }

    deinit { p.deallocate() }

    func fill(_ value: Float) { p.update(repeating: value, count: count) }

    @inline(__always) subscript(i: Int) -> Float {
        get { p[i] }
        set { p[i] = newValue }
    }
}

/// Circular history of the last `capacity` values with O(1) push and indexed access
/// (`self[0]` = newest, `self[1]` = previous, …).
final class History {
    let capacity: Int
    private let buf: DoubleBuffer
    private(set) var count = 0
    private var head = -1 // index of newest

    init(capacity: Int) {
        self.capacity = Swift.max(1, capacity)
        buf = DoubleBuffer(self.capacity)
    }

    func push(_ v: Double) {
        head = (head + 1) % capacity
        buf[head] = v.isFinite ? v : 0
        if count < capacity { count += 1 }
    }

    /// `ago` = 0 is the newest value. Out-of-range requests return 0.
    @inline(__always) subscript(ago: Int) -> Double {
        guard ago >= 0, ago < count else { return 0 }
        var i = head - ago
        if i < 0 { i += capacity }
        return buf[i]
    }

    var newest: Double { self[0] }

    func reset() { count = 0; head = -1 }

    /// Copies the most recent `n` values (oldest first) into `dst` and returns how many were copied.
    @discardableResult
    func copyChronological(last n: Int, into dst: UnsafeMutablePointer<Double>) -> Int {
        let m = Swift.min(n, count)
        for k in 0..<m { dst[k] = self[m - 1 - k] }
        return m
    }

    /// Mean and population standard deviation of the most recent `n` values.
    func meanStd(last n: Int) -> (mean: Double, std: Double) {
        let m = Swift.min(n, count)
        guard m > 0 else { return (0, 0) }
        var s = 0.0
        for k in 0..<m { s += self[k] }
        let mean = s / Double(m)
        var v = 0.0
        for k in 0..<m { let d = self[k] - mean; v += d * d }
        return (mean, sqrt(v / Double(m)))
    }

    func max(last n: Int) -> Double {
        let m = Swift.min(n, count)
        guard m > 0 else { return 0 }
        var best = -Double.infinity
        for k in 0..<m { best = Swift.max(best, self[k]) }
        return best
    }
}

/// Sliding window that keeps its values sorted for an O(window) median update.
final class SlidingMedian {
    let window: Int
    private let ring: DoubleBuffer
    private let sorted: DoubleBuffer
    private var head = 0
    private(set) var count = 0

    init(window: Int) {
        self.window = max(1, window)
        ring = DoubleBuffer(self.window)
        sorted = DoubleBuffer(self.window)
    }

    func push(_ raw: Double) {
        let v = raw.isFinite ? raw : 0
        if count == window {
            // Remove the oldest value from the sorted array.
            let old = ring[head]
            var idx = lowerBound(old)
            if idx >= count { idx = count - 1 }
            var i = idx
            while i < count - 1 { sorted[i] = sorted[i + 1]; i += 1 }
            count -= 1
        }
        ring[head] = v
        head = (head + 1) % window
        // Insert keeping order.
        var i = count
        while i > 0 && sorted[i - 1] > v { sorted[i] = sorted[i - 1]; i -= 1 }
        sorted[i] = v
        count += 1
    }

    private func lowerBound(_ v: Double) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < v { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    var median: Double {
        guard count > 0 else { return 0 }
        if count % 2 == 1 { return sorted[count / 2] }
        return 0.5 * (sorted[count / 2 - 1] + sorted[count / 2])
    }

    /// Population mean and standard deviation of the window.
    var meanStd: (mean: Double, std: Double) {
        guard count > 0 else { return (0, 0) }
        var s = 0.0
        for i in 0..<count { s += sorted[i] }
        let mean = s / Double(count)
        var v = 0.0
        for i in 0..<count { let d = sorted[i] - mean; v += d * d }
        return (mean, sqrt(v / Double(count)))
    }

    func reset() { head = 0; count = 0 }
}

/// Linear interpolation into a buffer with the reference tracker's edge rule
/// (`interp` in Appendix A: 0 when the upper neighbour is out of range).
@inline(__always)
func interpLinear(_ r: UnsafePointer<Double>, count: Int, _ lag: Double) -> Double {
    guard lag.isFinite, lag >= 0 else { return 0 }
    let i = Int(lag.rounded(.down))
    let f = lag - Double(i)
    if i + 1 >= count { return 0 }
    return (1 - f) * r[i] + f * r[i + 1]
}

/// Least-squares slope of `n` evenly spaced samples (oldest first), in units per sample.
func leastSquaresSlope(_ y: UnsafePointer<Double>, count n: Int) -> Double {
    guard n >= 2 else { return 0 }
    let mx = Double(n - 1) / 2
    var my = 0.0
    for i in 0..<n { my += y[i] }
    my /= Double(n)
    var num = 0.0, den = 0.0
    for i in 0..<n {
        let dx = Double(i) - mx
        num += dx * (y[i] - my)
        den += dx * dx
    }
    return den > 0 ? num / den : 0
}
