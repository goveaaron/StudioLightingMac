import Foundation

/// Art-Net 4 packet building and parsing (ArtDmx, ArtPoll, ArtPollReply, ArtSync).
///
/// Byte layouts follow the Art-Net 4 specification: the "Art-Net\0" ID, little-endian
/// OpCodes, big-endian protocol version 14 and big-endian DMX length. Nothing here traps on
/// bad input — parsers return nil for anything malformed.
public enum ArtNet {
    public static let port: UInt16 = 6454
    public static let id: [UInt8] = Array("Art-Net".utf8) + [0]
    public static let protocolVersion: UInt16 = 14

    public enum OpCode: UInt16, Sendable {
        case poll = 0x2000
        case pollReply = 0x2100
        case dmx = 0x5000
        case sync = 0x5200
    }

    /// A 15-bit Art-Net Port-Address: Net (7 bits) · Sub-Net (4 bits) · Universe (4 bits).
    public struct PortAddress: Hashable, Comparable, Sendable, CustomStringConvertible {
        public let value: UInt16

        public init(_ value: Int) {
            self.value = UInt16(clamp(value, 0, 0x7FFF))
        }

        public init(net: Int, subNet: Int, universe: Int) {
            self.init((clamp(net, 0, 0x7F) << 8) | (clamp(subNet, 0, 0xF) << 4) | clamp(universe, 0, 0xF))
        }

        /// Prism universe 1 is Port-Address 0 (plus `offset`).
        public init(prismUniverse: Int, offset: Int = 0) {
            self.init(prismUniverse - 1 + offset)
        }

        public var net: Int { Int(value >> 8) & 0x7F }
        public var subNet: Int { Int(value >> 4) & 0x0F }
        public var universe: Int { Int(value) & 0x0F }
        /// The byte sent at offset 14 of ArtDmx.
        public var subUni: UInt8 { UInt8(value & 0xFF) }

        public var description: String { "\(net):\(subNet):\(universe)" }

        public static func < (a: PortAddress, b: PortAddress) -> Bool { a.value < b.value }
    }

    private static func header(_ op: OpCode) -> [UInt8] {
        id + [UInt8(op.rawValue & 0xFF), UInt8(op.rawValue >> 8)]
    }

    private static var versionBytes: [UInt8] { [UInt8(protocolVersion >> 8), UInt8(protocolVersion & 0xFF)] }

    /// An ArtDmx packet. Data is padded to an even length of at least 2 and truncated to 512.
    /// - Parameter sequence: 1…255 to let receivers reorder, 0 to disable.
    public static func dmx(_ slots: [UInt8], address: PortAddress, sequence: UInt8, physical: UInt8 = 0) -> [UInt8] {
        var data = Array(slots.prefix(512))
        if data.count < 2 { data += [UInt8](repeating: 0, count: 2 - data.count) }
        if data.count % 2 == 1 { data.append(0) }
        var p = header(.dmx)
        p.reserveCapacity(18 + data.count)
        p += versionBytes
        p.append(sequence)
        p.append(physical)
        p.append(address.subUni)
        p.append(UInt8(address.value >> 8) & 0x7F)
        p.append(UInt8(data.count >> 8))
        p.append(UInt8(data.count & 0xFF))
        p += data
        return p
    }

    /// An ArtPoll asking every node to reply (Art-Net 4, 22 bytes).
    public static func poll(flags: UInt8 = 0, diagnosticsPriority: UInt8 = 0) -> [UInt8] {
        var p = header(.poll)
        p += versionBytes
        p.append(flags)
        p.append(diagnosticsPriority)
        p += [0x7F, 0xFF]   // TargetPortAddressTop (unused unless flag bit 5)
        p += [0x00, 0x00]   // TargetPortAddressBottom
        p += [0x00, 0x00]   // EstaMan
        p += [0x00, 0x00]   // Oem
        return p
    }

    /// An ArtSync (sent after a batch of ArtDmx when synchronous output is wanted).
    public static func sync() -> [UInt8] {
        header(.sync) + versionBytes + [0, 0]
    }

    /// The next sequence number: 1…255, skipping 0 (which means "sequencing off").
    public static func nextSequence(after s: UInt8) -> UInt8 {
        s == 255 ? 1 : s + 1
    }

    /// Returns the OpCode of an Art-Net packet, or nil if it isn't one.
    public static func opCode(of packet: [UInt8]) -> UInt16? {
        guard packet.count >= 10, Array(packet[0..<8]) == id else { return nil }
        return UInt16(packet[8]) | (UInt16(packet[9]) << 8)
    }

