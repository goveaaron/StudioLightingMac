import Foundation

/// What kind of output a device is.
public enum DMXDeviceKind: String, Codable, Sendable, CaseIterable {
    /// ENTTEC DMX USB Pro / Pro Mk2 and compatible widgets (DMXking ultraDMX …).
    case enttecPro
    /// FTDI-based Open DMX cables (no microcontroller; the Mac generates the DMX signal).
    case openDMX
    case artNet
    case sACN
    /// A stand-in used by the screenshot tour and self-test.
    case simulated

    public var title: String {
        switch self {
        case .enttecPro: return "USB DMX"
        case .openDMX: return "Open DMX"
        case .artNet: return "Art-Net"
        case .sACN: return "sACN"
        case .simulated: return "Simulated"
        }
    }

    public var isNetwork: Bool { self == .artNet || self == .sACN }
}

/// Where a device is in its life cycle. Unplugged, busy and asleep are normal states.
public enum DMXDeviceState: Equatable, Sendable {
    case stopped
    /// Waiting for the device to appear (not plugged in, or unplugged).
    case searching
    /// Opening and identifying.
    case connecting
    /// Sending DMX.
    case live
    /// Another app holds the device.
    case busy
    /// Opened, but it didn't answer like a DMX interface.
    case unsupported
    /// Something else went wrong (plain-English message).
    case failed(String)

    public var isLive: Bool { self == .live }

    /// One or two words for status badges.
    public var title: String {
        switch self {
        case .stopped: return "Off"
        case .searching: return "Not connected"
        case .connecting: return "Connecting…"
        case .live: return "Live"
        case .busy: return "In use by another app"
        case .unsupported: return "Not recognized"
        case .failed: return "Problem"
        }
    }

    /// A sentence explaining the state and what to do about it.
    public func message(deviceName: String, hasBeenLive: Bool) -> String {
        switch self {
        case .stopped:
            return "\(deviceName) is turned off in Prism."
        case .searching:
            return hasBeenLive
                ? "\(deviceName) was unplugged. Plug it back in — Prism reconnects by itself and your show keeps running."
                : "Looking for \(deviceName)…"
        case .connecting:
            return "Connecting to \(deviceName)…"
        case .live:
            return "\(deviceName) is sending your lights."
        case .busy:
            return SerialPortError.busy.message
        case .unsupported:
            return "This USB device didn't answer like a DMX USB Pro. If it's an Open DMX cable, turn on “Open DMX” for it in Settings › Outputs."
        case .failed(let text):
            return text
        }
    }
}

/// Live counters for one device. Updated by the device's I/O thread.
public struct DMXDeviceStats: Equatable, Sendable {
    /// Frames written to the device.
    public var framesSent: UInt64 = 0
    /// Frames the device couldn't take in time (dropped instead of waiting).
    public var framesDropped: UInt64 = 0
    /// Frames replaced by a newer one before they were sent (normal under load).
    public var framesCoalesced: UInt64 = 0
    public var writeErrors: UInt64 = 0
    public var reconnects: UInt64 = 0
    /// Writes per second over the last second.
    public var updatesPerSecond: Double = 0
    /// Time from the engine handing over a frame to the write completing, in milliseconds.
    public var lastLatencyMs: Double = 0
    public var averageLatencyMs: Double = 0
    /// `PrismClock` time of the last successful write (0 = never).
    public var lastSendTime: Double = 0

    public init() {}
}

/// Everything the UI shows about one output device. A value copy; cheap to pass around.
public struct DMXDeviceSnapshot: Equatable, Sendable, Identifiable {
    /// Stable key, e.g. "enttec:EN012345", "usb:A6XYZ", "artnet", "sacn".
    public var id: String
    public var kind: DMXDeviceKind
    /// Full product name, e.g. "ENTTEC DMX USB Pro".
    public var name: String
    /// Compact name for the toolbar, e.g. "DMX USB Pro".
    public var shortName: String
    public var state: DMXDeviceState
    public var serialNumber: String?
    public var firmware: String?
    /// Device node or network destination.
    public var path: String?
    /// Output timing as the device reports it (Pro widgets), e.g. "Break 96 µs · MAB 11 µs · 40 fps".
    public var timing: String?
    public var portCount: Int
    /// A non-fatal heads-up (e.g. the box is set to a slow refresh rate).
    public var warning: String?
    public var lastError: String?
    /// True once the device has been live at least once (so "searching" means "unplugged").
    public var hasBeenLive: Bool
    public var stats: DMXDeviceStats

