import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Portable POSIX plumbing for the output drivers (serial ports, UDP sockets, wake pipes).
// Everything here is used from a device's own I/O thread — never from the main thread or
// the engine tick — and never blocks for longer than the timeout it is given.

/// Module-qualified POSIX calls, so they never clash with methods named `open`/`read`/… .
enum Sys {
    static func open(_ path: String, _ flags: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.open(path, flags)
        #else
        return Glibc.open(path, flags)
        #endif
    }

    @discardableResult
    static func close(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.close(fd)
        #else
        return Glibc.close(fd)
        #endif
    }

    static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.read(fd, buffer, count)
        #else
        return Glibc.read(fd, buffer, count)
        #endif
    }

    static func write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.write(fd, buffer, count)
        #else
        return Glibc.write(fd, buffer, count)
        #endif
    }

    /// Adds `O_NONBLOCK` (and close-on-exec) to a descriptor.
    @discardableResult
    static func makeNonBlocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return false }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0
    }

    /// Sleeps the calling (I/O) thread. Never call from the main thread or the engine tick.
    static func sleep(seconds: Double) {
        guard seconds > 0, seconds.isFinite else { return }
        let micro = min(seconds, 10) * 1_000_000
        usleep(useconds_t(micro))
    }

    /// True for errno values that mean "the device or connection is gone for good".
    static func isGone(_ code: Int32) -> Bool {
        code == ENXIO || code == EIO || code == ENODEV || code == EBADF || code == EPIPE || code == ENOENT
    }

    /// True for errno values that mean "try again later".
    static func isTransient(_ code: Int32) -> Bool {
        code == EAGAIN || code == EWOULDBLOCK || code == EINTR || code == ENOBUFS
    }
}

/// Terminal ioctl request codes. Darwin's are function-like macros that Swift can't import,
/// so they are spelled out (values from <sys/ttycom.h> and <IOKit/serial/ioss.h>).
enum TTYIoctl {
    #if canImport(Darwin)
    static let exclusive: UInt = 0x2000_740D        // TIOCEXCL
    static let nonExclusive: UInt = 0x2000_740E     // TIOCNXCL
    static let setBreak: UInt = 0x2000_747B         // TIOCSBRK
    static let clearBreak: UInt = 0x2000_747A       // TIOCCBRK
    static let modemBitsSet: UInt = 0x8004_746C     // TIOCMBIS
    static let modemBitsClear: UInt = 0x8004_746B   // TIOCMBIC
    static let setSpeed: UInt = 0x8008_5402         // IOSSIOSPEED
    #else
    static let exclusive = UInt(TIOCEXCL)
    static let nonExclusive = UInt(TIOCNXCL)
    static let setBreak = UInt(TIOCSBRK)
    static let clearBreak = UInt(TIOCCBRK)
    static let modemBitsSet = UInt(TIOCMBIS)
    static let modemBitsClear = UInt(TIOCMBIC)
    #endif
    /// RTS modem line bit (TIOCM_RTS), identical on Darwin and Linux.
    static let rtsBit: Int32 = 0x004
}

/// Waits for a descriptor to become readable/writable, or for a wake pipe to fire.
///
/// macOS' `poll()` doesn't support character devices (see its man page), so Darwin uses
/// `select()`; Linux uses `poll()`.
enum IOWait {
    struct Result: Equatable {
        var readable = false
        var writable = false
        /// The wake pipe fired (a new frame or a control request is waiting).
        var woken = false
        /// The descriptor reported an error or hang-up (Linux) — the caller should read to confirm.
        var hangup = false
    }

    /// - Parameters:
    ///   - fd: descriptor to watch, or -1 to only wait for the wake pipe / timeout.
    ///   - wakeFD: read end of a `WakeSignal`, or -1.
    ///   - timeout: seconds (clamped to 0…10).
    static func wait(fd: Int32, read wantRead: Bool, write wantWrite: Bool, wakeFD: Int32, timeout: Double) -> Result {
        let t = max(0, min(timeout.isFinite ? timeout : 0, 10))
        #if canImport(Darwin)
        return selectWait(fd: fd, read: wantRead, write: wantWrite, wakeFD: wakeFD, timeout: t)
        #else
        return pollWait(fd: fd, read: wantRead, write: wantWrite, wakeFD: wakeFD, timeout: t)
        #endif
    }

    #if canImport(Darwin)
    private static let setCapacity: Int32 = 1024 // FD_SETSIZE

    private static func insert(_ fd: Int32, into set: inout fd_set) {
        guard fd >= 0, fd < setCapacity else { return }
        let word = Int(fd / 32), bit = UInt32(fd % 32)
        withUnsafeMutableBytes(of: &set) { raw in
            let words = raw.bindMemory(to: Int32.self)
            guard word < words.count else { return }
            words[word] |= Int32(bitPattern: UInt32(1) << bit)
        }
    }

