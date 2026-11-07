import Foundation
#if canImport(os)
import os
#elseif canImport(Glibc)
import Glibc
#endif

/// Minimal mutex with a non-blocking `tryLock()`, safe to *try* from a real-time audio thread
/// (`os_unfair_lock` on Apple platforms, `pthread_mutex` elsewhere). No allocation after init.
public final class TryLock: @unchecked Sendable {
    #if canImport(os)
    private let p: UnsafeMutablePointer<os_unfair_lock>
    public init() {
        p = .allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
    }
    deinit { p.deinitialize(count: 1); p.deallocate() }
    @inline(__always) public func tryLock() -> Bool { os_unfair_lock_trylock(p) }
    @inline(__always) public func lock() { os_unfair_lock_lock(p) }
    @inline(__always) public func unlock() { os_unfair_lock_unlock(p) }
    #else
    private let p: UnsafeMutablePointer<pthread_mutex_t>
    public init() {
        p = .allocate(capacity: 1)
        p.initialize(to: pthread_mutex_t())
        pthread_mutex_init(p, nil)
    }
    deinit { pthread_mutex_destroy(p); p.deinitialize(count: 1); p.deallocate() }
    @inline(__always) public func tryLock() -> Bool { pthread_mutex_trylock(p) == 0 }
    @inline(__always) public func lock() { pthread_mutex_lock(p) }
    @inline(__always) public func unlock() { pthread_mutex_unlock(p) }
    #endif
}

/// Single-producer / single-consumer ring of mono `Float` samples for real-time capture.
///
/// * The **producer** (an audio IOProc / tap callback) never blocks and never allocates: it copies
///   samples into preallocated storage and *publishes* the new write position with `tryLock()`.
///   If the consumer happens to hold the lock for those few nanoseconds, publication simply
///   happens on the next callback (no data is lost).
/// * The **consumer** (the analysis thread) takes the lock only to read/write two integers.
/// * When the consumer falls behind, the producer drops the *newest* samples (counted in
///   `droppedSamples`) instead of overwriting data that may be being read.
public final class AudioRingBuffer: @unchecked Sendable {
    /// Capacity in samples (a power of two).
    public let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let lock = TryLock()

    // Producer-private state.
    private var writeIndex = 0
    private var knownRead = 0
    private var producerDropped = 0
    private var anchorIndex = 0
    private var anchorTime = 0.0

    // Shared state (guarded by `lock`).
    private var publishedWrite = 0
    private var publishedAnchorIndex = 0
    private var publishedAnchorTime = 0.0
    private var publishedDropped = 0
    private var consumedRead = 0

    // Consumer-private state.
    private var readIndex = 0

    /// - Parameter minimumCapacity: rounded up to a power of two (default ≈ 2.7 s at 48 kHz).
    public init(minimumCapacity: Int = 131_072) {
        var c = 1024
        while c < minimumCapacity && c < (1 << 24) { c <<= 1 }
        capacity = c
        mask = c - 1
        storage = .allocate(capacity: c)
        storage.initialize(repeating: 0, count: c)
    }

    deinit { storage.deallocate() }

    // MARK: Producer (real-time safe)

    /// Writes `count` samples. `fill(destination, sourceOffset, chunkCount)` is called once or
    /// twice (around the wrap point) to produce samples `[sourceOffset, sourceOffset + chunkCount)`
    /// directly into ring storage — e.g. while mixing interleaved channels down to mono.
    /// `hostTime` is the capture time (seconds, caller's clock) of the first sample.
    /// Never blocks; the closure must not allocate or lock.
    @inline(__always)
    public func write(count: Int, hostTime: Double,
                      _ fill: (_ destination: UnsafeMutablePointer<Float>, _ sourceOffset: Int, _ count: Int) -> Void) {
        guard count > 0 else { return }
        let free = capacity - (writeIndex - knownRead)
        let n = min(count, max(0, free))
        if n < count { producerDropped &+= count - n }
        var done = 0
        while done < n {
            let pos = (writeIndex + done) & mask
            let chunk = min(n - done, capacity - pos)
            fill(storage + pos, done, chunk)
            done += chunk
        }
        if n > 0 {
            anchorIndex = writeIndex
            anchorTime = hostTime
            writeIndex += n
        }
        publish()
    }

