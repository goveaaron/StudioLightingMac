import XCTest
import Foundation
@testable import PrismCore

/// Byte-exact golden packets and pure logic of the output layer (Enttec, Art-Net, sACN,
/// routing, toolbar summary, Hardware Test plan).
final class OutputTests: XCTestCase {

    private func ramp(_ count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) } }

    // MARK: - Enttec framing (golden)

    func testLabel6FullUniverseGolden() {
        let slots = ramp(512)
        let p = EnttecPro.dmx(slots)
        XCTAssertEqual(p.count, 518)
        XCTAssertEqual(Array(p[0..<5]), [0x7E, 0x06, 0x01, 0x02, 0x00]) // SOM, label 6, length 513 LSB/MSB, start code
        XCTAssertEqual(Array(p[5..<517]), slots)
        XCTAssertEqual(p[517], 0xE7)
    }

    func testLabel6PartialUniverseIsPaddedTo24Slots() {
        let p = EnttecPro.dmx([255, 128, 1])
        XCTAssertEqual(p, [0x7E, 0x06, 25, 0x00, 0x00, 255, 128, 1] + [UInt8](repeating: 0, count: 21) + [0xE7])
    }

    func testLabel6TruncatesAndHonoursStartCodeAndLabel() {
        let p = EnttecPro.dmx(ramp(600), label: EnttecLabel.dmxKingPortB.rawValue, startCode: 0xCC)
        XCTAssertEqual(p.count, 518)
        XCTAssertEqual(Array(p[0..<5]), [0x7E, 101, 0x01, 0x02, 0xCC])
        XCTAssertEqual(Array(p[5..<517]), Array(ramp(600).prefix(512)))
        XCTAssertEqual(p.last, 0xE7)
    }

    func testRequestMessagesGolden() {
        XCTAssertEqual(EnttecPro.getSerial, [0x7E, 10, 0, 0, 0xE7])
        XCTAssertEqual(EnttecPro.getParameters, [0x7E, 3, 2, 0, 0, 0, 0xE7])
        XCTAssertEqual(EnttecPro.getManufacturer, [0x7E, 77, 0, 0, 0xE7])
        XCTAssertEqual(EnttecPro.getDevice, [0x7E, 78, 0, 0, 0xE7])
        XCTAssertEqual(EnttecPro.getHardwareVersion, [0x7E, 14, 0, 0, 0xE7])
        XCTAssertEqual(EnttecPro.setParameters(breakTime: 9, mabTime: 1, rate: 40), [0x7E, 4, 5, 0, 0, 0, 9, 1, 40, 0xE7])
        // Out-of-range values are clamped, oversize payloads truncated — never a trap.
        XCTAssertEqual(EnttecPro.setParameters(breakTime: 1, mabTime: 0, rate: 99), [0x7E, 4, 5, 0, 0, 0, 9, 1, 40, 0xE7])
        XCTAssertEqual(EnttecPro.message(label: 1, payload: [UInt8](repeating: 1, count: 700)).count, 605)
        XCTAssertEqual(EnttecMk2Profile.default.apiKeyMessage, [0x7E, 13, 4, 0, 0xC9, 0xA4, 0x03, 0xE4, 0xE7])
    }

    // MARK: - Enttec parsing

    static let serialReply: [UInt8] = [0x7E, 10, 4, 0, 0x67, 0x45, 0x23, 0x01, 0xE7]
    static let paramsReply: [UInt8] = [0x7E, 3, 5, 0, 0x2C, 0x01, 9, 1, 40, 0xE7]

    func testParserDecodesSerialAndParameters() {
        var parser = EnttecParser()
        let messages = parser.feed(Self.serialReply + Self.paramsReply)
        XCTAssertEqual(messages.map(\.label), [10, 3])
        XCTAssertEqual(EnttecDecode.serial(messages[0].payload), "01234567")
        let params = EnttecParameters(label3Reply: messages[1].payload)
        XCTAssertEqual(params?.firmwareVersion, "1.44")
        XCTAssertEqual(params?.timingSummary, "Break 96 µs · MAB 11 µs · 40 fps")
        XCTAssertEqual(params?.isSlowRefresh, false)
        XCTAssertEqual(EnttecParameters(firmware: 0x0100, breakTime: 9, mabTime: 1, rate: 10).isSlowRefresh, true)
        XCTAssertFalse(parser.hasPartialMessage)
    }

    func testParserHandlesByteByByteFeeds() {
        var parser = EnttecParser()
        var found: [EnttecMessage] = []
        for b in Self.paramsReply { found += parser.feed([b]) }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.label, 3)
    }

    func testParserResyncsAfterGarbageAndFalseStarts() {
        var parser = EnttecParser()
        // Noise, a start byte with an impossible length, and a false start whose end byte is wrong.
        let garbage: [UInt8] = [0x00, 0xFF, 0x7E, 10, 0xFF, 0x7F, 0x13, 0x7E, 0x03, 0x05, 0x00]
        let messages = parser.feed(garbage + Self.serialReply)
        XCTAssertEqual(messages.map(\.label), [10])
        XCTAssertEqual(messages.first.flatMap { EnttecDecode.serial($0.payload) }, "01234567")
        XCTAssertGreaterThan(parser.droppedBytes, 0)
    }

    func testResyncGivesUpOnATruncatedMessage() {
        var parser = EnttecParser()
        // A message that claims 16 bytes but stops after 2, followed by a real reply.
        XCTAssertTrue(parser.feed([0x7E, 0x05, 0x10, 0x00, 1, 2] + Self.serialReply).isEmpty)
        XCTAssertTrue(parser.hasPartialMessage)
        let recovered = parser.resync()
        XCTAssertEqual(recovered.map(\.label), [10])
    }

    func testDecodersRejectUnsetOrShortData() {
        XCTAssertNil(EnttecDecode.serial([0xFF, 0xFF, 0xFF, 0xFF]))
        XCTAssertNil(EnttecDecode.serial([0, 0, 0, 0]))
        XCTAssertNil(EnttecDecode.serial([1, 2]))
        XCTAssertNil(EnttecParameters(label3Reply: [1, 2, 3]))
        XCTAssertNil(EnttecDecode.idAndName([1]))
        let king = EnttecDecode.idAndName([0x6B, 0x6A] + Array("DMXking.com".utf8) + [0, 0x41])
        XCTAssertEqual(king, ESTAIdentity(id: 0x6A6B, name: "DMXking.com"))
        var buffer = [UInt8](repeating: 0, count: 513)
        EnttecDecode.applyChangeOfState([0, 0b0000_0110, 0, 0, 0, 0, 11, 22], to: &buffer)
        XCTAssertEqual(Array(buffer[0..<4]), [0, 11, 22, 0])
        EnttecDecode.applyChangeOfState([200, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], to: &buffer) // out of range: ignored
    }

    func testWidgetClassification() {
        let serial: [UInt8] = [0x67, 0x45, 0x23, 0x01]
        let params: [UInt8] = [0x2C, 0x01, 9, 1, 40]

        let pro = EnttecWidgetIdentity.classify(replies: [10: serial, 3: params])
        XCTAssertEqual(pro?.family, .enttecPro)
        XCTAssertEqual(pro?.shortName, "DMX USB Pro")
        XCTAssertEqual(pro?.displayName, "ENTTEC DMX USB Pro")
        XCTAssertEqual(pro?.portLabels, [6])
        XCTAssertEqual(pro?.serialNumber, "01234567")

        let mk2 = EnttecWidgetIdentity.classify(replies: [10: serial, 3: params, 14: [2]])
        XCTAssertEqual(mk2?.family, .enttecProMk2)
        XCTAssertEqual(mk2?.portCount, 1)
        let mk2Both = EnttecWidgetIdentity.classify(replies: [10: serial, 3: params, 14: [2]], mk2SecondPort: 0xCA)
        XCTAssertEqual(mk2Both?.portLabels, [6, 0xCA])

        let kingPro = EnttecWidgetIdentity.classify(replies: [
            10: serial, 3: params,
            77: [0x6B, 0x6A] + Array("DMXking.com".utf8),
            78: [0x02, 0x00] + Array("ultraDMX Pro".utf8),
        ])
        XCTAssertEqual(kingPro?.family, .dmxKing)
        XCTAssertEqual(kingPro?.displayName, "DMXking ultraDMX Pro")
        XCTAssertEqual(kingPro?.portLabels, [100, 101])

        let kingMicro = EnttecWidgetIdentity.classify(replies: [
            10: serial, 77: [0x6B, 0x6A] + Array("DMXking.com".utf8), 78: [0x03, 0x00] + Array("ultraDMX Micro".utf8),
        ])
        XCTAssertEqual(kingMicro?.portLabels, [6])
        XCTAssertEqual(kingMicro?.shortName, "ultraDMX Micro")

        let other = EnttecWidgetIdentity.classify(replies: [3: params, 77: [0x34, 0x12] + Array("Acme".utf8),
                                                            78: [0x01, 0x00] + Array("Box".utf8)])
        XCTAssertEqual(other?.family, .compatible)
        XCTAssertEqual(other?.displayName, "Acme Box")

        XCTAssertNil(EnttecWidgetIdentity.classify(replies: [:]))
        XCTAssertNil(EnttecWidgetIdentity.classify(replies: [5: [0, 0, 1, 2]]))
    }

    // MARK: - Art-Net (golden, spec offsets)

    func testArtDmxGolden() {
        let slots = ramp(512)
        let p = ArtNet.dmx(slots, address: ArtNet.PortAddress(prismUniverse: 1), sequence: 1)
        XCTAssertEqual(p.count, 530)
        XCTAssertEqual(Array(p[0..<8]), Array("Art-Net".utf8) + [0])
        XCTAssertEqual(Array(p[8..<10]), [0x00, 0x50])   // OpDmx, little-endian
        XCTAssertEqual(Array(p[10..<12]), [0x00, 14])    // ProtVer 14, big-endian
        XCTAssertEqual(p[12], 1)                         // Sequence
        XCTAssertEqual(p[13], 0)                         // Physical
        XCTAssertEqual(p[14], 0)                         // SubUni
        XCTAssertEqual(p[15], 0)                         // Net
        XCTAssertEqual(Array(p[16..<18]), [0x02, 0x00])  // Length 512, big-endian
        XCTAssertEqual(Array(p[18...]), slots)
    }

    func testArtNetPortAddressAndPadding() {
        let a = ArtNet.PortAddress(prismUniverse: 18)            // Port-Address 17 = 0:1:1
        XCTAssertEqual(a.value, 17)
        XCTAssertEqual(a.description, "0:1:1")
        let b = ArtNet.PortAddress(prismUniverse: 1, offset: 0x123)
        let p = ArtNet.dmx([1, 2, 3], address: b, sequence: 9)
        XCTAssertEqual(p[14], 0x23)
        XCTAssertEqual(p[15], 0x01)
        XCTAssertEqual(Array(p[16..<18]), [0, 4])                 // odd length padded to even
        XCTAssertEqual(Array(p[18...]), [1, 2, 3, 0])
        XCTAssertEqual(ArtNet.dmx([], address: a, sequence: 0).count, 20) // minimum 2 slots
        XCTAssertEqual(ArtNet.PortAddress(-5).value, 0)
        XCTAssertEqual(ArtNet.PortAddress(99_999).value, 0x7FFF)
        XCTAssertEqual(ArtNet.PortAddress(net: 1, subNet: 2, universe: 3).value, 0x123)
        XCTAssertEqual(ArtNet.nextSequence(after: 255), 1)
        XCTAssertEqual(ArtNet.nextSequence(after: 0), 1)
        XCTAssertEqual(ArtNet.nextSequence(after: 41), 42)
    }

    func testArtPollAndSyncGolden() {
        let poll = ArtNet.poll()
        XCTAssertEqual(poll.count, 22)
        XCTAssertEqual(Array(poll[8..<12]), [0x00, 0x20, 0x00, 14])
        XCTAssertEqual(ArtNet.opCode(of: poll), 0x2000)
        let sync = ArtNet.sync()
        XCTAssertEqual(sync.count, 14)
        XCTAssertEqual(Array(sync[8..<10]), [0x00, 0x52])
        XCTAssertNil(ArtNet.opCode(of: Array("Art-Nex".utf8) + [0, 0, 0x20]))
    }

    func testArtPollReplyRoundTripAndRejection() {
        let ip = IPv4(2, 0, 0, 10)
        let reply = ArtNet.pollReply(ip: ip, shortName: "Node 1", longName: "Studio Node",
                                     outputs: [ArtNet.PortAddress(0), ArtNet.PortAddress(1)])
        let node = ArtNet.parsePollReply(reply)
        XCTAssertEqual(node?.ip, ip)
        XCTAssertEqual(node?.shortName, "Node 1")
        XCTAssertEqual(node?.longName, "Studio Node")
        XCTAssertEqual(node?.outputs, [ArtNet.PortAddress(0), ArtNet.PortAddress(1)])
        XCTAssertNil(ArtNet.parsePollReply(Array(reply.prefix(100))))
        XCTAssertNil(ArtNet.parsePollReply(ArtNet.poll()))
        XCTAssertNil(ArtNet.parsePollReply([UInt8](repeating: 0x7E, count: 300)))
        let dmx = ArtNet.parseDMX(ArtNet.dmx([9, 8, 7, 6], address: ArtNet.PortAddress(5), sequence: 3))
        XCTAssertEqual(dmx, ArtNet.DMXPacket(sequence: 3, address: ArtNet.PortAddress(5), data: [9, 8, 7, 6]))
        XCTAssertNil(ArtNet.parseDMX(Array(ArtNet.dmx(ramp(10), address: .init(0), sequence: 1).prefix(20))))
    }

    // MARK: - sACN (golden, spec offsets)

    func testSACNDataPacketGolden() {
        let cid: [UInt8] = Array(1...16)
        let slots = ramp(512)
        let p = SACN.dataPacket(slots, universe: 1, sequence: 7, cid: cid, sourceName: "Prism", priority: 100)
        XCTAssertEqual(p.count, 638)
        XCTAssertEqual(Array(p[0..<4]), [0x00, 0x10, 0x00, 0x00])
        XCTAssertEqual(Array(p[4..<16]), [0x41, 0x53, 0x43, 0x2D, 0x45, 0x31, 0x2E, 0x31, 0x37, 0x00, 0x00, 0x00])
        XCTAssertEqual(Array(p[16..<18]), [0x72, 0x6E])         // root flags & length (622)
        XCTAssertEqual(Array(p[18..<22]), [0, 0, 0, 4])          // VECTOR_ROOT_E131_DATA
        XCTAssertEqual(Array(p[22..<38]), cid)
        XCTAssertEqual(Array(p[38..<40]), [0x72, 0x58])          // framing flags & length (600)
        XCTAssertEqual(Array(p[40..<44]), [0, 0, 0, 2])          // VECTOR_E131_DATA_PACKET
        XCTAssertEqual(Array(p[44..<49]), Array("Prism".utf8))
        XCTAssertEqual(p[49], 0)
        XCTAssertEqual(p[108], 100)                              // priority
        XCTAssertEqual(Array(p[109..<111]), [0, 0])              // sync address
        XCTAssertEqual(p[111], 7)                                // sequence
        XCTAssertEqual(p[112], 0)                                // options
        XCTAssertEqual(Array(p[113..<115]), [0, 1])              // universe
        XCTAssertEqual(Array(p[115..<117]), [0x72, 0x0B])        // DMP flags & length (523)
        XCTAssertEqual(p[117], 0x02)
        XCTAssertEqual(p[118], 0xA1)
        XCTAssertEqual(Array(p[119..<123]), [0, 0, 0, 1])        // first address, increment
        XCTAssertEqual(Array(p[123..<125]), [0x02, 0x01])        // 513 properties
        XCTAssertEqual(p[125], 0)                                // start code
        XCTAssertEqual(Array(p[126...]), slots)
    }

    func testSACNClampsAndAddresses() {
        let cid = SACN.cidBytes("not a uuid")
        XCTAssertEqual(cid.count, 16)
        XCTAssertEqual(SACN.cidBytes("6BA7B810-9DAD-11D1-80B4-00C04FD430C8").first, 0x6B)
        let p = SACN.dataPacket([1, 2, 3], universe: 70_000, sequence: 1, cid: cid, priority: 250)
        XCTAssertEqual(p.count, 129)
        XCTAssertEqual(p[108], 200)
        XCTAssertEqual(Array(p[113..<115]), [0xF9, 0xFF])         // 63999
        XCTAssertEqual(SACN.dataPacket([], universe: 0, sequence: 1, cid: cid)[114], 1)
        XCTAssertEqual(SACN.multicastAddress(universe: 1), IPv4(239, 255, 0, 1))
        XCTAssertEqual(SACN.multicastAddress(universe: 256).description, "239.255.1.0")
        XCTAssertEqual(SACN.universe(forPrismUniverse: 3, offset: 10), 13)
        let sync = SACN.syncPacket(syncAddress: 7, sequence: 2, cid: cid)
        XCTAssertEqual(sync.count, 49)
        XCTAssertEqual(Array(sync[16..<22]), [0x70, 0x21, 0, 0, 0, 8])
        XCTAssertEqual(Array(sync[38..<47]), [0x70, 0x0B, 0, 0, 0, 1, 2, 0, 7])
        let parsed = SACN.parseDataPacket(SACN.dataPacket([5, 6], universe: 9, sequence: 4, cid: cid,
                                                          options: SACN.optionStreamTerminated))
        XCTAssertEqual(parsed?.universe, 9)
        XCTAssertEqual(parsed?.slots, [5, 6])
        XCTAssertEqual(parsed?.isStreamTerminated, true)
        XCTAssertNil(SACN.parseDataPacket(Array(p.prefix(120))))
        XCTAssertNil(SACN.parseDataPacket(sync))
    }

    func testIPv4Parsing() {
        XCTAssertEqual(IPv4("192.168.1.50")?.description, "192.168.1.50")
        XCTAssertNil(IPv4("192.168.1"))
        XCTAssertNil(IPv4("192.168.1.256"))
        XCTAssertNil(IPv4("a.b.c.d"))
        XCTAssertNil(IPv4("1..2.3"))
        let en = NetworkInterface(name: "en0", address: IPv4(192, 168, 1, 20), netmask: IPv4(255, 255, 255, 0))
        XCTAssertEqual(en.broadcast, IPv4(192, 168, 1, 255))
        XCTAssertTrue(en.contains(IPv4(192, 168, 1, 99)))
        XCTAssertFalse(en.contains(IPv4(10, 0, 0, 1)))
        XCTAssertTrue(IPv4(239, 255, 0, 1).isMulticast)
    }

    // MARK: - Configuration & routing

    func testDefaultUniverseAssignment() {
        var config = OutputConfiguration()
        XCTAssertTrue(config.assignDefaults(deviceKey: "usb:A", portCount: 1, presentDevices: ["usb:A"]))
        XCTAssertEqual(config.universes(for: "usb:A"), [1: 1])
        XCTAssertFalse(config.assignDefaults(deviceKey: "usb:A", portCount: 1, presentDevices: ["usb:A"]))
        // A second box plugged in alongside gets the next universe.
        config.assignDefaults(deviceKey: "usb:B", portCount: 2, presentDevices: ["usb:A", "usb:B"])
        XCTAssertEqual(config.universes(for: "usb:B"), [1: 2, 2: 3])
        // A replacement box (the old one is gone) simply takes over universe 1.
        config.assignDefaults(deviceKey: "usb:C", portCount: 1, presentDevices: ["usb:C"])
        XCTAssertEqual(config.universes(for: "usb:C"), [1: 1])
        config.setUniverse(4, deviceKey: "usb:C", port: 1)
        XCTAssertEqual(config.universes(for: "usb:C"), [1: 4])
    }

    func testConfigurationDecodingIsTolerant() throws {
        var fallback = OutputConfiguration.decode(nil)
        fallback.sacn.cid = OutputConfiguration().sacn.cid
        XCTAssertEqual(fallback.bindings, [])
        XCTAssertEqual(fallback.keepAwake, true)
        XCTAssertNotNil(UUID(uuidString: OutputConfiguration.decode(nil).sacn.cid))
        XCTAssertEqual(OutputConfiguration.decode(Data("garbage".utf8)).keepAwake, true)
        let partial = OutputConfiguration.decode(Data(#"{"keepAwake": false, "artNet": {"enabled": true, "mode": "warp"}, "sacn": {"priority": 900, "cid": "x"}}"#.utf8))
        XCTAssertFalse(partial.keepAwake)
        XCTAssertTrue(partial.artNet.enabled)
        XCTAssertEqual(partial.artNet.mode, .automatic)
        XCTAssertEqual(partial.sacn.priority, 200)
        XCTAssertNotNil(UUID(uuidString: partial.sacn.cid))
        var config = OutputConfiguration()
        config.setUniverse(2, deviceKey: "usb:X", port: 1)
        config.disabledDevices = ["usb:Y"]
        config.sacn.enabled = true
        let round = OutputConfiguration.decode(config.encoded())
        XCTAssertEqual(round, config)
    }

    func testRoutedOutputForwardsOnlyItsUniverse() {
        let device = SimulatedDMXDevice(id: "sim", name: "Test Box")
        device.start()
        let output = RoutedOutput(device: device, port: 2, universe: 3)
        XCTAssertEqual(output.outputID, "sim#2")
        output.send(universe: 1, data: [1, 2, 3])
        XCTAssertNil(device.lastFrame(port: 2))
        output.send(universe: 3, data: [4, 5, 6])
        XCTAssertEqual(device.lastFrame(port: 2), [4, 5, 6])
        XCTAssertTrue(output.status.isConnected)
        device.setState(.busy)
        XCTAssertFalse(output.status.isConnected)
    }

    func testFrameSlotKeepsOnlyTheNewestFrame() {
        let slot = DMXFrameSlot(wake: nil)
        slot.submit(port: 1, data: [1], at: 1)
        slot.submit(port: 1, data: [2], at: 2)
        slot.submit(port: 1, data: [3], at: 3)
        XCTAssertEqual(slot.coalescedCount, 2)
        XCTAssertEqual(slot.take(port: 1)?.data, [3])
        XCTAssertNil(slot.take(port: 1))
        slot.submit(port: 1, data: [3], at: 4)                // unchanged: nothing to send
        XCTAssertNil(slot.take(port: 1))
        slot.restore(port: 1, frame: .init(data: [3], submittedAt: 3))
        slot.submit(port: 1, data: [4], at: 5)
        slot.restore(port: 1, frame: .init(data: [3], submittedAt: 3)) // newer frame wins
        XCTAssertEqual(slot.take(port: 1)?.data, [4])
        slot.markAllDirty(at: 6)
        XCTAssertEqual(slot.take(port: 1)?.data, [4])
        XCTAssertEqual(slot.latestFrame(port: 1), [4])
    }

    // MARK: - Toolbar summary

    private func device(_ id: String, _ state: DMXDeviceState, kind: DMXDeviceKind = .enttecPro,
                        hasBeenLive: Bool = false) -> DMXDeviceSnapshot {
        DMXDeviceSnapshot(id: id, kind: kind, name: kind == .enttecPro ? "ENTTEC DMX USB Pro" : kind.title,
                          shortName: kind == .enttecPro ? "DMX USB Pro" : kind.title, state: state,
                          hasBeenLive: hasBeenLive || state == .live)
    }

    func testSummaryStates() {
        XCTAssertEqual(OutputHealth.summarize([], noHardware: true).title, "Simulation")
        XCTAssertEqual(OutputHealth.summarize([]), .simulation)

        let live = OutputHealth.summarize([device("a", .live)], universes: ["a": [1]])
        XCTAssertEqual(live.level, .connected)
        XCTAssertEqual(live.title, "DMX USB Pro")
        XCTAssertEqual(live.detail, "Live · ENTTEC DMX USB Pro · universe 1")

        let busy = OutputHealth.summarize([device("a", .busy)])
        XCTAssertEqual(busy.level, .error)
        XCTAssertEqual(busy.title, "DMX box busy")
        XCTAssertTrue(busy.detail.contains("Lightkey"))
        XCTAssertEqual(OutputHealth.summarize([device("a", .busy), device("b", .live)]).level, .warning)

        let unplugged = OutputHealth.summarize([device("a", .searching, hasBeenLive: true)])
        XCTAssertEqual(unplugged.level, .warning)
        XCTAssertEqual(unplugged.title, "DMX box unplugged")

        XCTAssertEqual(OutputHealth.summarize([device("a", .searching)]), .simulation)
        XCTAssertEqual(OutputHealth.summarize([device("a", .connecting)]).title, "Connecting…")
        XCTAssertEqual(OutputHealth.summarize([device("a", .unsupported)]).level, .simulated)

        let two = OutputHealth.summarize([device("a", .live), device("artnet", .live, kind: .artNet)])
        XCTAssertEqual(two.title, "2 outputs live")
        XCTAssertEqual(two.level, .connected)

        let blocked = OutputHealth.summarize([device("artnet", .failed(NetworkSendProblem.blocked.message), kind: .artNet)])
        XCTAssertEqual(blocked.level, .warning)
        XCTAssertTrue(blocked.detail.contains("Local Network"))

        XCTAssertEqual(OutputHealth.universeList([1]), "universe 1")
        XCTAssertEqual(OutputHealth.universeList([3, 1, 2]), "universes 1–3")
        XCTAssertEqual(OutputHealth.universeList([1, 3]), "universes 1, 3")
    }

    func testDeviceStateMessagesArePlainEnglish() {
        XCTAssertTrue(DMXDeviceState.busy.message(deviceName: "DMX USB Pro", hasBeenLive: false).contains("Another app"))
        XCTAssertTrue(DMXDeviceState.searching.message(deviceName: "DMX USB Pro", hasBeenLive: true).contains("unplugged"))
        XCTAssertTrue(DMXDeviceState.unsupported.message(deviceName: "X", hasBeenLive: false).contains("Open DMX"))
        XCTAssertEqual(SerialPortError.fromOpen(errno: EBUSY), .busy)
        XCTAssertEqual(SerialPortError.fromOpen(errno: ENOENT), .notFound)
        XCTAssertEqual(SerialPortError.fromOpen(errno: EACCES), .permissionDenied)
        XCTAssertEqual(NetworkSendProblem(errno: EHOSTUNREACH), .blocked)
        XCTAssertEqual(NetworkSendProblem(errno: ENETUNREACH), .noNetwork)
    }

    // MARK: - Hardware Test plan

    private func demoFixtures() -> [ResolvedFixture] {
        DemoRig.londonStudio().resolvedFixtures(library: TestResources.library().definition)
    }

    func testSoloOverridesLightOnlyTheTarget() throws {
        let fixtures = demoFixtures()
        let ordered = HardwareTestPlan.order(fixtures)
        XCTAssertEqual(ordered.count, fixtures.filter { $0.fixture.address != nil }.count)
        XCTAssertEqual(ordered.map { $0.fixture.address ?? 0 }, ordered.map { $0.fixture.address ?? 0 }.sorted())
        let target = try XCTUnwrap(ordered.first)
        let overrides = HardwareTestPlan.soloOverrides(target: target.id, fixtures: fixtures)
        let targetRange = try XCTUnwrap(target.addressRange)
        let expected = FixtureRenderer.render(FixtureState(intensity: 0.3, color: .white), fixture: target)
        for o in overrides where o.universe == target.fixture.universe && targetRange.contains(o.address) {
            XCTAssertEqual(o.value, expected[o.address - targetRange.lowerBound])
        }
        XCTAssertTrue(expected.contains { $0 > 0 }, "the target must visibly light up")
        // Every other fixture is held at its rendered 'off' values.
        for other in ordered.dropFirst() {
            guard let range = other.addressRange else { continue }
            let off = FixtureRenderer.render(.off, fixture: other)
            for o in overrides where o.universe == other.fixture.universe && range.contains(o.address) && !targetRange.contains(o.address) {
                XCTAssertEqual(o.value, off[o.address - range.lowerBound])
            }
        }
        // Unique addresses, all valid.
        let keys = overrides.map { "\($0.universe):\($0.address)" }
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(overrides.allSatisfy { (1...512).contains($0.address) })
        XCTAssertEqual(HardwareTestPlan.universes(fixtures).first, 1)
    }

    func testChannelMapOwnershipAndConflicts() throws {
        var fixtures = demoFixtures()
        let map = ChannelMap(universe: 1, fixtures: fixtures)
        let first = try XCTUnwrap(HardwareTestPlan.order(fixtures).first(where: { $0.fixture.universe == 1 }))
        let start = try XCTUnwrap(first.fixture.address)
        XCTAssertEqual(map.owner(at: start)?.fixtureID, first.id)
        XCTAssertEqual(map.owner(at: start)?.channelIndex, 0)
        XCTAssertNil(map.owner(at: 0))
        XCTAssertNil(map.owner(at: 513))
        XCTAssertTrue(map.conflicts.isEmpty)
        XCTAssertGreaterThan(map.usedChannelCount, 0)
        // Overlap two fixtures and the shared addresses are reported.
        guard let other = fixtures.firstIndex(where: { $0.id != first.id }) else { return }
        fixtures[other].fixture.universe = 1
        fixtures[other].fixture.address = start
        let clash = ChannelMap(universe: 1, fixtures: fixtures)
        XCTAssertTrue(clash.conflicts.contains(start))
    }
}