    /// A node found by ArtPoll.
    public struct Node: Hashable, Sendable {
        public var ip: IPv4
        public var shortName: String
        public var longName: String
        /// Port-Addresses this node outputs to DMX.
        public var outputs: [PortAddress]
        /// Index of this reply for multi-port gateways (BindIndex), 0 when absent.
        public var bindIndex: UInt8

        public init(ip: IPv4, shortName: String, longName: String, outputs: [PortAddress], bindIndex: UInt8 = 0) {
            self.ip = ip
            self.shortName = shortName
            self.longName = longName
            self.outputs = outputs
            self.bindIndex = bindIndex
        }

        /// The best human name for lists.
        public var displayName: String {
            let s = shortName.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { return s }
            let l = longName.trimmingCharacters(in: .whitespaces)
            return l.isEmpty ? ip.description : l
        }
    }

    /// Parses an ArtPollReply. Returns nil for anything that isn't a well-formed reply.
    public static func parsePollReply(_ p: [UInt8]) -> Node? {
        guard p.count >= 194, opCode(of: p) == OpCode.pollReply.rawValue else { return nil }
        let ip = IPv4(p[10], p[11], p[12], p[13])
        let netSwitch = Int(p[18]) & 0x7F
        let subSwitch = Int(p[19]) & 0x0F
        let shortName = cString(p, from: 26, length: 18)
        let longName = cString(p, from: 44, length: 64)
        let numPorts = min(Int(p[173]), 4)
        var outputs: [PortAddress] = []
        for i in 0..<numPorts {
            let portType = p[174 + i]
            let canOutput = (portType & 0x80) != 0
            guard canOutput else { continue }
            let swOut = Int(p[190 + i]) & 0x0F
            outputs.append(PortAddress(net: netSwitch, subNet: subSwitch, universe: swOut))
        }
        let bindIndex: UInt8 = p.count > 211 ? p[211] : 0
        return Node(ip: ip, shortName: shortName, longName: longName, outputs: outputs, bindIndex: bindIndex)
    }

    /// A decoded ArtDmx (used by tests and loopback checks).
    public struct DMXPacket: Equatable, Sendable {
        public var sequence: UInt8
        public var address: PortAddress
        public var data: [UInt8]
    }

    /// Parses an ArtDmx packet. Returns nil for anything malformed.
    public static func parseDMX(_ p: [UInt8]) -> DMXPacket? {
        guard p.count >= 20, opCode(of: p) == OpCode.dmx.rawValue else { return nil }
        let length = (Int(p[16]) << 8) | Int(p[17])
        guard length >= 2, length <= 512, p.count >= 18 + length else { return nil }
        let address = PortAddress((Int(p[15] & 0x7F) << 8) | Int(p[14]))
        return DMXPacket(sequence: p[12], address: address, data: Array(p[18..<(18 + length)]))
    }

    /// Builds a minimal ArtPollReply (for tests and the simulated node).
    public static func pollReply(ip: IPv4, shortName: String, longName: String, outputs: [PortAddress]) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 239)
        for (i, b) in id.enumerated() { p[i] = b }
        p[8] = UInt8(OpCode.pollReply.rawValue & 0xFF)
        p[9] = UInt8(OpCode.pollReply.rawValue >> 8)
        let ipBytes = ip.bytes
        for i in 0..<4 { p[10 + i] = ipBytes[i] }
        p[14] = UInt8(port & 0xFF)
        p[15] = UInt8(port >> 8)
        let first = outputs.first ?? PortAddress(0)
        p[18] = UInt8(first.net)
        p[19] = UInt8(first.subNet)
        for (i, b) in Array(shortName.utf8.prefix(17)).enumerated() { p[26 + i] = b }
        for (i, b) in Array(longName.utf8.prefix(63)).enumerated() { p[44 + i] = b }
        let ports = Array(outputs.prefix(4))
        p[173] = UInt8(ports.count)
        for (i, a) in ports.enumerated() {
            p[174 + i] = 0x80          // can output DMX512
            p[182 + i] = 0x80          // data being transmitted
            p[190 + i] = UInt8(a.universe)
        }
        return p
    }

    static func cString(_ bytes: [UInt8], from start: Int, length: Int) -> String {
        guard start >= 0, start < bytes.count else { return "" }
        let end = min(bytes.count, start + length)
        var slice = Array(bytes[start..<end])
        if let zero = slice.firstIndex(of: 0) { slice = Array(slice[..<zero]) }
        return String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
