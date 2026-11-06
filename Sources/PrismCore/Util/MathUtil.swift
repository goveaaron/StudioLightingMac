import Foundation

@inline(__always)
public func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
    min(max(value, lower), upper)
}

@inline(__always)
public func clamp01(_ value: Double) -> Double {
    if value.isNaN { return 0 }
    return min(max(value, 0), 1)
}

@inline(__always)
public func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a + (b - a) * t
}

@inline(__always)
public func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    guard edge1 != edge0 else { return x < edge0 ? 0 : 1 }
    let t = clamp01((x - edge0) / (edge1 - edge0))
    return t * t * (3 - 2 * t)
}

/// Wraps an angle in degrees into 0..<360.
@inline(__always)
public func wrapDegrees(_ degrees: Double) -> Double {
    guard degrees.isFinite else { return 0 }
    let r = degrees.truncatingRemainder(dividingBy: 360)
    return r < 0 ? r + 360 : r
}

/// Interpolates between two hues (degrees) along the shortest arc.
@inline(__always)
public func lerpHue(_ a: Double, _ b: Double, _ t: Double) -> Double {
    var delta = wrapDegrees(b) - wrapDegrees(a)
    if delta > 180 { delta -= 360 }
    if delta < -180 { delta += 360 }
    return wrapDegrees(a + delta * t)
}

extension Double {
    /// Returns `fallback` when the value is NaN or infinite. Use on every value that crosses
    /// a trust boundary (files, network, user input) before it reaches the engine.
    @inline(__always)
    public func finiteOr(_ fallback: Double) -> Double {
        isFinite ? self : fallback
    }
}
