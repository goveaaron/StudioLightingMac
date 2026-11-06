import Foundation

/// A tiny, fast mutual-exclusion lock usable from any thread.
///
/// Prism's real-time engine thread and the UI/main thread hand data to each other
/// through values protected by this lock. Keep critical sections short
/// (copying a value in or out), never call out to unknown code while holding it.
public final class PrismLock: @unchecked Sendable {
    private let lock = NSLock()

    public init() {}

    @inline(__always)
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// A value protected by a lock. Reads return a copy; writes replace or mutate in place.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = PrismLock()
    private var _value: Value

    public init(_ value: Value) { _value = value }

    public var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

    @discardableResult
    public func mutate<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        try lock.withLock { try body(&_value) }
    }
}

/// Monotonic clock used by the engine, fades and effects (seconds since boot).
/// All times stored in `LiveState` (fade start times etc.) use this clock.
public enum PrismClock {
    @inline(__always)
    public static func now() -> Double {
        ProcessInfo.processInfo.systemUptime
    }
}
