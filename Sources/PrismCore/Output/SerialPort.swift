import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Why a serial port couldn't be opened or used — with plain-English text for the UI.
public enum SerialPortError: Error, Equatable, Sendable {
    /// The device node doesn't exist (unplugged).
    case notFound
    /// Another app has the port open exclusively.
    case busy
    /// macOS refused access.
    case permissionDenied
    /// The path isn't a serial device.
    case notASerialPort
    /// The device vanished while in use (unplugged, USB reset).
    case disconnected
    /// A write started but couldn't finish in time — the device stopped accepting data.
    case stalled
    /// The requested speed isn't supported by this device.
    case speedNotSupported
    /// Any other system error (errno).
    case system(Int32)

    /// Short, friendly explanation for status text and toasts.
    public var message: String {
        switch self {
        case .notFound: return "The DMX box isn't plugged in."
        case .busy: return "Another app is using your DMX box. Quit Lightkey, QLC+ or any other lighting app and Prism will connect by itself."
        case .permissionDenied: return "macOS didn't let Prism open the DMX box. Unplug it, plug it back in and try again."
        case .notASerialPort: return "This device isn't a DMX box."
        case .disconnected: return "The DMX box was unplugged."
        case .stalled: return "The DMX box stopped responding."
        case .speedNotSupported: return "This USB cable can't run at DMX speed."
        case .system(let code): return "The DMX box reported a system error (\(code))."
        }
    }

    static func fromOpen(errno code: Int32) -> SerialPortError {
        switch code {
        case EBUSY: return .busy
        case ENOENT, ENXIO, ENODEV: return .notFound
        case EACCES, EPERM: return .permissionDenied
        case ENOTTY: return .notASerialPort
        default: return .system(code)
        }
    }
}

/// A raw, non-blocking serial port owned by exactly one thread (a device's I/O thread).
///
/// Opens with `O_NONBLOCK` and takes exclusive access (`TIOCEXCL`) so a second app gets a
/// clean "busy" instead of interleaved bytes. Writes are bounded: a frame is either written
/// completely or not at all (dropped), and a write that stalls part-way is reported so the
/// caller can reconnect. Not thread-safe by design.
public final class SerialPort {
    public let path: String
    public private(set) var fd: Int32

    public var isOpen: Bool { fd >= 0 }

    private init(path: String, fd: Int32) {
        self.path = path
        self.fd = fd
    }

    deinit { close() }

    /// Opens `path` as a raw 8-bit serial port.
    /// - Parameters:
    ///   - baud: line speed. Standard rates use termios; non-standard rates (250 000 for
    ///     Open DMX) use `IOSSIOSPEED` on macOS.
    ///   - twoStopBits: 8N2 framing (DMX512 line format, used by Open DMX).
    ///   - exclusive: take `TIOCEXCL` so other apps get EBUSY while Prism owns the box.
    public static func open(path: String, baud: Int = 115_200, twoStopBits: Bool = false,
                            exclusive: Bool = true) throws -> SerialPort {
        let fd = Sys.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SerialPortError.fromOpen(errno: errno) }
        let port = SerialPort(path: path, fd: fd)

        if exclusive, ioctl(fd, TTYIoctl.exclusive) != 0 {
            let code = errno
            port.close()
            throw code == EBUSY ? SerialPortError.busy : SerialPortError.fromOpen(errno: code)
        }

        var t = termios()
        guard tcgetattr(fd, &t) == 0 else {
            let code = errno
            port.close()
            throw code == ENOTTY ? SerialPortError.notASerialPort : SerialPortError.fromOpen(errno: code)
        }
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(PARENB)
        t.c_cflag &= ~tcflag_t(CSIZE)
        t.c_cflag |= tcflag_t(CS8)
        if twoStopBits {
            t.c_cflag |= tcflag_t(CSTOPB)
        } else {
            t.c_cflag &= ~tcflag_t(CSTOPB)
        }
        #if canImport(Darwin)
        t.c_cflag &= ~tcflag_t(CCTS_OFLOW | CRTS_IFLOW)
        #else
        t.c_cflag &= ~tcflag_t(CRTSCTS)
        #endif
        t.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        withUnsafeMutableBytes(of: &t.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        let standard = standardSpeed(for: baud)
        _ = cfsetspeed(&t, standard ?? speed_t(B115200))
        guard tcsetattr(fd, TCSANOW, &t) == 0 else {
            let code = errno
            port.close()
            throw SerialPortError.fromOpen(errno: code)
        }
        if standard == nil {
            #if canImport(Darwin)
            var speed = speed_t(baud)
            let rc = withUnsafeMutablePointer(to: &speed) { ioctl(fd, TTYIoctl.setSpeed, $0) }
            if rc != 0 {
                port.close()
                throw SerialPortError.speedNotSupported
            }
            #else
            port.close()
            throw SerialPortError.speedNotSupported
            #endif
        }
        _ = tcflush(fd, TCIOFLUSH)
        return port
    }

