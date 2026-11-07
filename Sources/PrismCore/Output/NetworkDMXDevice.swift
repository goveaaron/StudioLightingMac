import Foundation

/// Art-Net output settings (machine settings — stored with the app, never in a project).
public struct ArtNetSettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// Unicast to nodes found by ArtPoll that output the universe; broadcast otherwise.
        case automatic
        case broadcast
        case unicast

        public var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .broadcast: return "Broadcast"
            case .unicast: return "One address"
            }
        }
    }

    public var enabled = false
    public var mode: Mode = .automatic
    /// Destination for `.unicast`, e.g. "2.0.0.10".
    public var unicastAddress = ""
    /// Network interface to use (nil = every suitable interface).
    public var interfaceName: String?
    /// Prism universe 1 → Port-Address 0 + offset.
    public var universeOffset = 0

    public init() {}

    private enum CodingKeys: String, CodingKey { case enabled, mode, unicastAddress, interfaceName, universeOffset }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? .automatic
        unicastAddress = (try? c.decodeIfPresent(String.self, forKey: .unicastAddress)) ?? ""
        interfaceName = (try? c.decodeIfPresent(String.self, forKey: .interfaceName)) ?? nil
        universeOffset = clamp((try? c.decodeIfPresent(Int.self, forKey: .universeOffset)) ?? 0, 0, 32767)
    }
}

/// sACN (E1.31) output settings (machine settings).
public struct SACNSettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case multicast
        case unicast

        public var title: String { self == .multicast ? "Multicast" : "One address" }
    }

    public var enabled = false
    public var mode: Mode = .multicast
    public var unicastAddress = ""
    public var interfaceName: String?
    /// Prism universe 1 → sACN universe 1 + offset.
    public var universeOffset = 0
    /// 0…200; receivers take the highest-priority source.
    public var priority = Int(SACN.defaultPriority)
    public var sourceName = "Prism"
    /// This Mac's sACN component ID (created once, kept forever).
    public var cid = UUID().uuidString

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, mode, unicastAddress, interfaceName, universeOffset, priority, sourceName, cid
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? .multicast
        unicastAddress = (try? c.decodeIfPresent(String.self, forKey: .unicastAddress)) ?? ""
        interfaceName = (try? c.decodeIfPresent(String.self, forKey: .interfaceName)) ?? nil
        universeOffset = clamp((try? c.decodeIfPresent(Int.self, forKey: .universeOffset)) ?? 0, 0, 63998)
        priority = clamp((try? c.decodeIfPresent(Int.self, forKey: .priority)) ?? Int(SACN.defaultPriority), 0, 200)
        let name = (try? c.decodeIfPresent(String.self, forKey: .sourceName)) ?? "Prism"
        sourceName = name.isEmpty ? "Prism" : name
        let stored = (try? c.decodeIfPresent(String.self, forKey: .cid)) ?? ""
        cid = UUID(uuidString: stored) != nil ? stored : UUID().uuidString
    }
}

/// Sends DMX over Ethernet/Wi-Fi with Art-Net or sACN. Ports are Prism universes.
///
/// Like the USB drivers, one private thread does all socket work; `submit` only swaps frames.
/// Unchanged universes are resent once a second (sACN: 3 quick copies after each change).
public final class NetworkDMXDevice: DMXDevice, @unchecked Sendable {
    public enum Transport: Sendable {
        case artNet(ArtNetSettings)
        case sACN(SACNSettings)
    }

    public let id: String
    public let kind: DMXDeviceKind
    private let transport: Transport
    private let runtime: DeviceRuntime
    private let interfaces: @Sendable () -> [NetworkInterface]
    private let destinationPort: UInt16
    private let listenPort: UInt16?
    private let nodeList = Locked<[ArtNet.Node]>([])
    private let terminate = Locked(false)

