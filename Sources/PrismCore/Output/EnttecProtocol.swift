import Foundation

// ENTTEC DMX USB Pro protocol (and the widely used compatible extensions).
// Source: ENTTEC "DMX USB Pro Widget API" v1.44, OLA, docs/research/macos_systems.md §1.
// Everything here is pure Swift: framing, an incremental parser that resynchronises after
// garbage, reply decoders and widget classification. Unit-tested on Linux.

/// ENTTEC DMX USB Pro API message labels, plus DMXking and Pro Mk2 extensions.
public enum EnttecLabel: UInt8, Sendable, CaseIterable {
    /// Drops the widget into its bootloader. Prism never sends it.
    case reprogramFirmware = 1
    /// Firmware flashing. Prism never sends it.
    case programFlashPage = 2
    case getWidgetParameters = 3
    case setWidgetParameters = 4
    case receivedDMX = 5
    case outputOnlySendDMX = 6
    case sendRDM = 7
    case receiveDMXOnChange = 8
    case changeOfState = 9
    case getSerialNumber = 10
    case sendRDMDiscovery = 11
    case rdmTimeout = 12
    /// Pro Mk2: unlocks the second port's labels.
    case mk2APIKey = 13
    /// Pro Mk2: hardware version (2 = Mk2, 3 = Mk2 rev B).
    case hardwareVersion = 14
    /// "USB Pro extensions" (DMXking, JESE, Goddard, OLA): ESTA manufacturer ID + name.
    case manufacturer = 77
    /// "USB Pro extensions": device ID + name.
    case device = 78
    /// DMXking ultraDMX Pro: DMX for port A / port B.
    case dmxKingPortA = 100
    case dmxKingPortB = 101
}

/// One complete message received from (or sent to) a Pro-compatible widget.
public struct EnttecMessage: Equatable, Sendable {
    public let label: UInt8
    public let payload: [UInt8]

    public init(label: UInt8, payload: [UInt8]) {
        self.label = label
        self.payload = payload
    }
}

/// Message framing: `7E label lenLSB lenMSB data… E7`.
public enum EnttecPro {
    public static let startOfMessage: UInt8 = 0x7E
    public static let endOfMessage: UInt8 = 0xE7
    /// Largest data length the API allows in one message.
    public static let maxPayload = 600
    /// DMX512 universes are always sent with at least this many slots (short universes make
    /// some fixtures misbehave because the refresh gets too fast).
    public static let minSlots = 24
    public static let maxSlots = 512

    /// Frames one message. Payloads longer than `maxPayload` are truncated (never traps).
    public static func message(label: UInt8, payload: [UInt8] = []) -> [UInt8] {
        let count = min(payload.count, maxPayload)
        var out = [UInt8]()
        out.reserveCapacity(count + 5)
        out.append(startOfMessage)
        out.append(label)
        out.append(UInt8(truncatingIfNeeded: count))
        out.append(UInt8(truncatingIfNeeded: count >> 8))
        if count == payload.count {
            out.append(contentsOf: payload)
        } else {
            out.append(contentsOf: payload.prefix(count))
        }
        out.append(endOfMessage)
        return out
    }

    /// A DMX output message: start code + 24…512 slots.
    ///
    /// The number of slots sent is `slots.count` clamped to 24…512 (short universes are padded
    /// with zeros, long ones truncated); the length tells the widget the universe size.
    /// - Parameters:
    ///   - label: 6 for a Pro (port 1), 100/101 for DMXking ultraDMX Pro, or the Mk2 port-2 label.
    ///   - startCode: 0 for dimmer data (anything else is an alternate start code packet).
    public static func dmx(_ slots: [UInt8], label: UInt8 = EnttecLabel.outputOnlySendDMX.rawValue,
                           startCode: UInt8 = 0) -> [UInt8] {
        let n = min(max(slots.count, minSlots), maxSlots)
        var out = [UInt8]()
        out.reserveCapacity(n + 6)
        out.append(startOfMessage)
        out.append(label)
        let length = n + 1
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(startCode)
        let copied = min(slots.count, n)
        out.append(contentsOf: slots.prefix(copied))
        if copied < n { out.append(contentsOf: repeatElement(0, count: n - copied)) }
        out.append(endOfMessage)
        return out
    }