    private static func standardSpeed(for baud: Int) -> speed_t? {
        switch baud {
        case 9600: return speed_t(B9600)
        case 19200: return speed_t(B19200)
        case 38400: return speed_t(B38400)
        case 57600: return speed_t(B57600)
        case 115_200: return speed_t(B115200)
        case 230_400: return speed_t(B230400)
        default: return nil
        }
    }

    /// Closes the port (releasing exclusive access). Safe to call twice.
    public func close() {
        guard fd >= 0 else { return }
        _ = ioctl(fd, TTYIoctl.nonExclusive)
        Sys.close(fd)
        fd = -1
    }

    public enum WriteOutcome: Equatable, Sendable {
        /// Every byte was handed to the driver.
        case sent
        /// The port couldn't accept data within `startTimeout`; nothing was written.
        case dropped
    }

    /// Writes `bytes` completely, or not at all.
    /// - Parameters:
    ///   - startTimeout: how long to wait for the port to accept the first byte (drop otherwise).
    ///   - finishTimeout: once started, how long the whole write may take before it is
    ///     considered stalled (throws `.stalled`, since a partial frame went out).
    public func write(_ bytes: [UInt8], startTimeout: Double = 0.005, finishTimeout: Double = 0.1) throws -> WriteOutcome {
        guard fd >= 0 else { throw SerialPortError.disconnected }
        guard !bytes.isEmpty else { return .sent }
        let started = PrismClock.now()
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let n = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Sys.write(fd, base + offset, remaining)
            }
            if n > 0 {
                offset += n
                continue
            }
            let code = n < 0 ? errno : EAGAIN
            if code == EINTR { continue }
            guard Sys.isTransient(code) else {
                throw Sys.isGone(code) ? SerialPortError.disconnected : SerialPortError.system(code)
            }
            let elapsed = PrismClock.now() - started
            let limit = offset == 0 ? startTimeout : finishTimeout
            if elapsed >= limit {
                if offset == 0 { return .dropped }
                throw SerialPortError.stalled
            }
            let w = IOWait.wait(fd: fd, read: false, write: true, wakeFD: -1, timeout: min(limit - elapsed, 0.01))
            if w.hangup && !w.writable {
                // Linux reports a vanished device as POLLHUP/POLLERR; confirm with a probe write next loop.
                if probeGone() { throw SerialPortError.disconnected }
            }
        }
        return .sent
    }

    /// Reads whatever is waiting, without blocking. Returns an empty array when nothing is.
    /// Throws `.disconnected` at end-of-file or when the device is gone.
    public func readAvailable(maxBytes: Int = 1024) throws -> [UInt8] {
        guard fd >= 0 else { throw SerialPortError.disconnected }
        let size = max(1, maxBytes)
        var buffer = [UInt8](repeating: 0, count: size)
        let n = buffer.withUnsafeMutableBytes { Sys.read(fd, $0.baseAddress, size) }
        if n > 0 { return Array(buffer[0..<n]) }
        if n == 0 { throw SerialPortError.disconnected }
        let code = errno
        if Sys.isTransient(code) { return [] }
        throw Sys.isGone(code) ? SerialPortError.disconnected : SerialPortError.system(code)
    }

    /// Discards unread input and unsent output.
    public func flush() {
        guard fd >= 0 else { return }
        _ = tcflush(fd, TCIOFLUSH)
    }

    /// Discards unread input only.
    public func flushInput() {
        guard fd >= 0 else { return }
        _ = tcflush(fd, TCIFLUSH)
    }

    /// Waits until all output has been transmitted (blocking; I/O thread only).
    @discardableResult
    public func drainOutput() -> Bool {
        guard fd >= 0 else { return false }
        return tcdrain(fd) == 0
    }

    /// Holds the line in a BREAK condition (Open DMX reset), or releases it.
    @discardableResult
    public func setBreak(_ on: Bool) -> Bool {
        guard fd >= 0 else { return false }
        return ioctl(fd, on ? TTYIoctl.setBreak : TTYIoctl.clearBreak) == 0
    }

    /// Sets or clears the RTS modem line (some Open DMX clones gate their driver with it).
    @discardableResult
    public func setRTS(_ on: Bool) -> Bool {
        guard fd >= 0 else { return false }
        var bits = TTYIoctl.rtsBit
        return withUnsafeMutablePointer(to: &bits) {
            ioctl(fd, on ? TTYIoctl.modemBitsSet : TTYIoctl.modemBitsClear, $0)
        } == 0
    }

    /// True if the terminal is no longer usable (attributes can't be read).
    func probeGone() -> Bool {
        guard fd >= 0 else { return true }
        var t = termios()
        if tcgetattr(fd, &t) == 0 { return false }
        return Sys.isGone(errno)
    }
}