    private static func contains(_ fd: Int32, in set: inout fd_set) -> Bool {
        guard fd >= 0, fd < setCapacity else { return false }
        let word = Int(fd / 32), bit = UInt32(fd % 32)
        return withUnsafeMutableBytes(of: &set) { raw -> Bool in
            let words = raw.bindMemory(to: Int32.self)
            guard word < words.count else { return false }
            return (UInt32(bitPattern: words[word]) & (UInt32(1) << bit)) != 0
        }
    }

    private static func selectWait(fd: Int32, read wantRead: Bool, write wantWrite: Bool, wakeFD: Int32,
                                   timeout: Double) -> Result {
        // Descriptors beyond FD_SETSIZE can't be selected: nap briefly and let the caller try
        // non-blocking I/O instead (it handles EAGAIN).
        if fd >= setCapacity || wakeFD >= setCapacity {
            Sys.sleep(seconds: min(timeout, 0.002))
            return Result(readable: wantRead && fd >= 0, writable: wantWrite && fd >= 0, woken: wakeFD >= 0, hangup: false)
        }
        var readSet = fd_set(), writeSet = fd_set(), errorSet = fd_set()
        var maxFD: Int32 = -1
        if fd >= 0 {
            if wantRead { insert(fd, into: &readSet) }
            if wantWrite { insert(fd, into: &writeSet) }
            insert(fd, into: &errorSet)
            maxFD = max(maxFD, fd)
        }
        if wakeFD >= 0 {
            insert(wakeFD, into: &readSet)
            maxFD = max(maxFD, wakeFD)
        }
        let whole = floor(timeout)
        var tv = timeval(tv_sec: Int(whole), tv_usec: Int32((timeout - whole) * 1_000_000))
        let rc = select(maxFD + 1, &readSet, &writeSet, &errorSet, &tv)
        guard rc > 0 else { return Result() }
        var r = Result()
        if fd >= 0 {
            r.readable = wantRead && contains(fd, in: &readSet)
            r.writable = wantWrite && contains(fd, in: &writeSet)
            r.hangup = contains(fd, in: &errorSet)
        }
        if wakeFD >= 0 { r.woken = contains(wakeFD, in: &readSet) }
        return r
    }
    #else
    private static func pollWait(fd: Int32, read wantRead: Bool, write wantWrite: Bool, wakeFD: Int32,
                                 timeout: Double) -> Result {
        var events: Int16 = 0
        if wantRead { events |= Int16(POLLIN) }
        if wantWrite { events |= Int16(POLLOUT) }
        var fds = [pollfd(fd: fd, events: events, revents: 0),
                   pollfd(fd: wakeFD, events: Int16(POLLIN), revents: 0)]
        let ms = Int32((timeout * 1000).rounded(.up))
        let rc = poll(&fds, nfds_t(fds.count), ms)
        guard rc > 0 else { return Result() }
        var r = Result()
        let rev = fds[0].revents
        if fd >= 0 {
            r.readable = wantRead && (rev & Int16(POLLIN)) != 0
            r.writable = wantWrite && (rev & Int16(POLLOUT)) != 0
            r.hangup = (rev & (Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL))) != 0
        }
        if wakeFD >= 0 { r.woken = (fds[1].revents & Int16(POLLIN)) != 0 }
        return r
    }
    #endif
}

/// A self-pipe that lets any thread wake a device's I/O thread out of `IOWait.wait`.
///
/// `signal()` is cheap and never blocks: only the first signal after a `drain()` writes a byte.
/// The I/O thread must re-check its work (frames, control flags) *after* `drain()`.
final class WakeSignal: @unchecked Sendable {
    let readFD: Int32
    private let writeFD: Int32
    private let pending = Locked(false)

    init?() {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return nil }
        readFD = fds[0]
        writeFD = fds[1]
        Sys.makeNonBlocking(readFD)
        Sys.makeNonBlocking(writeFD)
    }

    deinit {
        Sys.close(readFD)
        Sys.close(writeFD)
    }

    func signal() {
        let alreadyPending = pending.mutate { p -> Bool in
            let was = p
            p = true
            return was
        }
        guard !alreadyPending else { return }
        var byte: UInt8 = 1
        _ = Sys.write(writeFD, &byte, 1)
    }

    /// Empties the pipe. Call after `IOWait` reports `woken`, then re-check for work.
    func drain() {
        var buffer = [UInt8](repeating: 0, count: 64)
        while buffer.withUnsafeMutableBytes({ Sys.read(readFD, $0.baseAddress, 64) }) > 0 {}
        pending.value = false
    }
}