    /// Label 3 request with no user-configuration bytes.
    public static let getParameters = message(label: EnttecLabel.getWidgetParameters.rawValue, payload: [0, 0])
    /// Label 10 request.
    public static let getSerial = message(label: EnttecLabel.getSerialNumber.rawValue)
    /// Label 77 request (ignored by genuine ENTTEC widgets).
    public static let getManufacturer = message(label: EnttecLabel.manufacturer.rawValue)
    /// Label 78 request (ignored by genuine ENTTEC widgets).
    public static let getDevice = message(label: EnttecLabel.device.rawValue)
    /// Label 14 request (answered by the Pro Mk2).
    public static let getHardwareVersion = message(label: EnttecLabel.hardwareVersion.rawValue)

    /// Label 4 with no user-config bytes. Writes the widget's non-volatile memory, so only send
    /// it when the user asks. `breakTime`/`mabTime` are in 10.67 µs units; `rate` 0 = fastest.
    public static func setParameters(breakTime: UInt8, mabTime: UInt8, rate: UInt8) -> [UInt8] {
        message(label: EnttecLabel.setWidgetParameters.rawValue,
                payload: [0, 0, min(max(breakTime, 9), 127), min(max(mabTime, 1), 127), min(rate, 40)])
    }

    /// Label 8: 0 = report every received frame (label 5), 1 = report changes only (label 9).
    public static func receiveOnChange(_ onlyChanges: Bool) -> [UInt8] {
        message(label: EnttecLabel.receiveDMXOnChange.rawValue, payload: [onlyChanges ? 1 : 0])
    }
}

/// Incremental parser: feed it whatever `read()` returned and get back complete messages.
///
/// It scans for the start byte, validates the length and the end byte, and when a candidate
/// turns out to be garbage it rescans from the byte after the false start, so a real message
/// that follows noise is never swallowed. Memory is bounded (one maximal message).
public struct EnttecParser: Sendable {
    private var buffer: [UInt8] = []
    /// Bytes skipped while resynchronising (diagnostics).
    public private(set) var droppedBytes = 0

    public init() {}

    /// True while a message has started but not finished.
    public var hasPartialMessage: Bool { !buffer.isEmpty }

    /// Upper bound for a reply's data length, per label (anything longer is not a real start).
    static func maxLength(for label: UInt8) -> Int {
        switch label {
        case EnttecLabel.getSerialNumber.rawValue, EnttecLabel.hardwareVersion.rawValue: return 16
        case EnttecLabel.manufacturer.rawValue, EnttecLabel.device.rawValue: return 64
        case EnttecLabel.changeOfState.rawValue: return 46
        case EnttecLabel.receivedDMX.rawValue: return 514
        default: return EnttecPro.maxPayload
        }
    }

    public mutating func feed<S: Sequence>(_ bytes: S) -> [EnttecMessage] where S.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        return scan()
    }

    /// Gives up on a message that started but never finished (call when the line has been
    /// quiet for a while) and rescans what's left. Returns any messages found behind it.
    public mutating func resync() -> [EnttecMessage] {
        guard !buffer.isEmpty else { return [] }
        buffer.removeFirst()
        droppedBytes += 1
        return scan()
    }

    private mutating func scan() -> [EnttecMessage] {
        var out: [EnttecMessage] = []
        var i = 0
        let n = buffer.count
        while i < n {
            guard buffer[i] == EnttecPro.startOfMessage else {
                i += 1
                droppedBytes += 1
                continue
            }
            guard n - i >= 4 else { break }                           // need the header
            let label = buffer[i + 1]
            let length = Int(buffer[i + 2]) | Int(buffer[i + 3]) << 8
            if length > EnttecParser.maxLength(for: label) {          // not a real start: rescan
                i += 1
                droppedBytes += 1
                continue
            }
            let total = length + 5
            guard n - i >= total else { break }                       // wait for the rest
            if buffer[i + total - 1] == EnttecPro.endOfMessage {
                out.append(EnttecMessage(label: label, payload: Array(buffer[(i + 4)..<(i + 4 + length)])))
                i += total
            } else {                                                  // bad end byte: rescan
                i += 1
                droppedBytes += 1
            }
        }
        if i > 0 { buffer.removeFirst(min(i, buffer.count)) }
        return out
    }
}

