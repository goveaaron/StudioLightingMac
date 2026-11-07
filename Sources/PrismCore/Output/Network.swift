import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// An IPv4 address in host byte order.
public struct IPv4: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var value: UInt32

    public init(_ value: UInt32) { self.value = value }

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        value = (UInt32(a) << 24) | (UInt32(b) << 16) | (UInt32(c) << 8) | UInt32(d)
    }

    /// Parses a dotted quad ("192.168.1.50"); nil for anything else.
    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, let n = UInt32(part), n <= 255 else { return nil }
            v = (v << 8) | n
        }
        value = v
    }

    public static let any = IPv4(0)
    public static let loopback = IPv4(127, 0, 0, 1)
    public static let limitedBroadcast = IPv4(0xFFFF_FFFF)

    public var bytes: [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    public var description: String { bytes.map(String.init).joined(separator: ".") }

    public var isMulticast: Bool { (value >> 28) == 0xE }
    public var isLoopback: Bool { (value >> 24) == 127 }
    public var isLinkLocal: Bool { (value >> 16) == 0xA9FE }

    public static func < (a: IPv4, b: IPv4) -> Bool { a.value < b.value }

    var inAddr: in_addr { in_addr(s_addr: value.bigEndian) }

    init(inAddr: in_addr) { value = UInt32(bigEndian: inAddr.s_addr) }
}

/// An IPv4 network interface of this Mac.
public struct NetworkInterface: Hashable, Sendable, Identifiable {
    public var name: String
    public var address: IPv4
    public var netmask: IPv4
    public var isUp: Bool
    public var isLoopback: Bool
    public var supportsBroadcast: Bool
    public var supportsMulticast: Bool

    public init(name: String, address: IPv4, netmask: IPv4, isUp: Bool = true, isLoopback: Bool = false,
                supportsBroadcast: Bool = true, supportsMulticast: Bool = true) {
        self.name = name
        self.address = address
        self.netmask = netmask
        self.isUp = isUp
        self.isLoopback = isLoopback
        self.supportsBroadcast = supportsBroadcast
        self.supportsMulticast = supportsMulticast
    }

    public var id: String { name + "/" + address.description }

    /// The directed broadcast address (address | ~netmask).
    public var broadcast: IPv4 { IPv4(address.value | ~netmask.value) }

    /// e.g. "en0 · 192.168.1.20".
    public var displayName: String { "\(name) · \(address)" }

    /// True when `ip` is on this interface's subnet.
    public func contains(_ ip: IPv4) -> Bool { (ip.value & netmask.value) == (address.value & netmask.value) }

    // Interface flag bits (identical on Darwin and Linux except multicast).
    private static let flagUp: UInt32 = 0x1
    private static let flagBroadcast: UInt32 = 0x2
    private static let flagLoopback: UInt32 = 0x8
    #if canImport(Darwin)
    private static let flagMulticast: UInt32 = 0x8000
    #else
    private static let flagMulticast: UInt32 = 0x1000
    #endif

    /// All IPv4 interfaces right now (cheap; safe to call from any thread).
    public static func current() -> [NetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [NetworkInterface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let maskPtr = entry.pointee.ifa_netmask, let namePtr = entry.pointee.ifa_name else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { IPv4(inAddr: $0.pointee.sin_addr) }
            let mask = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { IPv4(inAddr: $0.pointee.sin_addr) }
            let flags = UInt32(entry.pointee.ifa_flags)
            result.append(NetworkInterface(
                name: String(cString: namePtr), address: ip, netmask: mask,
                isUp: flags & flagUp != 0, isLoopback: flags & flagLoopback != 0,
                supportsBroadcast: flags & flagBroadcast != 0, supportsMulticast: flags & flagMulticast != 0))
        }
        return result
    }

    /// Interfaces that can carry lighting traffic: up, IPv4, not loopback. Wired/known names first.
    public static func lightingCandidates(_ all: [NetworkInterface] = current()) -> [NetworkInterface] {
        all.filter { $0.isUp && !$0.isLoopback && $0.address != .any }
            .sorted { a, b in
                if a.isLinkLocalOnly != b.isLinkLocalOnly { return !a.isLinkLocalOnly }
                return a.name < b.name
            }
    }

    var isLinkLocalOnly: Bool { address.isLinkLocal }
}

