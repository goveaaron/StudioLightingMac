import Foundation

/// One device port feeding one Prism universe.
public struct OutputBinding: Codable, Hashable, Sendable {
    /// Device key, e.g. "usb:EN055555".
    public var deviceKey: String
    /// 1-based device port (Pro Mk2 / ultraDMX Pro have two).
    public var port: Int
    /// Prism universe (1-based).
    public var universe: Int

    public init(deviceKey: String, port: Int, universe: Int) {
        self.deviceKey = deviceKey
        self.port = max(1, port)
        self.universe = max(1, universe)
    }
}

/// All output settings of this Mac (stored in UserDefaults, never in a project file).
public struct OutputConfiguration: Codable, Equatable, Sendable {
    public var bindings: [OutputBinding] = []
    /// Devices the user switched off.
    public var disabledDevices: Set<String> = []
    /// FTDI devices the user marked as Open DMX cables.
    public var openDMXDevices: Set<String> = []
    /// Pro Mk2 boxes with their second universe turned on.
    public var secondPortDevices: Set<String> = []
    /// Keep the Mac awake while DMX is being sent.
    public var keepAwake = true
    /// Also keep the display on.
    public var keepDisplayAwake = false
    public var artNet = ArtNetSettings()
    public var sacn = SACNSettings()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case bindings, disabledDevices, openDMXDevices, secondPortDevices, keepAwake, keepDisplayAwake, artNet, sacn
    }

    /// Tolerant decoding: anything missing or malformed falls back to its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bindings = (try? c.decodeIfPresent([OutputBinding].self, forKey: .bindings)) ?? []
        disabledDevices = (try? c.decodeIfPresent(Set<String>.self, forKey: .disabledDevices)) ?? []
        openDMXDevices = (try? c.decodeIfPresent(Set<String>.self, forKey: .openDMXDevices)) ?? []
        secondPortDevices = (try? c.decodeIfPresent(Set<String>.self, forKey: .secondPortDevices)) ?? []
        keepAwake = (try? c.decodeIfPresent(Bool.self, forKey: .keepAwake)) ?? true
        keepDisplayAwake = (try? c.decodeIfPresent(Bool.self, forKey: .keepDisplayAwake)) ?? false
        artNet = (try? c.decodeIfPresent(ArtNetSettings.self, forKey: .artNet)) ?? ArtNetSettings()
        sacn = (try? c.decodeIfPresent(SACNSettings.self, forKey: .sacn)) ?? SACNSettings()
    }

    /// Decodes stored JSON, falling back to defaults for anything unreadable.
    public static func decode(_ data: Data?) -> OutputConfiguration {
        guard let data, let config = try? JSONDecoder().decode(OutputConfiguration.self, from: data) else {
            return OutputConfiguration()
        }
        return config
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// Universe for each port of a device (port → universe), as bound.
    public func universes(for deviceKey: String) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for b in bindings where b.deviceKey == deviceKey { map[b.port] = b.universe }
        return map
    }

    /// Gives every port of `deviceKey` (up to `portCount`) a universe if it has none yet:
    /// the first box gets universe 1, more boxes get the next universe not used by the devices
    /// currently present (so a replacement box simply takes over).
    /// - Returns: true when bindings changed.
    @discardableResult
    public mutating func assignDefaults(deviceKey: String, portCount: Int, presentDevices: Set<String>) -> Bool {
        var changed = false
        var used = Set(bindings.filter { $0.deviceKey != deviceKey && presentDevices.contains($0.deviceKey) }.map(\.universe))
        for b in bindings where b.deviceKey == deviceKey { used.insert(b.universe) }
        for port in 1...max(1, portCount) where !bindings.contains(where: { $0.deviceKey == deviceKey && $0.port == port }) {
            var u = 1
            while used.contains(u) { u += 1 }
            bindings.append(OutputBinding(deviceKey: deviceKey, port: port, universe: u))
            used.insert(u)
            changed = true
        }
        return changed
    }

    /// Points `port` of `deviceKey` at `universe`.
    public mutating func setUniverse(_ universe: Int, deviceKey: String, port: Int) {
        bindings.removeAll { $0.deviceKey == deviceKey && $0.port == port }
        bindings.append(OutputBinding(deviceKey: deviceKey, port: port, universe: universe))
    }
}

/// Connects the engine to one port of a device: the engine calls `send` for `universe` on
/// every tick and the frame is handed to the device's slot (never blocking).
public final class RoutedOutput: DMXOutput, @unchecked Sendable {
    public let outputID: String
    public let universe: Int
    public let port: Int
    public let device: DMXDevice

    public init(device: DMXDevice, port: Int, universe: Int) {
        self.device = device
        self.port = port
        self.universe = universe
        outputID = "\(device.id)#\(port)"
    }

