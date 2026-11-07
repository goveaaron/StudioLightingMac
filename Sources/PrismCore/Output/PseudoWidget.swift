import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A simulated ENTTEC DMX USB Pro on a pseudo-terminal.
///
/// It answers the serial-number and parameter requests (labels 10 and 3) like the real widget
/// and records the DMX frames it receives, so the real serial driver — open, exclusive access,
/// identification, non-blocking writes, unplug and reconnect — runs end-to-end without
/// hardware. Used by the unit tests on Linux and by the app's self-test on macOS (which also
/// exercises the Mac's own serial stack). Call `unplug()` when done: the serving thread keeps
/// the widget alive until then.
public final class PseudoWidget: @unchecked Sendable {
    public enum Personality: Sendable {
        /// Answers like a genuine ENTTEC DMX USB Pro.
        case enttecPro
        /// Also answers the DMXking labels 77/78 as an ultraDMX Pro (two outputs).
        case dmxKingPro
        /// Never answers (an unknown USB serial device).
        case mute
        /// Records raw bytes without parsing (Open DMX).
        case raw
    }

    /// The "hardware" side of the pty.
    public let master: Int32
    /// A slave descriptor held open by the widget (also used to simulate a busy port).
    public let heldSlave: Int32
    /// Device path the driver opens, e.g. /dev/ttys012.
    public let path: String
    public let personality: Personality

    private let lock = PrismLock()
    private var frames: [UInt8: [[UInt8]]] = [:]
    private var requests: [UInt8] = []
    private var rawBytes: [UInt8] = []
    private var stopped = false
    private let finished = DispatchSemaphore(value: 0)

    /// Nil when the system can't create a pseudo-terminal.
    public init?(_ personality: Personality = .enttecPro) {
        self.personality = personality
        #if canImport(Glibc)
        var m: Int32 = -1, s: Int32 = -1
        guard openpty(&m, &s, nil, nil, nil) == 0 else { return nil }
        guard let name = ttyname(s) else {
            Sys.close(m)
            Sys.close(s)
            return nil
        }
        master = m
        heldSlave = s
        path = String(cString: name)
        #else
        let m = posix_openpt(O_RDWR | O_NOCTTY)
        guard m >= 0 else { return nil }
        guard grantpt(m) == 0, unlockpt(m) == 0, let name = ptsname(m) else {
            Sys.close(m)
            return nil
        }
        let slavePath = String(cString: name)
        let s = Sys.open(slavePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard s >= 0 else {
            Sys.close(m)
            return nil
        }
        master = m
        heldSlave = s
        path = slavePath
        #endif
        Sys.makeNonBlocking(master)
        let thread = Thread { [self] in self.serve() }
        thread.name = "Prism.PseudoWidget"
        thread.start()
    }

    private func serve() {
        var parser = EnttecParser()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !lock.withLock({ stopped }) {
            let w = IOWait.wait(fd: master, read: true, write: false, wakeFD: -1, timeout: 0.02)
            guard w.readable || w.hangup else { continue }
            let n = buffer.withUnsafeMutableBytes { Sys.read(master, $0.baseAddress, 4096) }
            guard n > 0 else {
                usleep(2000)
                continue
            }
            let bytes = Array(buffer[0..<n])
            if personality == .raw {
                lock.withLock { rawBytes += bytes }
                continue
            }
            for m in parser.feed(bytes) { handle(m) }
        }
        finished.signal()
    }

    private func handle(_ m: EnttecMessage) {
        lock.withLock {
            if m.label == EnttecLabel.outputOnlySendDMX.rawValue || m.label == 100 || m.label == 101 {
                frames[m.label, default: []].append(Array(m.payload.dropFirst()))
            } else {
                requests.append(m.label)
            }
        }
        guard personality != .mute else { return }
        switch m.label {
        case 10: reply(10, [0x67, 0x45, 0x23, 0x01])          // serial 01234567
        case 3: reply(3, [0x2C, 0x01, 9, 1, 40])              // firmware 1.44, 96 µs / 11 µs, 40 fps
        case 77 where personality == .dmxKingPro: reply(77, [0x6B, 0x6A] + Array("DMXking.com".utf8))
        case 78 where personality == .dmxKingPro: reply(78, [0x02, 0x00] + Array("ultraDMX Pro".utf8))
        default: break // a genuine ENTTEC ignores labels it doesn't know
        }
    }

    private func reply(_ label: UInt8, _ payload: [UInt8]) {
        let bytes = EnttecPro.message(label: label, payload: payload)
        _ = bytes.withUnsafeBytes { Sys.write(master, $0.baseAddress, bytes.count) }
    }

    /// The newest DMX frame received with `label` (6 = output port 1), without the start code.
    public func lastFrame(label: UInt8 = 6) -> [UInt8]? { lock.withLock { frames[label]?.last } }
    /// Number of DMX frames received with `label`.
    public func frameCount(label: UInt8 = 6) -> Int { lock.withLock { frames[label]?.count ?? 0 } }
    /// Labels of every non-DMX message received, in order.
    public var seenRequests: [UInt8] { lock.withLock { requests } }
    /// Raw bytes received (`.raw` personality).
    public var raw: [UInt8] { lock.withLock { rawBytes } }

    /// "Unplugs" the widget: stops serving and closes the pty. Safe to call twice.
    public func unplug() {
        let wasRunning: Bool = lock.withLock {
            let r = !stopped
            stopped = true
            return r
        }
        guard wasRunning else { return }
        _ = finished.wait(timeout: .now() + 1)
        Sys.close(master)
        Sys.close(heldSlave)
    }

    deinit { unplug() }
}