    public init(id: String, kind: DMXDeviceKind, name: String, shortName: String? = nil,
                state: DMXDeviceState = .stopped, serialNumber: String? = nil, firmware: String? = nil,
                path: String? = nil, timing: String? = nil, portCount: Int = 1, warning: String? = nil,
                lastError: String? = nil, hasBeenLive: Bool = false, stats: DMXDeviceStats = DMXDeviceStats()) {
        self.id = id
        self.kind = kind
        self.name = name
        self.shortName = shortName ?? name
        self.state = state
        self.serialNumber = serialNumber
        self.firmware = firmware
        self.path = path
        self.timing = timing
        self.portCount = max(1, portCount)
        self.warning = warning
        self.lastError = lastError
        self.hasBeenLive = hasBeenLive
        self.stats = stats
    }

    /// "Unplugged" = was live earlier and is now looking for the device again.
    public var isUnplugged: Bool { hasBeenLive && state == .searching }

    /// The state's sentence for this device.
    public var message: String { state.message(deviceName: name, hasBeenLive: hasBeenLive) }

    /// The same snapshot without counters — used to decide whether the UI needs an update.
    public var withoutStats: DMXDeviceSnapshot {
        var copy = self
        copy.stats = DMXDeviceStats()
        return copy
    }
}

/// A physical or network DMX output managed by `OutputManager`.
///
/// Devices own their I/O on a private thread. `submit` is called from the engine tick and
/// must never block; everything else is called from the main thread and returns quickly
/// (`stop` waits at most `flushTimeout` plus a few milliseconds).
public protocol DMXDevice: AnyObject, Sendable {
    var id: String { get }
    var kind: DMXDeviceKind { get }
    /// Current state, identity and counters.
    var snapshot: DMXDeviceSnapshot { get }
    /// Hands the newest 512-slot frame for `port` (1-based; network devices use the Prism
    /// universe) to the device. Never blocks; an unsent older frame is replaced.
    func submit(port: Int, data: [UInt8])
    /// Starts connecting (and reconnecting forever, with backoff) on the device's own thread.
    func start()
    /// Sends the pending frame if possible within `flushTimeout`, then closes the device.
    func stop(flushTimeout: Double)
    /// Skip the backoff and try to (re)connect now (hot-plug arrival, wake from sleep).
    func reconnectNow()
    /// The system reported the device was removed: drop the connection immediately.
    func markRemoved()
    /// Called on the device's thread whenever state or identity changes (not for counters).
    func setChangeHandler(_ handler: (@Sendable (DMXDeviceSnapshot) -> Void)?)
}

/// Hands the newest frame per port from the engine to a device's I/O thread — never queues.
///
/// `submit` stores the frame and wakes the I/O thread only when the data changed (or the
/// device needs a resend), so a static look costs nothing between keep-alives.
public final class DMXFrameSlot: @unchecked Sendable {
    public struct Frame: Equatable, Sendable {
        public var data: [UInt8]
        /// `PrismClock` time the frame was handed over (for latency).
        public var submittedAt: Double
    }

    private let lock = PrismLock()
    private var pending: [Int: Frame] = [:]
    private var latest: [Int: [UInt8]] = [:]
    private var wakeEnabled = false
    private var coalesced: UInt64 = 0
    private let wake: WakeSignal?

    init(wake: WakeSignal?) {
        self.wake = wake
    }

