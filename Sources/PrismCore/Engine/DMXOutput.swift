import Foundation

/// Connection state of an output device, for the status pill in the toolbar.
public enum OutputStatus: Hashable, Sendable {
    case disconnected
    case connecting
    case connected(detail: String)
    case error(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected(let d): return d.isEmpty ? "Connected" : d
        case .error(let e): return e
        }
    }
}

/// Anything that can transmit DMX universes: Enttec DMX USB Pro, Art-Net node, sACN, a
/// virtual device for tests, etc.
///
/// `send` is called on the engine's real-time queue at the frame rate. Implementations MUST
/// NOT block (no synchronous network or disk I/O, no waiting on locks held by the UI). If the
/// device is busy, drop the frame — the next one follows in ~25 ms.
public protocol DMXOutput: AnyObject, Sendable {
    /// Stable identifier (e.g. "enttec:EN123456", "artnet:192.168.1.50:0").
    var outputID: String { get }
    var displayName: String { get }
    /// Which Prism universe (1-based) this output transmits.
    var universe: Int { get }
    var status: OutputStatus { get }
    /// Transmit one universe frame (512 bytes, index 0 = DMX address 1).
    func send(universe: Int, data: [UInt8])
}

/// A DMX output that just remembers the last frame. Used by tests, the dev server and the
/// "no device connected" state so the rest of the app behaves identically.
public final class VirtualDMXOutput: DMXOutput, @unchecked Sendable {
    public let outputID: String
    public let displayName: String
    public let universe: Int
    private let frame = Locked<[UInt8]>(Array(repeating: 0, count: 512))
    private let counter = Locked<UInt64>(0)

    public init(id: String = "virtual", name: String = "Virtual Output", universe: Int = 1) {
        self.outputID = id
        self.displayName = name
        self.universe = universe
    }

    public var status: OutputStatus { .connected(detail: "Virtual") }

    public func send(universe: Int, data: [UInt8]) {
        guard universe == self.universe else { return }
        frame.value = data
        counter.mutate { $0 &+= 1 }
    }

    public var lastFrame: [UInt8] { frame.value }
    public var framesSent: UInt64 { counter.value }
}
