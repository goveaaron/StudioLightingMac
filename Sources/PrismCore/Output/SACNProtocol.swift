import Foundation

/// Streaming ACN (ANSI E1.31-2018) packet building and parsing.
///
/// A data packet is 126 bytes of root, framing and DMP layers followed by up to 512 slots.
/// Universe numbers are 1…63999; priority 0…200 (default 100).
public enum SACN {
    public static let port: UInt16 = 5568
    public static let defaultPriority: UInt8 = 100
    public static let maxPriority: UInt8 = 200
    public static let universeRange = 1...63999

    static let acnPacketIdentifier: [UInt8] = [0x41, 0x53, 0x43, 0x2D, 0x45, 0x31, 0x2E, 0x31, 0x37, 0x00, 0x00, 0x00]
    static let vectorRootData: UInt32 = 0x0000_0004
    static let vectorRootExtended: UInt32 = 0x0000_0008
    static let vectorFramingData: UInt32 = 0x0000_0002
    static let vectorFramingSync: UInt32 = 0x0000_0001
    static let vectorDMPSetProperty: UInt8 = 0x02

    /// Options byte bits.
    public static let optionPreview: UInt8 = 0x80
    public static let optionStreamTerminated: UInt8 = 0x40
    public static let optionForceSync: UInt8 = 0x20

    /// The multicast group for a universe: 239.255.hi.lo.
    public static func multicastAddress(universe: Int) -> IPv4 {
        let u = clamp(universe, universeRange.lowerBound, universeRange.upperBound)
        return IPv4(239, 255, UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF))
    }

    /// Prism universe 1 is sACN universe 1 (plus `offset`), clamped to the valid range.
    public static func universe(forPrismUniverse u: Int, offset: Int = 0) -> Int {
        clamp(u + offset, universeRange.lowerBound, universeRange.upperBound)
    }

    /// 16 CID bytes from a UUID string; falls back to a stable non-zero value when invalid.
    public static func cidBytes(_ uuidString: String) -> [UInt8] {
        if let uuid = UUID(uuidString: uuidString) {
            let u = uuid.uuid
            return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        }
        var bytes = Array(uuidString.utf8.prefix(16))
        if bytes.count < 16 { bytes += [UInt8](repeating: 0x50, count: 16 - bytes.count) }
        return bytes
    }

    private static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    private static func flagsAndLength(_ length: Int) -> [UInt8] { be16(0x7000 | (length & 0x0FFF)) }

    private static func fixed(_ bytes: [UInt8], count: Int) -> [UInt8] {
        let head = Array(bytes.prefix(count))
        return head + [UInt8](repeating: 0, count: count - head.count)
    }

    /// An E1.31 data packet.
    /// - Parameters:
    ///   - slots: up to 512 DMX values (extra values are ignored).
    ///   - cid: 16-byte component identifier (padded/truncated).
    ///   - sourceName: shown by receivers; UTF-8, truncated to 63 bytes.
    public static func dataPacket(_ slots: [UInt8], universe: Int, sequence: UInt8, cid: [UInt8],
                                  sourceName: String = "Prism", priority: UInt8 = defaultPriority,
                                  options: UInt8 = 0, syncAddress: Int = 0, startCode: UInt8 = 0) -> [UInt8] {
        let data = Array(slots.prefix(512))
        let total = 126 + data.count
        let u = clamp(universe, universeRange.lowerBound, universeRange.upperBound)
        var p: [UInt8] = []
        p.reserveCapacity(total)
        // Root layer
        p += be16(0x0010)
        p += be16(0x0000)
        p += acnPacketIdentifier
        p += flagsAndLength(total - 16)
        p += be32(vectorRootData)
        p += fixed(cid, count: 16)
        // Framing layer
        p += flagsAndLength(total - 38)
        p += be32(vectorFramingData)
        p += fixed(Array(sourceName.utf8.prefix(63)), count: 64)
        p.append(min(priority, maxPriority))
        p += be16(clamp(syncAddress, 0, 63999))
        p.append(sequence)
        p.append(options)
        p += be16(u)
        // DMP layer
        p += flagsAndLength(total - 115)
        p.append(vectorDMPSetProperty)
        p.append(0xA1)
        p += be16(0x0000)
        p += be16(0x0001)
        p += be16(data.count + 1)
        p.append(startCode)
        p += data
        return p
    }

    /// An E1.31 universe-synchronization packet (49 bytes).
    public static func syncPacket(syncAddress: Int, sequence: UInt8, cid: [UInt8]) -> [UInt8] {
        var p: [UInt8] = []
        p += be16(0x0010)
        p += be16(0x0000)
        p += acnPacketIdentifier
        p += flagsAndLength(49 - 16)
        p += be32(vectorRootExtended)
        p += fixed(cid, count: 16)
        p += flagsAndLength(49 - 38)
        p += be32(vectorFramingSync)
        p.append(sequence)
        p += be16(clamp(syncAddress, 0, 63999))
        p += [0, 0]
        return p
    }

    /// A decoded data packet (used by tests and loopback checks).
    public struct DataPacket: Equatable, Sendable {
        public var universe: Int
        public var priority: UInt8
        public var sequence: UInt8
        public var options: UInt8
        public var sourceName: String
        public var startCode: UInt8
        public var slots: [UInt8]
        public var cid: [UInt8]

        public var isStreamTerminated: Bool { options & SACN.optionStreamTerminated != 0 }
    }

    /// Parses an E1.31 data packet; nil for anything malformed or of another type.
    public static func parseDataPacket(_ p: [UInt8]) -> DataPacket? {
        guard p.count >= 126, Array(p[4..<16]) == acnPacketIdentifier else { return nil }
        func u16(_ i: Int) -> Int { (Int(p[i]) << 8) | Int(p[i + 1]) }
        func u32(_ i: Int) -> UInt32 {
            (UInt32(p[i]) << 24) | (UInt32(p[i + 1]) << 16) | (UInt32(p[i + 2]) << 8) | UInt32(p[i + 3])
        }
        guard u32(18) == vectorRootData, u32(40) == vectorFramingData, p[117] == vectorDMPSetProperty else { return nil }
        let count = u16(123)
        guard count >= 1, count <= 513, p.count >= 125 + count else { return nil }
        let name = ArtNet.cString(p, from: 44, length: 64)
        return DataPacket(universe: u16(113), priority: p[108], sequence: p[111], options: p[112],
                          sourceName: name, startCode: p[125], slots: Array(p[126..<(125 + count)]),
                          cid: Array(p[22..<38]))
    }
}