    /// - Parameters:
    ///   - destinationPort: UDP port to send to (defaults to the protocol's port; tests override it).
    ///   - listenPort: Art-Net port to bind for ArtPollReply discovery (nil = no discovery).
    public init(transport: Transport,
                interfaces: @escaping @Sendable () -> [NetworkInterface] = { NetworkInterface.lightingCandidates() },
                destinationPort: UInt16? = nil, listenPort: UInt16? = ArtNet.port) {
        self.transport = transport
        self.interfaces = interfaces
        switch transport {
        case .artNet:
            id = "artnet"
            kind = .artNet
            self.destinationPort = destinationPort ?? ArtNet.port
            self.listenPort = listenPort
        case .sACN:
            id = "sacn"
            kind = .sACN
            self.destinationPort = destinationPort ?? SACN.port
            self.listenPort = nil
        }
        let name = kind == .artNet ? "Art-Net" : "sACN"
        runtime = DeviceRuntime(snapshot: DMXDeviceSnapshot(id: id, kind: kind, name: name, shortName: name, portCount: 1))
    }

    public var snapshot: DMXDeviceSnapshot { runtime.snapshot }
    /// Art-Net nodes that answered the last polls.
    public var nodes: [ArtNet.Node] { nodeList.value }

    public func submit(port: Int, data: [UInt8]) { runtime.slot.submit(port: port, data: data) }
    public func start() { runtime.start(name: "Prism \(kind.title)") { [self] in self.run() } }
    public func reconnectNow() { runtime.requestReconnect() }
    public func markRemoved() {}
    public func setChangeHandler(_ handler: (@Sendable (DMXDeviceSnapshot) -> Void)?) { runtime.setChangeHandler(handler) }

    /// Stops; when `terminateStreams` is set, sACN receivers are told the stream ended
    /// (so they release the universe right away instead of holding the last look).
    public func stop(flushTimeout: Double, terminateStreams: Bool) {
        terminate.value = terminateStreams
        runtime.stop(flushTimeout: flushTimeout)
    }

    public func stop(flushTimeout: Double) { stop(flushTimeout: flushTimeout, terminateStreams: false) }

    // MARK: - Loop

    private struct Stream {
        var sequence: UInt8 = 0
        var lastSent = 0.0
        var repeatsLeft = 0
    }

    private func run() {
        while !runtime.isStopping {
            let socket: UDPSocket?
            var discovery = false
            if kind == .artNet, let listen = listenPort, let s = UDPSocket.open(port: listen, shared: true) {
                socket = s
                discovery = true
            } else {
                socket = UDPSocket.open(port: 0, shared: false)
            }
            guard let socket else {
                runtime.setState(.failed("Prism couldn't open a network connection."))
                runtime.pause(3)
                continue
            }
            runtime.update { $0.state = .live; $0.lastError = nil }
            runtime.slot.markAllDirty()
            runtime.slot.setWakeEnabled(true)
            loop(socket, discovery: discovery)
            runtime.slot.setWakeEnabled(false)
            socket.close()
        }
        runtime.setState(.stopped)
    }

