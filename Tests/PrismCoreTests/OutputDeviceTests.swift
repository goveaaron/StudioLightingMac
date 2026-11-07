import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import PrismCore

/// End-to-end tests of the real drivers: a pseudo-terminal plays the DMX USB Pro (answering
/// labels 10/3 like the hardware), and UDP loopback receives Art-Net/sACN. These exercise the
/// actual open/identify/write/reconnect code paths without hardware.
final class OutputDeviceTests: XCTestCase {

    // MARK: - A simulated widget on a pty

    final class FakeWidget: @unchecked Sendable {
        enum Personality { case enttecPro, dmxKingPro, mute, raw }

        let master: Int32
        /// A slave descriptor held open by the "hardware" (also used to simulate a busy port).
        let heldSlave: Int32
        let path: String
        let personality: Personality
        private let lock = NSLock()
        private var frames: [UInt8: [[UInt8]]] = [:]
        private var requests: [UInt8] = []
        private var rawBytes: [UInt8] = []
        private var stopped = false
        private let finished = DispatchSemaphore(value: 0)

        init?(_ personality: Personality) {
            self.personality = personality
            #if canImport(Glibc)
            var m: Int32 = -1, s: Int32 = -1
            guard openpty(&m, &s, nil, nil, nil) == 0, let name = ttyname(s) else { return nil }
            master = m
            heldSlave = s
            path = String(cString: name)
            #else
            let m = posix_openpt(O_RDWR | O_NOCTTY)
            guard m >= 0, grantpt(m) == 0, unlockpt(m) == 0, let name = ptsname(m) else { return nil }
            master = m
            path = String(cString: name)
            heldSlave = Sys.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
            guard heldSlave >= 0 else { return nil }
            #endif
            Sys.makeNonBlocking(master)
            let thread = Thread { [self] in self.serve() }
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
                if m.label == 6 || m.label == 100 || m.label == 101 {
                    frames[m.label, default: []].append(Array(m.payload.dropFirst()))
                } else {
                    requests.append(m.label)
                }
            }
            guard personality != .mute else { return }
            switch m.label {
            case 10: reply(10, [0x67, 0x45, 0x23, 0x01])
            case 3: reply(3, [0x2C, 0x01, 9, 1, 40])
            case 77 where personality == .dmxKingPro: reply(77, [0x6B, 0x6A] + Array("DMXking.com".utf8))
            case 78 where personality == .dmxKingPro: reply(78, [0x02, 0x00] + Array("ultraDMX Pro".utf8))
            default: break // a genuine ENTTEC ignores labels it doesn't know
            }
        }

        private func reply(_ label: UInt8, _ payload: [UInt8]) {
            let bytes = EnttecPro.message(label: label, payload: payload)
            _ = bytes.withUnsafeBytes { Sys.write(master, $0.baseAddress, bytes.count) }
        }

        func lastFrame(label: UInt8 = 6) -> [UInt8]? { lock.withLock { frames[label]?.last } }
        func frameCount(label: UInt8 = 6) -> Int { lock.withLock { frames[label]?.count ?? 0 } }
        var seenRequests: [UInt8] { lock.withLock { requests } }
        var raw: [UInt8] { lock.withLock { rawBytes } }