/// Why sending on the network failed, in plain English.
public enum NetworkSendProblem: Equatable, Sendable {
    case noNetwork
    /// macOS blocked the traffic — usually the Local Network privacy permission.
    case blocked
    case other(Int32)

    init(errno code: Int32) {
        switch code {
        case ENETUNREACH, ENETDOWN, EADDRNOTAVAIL: self = .noNetwork
        case EHOSTUNREACH, EPERM, EACCES: self = .blocked
        default: self = .other(code)
        }
    }

    public var message: String {
        switch self {
        case .noNetwork:
            return "This Mac isn't connected to a network. Connect it to the lighting network (Ethernet or Wi-Fi)."
        case .blocked:
            return "macOS is blocking Prism on your local network. Open System Settings › Privacy & Security › Local Network and turn on Prism."
        case .other(let code):
            return "The network reported an error (\(code))."
        }
    }
}

/// A non-blocking UDP socket owned by one I/O thread.
final class UDPSocket {
    private(set) var fd: Int32
    let boundPort: UInt16

    private init(fd: Int32, boundPort: UInt16) {
        self.fd = fd
        self.boundPort = boundPort
    }

    deinit { close() }

    /// Opens a UDP socket bound to `port` on all interfaces (0 = any free port).
    /// - Parameter shared: allow other apps to bind the same port (needed for Art-Net 6454).
    static func open(port: UInt16, shared: Bool) -> UDPSocket? {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_DGRAM, Int32(IPPROTO_UDP))
        #else
        let fd = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), Int32(IPPROTO_UDP))
        #endif
        guard fd >= 0 else { return nil }
        if shared {
            setInt(fd, SOL_SOCKET, SO_REUSEADDR, 1)
            setInt(fd, SOL_SOCKET, SO_REUSEPORT, 1)
        }
        setInt(fd, SOL_SOCKET, SO_BROADCAST, 1)
        #if canImport(Darwin)
        setInt(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)
        #endif
        Sys.makeNonBlocking(fd)
        var addr = makeAddress(.any, port: port)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            Sys.close(fd)
            return nil
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gotName = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let actual = gotName == 0 ? UInt16(bigEndian: bound.sin_port) : port
        return UDPSocket(fd: fd, boundPort: actual)
    }

    func close() {
        guard fd >= 0 else { return }
        Sys.close(fd)
        fd = -1
    }

    @discardableResult
    private static func setInt(_ fd: Int32, _ level: Int32, _ option: Int32, _ value: Int32) -> Bool {
        var v = value
        return setsockopt(fd, level, option, &v, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    static func makeAddress(_ ip: IPv4, port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = ip.inAddr
        return addr
    }

    /// Multicast options for sACN: hop limit, loopback and outgoing interface.
    func configureMulticast(ttl: UInt8, loopback: Bool, interface: IPv4?) {
        guard fd >= 0 else { return }
        var t = ttl
        _ = setsockopt(fd, Int32(IPPROTO_IP), IP_MULTICAST_TTL, &t, socklen_t(MemoryLayout<UInt8>.size))
        var l: UInt8 = loopback ? 1 : 0
        _ = setsockopt(fd, Int32(IPPROTO_IP), IP_MULTICAST_LOOP, &l, socklen_t(MemoryLayout<UInt8>.size))
        if let interface {
            var a = interface.inAddr
            _ = setsockopt(fd, Int32(IPPROTO_IP), IP_MULTICAST_IF, &a, socklen_t(MemoryLayout<in_addr>.size))
        }
    }

    /// Sends one datagram without blocking. Returns 0 on success, otherwise errno.
    func send(_ bytes: [UInt8], to ip: IPv4, port: UInt16) -> Int32 {
        guard fd >= 0 else { return EBADF }
        var addr = UDPSocket.makeAddress(ip, port: port)
        let n = bytes.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return n >= 0 ? 0 : errno
    }

    /// Receives one waiting datagram, or nil when none is waiting.
    func receive(maxBytes: Int = 1500) -> (bytes: [UInt8], from: IPv4)? {
        guard fd >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        var from = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = buffer.withUnsafeMutableBytes { raw -> Int in
            withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &len)
                }
            }
        }
        guard n > 0 else { return nil }
        return (Array(buffer[0..<n]), IPv4(inAddr: from.sin_addr))
    }
}