    /// Stores `data` as the newest frame for `port`. Called from the engine tick.
    public func submit(port: Int, data: [UInt8], at time: Double = PrismClock.now()) {
        let shouldWake: Bool = lock.withLock {
            if let last = latest[port], last == data, pending[port] == nil { return false }
            if pending[port] != nil { coalesced &+= 1 }
            pending[port] = Frame(data: data, submittedAt: time)
            latest[port] = data
            return wakeEnabled
        }
        if shouldWake { wake?.signal() }
    }

    /// Takes the unsent frame for `port`, if any.
    func take(port: Int) -> Frame? {
        lock.withLock { pending.removeValue(forKey: port) }
    }

    /// Puts a frame back after a dropped write, unless a newer one arrived meanwhile.
    func restore(port: Int, frame: Frame) {
        lock.withLock {
            if pending[port] == nil { pending[port] = frame }
        }
    }

    /// The last frame ever submitted for `port` (for keep-alives).
    func latestFrame(port: Int) -> [UInt8]? {
        lock.withLock { latest[port] }
    }

    /// Ports that have ever received a frame.
    var knownPorts: [Int] {
        lock.withLock { Array(latest.keys).sorted() }
    }

    /// Marks the latest frame of every port as unsent — after a (re)connect the device gets
    /// the current look immediately, without waiting for the engine to change something.
    func markAllDirty(at time: Double = PrismClock.now()) {
        lock.withLock {
            for (port, data) in latest where pending[port] == nil {
                pending[port] = Frame(data: data, submittedAt: time)
            }
        }
    }

    /// Only a live device wants to be woken for frames.
    func setWakeEnabled(_ enabled: Bool) {
        lock.withLock { wakeEnabled = enabled }
    }

    var coalescedCount: UInt64 { lock.withLock { coalesced } }

    var hasPending: Bool { lock.withLock { !pending.isEmpty } }
}

/// Shared plumbing for devices that run their own I/O thread: state & snapshot publishing,
/// control flags, wake-ups, bounded stop and counters.
final class DeviceRuntime: @unchecked Sendable {
    let wake: WakeSignal?
    let slot: DMXFrameSlot

    private let lock = PrismLock()
    private var current: DMXDeviceSnapshot
    private var handler: (@Sendable (DMXDeviceSnapshot) -> Void)?
    private var stopRequested = false
    private var reconnectRequested = false
    private var removedFlag = false
    private var refreshFixRequested = false
    private var flushBudget = 0.1
    private var started = false
    private var finished = false
    private let done = DispatchSemaphore(value: 0)
    // Rate window for updatesPerSecond.
    private var windowStart = 0.0
    private var windowCount = 0

    init(snapshot: DMXDeviceSnapshot) {
        let signal = WakeSignal()
        wake = signal
        slot = DMXFrameSlot(wake: signal)
        current = snapshot
    }

    var wakeFD: Int32 { wake?.readFD ?? -1 }

    // MARK: Lifecycle