    /// Convenience: writes contiguous mono samples.
    @inline(__always)
    public func write(_ samples: UnsafePointer<Float>, count: Int, hostTime: Double) {
        write(count: count, hostTime: hostTime) { dst, offset, n in
            dst.update(from: samples + offset, count: n)
        }
    }

    @inline(__always)
    private func publish() {
        guard lock.tryLock() else { return }
        publishedWrite = writeIndex
        publishedAnchorIndex = anchorIndex
        publishedAnchorTime = anchorTime
        publishedDropped = producerDropped
        knownRead = consumedRead
        lock.unlock()
    }

    // MARK: Consumer

    /// Result of a `read`.
    public struct ReadResult: Sendable, Equatable {
        /// Samples copied into the destination.
        public var count: Int
        /// Absolute index (since `reset`) of the first copied sample.
        public var firstIndex: Int
        /// The most recent (sample index, host time) pair published by the producer.
        public var anchorIndex: Int
        public var anchorTime: Double
        /// Total samples dropped by the producer because the consumer was too slow.
        public var droppedSamples: Int
    }

    /// Copies up to `maxCount` unread samples into `destination`.
    public func read(into destination: UnsafeMutablePointer<Float>, maxCount: Int) -> ReadResult {
        lock.lock()
        let w = publishedWrite
        let aIdx = publishedAnchorIndex
        let aTime = publishedAnchorTime
        let dropped = publishedDropped
        lock.unlock()

        let first = readIndex
        let n = max(0, min(w - readIndex, maxCount))
        var done = 0
        while done < n {
            let pos = (readIndex + done) & mask
            let chunk = min(n - done, capacity - pos)
            destination.advanced(by: done).update(from: storage + pos, count: chunk)
            done += chunk
        }
        readIndex += n
        if n > 0 {
            lock.lock()
            consumedRead = readIndex
            lock.unlock()
        }
        return ReadResult(count: n, firstIndex: first, anchorIndex: aIdx, anchorTime: aTime, droppedSamples: dropped)
    }

    /// Unread samples currently published.
    public var availableToRead: Int {
        lock.lock()
        let w = publishedWrite
        lock.unlock()
        return max(0, w - readIndex)
    }
}

/// Streaming linear-interpolation resampler (analysis quality, not playback quality).
/// Converts any capture rate to the analyzer's 48 kHz without allocating.
public struct LinearResampler: Sendable {
    public let inputRate: Double
    public let outputRate: Double
    private let step: Double
    private var position = 0.0   // fractional read position relative to `previous`
    private var previous: Float = 0
    private var primed = false

    public init(inputRate: Double, outputRate: Double = 48_000) {
        let i = inputRate.isFinite && inputRate > 1000 ? inputRate : outputRate
        self.inputRate = i
        self.outputRate = outputRate
        step = i / outputRate
    }

    /// True when no conversion is needed.
    public var isPassthrough: Bool { abs(inputRate - outputRate) < 0.5 }

    /// Upper bound on outputs produced for `inputCount` inputs.
    public func maxOutputCount(forInput inputCount: Int) -> Int {
        Int((Double(inputCount) / step).rounded(.up)) + 2
    }

    /// Resamples `count` inputs into `output` (capacity ≥ `maxOutputCount`) and returns the
    /// number of samples written.
    public mutating func process(_ input: UnsafePointer<Float>, count: Int, into output: UnsafeMutablePointer<Float>) -> Int {
        guard count > 0 else { return 0 }
        if isPassthrough {
            output.update(from: input, count: count)
            return count
        }
        var produced = 0
        var i = 0
        if !primed { previous = input[0]; primed = true; i = 1; position = 0 }
        // `position` is measured in input samples after `previous` (0 ≤ position < 1 once caught up).
        while i < count {
            let next = input[i]
            while position < 1 {
                let f = Float(position)
                output[produced] = previous + (next - previous) * f
                produced += 1
                position += step
            }
            position -= 1
            previous = next
            i += 1
        }
        return produced
    }
}