/// Decoded label 3 reply.
public struct EnttecParameters: Equatable, Sendable {
    /// LSB = version, MSB = firmware type (1 = DMX only, 2 = RDM, 3 = RDM sniffer).
    public let firmware: UInt16
    /// Break time in 10.67 µs units.
    public let breakTime: UInt8
    /// Mark-after-break time in 10.67 µs units.
    public let mabTime: UInt8
    /// Packets per second the widget transmits (0 = as fast as possible).
    public let rate: UInt8

    public init(firmware: UInt16, breakTime: UInt8, mabTime: UInt8, rate: UInt8) {
        self.firmware = firmware
        self.breakTime = breakTime
        self.mabTime = mabTime
        self.rate = rate
    }

    public init?(label3Reply p: [UInt8]) {
        guard p.count >= 5 else { return nil }
        firmware = UInt16(p[0]) | UInt16(p[1]) << 8
        breakTime = p[2]
        mabTime = p[3]
        rate = p[4]
    }

    public var breakMicroseconds: Double { Double(breakTime) * 10.67 }
    public var mabMicroseconds: Double { Double(mabTime) * 10.67 }
    /// e.g. "2.4".
    public var firmwareVersion: String { "\(firmware >> 8).\(firmware & 0xFF)" }
    /// True when the widget would refresh the rig noticeably slowly (rate 1…19 fps).
    public var isSlowRefresh: Bool { rate != 0 && rate < 20 }
    /// Short technical summary, e.g. "Break 96 µs · MAB 11 µs · 40 fps".
    public var timingSummary: String {
        let rateText = rate == 0 ? "max rate" : "\(rate) fps"
        return "Break \(Int(breakMicroseconds.rounded())) µs · MAB \(Int(mabMicroseconds.rounded())) µs · \(rateText)"
    }
}

/// Reply decoders.
public enum EnttecDecode {
    /// Label 10 reply: 4 BCD bytes, least-significant first, e.g. "01234567"; nil when unset
    /// (`FF FF FF FF` on old widgets) or too short.
    public static func serial(_ p: [UInt8]) -> String? {
        guard p.count >= 4 else { return nil }
        let bytes = Array(p[0..<4])
        guard bytes != [0xFF, 0xFF, 0xFF, 0xFF], bytes != [0, 0, 0, 0] else { return nil }
        let hex = "0123456789ABCDEF".map { $0 }
        var s = ""
        for b in bytes.reversed() {
            s.append(hex[Int(b >> 4)])
            s.append(hex[Int(b & 0x0F)])
        }
        return s
    }

    /// Labels 77/78 reply: (ID, name).
    public static func idAndName(_ p: [UInt8]) -> ESTAIdentity? {
        guard p.count >= 2 else { return nil }
        let id = UInt16(p[0]) | UInt16(p[1]) << 8
        let nameBytes = p.dropFirst(2).prefix { $0 != 0 }.prefix(32)
        let name = String(decoding: nameBytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return ESTAIdentity(id: id, name: name)
    }

    /// Label 14 reply.
    public static func hardwareVersion(_ p: [UInt8]) -> UInt8? { p.first }

    /// Label 5: (start code, slots), or nil when the status byte flags a corrupt packet.
    public static func receivedDMX(_ p: [UInt8]) -> (startCode: UInt8, slots: [UInt8])? {
        guard p.count >= 2, p[0] == 0 else { return nil }
        return (p[1], Array(p.dropFirst(2)))
    }

    /// Label 9: applies a change-of-state message to a 513-byte buffer (index 0 = start code).
    public static func applyChangeOfState(_ p: [UInt8], to buffer: inout [UInt8]) {
        guard p.count >= 6 else { return }
        let base = Int(p[0]) * 8
        var k = 6
        for i in 0..<40 where p[1 + i / 8] & (1 << (i % 8)) != 0 {
            guard k < p.count, base + i < buffer.count else { return }
            buffer[base + i] = p[k]
            k += 1
        }
    }
}

/// An ESTA manufacturer or device ID with its name (labels 77/78).
public struct ESTAIdentity: Equatable, Sendable {
    public var id: UInt16
    public var name: String