    /// Runs `body` on a new thread exactly once.
    func start(name: String, body: @escaping @Sendable () -> Void) {
        let shouldStart: Bool = lock.withLock {
            guard !started, !stopRequested else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        let thread = Thread { [self] in
            body()
            self.lock.withLock { self.finished = true }
            self.done.signal()
        }
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Requests a stop and waits (bounded) for the I/O thread to flush and close.
    func stop(flushTimeout: Double) {
        let wasStarted: Bool = lock.withLock {
            stopRequested = true
            flushBudget = max(0, min(flushTimeout, 1))
            return started && !finished
        }
        wake?.signal()
        if wasStarted {
            _ = done.wait(timeout: .now() + max(0, min(flushTimeout, 1)) + 0.05)
        } else {
            update { $0.state = .stopped }
        }
    }

    var isStopping: Bool { lock.withLock { stopRequested } }
    var flushTimeout: Double { lock.withLock { flushBudget } }

    func requestReconnect() {
        lock.withLock { reconnectRequested = true }
        wake?.signal()
    }

    func markRemoved() {
        lock.withLock { removedFlag = true; reconnectRequested = true }
        wake?.signal()
    }

    func requestRefreshFix() {
        lock.withLock { refreshFixRequested = true }
        wake?.signal()
    }

    /// Returns and clears the "reconnect now" hint.
    func consumeReconnect() -> Bool {
        lock.withLock {
            let r = reconnectRequested
            reconnectRequested = false
            return r
        }
    }

    /// Returns and clears the "device removed" hint.
    func consumeRemoved() -> Bool {
        lock.withLock {
            let r = removedFlag
            removedFlag = false
            return r
        }
    }

    func consumeRefreshFix() -> Bool {
        lock.withLock {
            let r = refreshFixRequested
            refreshFixRequested = false
            return r
        }
    }

    /// Sleeps up to `seconds`, returning early on stop or a reconnect hint (frames don't wake it).
    func pause(_ seconds: Double) {
        let deadline = PrismClock.now() + seconds
        while !isStopping {
            let peekReconnect = lock.withLock { reconnectRequested }
            if peekReconnect { return }
            let remaining = deadline - PrismClock.now()
            if remaining <= 0 { return }
            let r = IOWait.wait(fd: -1, read: false, write: false, wakeFD: wakeFD, timeout: min(remaining, 0.5))
            if r.woken { wake?.drain() }
        }
    }

    // MARK: Snapshot

    var snapshot: DMXDeviceSnapshot {
        lock.withLock {
            var s = current
            s.stats.framesCoalesced = slot.coalescedCount
            if s.stats.lastSendTime > 0, PrismClock.now() - s.stats.lastSendTime > 2 {
                s.stats.updatesPerSecond = 0
            }
            return s
        }
    }

    func setChangeHandler(_ h: (@Sendable (DMXDeviceSnapshot) -> Void)?) {
        lock.withLock { handler = h }
    }

    /// Mutates the snapshot; notifies the change handler when anything but counters changed.
    func update(_ body: (inout DMXDeviceSnapshot) -> Void) {
        let notify: (DMXDeviceSnapshot, (@Sendable (DMXDeviceSnapshot) -> Void))? = lock.withLock {
            let before = current.withoutStats
            body(&current)
            if current.state == .live { current.hasBeenLive = true }
            guard current.withoutStats != before, let h = handler else { return nil }
            return (current, h)
        }
        if let (s, h) = notify { h(s) }
    }

    func setState(_ state: DMXDeviceState, error: String? = nil) {
        update {
            $0.state = state
            if let error { $0.lastError = error }
        }
    }

    /// Shows "Connecting…" before opening `path` — except while retrying a box that was busy,
    /// unrecognized or failing: that state stays up, so the status doesn't flicker every retry.
    func beginConnecting(path: String) {
        update { s in
            switch s.state {
            case .busy, .unsupported, .failed: break
            default: s.state = .connecting
            }
            s.path = path
        }
    }

    // MARK: Counters

    /// Counts a completed write. `latency` is nil for keep-alive resends.
    func recordSent(latency: Double?, now: Double) {
        lock.withLock {
            var st = current.stats
            st.framesSent &+= 1
            if let latency {
                let ms = max(0, latency * 1000)
                st.lastLatencyMs = ms
                st.averageLatencyMs = st.averageLatencyMs == 0 ? ms : st.averageLatencyMs * 0.9 + ms * 0.1
            }
            st.lastSendTime = now
            if windowStart == 0 { windowStart = now }
            windowCount += 1
            let span = now - windowStart
            if span >= 1 {
                st.updatesPerSecond = Double(windowCount) / span
                windowStart = now
                windowCount = 0
            }
            current.stats = st
        }
    }

    func recordDropped() {
        lock.withLock { current.stats.framesDropped &+= 1 }
    }

    func recordWriteError() {
        lock.withLock { current.stats.writeErrors &+= 1 }
    }

    func recordReconnect() {
        lock.withLock { current.stats.reconnects &+= 1 }
    }
}
