import Foundation

/// Device-independent facts about a `LightColor` that emitter mixing and DMX rendering need
/// every frame: the normalised linear target, CIE xy, CCT and Duv.
///
/// Computing these involves an sRGB decode, a Kelvin → xy evaluation and a Planckian search, so
/// `ColorAnalysis.of(_:)` memoises results in a small, fixed-size, lock-protected cache keyed by a
/// quantised colour (16 bits per sRGB channel, ¼ K, 1e-6 xy …). The analysis is always computed from
/// the de-quantised (canonical) colour, so a cache hit and a miss return bit-identical results.
public struct ColorAnalysis: Equatable, Sendable {
    /// Linear-light sRGB at full brightness (largest component = 1, never negative).
    public var linear: LinearRGB
    /// sRGB equivalent (the stored value for `.rgb`, `RGB(linear:)` otherwise).
    public var display: RGB
    /// CIE 1931 chromaticity.
    public var x: Double
    public var y: Double
    /// Correlated colour temperature in Kelvin (exact for `.kelvin`). 0 when `hasCCT` is false.
    public var kelvin: Double
    /// Signed CIE 1960 Duv (+ = greener than the Planckian locus). 0 when `hasCCT` is false.
    public var duv: Double
    /// Display-referred saturation: 0 = neutral … 1 = on the sRGB gamut boundary.
    public var saturation: Double
    /// True for black / zero colours (no chromaticity).
    public var isBlack: Bool
    /// Whether `kelvin` / `duv` were computed.
    public var hasCCT: Bool

    /// Analysis of `color`, memoised. Pass `includeCCT: false` to skip the Planckian search when
    /// the caller has no CCT/tint channels (cheaper on a cache miss).
    public static func of(_ color: LightColor, includeCCT: Bool = true) -> ColorAnalysis {
        guard let q = quantize(color) else { return compute(color, includeCCT: includeCCT) }
        let cache = ColorAnalysisCache.shared
        if let hit = cache.lookup(q.key, needCCT: includeCCT) { return hit }
        let value = compute(q.canonical, includeCCT: includeCCT)
        cache.store(q.key, value)
        return value
    }

    /// Uncached analysis of exactly `color`.
    static func compute(_ color: LightColor, includeCCT: Bool) -> ColorAnalysis {
        var lin: LinearRGB
        let display: RGB
        let xy: (x: Double, y: Double)
        var kelvin = 0.0, duv = 0.0, hasCCT = false
        switch color {
        case .rgb(let c):
            lin = c.linear.normalized
            display = c
            xy = ColorMath.linearSRGBToXY(lin)
        case .kelvin(let k, let t):
            xy = ColorMath.kelvinToXY(k, tint: t)
            lin = ColorMath.xyToLinearSRGB(x: xy.x, y: xy.y).normalized
            display = RGB(linear: lin)
            kelvin = clamp(k.finiteOr(5600), 1000, 25000)
            duv = ColorMath.tintToDuv(t)
            hasCCT = true
        case .hsi:
            lin = color.linearRGB
            display = RGB(linear: lin)
            xy = ColorMath.linearSRGBToXY(lin)
        case .xy(let x, let y):
            xy = (x.finiteOr(ColorMath.d65XY.x), y.finiteOr(ColorMath.d65XY.y))
            lin = ColorMath.xyToLinearSRGB(x: xy.x, y: xy.y).normalized
            display = RGB(linear: lin)
        }
        lin = lin.clampedNonNegative
        let peak = lin.maxComponent
        let isBlack = !(peak > 1e-9)
        if includeCCT && !hasCCT {
            (kelvin, duv) = ColorMath.xyToKelvinAndDuv(x: xy.x, y: xy.y)
            hasCCT = true
        }
        let saturation = isBlack ? 0 : clamp01(1 - ColorMath.linearToSRGB(clamp01(lin.minComponent / peak)))
        return ColorAnalysis(
            linear: lin, display: display, x: xy.x, y: xy.y,
            kelvin: kelvin, duv: duv, saturation: saturation, isBlack: isBlack, hasCCT: hasCCT
        )
    }