    private func loop(_ socket: UDPSocket, discovery: Bool) {
        var streams: [Int: Stream] = [:]
        var found: [IPv4: (node: ArtNet.Node, seen: Double)] = [:]
        var lastPoll = 0.0
        var cachedInterfaces: [NetworkInterface] = []
        var interfacesAt = -100.0
        var multicastInterface: IPv4?
        var problem: NetworkSendProblem?
        var lastRoute = ""
        let cid: [UInt8]
        if case .sACN(let s) = transport { cid = SACN.cidBytes(s.cid) } else { cid = [] }

        while true {
            let now = PrismClock.now()
            if now - interfacesAt > 5 {
                cachedInterfaces = selectedInterfaces()
                interfacesAt = now
            }
            if runtime.isStopping {
                finish(socket, streams: &streams, cid: cid, interfaces: cachedInterfaces, found: found)
                return
            }
            _ = runtime.consumeReconnect()

            if discovery, now - lastPoll >= 3 {
                lastPoll = now
                let poll = ArtNet.poll()
                for target in broadcastTargets(cachedInterfaces) { _ = socket.send(poll, to: target, port: destinationPort) }
                let expired = found.filter { now - $0.value.seen > 10 }.map(\.key)
                if !expired.isEmpty {
                    for key in expired { found.removeValue(forKey: key) }
                    nodeList.value = found.values.map(\.node).sorted { $0.ip < $1.ip }
                }
            }

            var nextDue = now + 0.25
            var sendErrors: [Int32] = []
            var sentSomething = false
            for universe in runtime.slot.knownPorts {
                var stream = streams[universe] ?? Stream()
                let t = PrismClock.now()
                var data: [UInt8]?
                var latency: Double?
                if let f = runtime.slot.take(port: universe) {
                    data = f.data
                    latency = t - f.submittedAt
                    stream.repeatsLeft = kind == .sACN ? 2 : 0
                } else if stream.repeatsLeft > 0, t - stream.lastSent >= 0.025 {
                    data = runtime.slot.latestFrame(port: universe)
                    stream.repeatsLeft -= 1
                } else if t - stream.lastSent >= 1.0 {
                    data = runtime.slot.latestFrame(port: universe)
                }
                if let data {
                    stream.sequence = ArtNet.nextSequence(after: stream.sequence)
                    let errors = send(data, universe: universe, sequence: stream.sequence, options: 0, socket: socket,
                                      cid: cid, interfaces: cachedInterfaces, found: found,
                                      multicastInterface: &multicastInterface)
                    sendErrors += errors
                    stream.lastSent = PrismClock.now()
                    if errors.isEmpty {
                        sentSomething = true
                        runtime.recordSent(latency: latency, now: stream.lastSent)
                    } else {
                        runtime.recordWriteError()
                    }
                }
                streams[universe] = stream
                nextDue = min(nextDue, stream.lastSent + (stream.repeatsLeft > 0 ? 0.025 : 1.0))
            }

            // Publish state: a send problem is shown but never stops the loop.
            let newProblem: NetworkSendProblem? = sendErrors.first.map(NetworkSendProblem.init(errno:))
            if sentSomething || newProblem != nil, newProblem != problem {
                problem = newProblem
                if let p = newProblem {
                    runtime.update { $0.state = .failed(p.message); $0.lastError = p.message }
                } else {
                    runtime.update { $0.state = .live; $0.lastError = nil }
                }
            }
            let route = routeDescription(cachedInterfaces, nodes: found.count)
            if route != lastRoute {
                lastRoute = route
                runtime.update { $0.path = route; $0.portCount = max(1, streams.count) }
            }

            let w = IOWait.wait(fd: socket.fd, read: discovery, write: false, wakeFD: runtime.wakeFD,
                                timeout: max(0.001, nextDue - PrismClock.now()))
            if w.woken { runtime.wake?.drain() }
            if w.readable {
                var changed = false
                var budget = 64
                while budget > 0, let (bytes, from) = socket.receive() {
                    budget -= 1
                    guard var node = ArtNet.parsePollReply(bytes) else { continue }
                    if node.ip == .any { node.ip = from }
                    // Ignore our own poll replies / loopback.
                    if cachedInterfaces.contains(where: { $0.address == node.ip }) { continue }
                    if let existing = found[node.ip] {
                        var merged = existing.node
                        for o in node.outputs where !merged.outputs.contains(o) { merged.outputs.append(o) }
                        if merged.shortName.isEmpty { merged.shortName = node.shortName }
                        found[node.ip] = (merged, PrismClock.now())
                        changed = changed || merged != existing.node
                    } else {
                        found[node.ip] = (node, PrismClock.now())
                        changed = true
                    }
                }
                if changed { nodeList.value = found.values.map(\.node).sorted { $0.ip < $1.ip } }
            }
        }
    }

    private func selectedInterfaces() -> [NetworkInterface] {
        let all = interfaces()
        let wanted: String?
        switch transport {
        case .artNet(let s): wanted = s.interfaceName
        case .sACN(let s): wanted = s.interfaceName
        }
        guard let wanted, !wanted.isEmpty else { return all }
        let match = all.filter { $0.name == wanted }
        return match.isEmpty ? all : match
    }

    private func broadcastTargets(_ list: [NetworkInterface]) -> [IPv4] {
        let targets = list.filter { $0.supportsBroadcast }.map(\.broadcast)
        return targets.isEmpty ? [.limitedBroadcast] : Array(Set(targets)).sorted()
    }