        /// "Unplugs" the widget: stops serving and closes the pty.
        func unplug() {
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

    private static func fastOptions() -> EnttecProDevice.Options {
        var o = EnttecProDevice.Options()
        o.backoff = [0.05, 0.1, 0.2]
        o.busyRetry = 0.3
        o.unsupportedRetry = 1
        return o
    }

    /// Polls `condition` until it holds or `timeout` passes.
    @discardableResult
    private func waitFor(_ timeout: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }

    private func frame(_ seed: Int) -> [UInt8] { (0..<512).map { UInt8(truncatingIfNeeded: $0 &* 3 &+ seed) } }

    // MARK: - Enttec Pro over a pty

    func testProIdentifiesGoesLiveAndDeliversFrames() throws {
        let widget = try XCTUnwrap(FakeWidget(.enttecPro))
        defer { widget.unplug() }
        let path = Locked<String?>(widget.path)
        let device = EnttecProDevice(id: "test", options: Self.fastOptions(), locate: { path.value })
        let changes = Locked<[DMXDeviceState]>([])
        device.setChangeHandler { s in changes.mutate { $0.append(s.state) } }
        device.start()
        defer { device.stop(flushTimeout: 0.1) }

        XCTAssertTrue(waitFor(5) { device.snapshot.state == .live }, "state: \(device.snapshot.state)")
        let s = device.snapshot
        XCTAssertEqual(s.serialNumber, "01234567")
        XCTAssertEqual(s.firmware, "1.44")
        XCTAssertEqual(s.timing, "Break 96 µs · MAB 11 µs · 40 fps")
        XCTAssertEqual(s.shortName, "DMX USB Pro")
        XCTAssertEqual(s.path, widget.path)
        XCTAssertTrue(changes.value.contains(.connecting))
        XCTAssertEqual(Array(widget.seenRequests.prefix(2)), [10, 3])

        let a = frame(1)
        device.submit(port: 1, data: a)
        XCTAssertTrue(waitFor(3) { widget.lastFrame() == a })
        XCTAssertGreaterThanOrEqual(device.snapshot.stats.framesSent, 1)
        XCTAssertEqual(OutputHealth.summarize([device.snapshot], universes: ["test": [1]]).title, "DMX USB Pro")
    }

    func testBurstOfFramesCoalescesToTheNewest() throws {
        let widget = try XCTUnwrap(FakeWidget(.enttecPro))
        defer { widget.unplug() }
        let device = EnttecProDevice(id: "burst", options: Self.fastOptions(), locate: { widget.path })
        device.start()
        defer { device.stop(flushTimeout: 0.1) }
        XCTAssertTrue(waitFor(5) { device.snapshot.state == .live })

        // The engine never waits: 300 submits return immediately, only the newest matters.
        let started = Date()
        for i in 0..<300 { device.submit(port: 1, data: frame(i)) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        let newest = frame(299)
        XCTAssertTrue(waitFor(3) { widget.lastFrame() == newest })
        XCTAssertLessThan(widget.frameCount(), 300)
        XCTAssertGreaterThan(device.snapshot.stats.framesCoalesced, 0)
    }

    func testUnplugIsDetectedAndReconnectResendsTheNewestFrame() throws {
        let first = try XCTUnwrap(FakeWidget(.enttecPro))
        let path = Locked<String?>(first.path)
        let device = EnttecProDevice(id: "plug", options: Self.fastOptions(), locate: { path.value })
        device.start()
        defer { device.stop(flushTimeout: 0.1) }
        XCTAssertTrue(waitFor(5) { device.snapshot.state == .live })
        device.submit(port: 1, data: frame(10))
        XCTAssertTrue(waitFor(3) { first.lastFrame() == self.frame(10) })

        // Unplug: the device node disappears and the pty hangs up.
        path.value = nil
        first.unplug()
        XCTAssertTrue(waitFor(2) { device.snapshot.state != .live }, "unplug not detected")
        XCTAssertTrue(waitFor(2) { device.snapshot.isUnplugged })
        XCTAssertEqual(OutputHealth.summarize([device.snapshot]).title, "DMX box unplugged")

        // The show keeps running while unplugged…
        let newest = frame(42)
        device.submit(port: 1, data: newest)

        // …and when the box comes back, it gets the current look without another submit.
        let second = try XCTUnwrap(FakeWidget(.enttecPro))
        defer { second.unplug() }
        path.value = second.path
        device.reconnectNow()
        XCTAssertTrue(waitFor(5) { device.snapshot.state == .live }, "state: \(device.snapshot.state)")
        XCTAssertTrue(waitFor(3) { second.lastFrame() == newest })
        XCTAssertGreaterThanOrEqual(device.snapshot.stats.reconnects, 1)
    }

    func testBusyPortSaysAnotherAppIsUsingTheBox() throws {
        guard geteuid() != 0 else { throw XCTSkip("root ignores exclusive tty access") }
        let widget = try XCTUnwrap(FakeWidget(.enttecPro))
        defer { widget.unplug() }
        // Another app holds the port exclusively.
        XCTAssertEqual(ioctl(widget.heldSlave, TTYIoctl.exclusive), 0)
        let device = EnttecProDevice(id: "busy", options: Self.fastOptions(), locate: { widget.path })
        device.start()
        defer { device.stop(flushTimeout: 0.1) }
        XCTAssertTrue(waitFor(3) { device.snapshot.state == .busy }, "state: \(device.snapshot.state)")
        XCTAssertTrue(device.snapshot.message.contains("Another app is using your DMX box"))
        let summary = OutputHealth.summarize([device.snapshot])
        XCTAssertEqual(summary.level, .error)
        XCTAssertEqual(summary.title, "DMX box busy")

        // The other app quits: Prism connects by itself.
        XCTAssertEqual(ioctl(widget.heldSlave, TTYIoctl.nonExclusive), 0)
        XCTAssertTrue(waitFor(5) { device.snapshot.state == .live }, "state: \(device.snapshot.state)")
    }

    func testSilentDeviceIsReportedAsNotRecognized() throws {
        let widget = try XCTUnwrap(FakeWidget(.mute))
        defer { widget.unplug() }
        let device = EnttecProDevice(id: "mute", options: Self.fastOptions(), locate: { widget.path })
        device.start()
        defer { device.stop(flushTimeout: 0.1) }
        XCTAssertTrue(waitFor(4) { device.snapshot.state == .unsupported }, "state: \(device.snapshot.state)")
        XCTAssertTrue(device.snapshot.message.contains("Open DMX"))
    }

    func testDMXkingProUsesBothPorts() throws {
        let widget = try XCTUnwrap(FakeWidget(.dmxKingPro))
        defer { widget.unplug() }
        let device = EnttecProDevice(id: "king", options: Self.fastOptions(), locate: { widget.path })
        device.start()
        defer { device.stop(flushTimeout: 0.1) }
        XCTAssertTrue(waitFor(5) { device.snapshot.state == .live })
        XCTAssertEqual(device.snapshot.portCount, 2)
        XCTAssertEqual(device.snapshot.name, "DMXking ultraDMX Pro")
        let a = frame(5), b = frame(6)
        device.submit(port: 1, data: a)
        device.submit(port: 2, data: b)
        XCTAssertTrue(waitFor(3) { widget.lastFrame(label: 100) == a && widget.lastFrame(label: 101) == b })
        XCTAssertEqual(widget.frameCount(label: 6), 0)
    }

    func testStopIsBoundedWhileSearching() {
        let device = EnttecProDevice(id: "none", options: Self.fastOptions(), locate: { nil })
        device.start()
        XCTAssertTrue(waitFor(2) { device.snapshot.state == .searching })
        let started = Date()
        device.stop(flushTimeout: 0.1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertTrue(waitFor(1) { device.snapshot.state == .stopped })
    }

    func testOpenDMXStreamsStartCodeAndSlots() throws {
        let widget = try XCTUnwrap(FakeWidget(.raw))
        defer { widget.unplug() }
        var options = OpenDMXDevice.Options()
        options.baud = 115_200 // ptys can't do 250 kbaud; the framing is what's under test
        let device = OpenDMXDevice(id: "open", options: options, locate: { widget.path })
        let a = frame(77)
        device.submit(port: 1, data: a)
        device.start()
        defer { device.stop(flushTimeout: 0.1) }
        XCTAssertTrue(waitFor(3) { device.snapshot.state == .live })
        XCTAssertTrue(waitFor(3) { widget.raw.count >= 513 * 3 })
        let raw = widget.raw
        let complete = raw.count / 513
        let last = Array(raw[((complete - 1) * 513)..<(complete * 513)])
        XCTAssertEqual(last, [0] + a)
    }

    // MARK: - Art-Net / sACN over UDP loopback

    private func receive(on socket: UDPSocket, timeout: Double, where accept: ([UInt8]) -> Bool) -> [UInt8]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            _ = IOWait.wait(fd: socket.fd, read: true, write: false, wakeFD: -1, timeout: 0.05)
            while let (bytes, _) = socket.receive() {
                if accept(bytes) { return bytes }
            }
        }
        return nil
    }

    private let loopback: @Sendable () -> [NetworkInterface] = {
        [NetworkInterface(name: "lo", address: .loopback, netmask: IPv4(255, 0, 0, 0), isLoopback: true)]
    }

    func testArtNetUnicastLoopback() throws {
        let receiver = try XCTUnwrap(UDPSocket.open(port: 0, shared: false))
        var settings = ArtNetSettings()
        settings.enabled = true
        settings.mode = .unicast
        settings.unicastAddress = "127.0.0.1"
        let device = NetworkDMXDevice(transport: .artNet(settings), interfaces: loopback,
                                      destinationPort: receiver.boundPort, listenPort: nil)
        device.start()
        defer { device.stop(flushTimeout: 0.1) }
        let a = frame(3)
        device.submit(port: 2, data: a)
        let packet = receive(on: receiver, timeout: 3) { ArtNet.parseDMX($0)?.data == a }
        let dmx = try XCTUnwrap(packet.flatMap(ArtNet.parseDMX))
        XCTAssertEqual(dmx.address, ArtNet.PortAddress(prismUniverse: 2))
        XCTAssertGreaterThan(dmx.sequence, 0)
        XCTAssertTrue(waitFor(2) { device.snapshot.state == .live })
        XCTAssertEqual(device.snapshot.path, "To 127.0.0.1")
    }

    func testSACNUnicastLoopbackAndTermination() throws {
        let receiver = try XCTUnwrap(UDPSocket.open(port: 0, shared: false))
        var settings = SACNSettings()
        settings.enabled = true
        settings.mode = .unicast
        settings.unicastAddress = "127.0.0.1"
        settings.priority = 150
        let device = NetworkDMXDevice(transport: .sACN(settings), interfaces: loopback,
                                      destinationPort: receiver.boundPort)
        device.start()
        let a = frame(9)
        device.submit(port: 1, data: a)
        let packet = receive(on: receiver, timeout: 3) { SACN.parseDataPacket($0)?.slots == a }
        let data = try XCTUnwrap(packet.flatMap(SACN.parseDataPacket))
        XCTAssertEqual(data.universe, 1)
        XCTAssertEqual(data.priority, 150)
        XCTAssertEqual(data.sourceName, "Prism")
        XCTAssertEqual(data.cid, SACN.cidBytes(settings.cid))
        device.stop(flushTimeout: 0.1, terminateStreams: true)
        let terminated = receive(on: receiver, timeout: 2) { SACN.parseDataPacket($0)?.isStreamTerminated == true }
        XCTAssertNotNil(terminated)
    }
}