    public var displayName: String { device.snapshot.name }

    public var status: OutputStatus {
        let s = device.snapshot
        switch s.state {
        case .live: return .connected(detail: s.shortName)
        case .connecting: return .connecting
        case .stopped, .searching: return .disconnected
        case .busy, .unsupported, .failed: return .error(s.message)
        }
    }

    public func send(universe: Int, data: [UInt8]) {
        guard universe == self.universe else { return }
        device.submit(port: port, data: data)
    }
}

/// What the toolbar's output pill says.
public struct OutputSummary: Equatable, Sendable {
    public enum Level: String, Equatable, Sendable {
        case connected
        case simulated
        case warning
        case error
    }

    public var level: Level
    public var title: String
    public var detail: String

    public init(level: Level, title: String, detail: String) {
        self.level = level
        self.title = title
        self.detail = detail
    }

    public static let simulation = OutputSummary(
        level: .simulated, title: "Simulation",
        detail: "No DMX box connected — Prism is simulating your lights. Plug in your DMX box and it connects by itself.")
}

/// Turns device states into the one-line summary for the toolbar (pure; unit-tested).
public enum OutputHealth {
    /// - Parameters:
    ///   - devices: every enabled device.
    ///   - universes: Prism universes each device is sending (device id → universes).
    ///   - noHardware: hardware is off for this session (`--no-hardware`, tour, self-test).
    public static func summarize(_ devices: [DMXDeviceSnapshot], universes: [String: [Int]] = [:],
                                 noHardware: Bool = false) -> OutputSummary {
        if noHardware {
            return OutputSummary(level: .simulated, title: "Simulation",
                                 detail: "Hardware is off for this session — Prism is simulating your lights.")
        }
        let live = devices.filter { $0.state.isLive }
        let busy = devices.filter { $0.state == .busy }
        let unplugged = devices.filter { $0.isUnplugged }
        let failedNetwork = devices.filter { $0.kind.isNetwork && isFailed($0.state) }
        let failedUSB = devices.filter { !$0.kind.isNetwork && isFailed($0.state) && $0.hasBeenLive }

        if let b = busy.first {
            return OutputSummary(level: live.isEmpty ? .error : .warning,
                                 title: live.isEmpty ? "DMX box busy" : "\(b.shortName) busy",
                                 detail: SerialPortError.busy.message)
        }
        if let u = unplugged.first ?? failedUSB.first {
            let others = live.isEmpty ? " Your show keeps running in simulation." : ""
            return OutputSummary(level: .warning,
                                 title: live.isEmpty ? "DMX box unplugged" : "\(u.shortName) unplugged",
                                 detail: "\(u.name) was disconnected. Plug it back in — Prism reconnects by itself.\(others)")
        }
        if let n = failedNetwork.first, live.isEmpty {
            return OutputSummary(level: .warning, title: "\(n.name) blocked", detail: n.message)
        }
        if live.count == 1, let d = live.first {
            return OutputSummary(level: .connected, title: d.shortName, detail: liveDetail(d, universes: universes[d.id]))
        }
        if live.count > 1 {
            let lines = live.map { liveDetail($0, universes: universes[$0.id]) }
            return OutputSummary(level: .connected, title: "\(live.count) outputs live", detail: lines.joined(separator: "\n"))
        }
        if devices.contains(where: { $0.state == .connecting }) {
            return OutputSummary(level: .simulated, title: "Connecting…", detail: "Connecting to your DMX box…")
        }
        if let odd = devices.first(where: { $0.state == .unsupported }) {
            return OutputSummary(level: .simulated, title: "Simulation",
                                 detail: "\(odd.name) didn't answer like a DMX box, so Prism is simulating your lights. Open Hardware Test for help.")
        }
        return .simulation
    }

    private static func isFailed(_ s: DMXDeviceState) -> Bool {
        if case .failed = s { return true }
        return false
    }

    /// "Live · ENTTEC DMX USB Pro · universe 1".
    public static func liveDetail(_ d: DMXDeviceSnapshot, universes: [Int]?) -> String {
        var parts = ["Live", d.name]
        if let u = universes, !u.isEmpty { parts.append(universeList(u)) }
        if d.kind.isNetwork, let route = d.path, !route.isEmpty { parts.append(route) }
        return parts.joined(separator: " · ")
    }

    /// "universe 1", "universes 1–3", "universes 1, 3".
    public static func universeList(_ universes: [Int]) -> String {
        let u = Array(Set(universes)).sorted()
        guard let first = u.first, let last = u.last else { return "" }
        if u.count == 1 { return "universe \(first)" }
        if last - first == u.count - 1 { return "universes \(first)–\(last)" }
        return "universes " + u.map(String.init).joined(separator: ", ")
    }
}