    /// Sends one universe to every destination. Returns the errno of each failed send.
    private func send(_ data: [UInt8], universe: Int, sequence: UInt8, options: UInt8, socket: UDPSocket,
                      cid: [UInt8], interfaces: [NetworkInterface], found: [IPv4: (node: ArtNet.Node, seen: Double)],
                      multicastInterface: inout IPv4?) -> [Int32] {
        var errors: [Int32] = []
        switch transport {
        case .artNet(let s):
            let address = ArtNet.PortAddress(prismUniverse: universe, offset: s.universeOffset)
            let packet = ArtNet.dmx(data, address: address, sequence: sequence)
            var targets: [IPv4]
            switch s.mode {
            case .unicast:
                targets = IPv4(s.unicastAddress).map { [$0] } ?? broadcastTargets(interfaces)
            case .broadcast:
                targets = broadcastTargets(interfaces)
            case .automatic:
                targets = found.values.filter { $0.node.outputs.contains(address) }.map(\.node.ip).sorted()
                if targets.isEmpty { targets = broadcastTargets(interfaces) }
            }
            for target in targets {
                let rc = socket.send(packet, to: target, port: destinationPort)
                if rc != 0 { errors.append(rc) }
            }
        case .sACN(let s):
            let u = SACN.universe(forPrismUniverse: universe, offset: s.universeOffset)
            let packet = SACN.dataPacket(data, universe: u, sequence: sequence, cid: cid, sourceName: s.sourceName,
                                         priority: UInt8(clamp(s.priority, 0, 200)), options: options)
            if s.mode == .unicast, let ip = IPv4(s.unicastAddress) {
                let rc = socket.send(packet, to: ip, port: destinationPort)
                if rc != 0 { errors.append(rc) }
            } else {
                let group = SACN.multicastAddress(universe: u)
                let outgoing = interfaces.filter { $0.supportsMulticast }
                if outgoing.count <= 1 {
                    if let only = outgoing.first, multicastInterface != only.address {
                        socket.configureMulticast(ttl: 1, loopback: true, interface: only.address)
                        multicastInterface = only.address
                    }
                    let rc = socket.send(packet, to: group, port: destinationPort)
                    if rc != 0 { errors.append(rc) }
                } else {
                    for interface in outgoing {
                        if multicastInterface != interface.address {
                            socket.configureMulticast(ttl: 1, loopback: true, interface: interface.address)
                            multicastInterface = interface.address
                        }
                        let rc = socket.send(packet, to: group, port: destinationPort)
                        if rc != 0 { errors.append(rc) }
                    }
                }
            }
        }
        return errors
    }

    /// Last frames on stop; sACN streams are terminated when asked to.
    private func finish(_ socket: UDPSocket, streams: inout [Int: Stream], cid: [UInt8], interfaces: [NetworkInterface],
                        found: [IPv4: (node: ArtNet.Node, seen: Double)]) {
        var multicastInterface: IPv4?
        let terminateStreams = kind == .sACN && terminate.value
        for universe in runtime.slot.knownPorts {
            var stream = streams[universe] ?? Stream()
            guard let data = runtime.slot.take(port: universe)?.data ?? (terminateStreams ? runtime.slot.latestFrame(port: universe) : nil) else { continue }
            let copies = terminateStreams ? 3 : 1
            for _ in 0..<copies {
                stream.sequence = ArtNet.nextSequence(after: stream.sequence)
                _ = send(data, universe: universe, sequence: stream.sequence,
                         options: terminateStreams ? SACN.optionStreamTerminated : 0, socket: socket, cid: cid,
                         interfaces: interfaces, found: found, multicastInterface: &multicastInterface)
            }
            streams[universe] = stream
        }
    }

    private func routeDescription(_ list: [NetworkInterface], nodes: Int) -> String {
        let via = list.count == 1 ? " on \(list[0].name)" : ""
        switch transport {
        case .artNet(let s):
            switch s.mode {
            case .unicast:
                return IPv4(s.unicastAddress).map { "To \($0)" } ?? "Broadcast\(via) (address not valid)"
            case .broadcast:
                return "Broadcast\(via)"
            case .automatic:
                return nodes > 0 ? "\(nodes) node\(nodes == 1 ? "" : "s") found\(via)" : "Broadcast\(via) · no nodes found yet"
            }
        case .sACN(let s):
            if s.mode == .unicast, let ip = IPv4(s.unicastAddress) { return "To \(ip) · priority \(s.priority)" }
            return "Multicast\(via) · priority \(s.priority)"
        }
    }
}