    /// Cache key and canonical (de-quantised) colour, or nil for colours that can't be keyed.
    static func quantize(_ color: LightColor) -> (key: UInt64, canonical: LightColor)? {
        switch color {
        case .rgb(let c):
            // `srgbToLinear` clamps to 0…1 anyway, so clamping here doesn't change the analysis.
            let r = UInt64((clamp01(c.r) * 65535).rounded())
            let g = UInt64((clamp01(c.g) * 65535).rounded())
            let b = UInt64((clamp01(c.b) * 65535).rounded())
            let key = (UInt64(1) << 60) | (r << 32) | (g << 16) | b
            return (key, .rgb(RGB(r: Double(r) / 65535, g: Double(g) / 65535, b: Double(b) / 65535)))
        case .kelvin(let k, let t):
            guard k.isFinite, t.isFinite else { return nil }
            let kq = UInt64((clamp(k, 1000, 30000) * 4).rounded())
            let tq = Int64((clamp(t, -1, 1) * 32767).rounded()) + 32767
            let key = (UInt64(2) << 60) | (kq << 16) | UInt64(tq)
            return (key, .kelvin(Double(kq) / 4, tint: Double(tq - 32767) / 32767))
        case .hsi(let h, let s):
            guard h.isFinite, s.isFinite else { return nil }
            let hq = UInt64((wrapDegrees(h) * 100).rounded()) % 36000
            let sq = UInt64((clamp01(s) * 65535).rounded())
            let key = (UInt64(3) << 60) | (hq << 16) | sq
            return (key, .hsi(hue: Double(hq) / 100, saturation: Double(sq) / 65535))
        case .xy(let x, let y):
            guard x.isFinite, y.isFinite, x >= 0, x <= 1, y > 0, y <= 1 else { return nil }
            let xq = UInt64((x * 1_000_000).rounded())
            let yq = UInt64((y * 1_000_000).rounded())
            let key = (UInt64(4) << 60) | (xq << 20) | yq
            return (key, .xy(x: Double(xq) / 1_000_000, y: Double(yq) / 1_000_000))
        }
    }

    static let placeholder = ColorAnalysis(
        linear: .black, display: .black, x: ColorMath.d65XY.x, y: ColorMath.d65XY.y,
        kelvin: 0, duv: 0, saturation: 0, isBlack: true, hasCCT: false
    )
}

/// Fixed-size, direct-mapped, lock-protected memo for `ColorAnalysis`.
/// Storage is allocated once; lookups and stores never allocate.
final class ColorAnalysisCache: @unchecked Sendable {
    static let shared = ColorAnalysisCache()

    private static let slotBits = 12
    private let capacity = 1 << ColorAnalysisCache.slotBits
    private let lock = NSLock()
    private let keys: UnsafeMutablePointer<UInt64>
    private let values: UnsafeMutablePointer<ColorAnalysis>
    private var hitCount: UInt64 = 0
    private var missCount: UInt64 = 0

    init() {
        keys = .allocate(capacity: capacity)
        keys.initialize(repeating: 0, count: capacity)
        values = .allocate(capacity: capacity)
        values.initialize(repeating: ColorAnalysis.placeholder, count: capacity)
    }

    deinit {
        keys.deinitialize(count: capacity)
        keys.deallocate()
        values.deinitialize(count: capacity)
        values.deallocate()
    }

    @inline(__always)
    private func slot(_ key: UInt64) -> Int {
        Int(truncatingIfNeeded: (key &* 0x9E37_79B9_7F4A_7C15) >> UInt64(64 - ColorAnalysisCache.slotBits))
    }

    func lookup(_ key: UInt64, needCCT: Bool) -> ColorAnalysis? {
        let i = slot(key)
        lock.lock()
        defer { lock.unlock() }
        if keys[i] == key {
            let v = values[i]
            if !needCCT || v.hasCCT {
                hitCount &+= 1
                return v
            }
        }
        missCount &+= 1
        return nil
    }

    func store(_ key: UInt64, _ value: ColorAnalysis) {
        let i = slot(key)
        lock.lock()
        keys[i] = key
        values[i] = value
        lock.unlock()
    }

    /// Hit/miss counters (diagnostics and tests).
    var stats: (hits: UInt64, misses: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (hitCount, missCount)
    }

    func removeAll() {
        lock.lock()
        keys.update(repeating: 0, count: capacity)
        hitCount = 0
        missCount = 0
        lock.unlock()
    }
}