    public init(id: UInt16, name: String) {
        self.id = id
        self.name = name
    }
}

/// DMXking IDs (OLA `WidgetDetectorThread.h`).
public enum DMXKing {
    public static let estaID: UInt16 = 0x6A6B
    public static let dongleID: UInt16 = 0
    public static let ultraDMXID: UInt16 = 1
    /// The two-port ultraDMX Pro: port A on label 100, port B on label 101.
    public static let ultraDMXProID: UInt16 = 2
    public static let ultraDMXMicroID: UInt16 = 3
    public static let ultraDMXRDMProID: UInt16 = 4
}

/// The extra handshake the ENTTEC DMX USB Pro Mk2 needs before its second port works.
///
/// ENTTEC hands each developer an API key together with the label numbers that go with it.
/// The defaults are the publicly published set from the MIT-licensed
/// `dgtlworkshop/enttec-usb-pro-mk2-js`. The second port is opt-in in Prism: when it's off,
/// a Mk2 is driven exactly like a single-universe Pro and none of this is ever sent.
public struct EnttecMk2Profile: Equatable, Sendable {
    public var apiKey: UInt32
    public var portAssignmentLabel: UInt8
    public var port2SendLabel: UInt8

    public init(apiKey: UInt32, portAssignmentLabel: UInt8, port2SendLabel: UInt8) {
        self.apiKey = apiKey
        self.portAssignmentLabel = portAssignmentLabel
        self.port2SendLabel = port2SendLabel
    }

    public static let `default` = EnttecMk2Profile(apiKey: 0xE403_A4C9, portAssignmentLabel: 0x93, port2SendLabel: 0xCA)

    /// Label 13 with the key, little-endian.
    public var apiKeyMessage: [UInt8] {
        EnttecPro.message(label: EnttecLabel.mk2APIKey.rawValue,
                          payload: [UInt8(truncatingIfNeeded: apiKey), UInt8(truncatingIfNeeded: apiKey >> 8),
                                    UInt8(truncatingIfNeeded: apiKey >> 16), UInt8(truncatingIfNeeded: apiKey >> 24)])
    }

    /// Port assignment: both ports enabled for DMX output.
    public var enableBothPortsMessage: [UInt8] {
        EnttecPro.message(label: portAssignmentLabel, payload: [1, 1])
    }
}

/// What a Pro-compatible widget turned out to be after identification.
public struct EnttecWidgetIdentity: Equatable, Sendable {
    public enum Family: String, Sendable {
        case enttecPro
        case enttecProMk2
        case dmxKing
        case compatible
    }

    public var family: Family
    /// The widget's own serial number (label 10), e.g. "01234567".
    public var serialNumber: String?
    public var parameters: EnttecParameters?
    public var hardwareVersion: UInt8?
    public var manufacturer: ESTAIdentity?
    public var device: ESTAIdentity?
    /// Label used to send DMX on each port (index 0 = port 1).
    public var portLabels: [UInt8]
    /// Full product name, e.g. "ENTTEC DMX USB Pro".
    public var displayName: String
    /// Compact name for the toolbar, e.g. "DMX USB Pro".
    public var shortName: String

    public var portCount: Int { portLabels.count }

    public init(family: Family, serialNumber: String? = nil, parameters: EnttecParameters? = nil,
                hardwareVersion: UInt8? = nil, manufacturer: ESTAIdentity? = nil, device: ESTAIdentity? = nil,
                portLabels: [UInt8] = [EnttecLabel.outputOnlySendDMX.rawValue],
                displayName: String, shortName: String) {
        self.family = family
        self.serialNumber = serialNumber
        self.parameters = parameters
        self.hardwareVersion = hardwareVersion
        self.manufacturer = manufacturer
        self.device = device
        self.portLabels = portLabels
        self.displayName = displayName
        self.shortName = shortName
    }

    /// Classifies a widget from its identification replies (label → payload). Returns nil when
    /// nothing answered (not Pro-compatible, or an Open DMX that has no microcontroller).
    /// - Parameter mk2SecondPort: label for the Mk2's second port, when the user turned it on
    ///   and the handshake was sent; nil keeps a Mk2 single-universe.
    public static func classify(replies: [UInt8: [UInt8]], usbProductName: String? = nil,
                                mk2SecondPort: UInt8? = nil) -> EnttecWidgetIdentity? {
        let serialReply = replies[EnttecLabel.getSerialNumber.rawValue]
        let paramsReply = replies[EnttecLabel.getWidgetParameters.rawValue]
        let manufacturer = replies[EnttecLabel.manufacturer.rawValue].flatMap(EnttecDecode.idAndName)
        let device = replies[EnttecLabel.device.rawValue].flatMap(EnttecDecode.idAndName)
        let hw = replies[EnttecLabel.hardwareVersion.rawValue].flatMap(EnttecDecode.hardwareVersion)
        guard serialReply != nil || paramsReply != nil || manufacturer != nil || device != nil else { return nil }

        let serial = serialReply.flatMap(EnttecDecode.serial)
        let params = paramsReply.flatMap(EnttecParameters.init(label3Reply:))
        let port1 = EnttecLabel.outputOnlySendDMX.rawValue

        if let m = manufacturer, m.id == DMXKing.estaID {
            let deviceName = (device?.name).flatMap { $0.isEmpty ? nil : $0 } ?? "ultraDMX"
            let twoPorts = device?.id == DMXKing.ultraDMXProID
            return EnttecWidgetIdentity(
                family: .dmxKing, serialNumber: serial, parameters: params, hardwareVersion: hw,
                manufacturer: m, device: device,
                portLabels: twoPorts ? [EnttecLabel.dmxKingPortA.rawValue, EnttecLabel.dmxKingPortB.rawValue] : [port1],
                displayName: "DMXking \(deviceName)", shortName: deviceName)
        }
        if let m = manufacturer, !m.name.isEmpty || device != nil {
            let deviceName = (device?.name).flatMap { $0.isEmpty ? nil : $0 } ?? "USB DMX"
            let maker = m.name.isEmpty ? "" : m.name + " "
            return EnttecWidgetIdentity(
                family: .compatible, serialNumber: serial, parameters: params, hardwareVersion: hw,
                manufacturer: m, device: device, portLabels: [port1],
                displayName: maker + deviceName, shortName: deviceName)
        }
        if let hw, hw == 2 || hw == 3 {
            var labels = [port1]
            if let second = mk2SecondPort { labels.append(second) }
            return EnttecWidgetIdentity(
                family: .enttecProMk2, serialNumber: serial, parameters: params, hardwareVersion: hw,
                manufacturer: nil, device: nil, portLabels: labels,
                displayName: "ENTTEC DMX USB Pro Mk2", shortName: "DMX USB Pro Mk2")
        }
        let product = usbProductName?.trimmingCharacters(in: .whitespaces) ?? ""
        let looksGeneric = product.isEmpty || product.uppercased().contains("DMX USB PRO") || product.uppercased().contains("FT232")
        return EnttecWidgetIdentity(
            family: .enttecPro, serialNumber: serial, parameters: params, hardwareVersion: hw,
            manufacturer: nil, device: nil, portLabels: [port1],
            displayName: looksGeneric ? "ENTTEC DMX USB Pro" : product,
            shortName: looksGeneric ? "DMX USB Pro" : product)
    }
}
