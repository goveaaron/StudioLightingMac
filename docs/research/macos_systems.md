# Prism — macOS Systems Technical Reference

Research notes for the people building Prism (SwiftUI DMX controller, macOS 14+, SwiftPM, built on
GitHub Actions, ad-hoc signed, not sandboxed, shipped through GitHub Releases).
Researched on **2026-11-06**. Nobody can compile locally, so every API signature here was checked
against the SDK headers, Apple technotes, the SwiftPM / swift-build sources, or working open-source
code (sources are listed in §10).

Legend: ✅ = checked against a primary source or working code · ⚠️ = not fully confirmed; check it on
hardware or in CI before relying on it.

Repo facts this doc assumes (taken from `Package.swift`): `swift-tools-version:5.10` (so Swift 5
language mode), package name `Prism`, macOS app target `PrismApp` built as executable product `Prism`,
SwiftNIO used for the remote server (`PrismServer`).

## Contents

1. [ENTTEC DMX USB Pro & compatible widgets](#1-enttec-dmx-usb-pro--compatible-widgets)
2. [Serial ports on macOS in Swift (IOKit + POSIX)](#2-serial-ports-on-macos-in-swift-iokit--posix)
3. [Art-Net 4 and sACN (E1.31)](#3-art-net-4-and-sacn-e131)
4. [App bundling, Info.plist, signing, Gatekeeper, TCC](#4-app-bundling-infoplist-signing-gatekeeper-tcc)
5. [Local Network privacy, embedded server, Bonjour, LAN IPs](#5-local-network-privacy-embedded-server-bonjour-lan-ips)
6. [GitHub Actions (macOS runners)](#6-github-actions-macos-runners)
7. [Cloudflare quick tunnels (and alternatives)](#7-cloudflare-quick-tunnels-and-alternatives)
8. [CoreMIDI and OSC](#8-coremidi-and-osc)
9. [Sleep prevention, launch at login, single instance](#9-sleep-prevention-launch-at-login-single-instance)
10. [Sources & open uncertainties](#10-sources--open-uncertainties)

---

## 1. ENTTEC DMX USB Pro & compatible widgets

### 1.1 Device family at a glance

| Device | USB side | macOS device node | Protocol | Notes |
|---|---|---|---|---|
| ENTTEC **DMX USB Pro** (70304) | FTDI FT245 FIFO, VID `0x0403` PID `0x6001`; product string `DMX USB PRO`, vendor `ENTTEC` | `/dev/cu.usbserial-EN……` (suffix = FTDI iSerial, e.g. `EN406708`) ✅ | ENTTEC Pro API (below) | The baud rate is a dummy value (the API doc says "install VCOM FT245BM driver… baud rate is a dummy value") ✅. Has its own MCU and frame buffer, so DMX timing does not depend on the Mac. |
| ENTTEC **DMX USB Pro Mk2** (70314, legacy) | FTDI `0403:6001` | same pattern | Pro API + extra port-2 labels that are unlocked with an API key | Two universes plus MIDI. Label 14 (hardware version) replies `2` (Mk2) or `3` (Mk2 rev B) — from OLA ✅ |
| ENTTEC **Open DMX USB** (70303) | FTDI FT232R UART, no MCU | `/dev/cu.usbserial-……` | none: the host bit-streams DMX at 250 kbaud 8N2 and makes the BREAK itself | Timing depends on the host. Doable on macOS without D2XX (§1.8). |
| DMXking **ultraDMX Micro / ultraDMX RDM Pro / ultraDMX Pro** (older) | FTDI `0403:6001` | `/dev/cu.usbserial-……` | ENTTEC Pro compatible; answers labels 77/78 with ESTA ID `0x6A6B` ✅ | The 2-port **ultraDMX Pro** sends port A on label **100** and port B on label **101** (OLA `UltraDMXProWidget`) ✅ |
| DMXking **ultraDMX MAX** and other newer MCU-based widgets | USB **CDC-ACM** class ("standard CDC drivers") | `/dev/cu.usbmodem……` (AppleUSBACMData) | ENTTEC Pro compatible | Matching only `usbserial` paths would miss these. Enumerate every `IOSerialBSDClient` and probe each one (§1.7). |

DMXking device IDs as reported by label 78 (from OLA `WidgetDetectorThread.h`) ✅: `0` = DMX512 dongle,
`1` = ultraDMX, `2` = ultraDMX Pro (2 ports), `3` = ultraDMX Micro, `4` = ultraDMX RDM Pro.
Other ESTA IDs OLA recognises: Goddard Design `0x4744`, JESE `0x6864`, Open Lighting `0x7A70`.

### 1.2 Message framing ✅ (ENTTEC "DMX USB Pro Widget API" v1.44)

Every message in either direction has this layout:

| Byte | Value |
|---|---|
| 0 | `0x7E` start-of-message |
| 1 | label (message type) |
| 2 | data length LSB |
| 3 | data length MSB (length 0…600) |
| 4…4+n-1 | data |
| 4+n | `0xE7` end-of-message |

### 1.3 Labels

| Label | Name | Direction | Payload |
|---|---|---|---|
| 1 | Reprogram Firmware request | host→widget | none (widget drops into its bootloader). **Never send this by accident.** |
| 2 | Program Flash Page | both | request: 64 bytes of a flash page; reply: 4 ASCII bytes `TRUE`/`FALS` |
| 3 | Get Widget Parameters | both | request: user-config size LSB, MSB (0…508). Reply: firmware LSB, firmware MSB, break time, MAB time, refresh rate, user config bytes |
| 4 | Set Widget Parameters | host→widget | user-config size LSB, MSB, break (9…127), MAB (1…127), rate (1…40, or 0 = as fast as possible), user config |
| 5 | Received DMX Packet | widget→host | status byte (bit0 = widget receive queue overflowed, bit1 = receive overrun; any non-zero value means the packet is corrupt) + 1…513 bytes that begin with the start code |
| 6 | Output Only Send DMX Packet | host→widget | start code + 24…512 slots (25…513 bytes). **The length sets the transmitted universe size.** |
| 7 | Send RDM Packet | host→widget | 1…513 bytes of RDM (start code 0xCC…) |
| 8 | Receive DMX on Change | host→widget | 1 byte: 0 = always send label 5 for every received frame, 1 = send only changes as label 9. Also resets the widget's internal receive buffer |
| 9 | Received DMX Change-of-State | widget→host | start changed-byte number (1 byte) + changed-bit array (5 bytes) + 1…40 changed data bytes |
| 10 | Get Widget Serial Number | both | request: none. Reply: 4 bytes **BCD, LSB first**; `FF FF FF FF` on old widgets with no serial set |
| 11 | Send RDM Discovery Request | host→widget | 38-byte DISC_UNIQUE_BRANCH request |
| 12 | RDM timeout | widget→host | sent when an RDM request times out (OLA `RDM_TIMEOUT_LABEL`) ✅ |
| 13 | Mk2 API key | host→widget | 4-byte little-endian API key. Unlocks the Mk2 port-2 labels (see 1.6) |
| 14 | Hardware version | both | reply: 1 byte (`2` = Pro Mk2, `3` = Mk2 rev B) (OLA) ✅ |
| 77 / 78 | Manufacturer / Device ("USB Pro extensions", used by DMXking, JESE, Goddard, OLA firmware) | both | request: none. Reply: ID low byte, ID high byte, ASCII name (up to 32 bytes) ✅ |
| 100 / 101 | DMXking ultraDMX Pro: send DMX to port A / port B | host→widget | same payload as label 6 ✅ (OLA) |
| 141 / 145 | Mk2 port assignment query / set (OLA) | both | `145` with data `{1, 1}` turns on both ports (OLA). Only works after the key is sent ⚠️ |

Firmware version (label 3 reply, MSB): `1` = DMX-only firmware, `2` = RDM firmware, `3` = RDM sniffer.
OLA turns on RDM when `firmware >= 0x0204` ✅. The widget's RDM UID is ESTA `0x454E` ("EN") followed
by the 4 serial bytes.

**Mode switching** ⚠️ (wording from the API doc): output keeps repeating at the configured rate after a
label 6. It stops and the port turns back into an input when the widget receives a request other than
label 6 (or label 3). So: identify the widget first (labels 10, 3, 77/78), then send nothing but label 6
frames while you are outputting.

### 1.4 Timing, refresh rate, and what happens if you send too fast

- The widget **owns DMX timing**. It sends the last frame it received over and over at the configured
  rate (label 4: 1–40 packets/s, or 0 = back to back), using its own BREAK/MAB settings. Units are
  10.67 µs: break 9–127 (≈96 µs–1.35 ms), MAB 1–127 (≈10.7 µs–1.35 ms) ✅. ENTTEC's marketing figures
  are "refresh 1–40 fps, break 96 µs–1.3 ms, MAB 10.6 µs–1.3 ms".
- A full 512-slot DMX frame takes about 22.7 ms on the wire, so the physical maximum is about 44 Hz.
  ENTTEC widgets top out at 40 fps.
- **Sending label 6 faster than the widget outputs just overwrites its buffer.** Frames in between are
  never transmitted, but no harm is done. The real risk is on the host: if you write faster than USB and
  the widget accept data, the driver's TX queue fills, `write()` returns `EAGAIN` (non-blocking fd), and
  latency builds up if you keep queueing.
  **Recommended strategy:** keep one "latest frame" buffer and send it from a dedicated output loop at
  at most 40 Hz (25 ms) when it changes, plus a keep-alive resend every ~1 s. If the fd is not writable
  when a tick comes around, skip that tick and send the newest frame on the next one. Never let a
  backlog build up.
- Only write label 4 when the user changes a setting, not on every connect. It writes to the widget's
  non-volatile memory.
- Always send at least 24 slots (pad with zeros). A shorter universe means a faster refresh, which some
  fixtures cannot handle.

### 1.5 Swift: frame encoder, stream parser, decoders ✅ (pure Swift, compiles on macOS & Linux)

```swift
import Foundation

/// ENTTEC DMX USB Pro API v1.44 labels (+ widely used extensions).
enum EnttecLabel: UInt8 {
    case reprogramFirmware     = 1   // never send by accident
    case programFlashPage      = 2
    case getWidgetParameters   = 3
    case setWidgetParameters   = 4
    case receivedDMX           = 5
    case outputOnlySendDMX     = 6
    case sendRDM               = 7
    case receiveDMXOnChange    = 8
    case changeOfState         = 9
    case getSerialNumber       = 10
    case sendRDMDiscovery      = 11
    case rdmTimeout            = 12
    case hardwareVersion       = 14
    case manufacturer          = 77  // reply: id_lo, id_hi, name[≤32]
    case device                = 78  // reply: id_lo, id_hi, name[≤32]
    case dmxKingPortA          = 100 // DMXking ultraDMX Pro
    case dmxKingPortB          = 101
}

enum EnttecPro {
    static let som: UInt8 = 0x7E
    static let eom: UInt8 = 0xE7
    static let maxPayload = 600

    static func message(label: UInt8, payload: [UInt8] = []) -> [UInt8] {
        precondition(payload.count <= maxPayload, "ENTTEC payload too large")
        var out = [UInt8]()
        out.reserveCapacity(payload.count + 5)
        out.append(som)
        out.append(label)
        out.append(UInt8(truncatingIfNeeded: payload.count))
        out.append(UInt8(truncatingIfNeeded: payload.count >> 8))
        out.append(contentsOf: payload)
        out.append(eom)
        return out
    }

    /// Label 6 (or DMXking 100/101): start code + 24…512 slots. Pads short universes to 24 slots.
    static func dmx(_ slots: [UInt8], label: EnttecLabel = .outputOnlySendDMX, startCode: UInt8 = 0) -> [UInt8] {
        let n = min(max(slots.count, 24), 512)
        var payload = [UInt8](repeating: 0, count: n + 1)
        payload[0] = startCode
        for i in 0..<min(slots.count, 512) { payload[i + 1] = slots[i] }
        return message(label: label.rawValue, payload: payload)
    }

    static let getParameters = message(label: EnttecLabel.getWidgetParameters.rawValue, payload: [0, 0])
    static let getSerial     = message(label: EnttecLabel.getSerialNumber.rawValue)
    static let getManufacturer = message(label: EnttecLabel.manufacturer.rawValue)
    static let getDevice     = message(label: EnttecLabel.device.rawValue)

    /// Label 4 with no user-config bytes. breakTime/mabTime in 10.67 µs units; rate 0 = fastest.
    static func setParameters(breakTime: UInt8, mabTime: UInt8, rate: UInt8) -> [UInt8] {
        message(label: EnttecLabel.setWidgetParameters.rawValue,
                payload: [0, 0, min(max(breakTime, 9), 127), min(max(mabTime, 1), 127), min(rate, 40)])
    }

    /// Label 8: 0 = report every received frame (label 5), 1 = report changes only (label 9).
    static func receiveOnChange(_ onlyChanges: Bool) -> [UInt8] {
        message(label: EnttecLabel.receiveDMXOnChange.rawValue, payload: [onlyChanges ? 1 : 0])
    }
}

struct EnttecMessage: Equatable {
    let label: UInt8
    let payload: [UInt8]
}

/// Incremental parser: feed it whatever `read()` returned and get back the complete messages.
struct EnttecParser {
    private enum State { case start, label, lenLo, lenHi, data, end }
    private var state: State = .start
    private var label: UInt8 = 0
    private var length = 0
    private var buffer: [UInt8] = []

    mutating func feed<S: Sequence>(_ bytes: S) -> [EnttecMessage] where S.Element == UInt8 {
        var messages: [EnttecMessage] = []
        for byte in bytes {
            switch state {
            case .start:
                if byte == EnttecPro.som { state = .label }
            case .label:
                label = byte
                state = .lenLo
            case .lenLo:
                length = Int(byte)
                state = .lenHi
            case .lenHi:
                length |= Int(byte) << 8
                buffer.removeAll(keepingCapacity: true)
                if length > EnttecPro.maxPayload { state = .start }      // garbage: resync
                else { state = length == 0 ? .end : .data }
            case .data:
                buffer.append(byte)
                if buffer.count == length { state = .end }
            case .end:
                if byte == EnttecPro.eom { messages.append(EnttecMessage(label: label, payload: buffer)) }
                state = .start                                          // bad EOM: drop & resync
            }
        }
        return messages
    }
}

struct EnttecParameters {
    let firmware: UInt16          // MSB: 1 = DMX, 2 = RDM, 3 = RDM sniffer
    let breakMicros: Double
    let mabMicros: Double
    let rate: UInt8               // packets/s, 0 = as fast as possible
    init?(label3Reply p: [UInt8]) {
        guard p.count >= 5 else { return nil }
        firmware = UInt16(p[0]) | UInt16(p[1]) << 8
        breakMicros = Double(p[2]) * 10.67
        mabMicros = Double(p[3]) * 10.67
        rate = p[4]
    }
}

enum EnttecDecode {
    /// Label 10 reply: 4 BCD bytes, least-significant first. Returns e.g. "01234567", or nil if unset.
    static func serial(_ p: [UInt8]) -> String? {
        guard p.count >= 4, p[0..<4] != [0xFF, 0xFF, 0xFF, 0xFF] else { return nil }
        return p[0..<4].reversed().map { String(format: "%02X", $0) }.joined()
    }

    /// Labels 77/78 reply: (id, name).
    static func idAndName(_ p: [UInt8]) -> (id: UInt16, name: String)? {
        guard p.count >= 2 else { return nil }
        let id = UInt16(p[0]) | UInt16(p[1]) << 8
        let nameBytes = p.dropFirst(2).prefix { $0 != 0 }
        return (id, String(decoding: nameBytes, as: UTF8.self))
    }

    /// Label 5: returns (startCode, slots) or nil when the status byte flags corruption.
    static func receivedDMX(_ p: [UInt8]) -> (startCode: UInt8, slots: ArraySlice<UInt8>)? {
        guard p.count >= 2, p[0] == 0 else { return nil }
        return (p[1], p[2...])
    }

    /// Label 9: apply a change-of-state message to a 513-byte buffer (index 0 = start code).
    static func applyChangeOfState(_ p: [UInt8], to buffer: inout [UInt8]) {
        guard p.count >= 6 else { return }
        let base = Int(p[0]) * 8
        var k = 6                                   // first changed data byte
        for i in 0..<40 where p[1 + i / 8] & (1 << (i % 8)) != 0 {
            guard k < p.count, base + i < buffer.count else { return }
            buffer[base + i] = p[k]
            k += 1
        }
    }
}
```

### 1.6 Pro Mk2 differences

- Port 1 works exactly like a Pro (labels 3/4/5/6/8/9/10). Port 2 (and MIDI) is reached through
  extra labels that only work after sending a 4-byte API key with **label 13**. ENTTEC hands the key
  and the port-2 label numbers to developers. OLA's GPL source contains a key and those labels, but
  check ENTTEC's terms before reusing them. Detect a Mk2 with label 14 (reply `2`/`3`). After the key
  is sent, label 145 with data `{1, 1}` enables both ports, and replies for port 2 come back with
  labels above 128 (OLA) ⚠️.
- Recommendation for v1: treat a Mk2 as a single-universe Pro. Add port 2 later, once you have the key.

### 1.7 Opening and identifying a widget (recommended sequence)

1. Open the port: raw mode, non-blocking, exclusive (§2.4). The baud value doesn't matter for FT245
   and CDC widgets. Use 115200 for FTDI-UART-based clones (⚠️ some clones are fixed at 57600/250000).
2. `tcflush(fd, TCIOFLUSH)`, then send label **10**. Wait up to ~500 ms for a label-10 reply.
3. Send label **3** (`EnttecPro.getParameters`) to get the firmware version and refresh rate.
4. Optionally send **77** then **78**. A genuine ENTTEC ignores them. DMXking/JESE/Goddard reply with
   their ESTA ID and name; use that to pick the ultraDMX Pro two-port mode (labels 100/101).
5. If nothing answers within the timeout, it is either not a Pro-compatible widget or an **Open DMX**
   (FT232R with no MCU, so it never replies). Only offer "Open DMX" mode when the user picks it for an
   FTDI `0403:6001` device that didn't respond.
6. Start the output loop (label 6, ≤ 40 Hz, coalesced, §1.4). Don't send label 4 unless the user asked.

OLA, the reference implementation, rescans unrecognised serial devices every 20 s
(`SCAN_INTERVAL_MS = 20000`). Use IOKit hot-plug notifications instead (§2.3).

### 1.8 ENTTEC Open DMX USB on macOS without D2XX — feasible ✅ (with caveats)

The Open DMX is a bare FT232R wired to an RS-485 driver. Through the normal serial node (Apple's
built-in FTDI driver):

- Set **250000 baud** with `IOSSIOSPEED` (the FT232R hits 250 k exactly: 3 MHz / 12), **8 data bits, 2
  stop bits, no parity**.
- For each frame: `tcdrain` (wait until the previous frame has been shifted out) → `ioctl(TIOCSBRK)` →
  sleep ≥ 100 µs → `ioctl(TIOCCBRK)` → sleep ≥ 12 µs (MAB) → `write` 513 bytes (start code + 512).
  The break/clear calls become USB control transfers, so the real BREAK and MAB come out roughly
  0.1–2 ms long. That is within DMX512 limits (BREAK ≥ 92 µs, MAB ≥ 12 µs, both ≤ 1 s).
- ENTTEC's own D2XX sample also clears RTS (`FT_ClrRts`). The POSIX equivalent is `TIOCMBIC` with
  `TIOCM_RTS` (shown below) ⚠️.
- Run it on a dedicated thread at QoS `.userInteractive`, at 25–40 Hz (one 513-slot frame at 8N2 is
  ≈22.6 ms). Also start a `ProcessInfo` activity (§9) so App Nap / timer coalescing don't stretch the
  loop. Expect occasional jitter or flicker when the Mac is under load; that's the nature of the device,
  so recommend a Pro-class widget in the UI.
- D2XX (FTDI's user-space library) is **not** needed. On current macOS it only works when no driver
  has claimed the device, and Apple's dext claims standard FTDI IDs by default (see 1.9).

```swift
import Foundation

/// Host-timed DMX for ENTTEC Open DMX USB (FT232R). Uses `SerialPort` from §2.4.
final class OpenDMXOutput: @unchecked Sendable {
    private let port: SerialPort
    private let lock = NSLock()
    private var frame = [UInt8](repeating: 0, count: 513)   // [0] = start code 0x00
    private var running = false

    init(path: String) throws {
        port = SerialPort(path: path)
        try port.open(SerialPort.Config(baud: 230_400, twoStopBits: true, customBaud: 250_000))
        _ = port.setRTS(false)                               // mirrors FT_ClrRts in ENTTEC's sample
    }

    func update(slots: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        for i in 0..<min(512, slots.count) { frame[i + 1] = slots[i] }
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    private func snapshot() -> [UInt8] { lock.lock(); defer { lock.unlock() }; return frame }

    func start(rateHz: Double = 30) {
        lock.lock(); running = true; lock.unlock()
        let thread = Thread { [self] in
            let period = 1.0 / rateHz
            var deadline = CFAbsoluteTimeGetCurrent()
            while isRunning {
                let bytes = snapshot()
                guard port.drain(), port.setBreak(true) else { break }
                usleep(110)                                  // BREAK ≥ 92 µs
                guard port.setBreak(false) else { break }
                usleep(16)                                   // MAB ≥ 12 µs
                do { _ = try port.write(bytes, startTimeoutMs: 20, finishTimeoutMs: 200) }
                catch { break }                              // device gone → caller reconnects
                deadline += period
                let wait = deadline - CFAbsoluteTimeGetCurrent()
                if wait > 0 { Thread.sleep(forTimeInterval: wait) } else { deadline = CFAbsoluteTimeGetCurrent() }
            }
            lock.lock(); running = false; lock.unlock()
        }
        thread.name = "Prism.OpenDMX"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() { lock.lock(); running = false; lock.unlock() }
}
```

### 1.9 macOS drivers, device names, IDs ✅

- **Apple's built-in FTDI driver.** Since macOS 10.15 it is a DriverKit extension:
  `/System/Library/DriverExtensions/com.apple.DriverKit-AppleUSBFTDI.dext` (an `IOUserSerial`). Before
  that it was the `AppleUSBFTDI` kext (10.9+). It matches the **standard FTDI VID/PIDs** (`0403:6001`
  FT232R/FT245R plus the FT2232/FT4232/FT232H/FT-X PIDs), so ENTTEC Pro/Mk2/Open DMX and FTDI-based
  DMXking widgets work with **no driver install**. ENTTEC's manual: "From macOS X 10.11 onwards,
  third-party drivers are not needed." Device nodes are `/dev/cu.usbserial-<iSerial>` plus a matching
  `/dev/tty.usbserial-<iSerial>`. **Always open the `cu.` (callout) node.** The `tty.` (dial-in) node
  blocks on carrier detect.
- **FTDI's own VCP driver** (`FTDIUSBSerialDextDriver`) is only needed for devices with custom
  VID/PIDs. If both are installed, which one claims the device is unpredictable, and users report
  ports that vanish. Tell users not to install it unless a device needs it.
- **D2XX** (FTDI's libusb-style user-space API) needs exclusive USB access, so a VCP dext must *not*
  be attached. FTDI's old workaround (a "D2xxHelper" codeless kext) belongs to the deprecated kext
  world. **Don't use D2XX in Prism.** Everything above works through the VCP serial node.
- **CDC-ACM widgets** (ultraDMX MAX and many clones) use Apple's `AppleUSBACMData` and appear as
  `/dev/cu.usbmodem…`.
- **USB descriptor strings via IOKit:** walk *up* from the `IOSerialBSDClient` to the `IOUSBHostDevice`
  and read `idVendor` (FTDI = 1027 = `0x0403`), `idProduct` (24577 = `0x6001`), `USB Serial Number`,
  `USB Product Name`, `USB Vendor Name`, `locationID`. Newer USB stacks also publish
  `kUSBSerialNumberString` / `kUSBProductString` / `kUSBVendorString`, so try both spellings. Code is
  in §2.2. The FTDI iSerial (e.g. `EN406708`) is **not** the widget's own serial number from label 10;
  show both.

---

## 2. Serial ports on macOS in Swift (IOKit + POSIX)

Everything below uses public IOKit/Darwin APIs and needs **no entitlements** in a non-sandboxed app.
(A sandboxed build would need `com.apple.security.device.serial`.) Facts that apply throughout:

- The `kIOSerial…`, `kIOCalloutDeviceKey`, `kIOServicePlane`, `kIOProviderClassKey`,
  `kIOFirstMatchNotification` and `kIOTerminatedNotification` constants are C string macros. Swift
  imports them as `String`, and you can pass them straight to `const char *` parameters ✅.
- `kIOMainPortDefault` (macOS 12+) replaces the deprecated `kIOMasterPortDefault`.
- `IOServiceGetMatchingServices` and `IOServiceAddMatchingNotification` **consume** the matching
  dictionary (`CF_RELEASES_ARGUMENT`; Swift balances the reference for you). Build a **new dictionary
  for every call**.
- The `ioctl` request codes (`TIOCEXCL`, `IOSSIOSPEED`, …) are function-like macros, which Swift does
  **not** import. They are spelled out by hand in §2.4. The Swift Darwin overlay has
  `ioctl(fd, UInt)`, `ioctl(fd, UInt, CInt)` and `ioctl(fd, UInt, UnsafeMutableRawPointer)` ✅.

### 2.1 Enumerating ports ✅

```swift
import Foundation
import IOKit
import IOKit.serial

struct SerialPortInfo: Hashable, Sendable, Identifiable {
    var id: UInt64 { registryID }
    let registryID: UInt64          // IORegistry entry ID of the IOSerialBSDClient (stable while plugged in)
    let path: String                // "/dev/cu.usbserial-EN406708" (always open the cu.* node)
    let ttyName: String?            // "usbserial-EN406708"
    let vendorID: Int?              // 0x0403 = FTDI
    let productID: Int?             // 0x6001 = FT232R/FT245R
    let usbSerial: String?          // FTDI iSerial, e.g. "EN406708" (not the ENTTEC label-10 serial)
    let productName: String?        // "DMX USB PRO"
    let vendorName: String?         // "ENTTEC"
    let locationID: Int?            // physical USB port; useful to tell identical widgets apart

    var isUSB: Bool { vendorID != nil }
    var isFTDI: Bool { vendorID == 0x0403 }
    /// Heuristic for sorting likely DMX widgets to the top of the device list.
    var looksLikeDMXWidget: Bool {
        let text = [productName, vendorName, usbSerial].compactMap { $0 }.joined(separator: " ").lowercased()
        return text.contains("dmx") || text.contains("enttec") || (usbSerial?.hasPrefix("EN") ?? false)
            || (isFTDI && productID == 0x6001)
    }
}

enum SerialPortScanner {
    /// A fresh matching dictionary for every IOKit call (they consume it).
    static func matchingDictionary() -> CFDictionary {
        let dict: [String: Any] = [
            kIOProviderClassKey: kIOSerialBSDServiceValue,   // same as IOServiceMatching("IOSerialBSDClient")
            kIOSerialBSDTypeKey: kIOSerialBSDAllTypes,
        ]
        return dict as CFDictionary
    }

    static func scan() -> [SerialPortInfo] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary(), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        return drain(iterator)
    }

    /// Reads every object from an iterator. This is also what (re-)arms notification iterators.
    static func drain(_ iterator: io_iterator_t) -> [SerialPortInfo] {
        var result: [SerialPortInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let info = info(for: service) { result.append(info) }
        }
        return result
    }

    static func info(for service: io_object_t) -> SerialPortInfo? {
        guard let path = stringProperty(service, kIOCalloutDeviceKey) else { return nil }
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &entryID)
        return SerialPortInfo(
            registryID: entryID,
            path: path,
            ttyName: stringProperty(service, kIOTTYDeviceKey),
            vendorID: searchParents(service, "idVendor") as? Int,
            productID: searchParents(service, "idProduct") as? Int,
            usbSerial: firstString(service, "USB Serial Number", "kUSBSerialNumberString"),
            productName: firstString(service, "USB Product Name", "kUSBProductString"),
            vendorName: firstString(service, "USB Vendor Name", "kUSBVendorString"),
            locationID: searchParents(service, "locationID") as? Int)
    }

    // MARK: Registry helpers (§2.2)

    static func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    /// Looks for `key` on the entry itself and then on each parent in the IOService plane.
    static func searchParents(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    }

    static func firstString(_ entry: io_registry_entry_t, _ keys: String...) -> String? {
        for key in keys { if let s = searchParents(entry, key) as? String { return s } }
        return nil
    }
}
```

`kIOSerialBSDAllTypes` (`"IOSerialStream"`) matches both RS-232-type and modem-type clients. That
covers FTDI (`usbserial`) as well as CDC-ACM (`usbmodem`) devices. Bluetooth and debug consoles
(`/dev/cu.Bluetooth-Incoming-Port`, `/dev/cu.debug-console`) show up as well. Hide entries without a
`vendorID` (non-USB) by default.

### 2.2 USB descriptor properties

The registry path for an FTDI widget looks like this:
`IOSerialBSDClient → (AppleUSBFTDI dext / IOUserSerial) → IOUSBHostInterface → IOUSBHostDevice`.
`IORegistryEntrySearchCFProperty` with `kIORegistryIterateRecursively | kIORegistryIterateParents`
walks up that chain and returns the first match ✅.

| Key | Found on | Type | Example |
|---|---|---|---|
| `idVendor` / `idProduct` | interface **and** device | CFNumber → `Int` | 1027 / 24577 |
| `USB Serial Number` (legacy) / `kUSBSerialNumberString` (IOUSBHost) | device | CFString | `EN406708` |
| `USB Product Name` / `kUSBProductString` | device | CFString | `DMX USB PRO` |
| `USB Vendor Name` / `kUSBVendorString` | device | CFString | `ENTTEC` |
| `locationID` | device | CFNumber | `0x14200000` |
| `IOCalloutDevice` / `IODialinDevice` / `IOTTYDevice` | IOSerialBSDClient | CFString | `/dev/cu.usbserial-EN406708` |

Current macOS releases publish both spellings of the string keys, which is why the code tries both.
The literal strings above are the values of the `kUSB…` macros, written out so the code doesn't
depend on which USB headers get imported.

### 2.3 Hot-plug notifications ✅

```swift
import Foundation
import IOKit
import IOKit.serial

/// Reports serial ports as they appear and disappear. Callbacks run on a private serial queue,
/// so hop to the main actor yourself. Call `start()` once and `stop()` when you're done
/// (stop() balances the retain taken by start()). Don't call stop() from inside a callback.
final class SerialPortMonitor: @unchecked Sendable {
    var onAdded: (@Sendable (SerialPortInfo) -> Void)?
    var onRemoved: (@Sendable (SerialPortInfo) -> Void)?

    private let queue = DispatchQueue(label: "Prism.SerialPortMonitor")
    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var known: [UInt64: SerialPortInfo] = [:]     // registryID → info (needed on removal)
    private var retainedSelf: Unmanaged<SerialPortMonitor>?

    func start() {
        queue.sync {
            guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
            notifyPort = port
            IONotificationPortSetDispatchQueue(port, queue)

            let ref = Unmanaged.passRetained(self)      // keeps self alive while callbacks are armed
            retainedSelf = ref
            let context = ref.toOpaque()

            let addedCallback: IOServiceMatchingCallback = { context, iterator in
                guard let context else { return }
                Unmanaged<SerialPortMonitor>.fromOpaque(context).takeUnretainedValue().handleAdded(iterator)
            }
            let removedCallback: IOServiceMatchingCallback = { context, iterator in
                guard let context else { return }
                Unmanaged<SerialPortMonitor>.fromOpaque(context).takeUnretainedValue().handleRemoved(iterator)
            }

            IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
                                             SerialPortScanner.matchingDictionary(),
                                             addedCallback, context, &addedIterator)
            handleAdded(addedIterator)      // MUST drain once: reports existing ports and arms the notification

            IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
                                             SerialPortScanner.matchingDictionary(),
                                             removedCallback, context, &removedIterator)
            handleRemoved(removedIterator)  // arm
        }
    }

    func stop() {
        queue.sync {
            if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
            if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
            if let port = notifyPort { IONotificationPortDestroy(port); notifyPort = nil }
            known.removeAll()
        }
        retainedSelf?.release()
        retainedSelf = nil
    }

    private func handleAdded(_ iterator: io_iterator_t) {
        for info in SerialPortScanner.drain(iterator) {
            known[info.registryID] = info
            onAdded?(info)
        }
    }

    private func handleRemoved(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)   // still valid on a terminated object
            if let info = known.removeValue(forKey: entryID) { onRemoved?(info) }
        }
    }
}
```

Notes:
- `IOServiceMatchingCallback` is `@convention(c) (UnsafeMutableRawPointer?, io_iterator_t) -> Void`.
  The closures must not capture anything, so `self` travels through the `refCon` pointer ✅.
- **If you never drain an iterator, it never fires.** The first drain after
  `IOServiceAddMatchingNotification` is what arms it ✅.
- A removal arrives as a terminated `IOSerialBSDClient`. Its properties may already be gone, so look
  it up by registry entry ID (kept in `known`).
- The removal notification and the `ENXIO`/EOF on an open fd (§2.5) race each other. Handle both
  idempotently.

### 2.4 Opening, configuring, reading, writing ✅

This is the `SerialPort` class used in §1. Design: the fd is opened **non-blocking + exclusive**,
reads come from a `DispatchSourceRead`, and writes are non-blocking with a `poll()` timeout.
Writers and `close()` are serialised so an fd number is never used after it has been closed.

```swift
import Foundation
import Darwin

/// ioctl request codes (function-like macros in <sys/ttycom.h> and <IOKit/serial/ioss.h>,
/// which Swift does not import). 64-bit macOS values.
enum IOCTL {
    static let TIOCEXCL: UInt    = 0x2000_740D   // _IO('t', 13)          exclusive open
    static let TIOCNXCL: UInt    = 0x2000_740E   // _IO('t', 14)
    static let TIOCCBRK: UInt    = 0x2000_747A   // _IO('t', 122)         clear break
    static let TIOCSBRK: UInt    = 0x2000_747B   // _IO('t', 123)         set break
    static let TIOCMBIC: UInt    = 0x8004_746B   // _IOW('t', 107, int)   clear modem bits
    static let TIOCMBIS: UInt    = 0x8004_746C   // _IOW('t', 108, int)   set modem bits
    static let IOSSIOSPEED: UInt = 0x8008_5402   // _IOW('T', 2, speed_t) any baud rate
    static let IOSSDATALAT: UInt = 0x8008_5400   // _IOW('T', 0, unsigned long) receive latency, µs
}

enum SerialPortError: Error, CustomStringConvertible {
    case open(path: String, errno: Int32)          // EBUSY = someone else has it (TIOCEXCL), ENOENT = unplugged
    case configure(step: String, errno: Int32)
    case notOpen
    case disconnected(errno: Int32)
    case writeStalled                              // part of a frame went out, then the driver stopped accepting data
    case io(errno: Int32)

    var description: String {
        func msg(_ e: Int32) -> String { String(cString: strerror(e)) }
        switch self {
        case let .open(path, e): return "open \(path): \(msg(e))"
        case let .configure(step, e): return "\(step): \(msg(e))"
        case .notOpen: return "port not open"
        case let .disconnected(e): return "device disconnected (\(msg(e)))"
        case .writeStalled: return "write stalled"
        case let .io(e): return msg(e)
        }
    }
}

final class SerialPort: @unchecked Sendable {
    struct Config: Sendable {
        var baud: speed_t
        var twoStopBits: Bool
        /// A non-standard rate (e.g. 250_000) applied with IOSSIOSPEED *after* tcsetattr.
        var customBaud: speed_t?
        init(baud: speed_t = 115_200, twoStopBits: Bool = false, customBaud: speed_t? = nil) {
            self.baud = baud; self.twoStopBits = twoStopBits; self.customBaud = customBaud
        }
    }

    let path: String
    /// Both run on the port's private queue. Set them before `open`.
    var onData: (@Sendable ([UInt8]) -> Void)?
    var onDisconnect: (@Sendable (Int32) -> Void)?

    private let queue = DispatchQueue(label: "Prism.SerialPort", qos: .userInitiated)
    private let stateLock = NSLock()      // guards fd + source
    private let ioLock = NSLock()         // serialises writes/ioctls with close()
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String) { self.path = path }
    deinit { close() }

    var fileDescriptor: Int32 { stateLock.lock(); defer { stateLock.unlock() }; return fd }
    var isOpen: Bool { fileDescriptor >= 0 }

    func open(_ config: Config = Config()) throws {
        guard !isOpen else { return }
        let newFD = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard newFD >= 0 else { throw SerialPortError.open(path: path, errno: errno) }
        do { try Self.configure(newFD, config) } catch { Darwin.close(newFD); throw error }

        let src = DispatchSource.makeReadSource(fileDescriptor: newFD, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable(newFD) }
        src.setCancelHandler { Darwin.close(newFD) }          // the only place the fd is closed
        stateLock.lock(); fd = newFD; source = src; stateLock.unlock()
        src.resume()
    }

    /// Returns true if this call actually closed the port.
    @discardableResult
    func close() -> Bool {
        ioLock.lock(); defer { ioLock.unlock() }               // wait for an in-flight write
        stateLock.lock()
        let src = source
        let wasOpen = fd >= 0
        fd = -1; source = nil
        stateLock.unlock()
        src?.cancel()                                          // cancel handler closes the fd (drops TIOCEXCL)
        return wasOpen
    }

    // MARK: Line control

    /// Blocks until everything written so far has gone out on the wire.
    func drain() -> Bool { withOpenFD { tcdrain($0) == 0 } ?? false }

    func setBreak(_ on: Bool) -> Bool {
        withOpenFD { ioctl($0, on ? IOCTL.TIOCSBRK : IOCTL.TIOCCBRK) == 0 } ?? false
    }

    func setRTS(_ on: Bool) -> Bool {
        withOpenFD { fd -> Bool in
            var bits: CInt = TIOCM_RTS
            return ioctl(fd, on ? IOCTL.TIOCMBIS : IOCTL.TIOCMBIC, &bits) == 0
        } ?? false
    }

    // MARK: Writing

    private enum WriteOutcome { case done, dropped, stalled, failed(Int32) }

    /// Writes a whole frame, or nothing at all if the port isn't writable within `startTimeoutMs`.
    /// - Returns: `false` if the frame was dropped (nothing was sent). Skip the tick and retry later.
    /// - Throws: `.disconnected` (port closed, `onDisconnect` fired), `.writeStalled` (close and reopen),
    ///   `.notOpen`, `.io`.
    @discardableResult
    func write(_ bytes: [UInt8], startTimeoutMs: Int32 = 0, finishTimeoutMs: Int32 = 100) throws -> Bool {
        guard let outcome = withOpenFD({ Self.writeAll($0, bytes, startTimeoutMs, finishTimeoutMs) }) else {
            throw SerialPortError.notOpen
        }
        switch outcome {
        case .done: return true
        case .dropped: return false
        case .stalled: throw SerialPortError.writeStalled
        case .failed(let e):
            if [ENXIO, EIO, ENODEV, EBADF, EPIPE].contains(e) {
                if close() { onDisconnect?(e) }
                throw SerialPortError.disconnected(errno: e)
            }
            throw SerialPortError.io(errno: e)
        }
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8], _ startMs: Int32, _ finishMs: Int32) -> WriteOutcome {
        bytes.withUnsafeBytes { raw -> WriteOutcome in
            guard let base = raw.baseAddress else { return .done }          // empty write
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base + offset, raw.count - offset)
                if n > 0 { offset += n; continue }
                let e = n < 0 ? errno : EAGAIN
                if e == EINTR { continue }
                guard e == EAGAIN else { return .failed(e) }
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let r = poll(&pfd, 1, offset == 0 ? startMs : finishMs)
                if r < 0 {
                    let pe = errno
                    if pe == EINTR { continue }
                    return .failed(pe)
                }
                if r == 0 { return offset == 0 ? .dropped : .stalled }
                if pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return .failed(ENXIO) }
            }
            return .done
        }
    }

    // MARK: Internals

    private func withOpenFD<T>(_ body: (Int32) -> T) -> T? {
        ioLock.lock(); defer { ioLock.unlock() }
        let current = fileDescriptor
        return current >= 0 ? body(current) : nil
    }

    private func readAvailable(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let (n, err) = buffer.withUnsafeMutableBytes { raw -> (Int, Int32) in
            let r = Darwin.read(fd, raw.baseAddress, raw.count)
            return (r, r < 0 ? errno : 0)
        }
        if n > 0 {
            onData?(Array(buffer[..<n]))
        } else if n == 0 || (err != EAGAIN && err != EINTR) {
            // n == 0 is a real EOF/hang-up here because VMIN = 1 (see configure)
            if close() { onDisconnect?(err) }
        }
    }

    private static func configure(_ fd: Int32, _ c: Config) throws {
        func check(_ result: Int32, _ step: String) throws {
            if result != 0 { throw SerialPortError.configure(step: step, errno: errno) }
        }
        try check(ioctl(fd, IOCTL.TIOCEXCL), "TIOCEXCL")      // other opens now fail with EBUSY
        var t = termios()
        try check(tcgetattr(fd, &t), "tcgetattr")
        cfmakeraw(&t)                                        // no echo/canonical/signals; CS8; VMIN 1, VTIME 0
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)                // ignore modem lines, enable receiver
        t.c_cflag &= ~tcflag_t(PARENB | CCTS_OFLOW | CRTS_IFLOW)   // no parity, no RTS/CTS flow control
        if c.twoStopBits { t.c_cflag |= tcflag_t(CSTOPB) } else { t.c_cflag &= ~tcflag_t(CSTOPB) }
        t.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)         // no XON/XOFF
        withUnsafeMutableBytes(of: &t.c_cc) { cc in
            cc[Int(VMIN)] = 1     // with O_NONBLOCK: no data → EAGAIN (with VMIN 0, read() would return 0)
            cc[Int(VTIME)] = 0
        }
        try check(cfsetspeed(&t, c.baud), "cfsetspeed")
        try check(tcsetattr(fd, TCSANOW, &t), "tcsetattr")
        if var custom = c.customBaud {                       // must come after tcsetattr, which resets the speed
            try check(ioctl(fd, IOCTL.IOSSIOSPEED, &custom), "IOSSIOSPEED")
        }
        tcflush(fd, TCIOFLUSH)
    }
}
```

**Why VMIN = 1?** With `O_NONBLOCK`, the BSD tty layer returns **0** from `read()` when there is no data
and `VMIN == 0`. That makes "no data" look exactly like EOF. With `VMIN = 1` (what `cfmakeraw` sets),
"no data" gives `EAGAIN`, so `0` reliably means the device went away. This comes from 4.4BSD
`ttread()`, which XNU inherits ⚠️ (reasoned from the source, not tested on hardware).

A 40 Hz coalescing sender for Pro-class widgets (the strategy from §1.4):

```swift
import Foundation

final class EnttecProOutput: @unchecked Sendable {
    private let port: SerialPort
    private let queue = DispatchQueue(label: "Prism.EnttecOut", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: [UInt8]?                 // newest frame not yet sent (guarded by lock)
    private var timer: DispatchSourceTimer?       // queue-confined
    private var last: [UInt8] = []                // queue-confined
    private var lastSent: UInt64 = 0              // queue-confined (uptime ns)
    var onFailure: (@Sendable (Error) -> Void)?

    init(port: SerialPort) { self.port = port }

    /// Call from any thread, as often as you like. Only the newest frame is sent.
    func submit(_ slots: [UInt8]) { lock.lock(); pending = slots; lock.unlock() }

    func start(hz: Int = 40) {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / hz), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            t.resume()
        }
    }

    func stop() { queue.async { [self] in timer?.cancel(); timer = nil } }

    private func tick() {
        lock.lock(); let next = pending; pending = nil; lock.unlock()
        let now = DispatchTime.now().uptimeNanoseconds
        let keepAliveDue = now &- lastSent > 1_000_000_000
        guard next != nil || keepAliveDue, let slots = next ?? (last.isEmpty ? nil : last) else { return }
        do {
            if try port.write(EnttecPro.dmx(slots), startTimeoutMs: 0, finishTimeoutMs: 100) {
                last = slots; lastSent = now
            } else if let next {                  // not writable right now: retry next tick unless superseded
                lock.lock(); if pending == nil { pending = next }; lock.unlock()
            }
        } catch {
            timer?.cancel(); timer = nil
            onFailure?(error)                     // reconnect logic lives in the device manager
        }
    }
}
```

### 2.5 Unplug and error handling

| Symptom | Meaning | Action |
|---|---|---|
| `open` → `EBUSY` | Another process (or another Prism instance) holds it with `TIOCEXCL` | Tell the user which port is busy |
| `open` → `ENOENT` / `ENXIO` | The node disappeared (unplugged) | Wait for the hot-plug "added" event |
| `write` → `EAGAIN` | Driver TX queue full | `poll(POLLOUT)` with a short timeout, otherwise drop the frame (never queue) |
| `write` → `ENXIO`, `EIO`, `ENODEV`, `EBADF`, `EPIPE` | Device gone | Close (cancel the source), mark disconnected, wait for "added" |
| `read` → `0` (with VMIN = 1) or `ENXIO`/`EIO` | Device gone (EOF/hang-up) | Same as above |
| `POLLHUP` / `POLLERR` in `revents` | Hang-up | Same as above |
| IOKit terminated notification | Authoritative removal | Close the matching `SerialPort` if it's still open |

Reconnect by **USB serial number** (`usbSerial`, falling back to `locationID`), not by path. The path
usually comes back the same for FTDI (it is derived from the iSerial), but CDC `usbmodem` names are
derived from the location and can change between ports.

### 2.6 Pitfalls

- **Use `cu.*`, not `tty.*`.** Opening `tty.*` waits for DCD unless `O_NONBLOCK` is set, and has
  modem semantics.
- **Use `TIOCEXCL`.** Without it, two apps (or two Prism instances) can interleave frames on the same
  widget.
- **`IOSSIOSPEED` after `tcsetattr`.** Every later `tcsetattr` resets the speed, so re-apply it each
  time. Pass a standard rate (e.g. 230400) to `cfsetspeed`, because some drivers reject non-standard
  values there.
- `cfmakeraw` doesn't touch hardware flow control. Clear `CCTS_OFLOW | CRTS_IFLOW` explicitly (avoid
  the composite `CRTSCTS` macro). Otherwise a widget that doesn't drive CTS blocks every write.
- **App Nap / timer coalescing** can stretch a 25 ms timer to seconds when Prism is in the background
  with no visible windows. Hold a `ProcessInfo` activity while outputting (§9). `DispatchSource`
  timers with `.strict` and a small leeway help.
- `IOSSDATALAT` (receive latency) is optional. Apple's FTDI dext may ignore it ⚠️. It only affects how
  quickly *replies* arrive, not DMX output.
- With Swift 6 language mode, mark these classes `@unchecked Sendable` (as above) or put them on a
  custom actor. The repo is currently in Swift 5 mode (tools 5.10), so you get warnings, not errors.

---

## 3. Art-Net 4 and sACN (E1.31)

### 3.1 Art-Net 4 packets ✅ (Art-Net 4 spec; byte offsets checked against OLA `ArtNetPackets.h`)

Every Art-Net packet is UDP with **port 6454 (0x1936) as both source and destination**. It starts with
the 8-byte ID `"Art-Net\0"`, then a **little-endian** OpCode. ProtVer is 14 and is sent **big-endian**
(Hi = 0, Lo = 14). Watch the byte order: it changes from field to field.

| OpCode | Name | Use |
|---|---|---|
| `0x2000` | ArtPoll | discovery (controller → broadcast) |
| `0x2100` | ArtPollReply | discovery reply (node → controller, **unicast** in Art-Net 4) |
| `0x5000` | ArtDmx (OpOutput) | DMX data |
| `0x5100` | ArtNzs | non-zero start code data |
| `0x5200` | ArtSync | "apply the frames you just received" |
| `0x6000` | ArtAddress | remote node configuration |

**ArtDmx** (18-byte header + data):

| Offset | Field | Notes |
|---|---|---|
| 0–7 | ID | `Art-Net\0` |
| 8–9 | OpCode | `0x00 0x50` (LE) |
| 10–11 | ProtVerHi, ProtVerLo | `0, 14` |
| 12 | Sequence | 1…255, wraps back to 1. `0` = sequencing disabled |
| 13 | Physical | informational (input port number). Send 0 |
| 14 | SubUni | low byte of Port-Address = SubNet << 4 \| Universe |
| 15 | Net | high 7 bits of Port-Address |
| 16–17 | LengthHi, LengthLo | **big-endian**. Even number, 2…512 |
| 18… | Data | slot 1 at offset 18 |

**Port-Address** is 15 bits: `Net (7 bits) << 8 | SubNet (4 bits) << 4 | Universe (4 bits)`, so values
run 0…32767. Port-Address 0 is deprecated by the spec but **used everywhere in practice**. Many UIs
label it "Universe 0", some call it "Universe 1". Show `Net.SubNet.Universe` or the raw Port-Address,
and add a per-output "Art-Net universe offset" setting. sACN universes start at **1**. A common
convention is Art-Net Port-Address *n* ↔ sACN universe *n + 1*.

**ArtPoll** (Art-Net 4: 22 bytes; nodes accept ≥ 14): 12 Flags (bit 1 = send ArtPollReply when
something changes, bit 2 = send diagnostics, bit 3 = diagnostics unicast, bit 4 = disable VLC, bit 5 =
targeted mode), 13 DiagPriority, 14–15 TargetPortAddressTop (Hi, Lo), 16–17 TargetPortAddressBottom,
18–19 EstaMan (Hi, Lo), 20–21 Oem (Hi, Lo).

**ArtPollReply** (239 bytes). Offsets for the fields you need:

| Offset | Field | Offset | Field |
|---|---|---|---|
| 10–13 | IPv4 address | 172–173 | NumPorts (Hi, Lo) |
| 14–15 | Port (LE, 0x1936) | 174–177 | PortTypes[4] (bit 7 = can output DMX, bit 6 = can input) |
| 16–17 | VersInfo (Hi, Lo) | 178–181 | GoodInput[4] |
| 18 | NetSwitch (Net, bits 14–8) | 182–185 | GoodOutputA[4] |
| 19 | SubSwitch (bits 7–4) | 186–189 | SwIn[4] |
| 20–21 | Oem (Hi, Lo) | 190–193 | **SwOut[4]** (low nibble = Universe of each output port) |
| 22 | UBEA version | 194 | AcnPriority (was SwVideo) |
| 23 | Status1 | 200 | Style (0 = node, 1 = controller, …) |
| 24–25 | EstaMan (**Lo, Hi**) | 201–206 | MAC |
| 26–43 | ShortName[18] | 207–210 | BindIp |
| 44–107 | LongName[64] | 211 | BindIndex (1…n for multi-page nodes) |
| 108–171 | NodeReport[64] | 212 | Status2 |

Art-Net 4 additions after 212 ⚠️ (from the spec text, not checked against code): 213–216
GoodOutputB, 217 Status3, 218–223 DefaultResponderUID, 224–225 User, 226–227 RefreshRate. A node with
more than 4 ports sends **one reply per 4-port page** (different BindIndex).

**ArtSync** = 14 bytes (header + ProtVer + Aux1 + Aux2, all 0). Send it right after the ArtDmx frames
for one "look" so nodes switch all universes at the same moment. Once a node has seen ArtSync, it
waits for it (and falls back to immediate output after about 4 s without one).

### 3.2 Swift: Art-Net builders and ArtPollReply parser ✅

```swift
import Foundation

enum ArtNet {
    static let port: UInt16 = 6454
    static let id: [UInt8] = Array("Art-Net".utf8) + [0]
    static let protocolVersion: UInt8 = 14

    enum OpCode: UInt16 { case poll = 0x2000, pollReply = 0x2100, dmx = 0x5000, nzs = 0x5100, sync = 0x5200, address = 0x6000 }

    struct PortAddress: Hashable, Sendable {
        let raw: UInt16                                   // 0…32767
        init(raw: UInt16) { self.raw = raw & 0x7FFF }
        init(net: UInt8, subNet: UInt8, universe: UInt8) {
            raw = UInt16(net & 0x7F) << 8 | UInt16(subNet & 0x0F) << 4 | UInt16(universe & 0x0F)
        }
        var net: UInt8 { UInt8(raw >> 8) }
        var subNet: UInt8 { UInt8((raw >> 4) & 0x0F) }
        var universe: UInt8 { UInt8(raw & 0x0F) }
        var subUni: UInt8 { UInt8(raw & 0xFF) }
    }

    private static func header(_ op: OpCode) -> [UInt8] {
        id + [UInt8(op.rawValue & 0xFF), UInt8(op.rawValue >> 8)]          // OpCode is little-endian
    }

    /// ArtDmx. Pads to an even length ≥ 2. `sequence`: 1…255 (wrap to 1), or 0 to disable.
    static func dmx(_ slots: [UInt8], to address: PortAddress, sequence: UInt8, physical: UInt8 = 0) -> [UInt8] {
        var length = min(max(slots.count, 2), 512)
        if length % 2 == 1 { length += 1 }
        var p = header(.dmx)
        p.reserveCapacity(18 + length)
        p += [0, protocolVersion, sequence, physical, address.subUni, address.net,
              UInt8(length >> 8), UInt8(length & 0xFF)]                     // length is big-endian
        p += slots.prefix(length)
        if slots.count < length { p += [UInt8](repeating: 0, count: length - slots.count) }
        return p
    }

    /// ArtPoll (22 bytes). Flags 0x02 = "reply again whenever your state changes".
    static func poll(flags: UInt8 = 0x02, diagPriority: UInt8 = 0x10,
                     estaMan: UInt16 = 0x0000, oem: UInt16 = 0x0000) -> [UInt8] {
        header(.poll) + [0, protocolVersion, flags, diagPriority,
                         0x7F, 0xFF,                 // TargetPortAddressTop (only used when flags bit 5 is set)
                         0x00, 0x00,                 // TargetPortAddressBottom
                         UInt8(estaMan >> 8), UInt8(estaMan & 0xFF),
                         UInt8(oem >> 8), UInt8(oem & 0xFF)]
    }

    static func sync() -> [UInt8] { header(.sync) + [0, protocolVersion, 0, 0] }

    /// Next ArtDmx sequence number (1…255, never 0).
    static func nextSequence(after s: UInt8) -> UInt8 { s >= 255 ? 1 : s + 1 }

    struct Node: Hashable, Sendable {
        let ip: String
        let shortName: String
        let longName: String
        let estaMan: UInt16
        let oem: UInt16
        let mac: [UInt8]
        let bindIndex: UInt8
        let outputs: [PortAddress]                     // Port-Addresses this page can output
    }

    static func parsePollReply(_ d: [UInt8]) -> Node? {
        guard d.count >= 207, Array(d[0..<8]) == id, d[8] == 0x00, d[9] == 0x21 else { return nil }
        func text(_ r: Range<Int>) -> String { String(decoding: d[r].prefix { $0 != 0 }, as: UTF8.self) }
        let net = d[18] & 0x7F, subNet = d[19] & 0x0F
        let numPorts = min(Int(d[172]) << 8 | Int(d[173]), 4)
        var outputs: [PortAddress] = []
        for i in 0..<numPorts where d[174 + i] & 0x80 != 0 {
            outputs.append(PortAddress(net: net, subNet: subNet, universe: d[190 + i] & 0x0F))
        }
        return Node(ip: "\(d[10]).\(d[11]).\(d[12]).\(d[13])",
                    shortName: text(26..<44), longName: text(44..<108),
                    estaMan: UInt16(d[25]) << 8 | UInt16(d[24]),             // EstaMan is Lo, Hi here
                    oem: UInt16(d[20]) << 8 | UInt16(d[21]),
                    mac: Array(d[201..<207]),
                    bindIndex: d.count > 211 ? d[211] : 0,
                    outputs: outputs)
    }
}
```

**Discovery and sending strategy (Art-Net 4):**
- Bind **one** UDP socket to `0.0.0.0:6454` (`SO_REUSEADDR` + `SO_REUSEPORT`) and use it to send
  everything and to receive replies. Art-Net 4 nodes **unicast** ArtPollReply to the poller's IP on
  port 6454. If 6454 is already taken (another Art-Net app running), send from an ephemeral port and
  turn discovery off.
- Send an ArtPoll every **2.5–3 s** to the **directed broadcast** address of the chosen interface
  (e.g. `192.168.1.255`, or `2.255.255.255` on classic 2.x Art-Net networks). Avoid `255.255.255.255`,
  which is ambiguous on multi-homed Macs. Drop a node after about 3 missed polls.
- Send ArtDmx **unicast** to each node whose `outputs` include the Port-Address. Fall back to directed
  broadcast when no node is known or the user turns it on. Send at most ~44 Hz per universe, only when
  something changed, plus a keep-alive resend about every second. Keep one sequence counter per
  universe and destination.
- Optional: after all universes of a frame, send `ArtNet.sync()` to the same destinations.
- Art-Net expects every controller to answer ArtPoll with its own ArtPollReply (Style = 1,
  controller). This is not required for nodes to accept data. Do it later ⚠️. A registered OEM code
  (free from Artistic Licence) and an ESTA code are needed only for a polished product. Zeros work.

### 3.3 sACN / E1.31 data packet ✅ (E1.31-2016; offsets checked against Hundemeier/sacn)

Full universe (512 slots) = **638 bytes**. All multi-byte fields are **big-endian**. Each "flags &
length" field is `0x7000 | (bytes from that field's offset to the end of the packet)`.

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 2 | Preamble size | `0x0010` |
| 2 | 2 | Post-amble size | `0x0000` |
| 4 | 12 | ACN packet identifier | `"ASC-E1.17\0\0\0"` |
| 16 | 2 | Root flags & length | `0x7000 \| (len-16)` → `0x726E` |
| 18 | 4 | Root vector | `0x00000004` (E1.31 data) |
| 22 | 16 | **CID** | sender UUID (generate once, persist) |
| 38 | 2 | Framing flags & length | `0x7000 \| (len-38)` → `0x7258` |
| 40 | 4 | Framing vector | `0x00000002` (data packet) |
| 44 | 64 | Source name | UTF-8, NUL-padded |
| 108 | 1 | Priority | 0…200, default **100** |
| 109 | 2 | Sync address | 0 = no sync |
| 111 | 1 | Sequence number | per universe, wraps 255 → 0 |
| 112 | 1 | Options | `0x80` preview, `0x40` stream terminated, `0x20` force synchronization |
| 113 | 2 | Universe | 1…63999 |
| 115 | 2 | DMP flags & length | `0x7000 \| (len-115)` → `0x720B` |
| 117 | 1 | DMP vector | `0x02` (set property) |
| 118 | 1 | Address & data type | `0xA1` |
| 119 | 2 | First property address | `0x0000` |
| 121 | 2 | Address increment | `0x0001` |
| 123 | 2 | Property value count | slots + 1 (513) |
| 125 | 1 | START code | `0x00` |
| 126 | ≤512 | Slots | |

**Sync packet** (49 bytes): root vector `0x00000008`, framing vector `0x00000001`, 44 sequence, 45–46
sync address, 47–48 reserved.

Transmission rules:
- Send to multicast **239.255.{universe >> 8}.{universe & 0xFF}**, port **5568** (or unicast to a
  configured IP).
- When data stops changing, send **3** more identical packets, then keep-alive every **800–1000 ms**.
  Receivers time out after **2.5 s**.
- When the user stops an output, send **3 packets with the Stream_Terminated bit** (`0x40`) so
  receivers release it at once instead of holding the last look for 2.5 s.
- Universe discovery (universe 64214, every 10 s) is optional. Skip it in v1.

### 3.4 Swift: sACN builders ✅

```swift
import Foundation

enum SACN {
    static let port: UInt16 = 5568
    static let defaultPriority: UInt8 = 100
    static let optionPreview: UInt8 = 0x80
    static let optionStreamTerminated: UInt8 = 0x40
    static let optionForceSync: UInt8 = 0x20

    static func multicastAddress(universe: UInt16) -> String { "239.255.\(universe >> 8).\(universe & 0xFF)" }

    private static let acnIdentifier: [UInt8] = Array("ASC-E1.17".utf8) + [0, 0, 0]

    static func cidBytes(_ uuid: UUID) -> [UInt8] { withUnsafeBytes(of: uuid.uuid) { Array($0) } }

    /// The CID must stay the same across launches.
    static func persistentCID(_ defaults: UserDefaults = .standard) -> UUID {
        if let s = defaults.string(forKey: "sACN.CID"), let u = UUID(uuidString: s) { return u }
        let u = UUID()
        defaults.set(u.uuidString, forKey: "sACN.CID")
        return u
    }

    static func dataPacket(slots: [UInt8], universe: UInt16, sequence: UInt8, cid: [UInt8],
                           sourceName: String, priority: UInt8 = defaultPriority,
                           syncAddress: UInt16 = 0, options: UInt8 = 0, startCode: UInt8 = 0) -> [UInt8] {
        precondition(cid.count == 16 && (1...63999).contains(universe))
        let count = min(slots.count, 512)
        let total = 126 + count
        var p = [UInt8](repeating: 0, count: total)
        p[1] = 0x10                                            // preamble size
        p.replaceSubrange(4..<16, with: acnIdentifier)
        put16(&p, 16, 0x7000 | UInt16(total - 16))
        put32(&p, 18, 0x0000_0004)                             // VECTOR_ROOT_E131_DATA
        p.replaceSubrange(22..<38, with: cid)
        put16(&p, 38, 0x7000 | UInt16(total - 38))
        put32(&p, 40, 0x0000_0002)                             // VECTOR_E131_DATA_PACKET
        let name = Array(sourceName.utf8.prefix(63))           // keep at least one NUL
        p.replaceSubrange(44..<(44 + name.count), with: name)
        p[108] = min(priority, 200)
        put16(&p, 109, syncAddress)
        p[111] = sequence
        p[112] = options
        put16(&p, 113, universe)
        put16(&p, 115, 0x7000 | UInt16(total - 115))
        p[117] = 0x02                                          // VECTOR_DMP_SET_PROPERTY
        p[118] = 0xA1
        put16(&p, 121, 0x0001)                                 // address increment (119–120 stay 0)
        put16(&p, 123, UInt16(count + 1))
        p[125] = startCode
        p.replaceSubrange(126..<total, with: slots.prefix(count))
        return p
    }

    static func syncPacket(syncAddress: UInt16, sequence: UInt8, cid: [UInt8]) -> [UInt8] {
        precondition(cid.count == 16)
        var p = [UInt8](repeating: 0, count: 49)
        p[1] = 0x10
        p.replaceSubrange(4..<16, with: acnIdentifier)
        put16(&p, 16, 0x7000 | 33)                             // 49 - 16
        put32(&p, 18, 0x0000_0008)                             // VECTOR_ROOT_E131_EXTENDED
        p.replaceSubrange(22..<38, with: cid)
        put16(&p, 38, 0x7000 | 11)                             // 49 - 38
        put32(&p, 40, 0x0000_0001)                             // VECTOR_E131_EXTENDED_SYNCHRONIZATION
        p[44] = sequence
        put16(&p, 45, syncAddress)
        return p
    }

    private static func put16(_ p: inout [UInt8], _ i: Int, _ v: UInt16) {
        p[i] = UInt8(v >> 8); p[i + 1] = UInt8(v & 0xFF)
    }
    private static func put32(_ p: inout [UInt8], _ i: Int, _ v: UInt32) {
        p[i] = UInt8(v >> 24); p[i + 1] = UInt8((v >> 16) & 0xFF)
        p[i + 2] = UInt8((v >> 8) & 0xFF); p[i + 3] = UInt8(v & 0xFF)
    }
}
```

### 3.5 Sending UDP: use BSD sockets for broadcast and multicast ✅

- **Network.framework `NWConnection` does not support broadcast.** Sending to a broadcast address
  fails. Apple DTS's advice is to use BSD sockets for broadcast.
- Multicast *sending* to 239.255.x.y with BSD sockets is simple and, on macOS, needs no entitlement.
  The multicast entitlement is an iOS requirement. `NWConnectionGroup` works too but adds complexity.
- On macOS 15+, every one of these sends is subject to **Local Network privacy** (§5). A denied send
  fails with `EHOSTUNREACH` ("No route to host").

```swift
import Foundation
import Darwin

/// One IPv4 UDP socket for Art-Net/sACN/OSC output (and, optionally, for receiving ArtPollReply).
final class UDPSocket: @unchecked Sendable {
    let fd: Int32
    private var readSource: DispatchSourceRead?

    /// - Parameters:
    ///   - bindPort: 6454 to receive ArtPollReply; nil = ephemeral source port.
    ///   - interfaceName: e.g. "en0". Pins broadcast/multicast output to that NIC (multi-homed Macs).
    init(bindPort: UInt16? = nil, interfaceName: String? = nil, multicastTTL: UInt8 = 1) throws {
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { throw UDPSocket.posix() }
        // Configure the local `s`; assign `fd` only at the very end, so a throw never reaches deinit.
        var on: Int32 = 1
        let intSize = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(s, SOL_SOCKET, SO_BROADCAST, &on, intSize)
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, intSize)
        setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &on, intSize)
        var ttl = multicastTTL
        setsockopt(s, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var loop: UInt8 = 1                      // let a visualiser on the same Mac see our multicast
        setsockopt(s, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, socklen_t(MemoryLayout<UInt8>.size))

        if let name = interfaceName, case let index = if_nametoindex(name), index != 0 {
            var idx = Int32(index)
            let ipBoundIF: Int32 = 25            // IP_BOUND_IF in <netinet/in.h> (Apple-specific)
            setsockopt(s, IPPROTO_IP, ipBoundIF, &idx, intSize)
            if let lan = LANAddresses.ipv4().first(where: { $0.name == name }) {
                var addr = in_addr()
                if inet_pton(AF_INET, lan.address, &addr) == 1 {
                    setsockopt(s, IPPROTO_IP, IP_MULTICAST_IF, &addr, socklen_t(MemoryLayout<in_addr>.size))
                }
            }
        }

        if let port = bindPort {
            var sin = sockaddr_in()                                  // sin_addr = INADDR_ANY (0)
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_port = port.bigEndian
            let rc = withUnsafePointer(to: &sin) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if rc != 0 { let err = UDPSocket.posix(); Darwin.close(s); throw err }   // EADDRINUSE: port taken
        }
        fd = s
    }

    deinit {
        if let src = readSource { src.cancel() } else { Darwin.close(fd) }
    }

    /// Non-blocking-ish send. Drop the frame on EAGAIN/ENOBUFS rather than queueing.
    func send(_ bytes: [UInt8], to host: String, port: UInt16) throws {
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &sin.sin_addr) == 1 else { throw POSIXError(.EINVAL) }
        let sent = bytes.withUnsafeBytes { raw in
            withUnsafePointer(to: &sin) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, MSG_DONTWAIT, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 { throw Self.posix() }   // EHOSTUNREACH: LNP denied or no route; ENOBUFS/EAGAIN: busy
    }

    /// Delivers (payload, sender IPv4) on `queue`. Only useful when bound (e.g. ArtPollReply on 6454).
    func startReceiving(on queue: DispatchQueue, _ handler: @escaping @Sendable ([UInt8], String) -> Void) {
        let s = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 1500)
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buf.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(s, raw.baseAddress, raw.count, 0, $0, &len)
                    }
                }
            }
            guard n > 0 else { return }
            let a = UInt32(bigEndian: from.sin_addr.s_addr)
            handler(Array(buf[..<n]), "\(a >> 24).\((a >> 16) & 0xFF).\((a >> 8) & 0xFF).\(a & 0xFF)")
        }
        src.setCancelHandler { Darwin.close(s) }
        readSource = src
        src.resume()
    }

    private static func posix() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
```

Usage:

```swift
let artnet = try UDPSocket(bindPort: ArtNet.port, interfaceName: "en0")
try artnet.send(ArtNet.dmx(levels, to: .init(raw: 0), sequence: seq), to: "192.168.1.255", port: ArtNet.port)

let sacn = try UDPSocket(interfaceName: "en0")
let cid = SACN.cidBytes(SACN.persistentCID())
try sacn.send(SACN.dataPacket(slots: levels, universe: 1, sequence: seq, cid: cid, sourceName: "Prism"),
              to: SACN.multicastAddress(universe: 1), port: SACN.port)
```

The directed broadcast address for an interface is `ip | ~netmask`. `getifaddrs` also hands it to you
as `ifa_dstaddr` when `IFF_BROADCAST` is set (§5.4). Unicast UDP to a single known IP works fine with
`NWConnection(host:port:using: .udp)`. Keep the BSD socket anyway so there's one code path.

---

## 4. App bundling, Info.plist, signing, Gatekeeper, TCC

### 4.1 Bundle layout

```
Prism.app/
  Contents/
    Info.plist
    PkgInfo                      "APPL????"
    MacOS/Prism                  universal Mach-O (arm64 + x86_64)
    Resources/AppIcon.icns
    Resources/*.bundle           SwiftPM resource bundles, if any (see 4.3)
    _CodeSignature/CodeResources (written by codesign)
```

Keep packaging inputs (`Info.plist`, `AppIcon.icns`, entitlements) **outside `Sources/`**, for example
in `packaging/`. SwiftPM rejects a top-level `Info.plist` resource and warns about unhandled files.

### 4.2 Info.plist ✅ (keys per Apple's Information Property List reference)

`__VERSION__`, `__BUILD__` and `__BUNDLE_ID__` are replaced by the bundling script. The bundle ID and
UTI below are suggestions. Pick them once and **never change them**, because TCC, Local Network
grants, LaunchServices and UserDefaults all key off the bundle ID.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>      <string>en</string>
    <key>CFBundleExecutable</key>             <string>Prism</string>
    <key>CFBundleIdentifier</key>             <string>__BUNDLE_ID__</string>
    <key>CFBundleInfoDictionaryVersion</key>  <string>6.0</string>
    <key>CFBundleName</key>                   <string>Prism</string>
    <key>CFBundleDisplayName</key>            <string>Prism</string>
    <key>CFBundlePackageType</key>            <string>APPL</string>
    <key>CFBundleShortVersionString</key>     <string>__VERSION__</string>
    <key>CFBundleVersion</key>                <string>__BUILD__</string>
    <key>CFBundleIconFile</key>               <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>         <string>14.0</string>
    <key>LSApplicationCategoryType</key>      <string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key>        <true/>
    <key>NSPrincipalClass</key>               <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>       <string>© 2026 Prism contributors</string>

    <!-- Privacy usage strings: without them the app is killed the moment it touches the API -->
    <key>NSCameraUsageDescription</key>
    <string>Prism uses the camera to sample colours and track motion for lighting effects.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Prism listens to audio to drive sound-reactive lighting and voice commands.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Prism recognises spoken commands such as "blackout" or "next cue".</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Prism analyses the audio playing on this Mac to drive sound-reactive lighting.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Prism sends Art-Net and sACN to lighting nodes and lets phones on your network act as remotes.</string>
    <key>NSBonjourServices</key>
    <array><string>_prism._tcp</string></array>

    <!-- Optional: only needed if URLSession talks plain http:// to LAN devices -->
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsLocalNetworking</key><true/></dict>

    <!-- Optional: prism:// URL scheme (Shortcuts "Open URL", automation) -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>     <string>__BUNDLE_ID__.url</string>
            <key>CFBundleURLSchemes</key>  <array><string>prism</string></array>
        </dict>
    </array>

    <!-- Document type: .prismlights (JSON) -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>        <string>Prism Lighting Show</string>
            <key>CFBundleTypeRole</key>        <string>Editor</string>
            <key>LSHandlerRank</key>           <string>Owner</string>
            <key>LSItemContentTypes</key>      <array><string>io.github.goveaaron.prism.show</string></array>
            <key>CFBundleTypeIconFile</key>    <string>AppIcon</string>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>        <string>io.github.goveaaron.prism.show</string>
            <key>UTTypeDescription</key>       <string>Prism Lighting Show</string>
            <key>UTTypeConformsTo</key>        <array><string>public.json</string></array>
            <key>UTTypeIconFile</key>          <string>AppIcon</string>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key> <array><string>prismlights</string></array>
                <key>public.mime-type</key>          <array><string>application/vnd.prism.lights+json</string></array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
```

Notes:
- `public.json` already conforms to `public.text`/`public.data`, so Quick Look and text editors can
  still read it. Use `UTExportedTypeDeclarations` because Prism *owns* the type.
  (`UTImportedTypeDeclarations` is for types other apps define.)
- `NSAudioCaptureUsageDescription` covers **Core Audio process taps** (`CATapDescription`,
  macOS 14.2+). If you capture system audio with **ScreenCaptureKit** instead, the permission is
  Screen & System Audio Recording. There's no plist key for it; the system prompt appears on first
  use.
- `NSBonjourServices` is enforced on iOS. On macOS it's harmless and documents intent ⚠️.
- In Swift: `extension UTType { static let prismShow = UTType(exportedAs: "io.github.goveaaron.prism.show") }`
  (`import UniformTypeIdentifiers`). `UTType(exportedAs:)` is non-failable. Use it for
  `.fileImporter`/`.fileExporter`, `FileDocument.readableContentTypes`, or `NSOpenPanel.allowedContentTypes`.
- Optional: `-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker packaging/Info.plist`
  embeds a plist into a *bare* executable (e.g. for `swift run`), so TCC can find usage strings when
  running unbundled. The real app should still use `Contents/Info.plist`.

### 4.3 SwiftPM resources: `Bundle.module` pitfalls ✅ (read from the SwiftPM and swift-build sources)

If any target declares `resources:`, SwiftPM generates `resource_bundle_accessor.swift` with a lazy
`Bundle.module`. Which accessor you get depends on the build system:

| Build | Accessor | Where it looks | If not found |
|---|---|---|---|
| `swift build` (**native** build system, the default in the 6.2/6.3 release toolchains) | SwiftPM `SwiftModuleBuildDescription` | 1) `Bundle.main.bundleURL/<Package>_<Target>.bundle`. In an .app that is **`Prism.app/Prism_PrismApp.bundle`, the bundle root, not `Contents/Resources`**. 2) the **absolute build path** baked in at compile time (`/Users/runner/work/…/release/Prism_PrismApp.bundle`) | `Swift.fatalError("could not load resource bundle: from … or …")` at first use |
| `swift build --build-system swiftbuild`; multi-arch single invocation (`--arch arm64 --arch x86_64`, which goes through the Xcode build system); Xcode / `xcodebuild` | swift-build `SourcesTaskProducer` | `PACKAGE_RESOURCE_BUNDLE_PATH` env var (DEBUG only), `Bundle.main.resourceURL` (= `Contents/Resources`) ✅, `Bundle(for: BundleFinder.self).resourceURL`, `Bundle.main.bundleURL` | `fatalError("unable to find bundle named …")` |

Consequences for Prism:
- With the native build, the only place the release accessor finds the bundle is the .app **root**,
  and a file at the bundle root makes `codesign` fail with *"unsealed contents present in the bundle
  root"*. The CI machine's build path doesn't exist on users' Macs. **So never call `Bundle.module`
  in code that ships in the .app.**
- SwiftPM `main` has switched the default to `swiftbuild` for future toolchains ⚠️ (which Xcode
  picks that up is not confirmed). Don't depend on either accessor.

What to do instead:
1. **Web remote assets (HTML/JS/CSS) in `PrismServer`:** use `.embedInCode` (tools-version 5.9+).
   Each file becomes a static byte array, so no bundle is involved and it also works for
   `PrismDevServer` on Linux:
   ```swift
   // Package.swift (target PrismServer)
   resources: [.embedInCode("Web/index.html"), .embedInCode("Web/app.js")]
   // generated: struct PackageResources { static let index_html: [UInt8]; static let app_js: [UInt8] }
   let html = Data(PackageResources.index_html)
   ```
   You must list individual files (no directories). The identifier is the file name with
   non-identifier characters turned into `_`. Very large files slow compilation. Both build systems
   generate the same `struct PackageResources` ✅ (SwiftPM `LLBuildManifest.swift`, swift-build
   `GenerateEmbedInCodeAccessorTaskAction.swift`), so this keeps working if the default changes.
2. **App images and sounds:** use SF Symbols or code-drawn assets. Alternatively, ship `.copy`
   resources and use your own accessor that never calls `fatalError`. Have the bundling script copy
   `*.bundle` into `Contents/Resources`:
   ```swift
   import Foundation

   enum PrismResources {
       /// Finds "<Package>_<Target>.bundle" in Contents/Resources (app), next to the binary
       /// (`swift run`), or falls back to Bundle.main. Never traps.
       static func bundle(named name: String = "Prism_PrismApp") -> Bundle {
           let file = name + ".bundle"
           let candidates: [URL?] = [
               Bundle.main.resourceURL,
               Bundle.main.executableURL?.deletingLastPathComponent(),
               Bundle.main.bundleURL,
           ]
           for case let base? in candidates {
               if let b = Bundle(url: base.appendingPathComponent(file)) { return b }
           }
           return .main
       }
   }
   ```

### 4.4 Universal binary ✅

- Build each slice with the native build system and merge with `lipo`. Output paths are
  `.build/arm64-apple-macosx/release/Prism` and `.build/x86_64-apple-macosx/release/Prism`. Ask
  `swift build … --show-bin-path` rather than hard-coding them.
- `swift build -c release --arch arm64 --arch x86_64` in **one** invocation also works, but it goes
  through the Xcode build system (`.build/apple/Products/Release/Prism`) and gets the *other*
  resource accessor. Per-arch + `lipo` is more predictable.
- Check with `lipo -archs Prism.app/Contents/MacOS/Prism` (→ `x86_64 arm64`).

### 4.5 Bundling script (for CI) ✅

```bash
#!/usr/bin/env bash
# scripts/bundle-app.sh <short-version> <build-number>
# Builds a universal Prism.app in dist/, signs it (ad-hoc by default) and zips it.
set -euo pipefail

VERSION="${1:-0.0.0}"
BUILD="${2:-1}"
PRODUCT="Prism"
BUNDLE_ID="${BUNDLE_ID:-io.github.goveaaron.prism}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"        # "-" = ad-hoc; or a certificate name/SHA-1 (see 4.7)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$PRODUCT.app"

cd "$ROOT"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 1) One build per architecture (native build system), then merge.
BIN_DIRS=()
for ARCH in arm64 x86_64; do
  swift build -c release --product "$PRODUCT" --arch "$ARCH"
  BIN_DIRS+=("$(swift build -c release --product "$PRODUCT" --arch "$ARCH" --show-bin-path)")
done
lipo -create -output "$APP/Contents/MacOS/$PRODUCT" "${BIN_DIRS[0]}/$PRODUCT" "${BIN_DIRS[1]}/$PRODUCT"
lipo -archs "$APP/Contents/MacOS/$PRODUCT"

# 2) SwiftPM resource bundles (only if a target declares resources) → Contents/Resources.
shopt -s nullglob
for B in "${BIN_DIRS[0]}"/*.bundle; do
  ditto "$B" "$APP/Contents/Resources/$(basename "$B")"
done
shopt -u nullglob

# 3) Info.plist, PkgInfo, icon.
sed -e "s/__VERSION__/${VERSION}/g" -e "s/__BUILD__/${BUILD}/g" -e "s/__BUNDLE_ID__/${BUNDLE_ID}/g" \
  "$ROOT/packaging/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$ROOT/packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# 4) Sign the finished bundle (signing seals Info.plist + Resources), then verify.
#    No --deep, no --options runtime (no hardened runtime → no entitlements needed, see 4.7).
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E '^(Identifier|Format|Signature|TeamIdentifier)'

# 5) Zip the way Finder does and publish a checksum.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$PRODUCT.zip"
(cd "$DIST" && shasum -a 256 "$PRODUCT.zip" > "$PRODUCT.zip.sha256")
```

Any change to the bundle after `codesign` (editing Info.plist, adding files) breaks the seal. A
quarantined copy then shows as **"damaged"**. Always sign last.

### 4.6 Icon (.icns) ✅

```bash
#!/usr/bin/env bash
# scripts/make-icns.sh packaging/icon-1024.png → packaging/AppIcon.icns
set -euo pipefail
SRC="${1:-packaging/icon-1024.png}"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for S in 16 32 128 256 512; do
  sips -z "$S" "$S" "$SRC" --out "$SET/icon_${S}x${S}.png" >/dev/null
  sips -z $((S * 2)) $((S * 2)) "$SRC" --out "$SET/icon_${S}x${S}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o packaging/AppIcon.icns
```

Commit the generated `.icns` so CI doesn't need image tools. On **macOS 26**, icons that don't follow
the new rounded-square grid are drawn inside a grey squircle. Draw the 1024 px artwork as a full
squircle with Apple's template margins. The alternative is an Icon Composer `.icon` file compiled by
Xcode 26's `actool` (exact flags not checked ⚠️).

### 4.7 Code signing, entitlements, TCC ✅

**Ad-hoc signing** (`codesign -s -`):
- Apple Silicon needs *some* signature. The linker already ad-hoc signs the binary, but sign the
  **bundle** too, so Info.plist and resources are sealed and the identifier comes from
  `CFBundleIdentifier`.
- **Entitlements:** none are needed for camera, microphone, speech, audio capture, serial or network
  when the app is **not sandboxed and has no hardened runtime**. TCC prompts are driven by the
  Info.plist usage strings. You only need `com.apple.security.device.camera` /
  `com.apple.security.device.audio-input` if you switch on the hardened runtime
  (`--options runtime`), which matters only for notarization with a Developer ID.
- **TCC across updates:** an ad-hoc signature has no certificate, so its *designated requirement* is
  the **cdhash**, which changes with every build. TCC (camera, mic, speech, audio capture, screen
  recording) and Local Network decisions are stored with that requirement. **After every update
  users get asked again**, and System Settings can show stale duplicates. Clean up with
  `tccutil reset Camera io.github.goveaaron.prism` (or `Microphone`, `SpeechRecognition`, `All`, …).
- **Fix: sign every release with the same self-signed code-signing certificate.** The DR then becomes
  `identifier "io.github.goveaaron.prism" and certificate leaf = H"…"`, which stays the same across
  builds, so permissions persist. It costs nothing, but Gatekeeper still treats the app as
  unidentified (4.8). Only a **Developer ID** (paid) plus notarization removes the Gatekeeper prompt.

Creating the certificate (once, on any Mac): Keychain Access › Certificate Assistant › *Create a
Certificate…* › Name `Prism Code Signing`, Identity Type *Self Signed Root*, Certificate Type *Code
Signing*. Then export it as `.p12` with a password, base64 it into the repo secrets
`SIGNING_P12_BASE64` and `SIGNING_P12_PASSWORD`, and keep a backup. Losing the key means everyone gets
re-prompted once.

Using it in CI. Option A, the system `codesign` with a temporary keychain:

```bash
KC="$RUNNER_TEMP/signing.keychain-db"; KC_PW="$(uuidgen)"
echo "$SIGNING_P12_BASE64" | base64 --decode > "$RUNNER_TEMP/cert.p12"
security create-keychain -p "$KC_PW" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$KC_PW" "$KC"
security import "$RUNNER_TEMP/cert.p12" -P "$SIGNING_P12_PASSWORD" -A -t cert -f pkcs12 -k "$KC"
security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PW" "$KC"
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
# Self-signed = not trusted, so it's missing from `security find-identity -v`. Sign by SHA-1 hash:
HASH="$(security find-identity -p codesigning "$KC" | awk '/Prism Code Signing/ {print $2; exit}')"
SIGN_IDENTITY="$HASH" scripts/bundle-app.sh "$VERSION" "$GITHUB_RUN_NUMBER"
```

⚠️ Per TN3161, `codesign` looks only for *valid* (trusted) identities when you give it a name.
Whether a SHA-1 hash gets around that for an untrusted self-signed cert on current runners is not
confirmed. If it fails with "no identity found" or `CSSMERR_TP_NOT_TRUSTED`, try
`security add-trusted-cert -r trustRoot -p codeSign -k "$KC" cert.cer` (may need user interaction on
some macOS versions) or use option B.

Option B, **`rcodesign`** (apple-codesign 0.29.0, pure Rust, no keychain or trust needed). Download
`apple-codesign-0.29.0-macos-universal.tar.gz` from the indygreg/apple-platform-rs releases, then
`rcodesign sign --p12-file cert.p12 --p12-password-file pw.txt dist/Prism.app` ⚠️ (check the DR it
writes with `codesign -d -r- dist/Prism.app`).

Check what you shipped: `codesign -d -r- Prism.app` prints the designated requirement. It should
show `certificate leaf = H"…"` (or `root`), not `cdhash H"…"`.

### 4.8 Gatekeeper and quarantine (macOS 15 Sequoia / 26 Tahoe) ✅

Gatekeeper only checks files that carry the **`com.apple.quarantine`** xattr. Browsers, Mail,
Messages and AirDrop set it, and Archive Utility copies it onto the extracted app. **`curl`, `gh`,
`git` and `ditto` do not set it.**

| How it arrived | Signature | What the user sees |
|---|---|---|
| Browser download | ad-hoc or self-signed | "Apple could not verify 'Prism' is free of malware…" with only *Done* / *Move to Trash*. **macOS 15+ removed the Control-click › Open bypass.** The user opens System Settings › Privacy & Security, clicks **Open Anyway** (shown for about an hour after the blocked launch), and authenticates. Only needed once per copy. |
| Browser download | signature broken (bundle modified after signing) | "'Prism' is damaged and can't be opened." No Open Anyway. Needs `xattr -dr com.apple.quarantine`. |
| Browser download | Developer ID + notarized | Simple "downloaded from the Internet" confirmation |
| `curl` / installer script | ad-hoc or self-signed | **Launches with no Gatekeeper prompt** (XProtect still scans) |

Recommended install path: a one-line installer that uses `curl` (no quarantine), with the browser
download plus "Open Anyway" instructions as a fallback in the README.

```bash
#!/bin/bash
# scripts/install.sh — usage:
#   curl -fsSL https://raw.githubusercontent.com/goveaaron/StudioLightingMac/main/scripts/install.sh | bash
set -euo pipefail
REPO="goveaaron/StudioLightingMac"
URL="https://github.com/${REPO}/releases/latest/download/Prism.zip"
DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading Prism…"
curl -fL --progress-bar -o "$TMP/Prism.zip" "$URL"
if curl -fsL -o "$TMP/Prism.zip.sha256" "${URL}.sha256"; then
  (cd "$TMP" && shasum -a 256 -c Prism.zip.sha256)
fi
ditto -x -k "$TMP/Prism.zip" "$TMP"
[ -d "$TMP/Prism.app" ] || { echo "Prism.app not found in archive" >&2; exit 1; }

if pgrep -xq Prism; then
  echo "Quitting running Prism…"
  pkill -x Prism || true          # Prism turns SIGTERM into a normal quit: save, blackout (§9.3)
  for _ in $(seq 1 20); do pgrep -xq Prism || break; sleep 0.5; done
  if pgrep -xq Prism; then echo "Prism is still running. Quit it and run the installer again." >&2; exit 1; fi
fi
rm -rf "$DEST/Prism.app"
ditto "$TMP/Prism.app" "$DEST/Prism.app"
xattr -dr com.apple.quarantine "$DEST/Prism.app" 2>/dev/null || true   # no-op for curl downloads
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/Prism.app" || true
echo "Installed to $DEST/Prism.app"
open "$DEST/Prism.app"
```

- `releases/latest/download/<asset>` always redirects to the newest **non-prerelease, non-draft**
  release. Keep the asset name fixed (`Prism.zip`) and upload `Prism.zip.sha256` next to it.
- ⚠️ macOS 13+ "App Management" protection can stop Terminal from replacing an app bundle that was
  signed by someone else. If users see *"Terminal was prevented from modifying apps on your Mac"*,
  they allow Terminal under Privacy & Security › App Management, or drag the old copy to the Trash
  first. Whether this applies to ad-hoc/self-signed bundles is not confirmed.
- Updating in place replaces the bundle's cdhash, so see 4.7 for TCC.

### 4.9 Document type registration ✅

- LaunchServices reads `CFBundleDocumentTypes` / `UTExportedTypeDeclarations` from **any** bundle,
  however it was built. SwiftPM-built apps work. Registration happens when the app is copied into
  `/Applications` and/or first launched. To force it, run
  `…/LaunchServices.framework/Support/lsregister -f /Applications/Prism.app` (path as in the installer).
  Check with `mdls -name kMDItemContentType show.prismlights` → `io.github.goveaaron.prism.show`.
- **SwiftUI `DocumentGroup` + `FileDocument`** with `readableContentTypes = [.prismShow]` gives
  double-click-to-open, Recent Documents and autosave for free. Use it if a show is a document.
- If Prism is a **single-window app** that loads one show at a time: add an
  `@NSApplicationDelegateAdaptor` and implement `application(_:open urls:)`, which is called for files
  *and* `prism://` URLs. Also put `.handlesExternalEvents(matching: [])` on the main scene's content so
  SwiftUI doesn't open an extra window for each event ⚠️ (SwiftUI's routing of external events
  differs between macOS releases, so test it). `.onOpenURL` is the SwiftUI-only alternative.

### 4.10 App Intents (Shortcuts / Siri) with plain SwiftPM ⚠️

- App Intents only appear in Shortcuts if the bundle contains
  **`Contents/Resources/Metadata.appintents/`**. Xcode's *Extract App Intents Metadata* build step
  creates it by running `appintentsmetadataprocessor` over the binary plus Swift const-value files
  the compiler emits. The intent types compile fine with SwiftPM, but **the native `swift build`
  never produces this metadata**, so the intents silently don't show up.
- swift-build (the open-source Xcode build engine) has an `AppIntentsMetadataTaskProducer`. It only
  runs for build-phase targets when `LM_SKIP_METADATA_EXTRACTION` is off and the toolchain provides
  the compiler spec. Whether `swift build --build-system swiftbuild` triggers it for a SwiftPM
  executable is **unverified**. Calling `appintentsmetadataprocessor` by hand is possible, but it has
  many undocumented flags and is fragile.
- **Recommendation:** v1 ships a `prism://` URL scheme (e.g. `prism://cue/next`,
  `prism://scene/Blue`). It works today in Shortcuts ("Open URL"), Stream Deck, and from the shell
  with `open prism://…`. If real App Intents are needed later, add a small generated Xcode project
  (XcodeGen/Tuist) with an app target that depends on the package, and build the release with
  `xcodebuild`. That produces `Metadata.appintents` automatically.

---

## 5. Local Network privacy, embedded server, Bonjour, LAN IPs

### 5.1 What Local Network privacy (LNP) gates on macOS 15+ ✅ (TN3179, revised 2026-10-06)

| Operation | Needs Local Network permission? |
|---|---|
| Listening for and **accepting incoming TCP** connections (the NIO HTTP/WebSocket server for the phone remote) | **No** |
| Replying on an accepted connection (HTTP responses, WebSocket frames) | No (part of the incoming connection) |
| Receiving **unicast** UDP (e.g. OSC sent to the Mac's IP) | No |
| **Sending UDP unicast** to a LAN address (Art-Net unicast, OSC replies to a LAN device) | **Yes** |
| **Sending UDP broadcast** (ArtPoll, broadcast ArtDmx) or **multicast** (sACN) | **Yes** (all of 224.0.0.0/4 and 255.255.255.255 count as local) |
| Connecting a UDP socket, or an outgoing TCP connection to a LAN host (WLED, Hue bridge, …) | Yes |
| Receiving broadcast/multicast; Bonjour register/browse; resolving `.local` names | Yes |
| Loopback (127.0.0.1), and traffic to the Internet (e.g. cloudflared → Cloudflare edge) | No |

Key facts:
- The check happens **inside the network stack**, so it applies to BSD sockets, Network.framework,
  URLSession and SwiftNIO alike. A denied send fails with **`EHOSTUNREACH`** ("No route to host")
  and no packet leaves the Mac. Network.framework connections go to `.waiting` with
  `NWPath.UnsatisfiedReason.localNetworkDenied`. Bonjour fails with **-65570**
  (`kDNSServiceErr_PolicyDenied`).
- The alert appears at the **first gated operation**, and the system **may deny that operation
  immediately**, before the user answers. Retry: keep the output loop running and recover once the
  error stops. Don't treat the first failure as fatal.
- **Exempt:** command-line tools run from Terminal or SSH (and their children), launchd daemons, and
  root. So **`swift run` from Terminal never shows the problem**. Test the bundled .app.
- If Prism spawns a helper such as `cloudflared`, **Prism is the responsible code** and its Info.plist
  string is shown.
- **Identity = code signature.** TN3179 says ad-hoc signing makes tracking unreliable and recommends
  an **Apple-issued** identity. So with ad-hoc builds, expect the prompt again after updates. A
  self-signed certificate (§4.7) gives a stable DR, but whether LNP honours it is ⚠️ unconfirmed.
  TN3178 also requires a **unique LC_UUID** in the main executable (the SwiftPM/ld default).
- Resetting during testing: macOS **27.2+** has +/- buttons in System Settings › Privacy & Security ›
  Local Network. On earlier versions there's no reset; use a fresh user account or a VM.
- Since macOS 15.5, the system-wide defaults `AllowedEthernetLocalNetworkAddresses` and
  `AllowedWiFiLocalNetworkAddresses` (set with sudo, then restart) exempt chosen networks for **all**
  apps. Handy for a dedicated lighting Mac. TN3179 documents the value format.

**UX recommendation:** add an onboarding step "Allow Prism to talk to lighting devices". Clicking it
sends one ArtPoll to the directed broadcast address, which brings up the alert while the user is
expecting it. Show a persistent banner when sends fail with `EHOSTUNREACH`, with a button that opens
`x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork` ⚠️ (deep link not
confirmed on macOS 26; otherwise tell users the path).

### 5.2 Embedded server for the phone remote

- Bind the NIO server to `0.0.0.0:<port>` (e.g. 8787) for LAN access. Accepting phone connections
  needs no LNP permission.
- **macOS Application Firewall** (off by default; on in many managed or "security conscious" setups):
  the first incoming connection to an unsigned or ad-hoc app triggers *"Do you want the application
  'Prism' to accept incoming network connections?"*. The decision is tied to the code signature, so
  **ad-hoc rebuilds prompt again** after every update, while a stable self-signed signature keeps it.
  Developer-ID-signed apps are allowed automatically when "Automatically allow downloaded signed
  software" is on. If only the Cloudflare tunnel is used, bind to **127.0.0.1**; loopback is never
  filtered and nobody is prompted.
- Protect the remote with a random token in the QR URL (`http://192.168.1.23:8787/?k=…`), checked on
  every HTTP request and on the WebSocket upgrade. The LAN isn't trusted, and a tunnel URL is public.

### 5.3 Bonjour advertisement for a SwiftNIO server ✅ (dnssd API; pattern from mattt/iMCP)

`NWListener.service` only advertises an `NWListener`'s own port. For a server you already run with
NIO, register the service with **dnssd** (not deprecated; `NetService` is deprecated):

```swift
import Foundation
import dnssd

/// Advertises the NIO server as _prism._tcp. Callbacks arrive on the main queue.
final class BonjourAdvertiser {
    private var ref: DNSServiceRef?

    /// - Returns: 0 (kDNSServiceErr_NoError) if the request started. Registration itself can still
    ///   fail asynchronously (e.g. -65570 PolicyDenied when Local Network access is denied).
    @discardableResult
    func start(port: UInt16, name: String = "", type: String = "_prism._tcp",
               txt: [String: String] = ["v": "1", "path": "/"]) -> DNSServiceErrorType {
        stop()
        // TXT rdata = sequence of <len><key=value> strings
        let record: [UInt8] = txt.sorted { $0.key < $1.key }.flatMap { key, value -> [UInt8] in
            let bytes = Array("\(key)=\(value)".utf8.prefix(255))
            return [UInt8(bytes.count)] + bytes
        }
        var newRef: DNSServiceRef?
        let err = DNSServiceRegister(
            &newRef,
            0,                    // flags (name conflicts are auto-renamed "Prism (2)")
            0,                    // interface index 0 = all interfaces
            name,                 // "" = use the computer name
            type,
            nil,                  // domain: default ("local.")
            nil,                  // host: this Mac
            port.bigEndian,       // network byte order!
            UInt16(record.count),
            record,
            { _, _, error, _, _, _, _ in
                if error != kDNSServiceErr_NoError { NSLog("Prism Bonjour registration failed: %d", error) }
            },
            nil)
        guard err == kDNSServiceErr_NoError, let newRef else { return err }
        let qerr = DNSServiceSetDispatchQueue(newRef, .main)
        guard qerr == kDNSServiceErr_NoError else { DNSServiceRefDeallocate(newRef); return qerr }
        ref = newRef
        return err
    }

    func stop() {
        if let ref { DNSServiceRefDeallocate(ref) }   // also withdraws the advertisement
        ref = nil
    }

    deinit { stop() }
}
```

Comparing `DNSServiceErrorType` (`Int32`) with `kDNSServiceErr_NoError` (imported as `Int`) compiles
because `BinaryInteger` has heterogeneous `==`/`!=` ✅. Note that a **phone browser can't browse
Bonjour**, so Bonjour only helps a native companion app, or users typing `http://<name>.local:8787`.
iOS resolves `.local`; Android support varies ⚠️. **The QR code with a numeric IP is the main path.**

### 5.4 LAN IPv4 addresses for QR codes ✅

```swift
import Foundation
import Darwin
import SystemConfiguration

struct LANInterface: Hashable, Sendable {
    let name: String          // "en0"
    let address: String       // "192.168.1.23"
    let netmask: String       // "255.255.255.0"
    let broadcast: String?    // "192.168.1.255" (directed broadcast for Art-Net)
}

enum LANAddresses {
    /// Up, running, non-loopback IPv4 interfaces. Skips link-local, VPN tunnels and AWDL.
    static func ipv4() -> [LANInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [LANInterface] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(truncatingIfNeeded: ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let sa = ifa.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            if ["utun", "ipsec", "awdl", "llw", "gif", "stf"].contains(where: { name.hasPrefix($0) }) { continue }
            guard let ip = numericHost(sa), !ip.hasPrefix("169.254.") else { continue }
            let mask = ifa.ifa_netmask.flatMap(numericHost) ?? "255.255.255.0"
            let bcast = (flags & IFF_BROADCAST != 0) ? ifa.ifa_dstaddr.flatMap(numericHost) : nil
            result.append(LANInterface(name: name, address: ip, netmask: mask, broadcast: bcast))
        }
        // Primary interface (default route) first, then by name.
        let primary = primaryInterfaceName()
        return result.sorted { ($0.name == primary ? 0 : 1, $0.name) < ($1.name == primary ? 0 : 1, $1.name) }
    }

    /// Interface that carries the default IPv4 route, e.g. "en0".
    static func primaryInterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Prism" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString),
              let dict = value as? [String: Any] else { return nil }
        return dict["PrimaryInterface"] as? String
    }

    /// Bonjour host name, e.g. "Studio-Mac" → use "Studio-Mac.local".
    static func localHostName() -> String? {
        SCDynamicStoreCopyLocalHostName(nil) as String?
    }

    private static func numericHost(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
```

- `bridge100` (Internet Sharing) and `en*` adapters all show up. Let the user pick when there is more
  than one; show the interface name and IP in the QR panel.
- Watch for network changes with `NWPathMonitor` (not gated by LNP) and regenerate the QR code when
  the path changes.
- The phone must be on the same subnet. Guest Wi-Fi with client isolation blocks it; detect this
  with a "can't connect?" hint that offers the Cloudflare tunnel (§7).

---

## 6. GitHub Actions (macOS runners)

### 6.1 Runner labels and Xcode ✅ (actions/runner-images README and image readmes, images 20261026/20261028)

| Label | Arch | OS | Xcode installed | Notes |
|---|---|---|---|---|
| `macos-latest`, `macos-26`, `macos-26-xlarge` | arm64 (M1 3-core; xlarge = bigger, billed) | macOS 26.6.2 | 26.0.1, 26.1.1, 26.2, 26.3, 26.4.1, 26.5, **26.6 (default)** | **Recommended** |
| `macos-26-intel`, `macos-26-large`, `macos-latest-large` | x64 | macOS 26 | 26.x | `-large` is billed |
| `macos-15`, `macos-15-xlarge` | arm64 | macOS 15.8.2 | 16.0–16.4 (**16.4 default**), 26.0.1–26.3 | |
| `macos-15-intel`, `macos-15-large` | x64 | macOS 15 | same | Intel images supported until about Aug 2027 |
| `xcode-27`, `xcode-27-xlarge` | arm64 | macOS 27.0.1 | Xcode 27 (preview) | New label style; preview, may change |
| `macos-14` | — | — | — | **Retired from GitHub Actions on 2 Nov 2026** |

- Image policy: **one Xcode major version per macOS image**. All minor versions of it are present, and
  a new patch release replaces the previous one. So pin a minor version you know exists and update
  it when the image changes. Check `xcodebuild -version` / `swift --version` in the log. Xcode 26.x
  ships Swift 6.2–6.3 ⚠️ (Swift version per Xcode minor not listed in the readme).
- **Selecting Xcode:** set the `DEVELOPER_DIR` env var (`/Applications/Xcode_26.6.app/Contents/Developer`;
  per step or job, no sudo), or run `sudo xcode-select -s /Applications/Xcode_26.6.app` (passwordless
  sudo works on hosted runners). `maxim-lobanov/setup-xcode@v1.7.0` (`xcode-version: '26.6'`) does
  the same.
- `macos-latest` moves gradually (over 1–2 months) when a new OS becomes "latest". Use **`macos-26`**
  for reproducible builds.
- The macOS 26 image is switching its **default OpenSSL from 3 to 4** (runner-images issue #14856).
  This matters only if you script `openssl pkcs12` (§4.7).
- Current action versions (Nov 2026): `actions/checkout@v7` (7.0.1), `actions/cache@v6` (6.1.0),
  `actions/upload-artifact@v7` (7.0.2), `actions/download-artifact@v8` (8.0.2),
  `softprops/action-gh-release@v3` (3.0.4). `gh` 2.103 is preinstalled on all images.

### 6.2 Limits and billing ✅ (GitHub docs, "Actions limits" / billing)

- **Public repo + standard GitHub-hosted runners = free, unlimited minutes.** Larger runners
  (`-large`, `-xlarge`) are always billed.
- Concurrency (Free plan): **20 concurrent jobs, at most 5 of them macOS**. Job timeout **6 h**.
  Use `concurrency:` to cancel superseded PR runs.
- Cache: **10 GB per repo** (least recently used entries are evicted). Artifacts and logs: default
  retention 90 days. Storage quotas apply to private repos only.

### 6.3 Workflow: test, bundle, upload, release on tag ✅

```yaml
# .github/workflows/build.yml
name: build
on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:
  workflow_dispatch:

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

permissions:
  contents: read

jobs:
  build:
    runs-on: macos-26
    timeout-minutes: 60
    env:
      DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer
      HAS_SIGNING_CERT: ${{ secrets.SIGNING_P12_BASE64 != '' }}
    steps:
      - uses: actions/checkout@v7

      - name: Toolchain
        run: |
          xcodebuild -version
          swift --version

      - name: Cache SwiftPM build
        uses: actions/cache@v6
        with:
          path: .build
          key: spm-${{ runner.os }}-${{ runner.arch }}-xcode26.6-${{ hashFiles('Package.resolved', 'Package.swift') }}
          restore-keys: |
            spm-${{ runner.os }}-${{ runner.arch }}-xcode26.6-

      - name: Test
        run: swift test --parallel

      - name: Version
        id: ver
        run: |
          if [[ "$GITHUB_REF_TYPE" == "tag" ]]; then V="${GITHUB_REF_NAME#v}"; else V="0.0.${GITHUB_RUN_NUMBER}"; fi
          echo "version=$V" >> "$GITHUB_OUTPUT"

      # Optional stable signing identity (§4.7). Leave the secrets unset to fall back to ad-hoc.
      - name: Import signing certificate
        if: env.HAS_SIGNING_CERT == 'true'
        env:
          SIGNING_P12_BASE64: ${{ secrets.SIGNING_P12_BASE64 }}
          SIGNING_P12_PASSWORD: ${{ secrets.SIGNING_P12_PASSWORD }}
        run: |
          KC="$RUNNER_TEMP/signing.keychain-db"; KC_PW="$(uuidgen)"
          echo "$SIGNING_P12_BASE64" | base64 --decode > "$RUNNER_TEMP/cert.p12"
          security create-keychain -p "$KC_PW" "$KC"
          security set-keychain-settings -lut 21600 "$KC"
          security unlock-keychain -p "$KC_PW" "$KC"
          security import "$RUNNER_TEMP/cert.p12" -P "$SIGNING_P12_PASSWORD" -A -t cert -f pkcs12 -k "$KC"
          security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PW" "$KC"
          security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
          HASH="$(security find-identity -p codesigning "$KC" | awk '/Prism Code Signing/ {print $2; exit}')"
          echo "SIGN_IDENTITY=$HASH" >> "$GITHUB_ENV"

      - name: Bundle
        run: scripts/bundle-app.sh "${{ steps.ver.outputs.version }}" "$GITHUB_RUN_NUMBER"

      - name: Smoke test + screenshot
        run: |
          # Launch the binary directly: it inherits the runner agent's TCC grants (see 6.4).
          PRISM_CI_DEMO=1 ./dist/Prism.app/Contents/MacOS/Prism &
          APP_PID=$!
          sleep 10
          kill -0 "$APP_PID"                    # fails the step if the app crashed on launch
          screencapture -x dist/screenshot.png
          kill "$APP_PID" || true

      - uses: actions/upload-artifact@v7
        with:
          name: Prism-${{ steps.ver.outputs.version }}
          path: |
            dist/Prism.zip
            dist/Prism.zip.sha256
            dist/screenshot.png
          retention-days: 30

  release:
    if: startsWith(github.ref, 'refs/tags/v')
    needs: build
    runs-on: ubuntu-latest            # no need to spend a macOS slot on uploading
    permissions:
      contents: write
    steps:
      - uses: actions/download-artifact@v8
        with:
          path: dist
          merge-multiple: true
      - name: Create GitHub release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "$GITHUB_REF_NAME" dist/Prism.zip dist/Prism.zip.sha256 \
            --repo "$GITHUB_REPOSITORY" --title "Prism ${GITHUB_REF_NAME#v}" \
            --generate-notes --verify-tag
```

Notes:
- Secrets can't be used directly in `if:`. The job-level `HAS_SIGNING_CERT` flag
  (`${{ secrets.X != '' }}`; the `secrets` context *is* allowed in `jobs.<id>.env`) evaluates to the
  string `'true'`/`'false'`, and the step tests that. The secrets themselves are only exposed to
  that one step.
- Caching `.build` saves the SwiftNIO compile (several minutes). Keep the Xcode version in the key,
  because module caches from another compiler cause odd errors. If a cached build ever misbehaves,
  bump the key prefix.
- Pre-release tags (`v1.2.0-beta.1`): add `--prerelease`. `releases/latest/download/…` (used by the
  installer) skips pre-releases.
- `softprops/action-gh-release@v3` is an alternative to the `gh` command; both need
  `contents: write`.

### 6.4 GUI apps and screenshots on hosted runners ✅ (runner-images `configure-tccdb-macos.sh`)

- Hosted macOS runners run a logged-in GUI session. The image pre-populates the TCC database with
  **Screen Capture** for `/bin/bash`, the runner agent (`hosted-compute-agent`/provisioner),
  Terminal and `osascript`. It also pre-approves `replayd`. So **`screencapture -x file.png` works**
  from a `run:` step.
- The agent/provisioner also hold the **Microphone** grant. A binary started **directly** from a step
  is attributed to the agent (its responsible process) and inherits these grants. Starting it with
  **`open Prism.app`** makes Prism its own responsible process, so any TCC prompt (camera, mic,
  speech, Local Network) appears and **blocks forever** with nobody to click it. Add a CI/demo mode
  (`PRISM_CI_DEMO=1`) that touches no protected resources.
- Expect a small default display resolution ⚠️. Size the window to fit, or capture a window with
  `screencapture -l <windowID>`.

---

## 7. Cloudflare quick tunnels (and alternatives)

### 7.1 Facts ✅ (Cloudflare "Quick Tunnels" docs, updated 2026-09-30; cloudflared release 2026.10.7)

- Command: `cloudflared tunnel --url http://127.0.0.1:8787 --no-autoupdate`. **No Cloudflare account
  and no login needed.** It prints a random `https://<words>.trycloudflare.com` URL. The hostname
  **changes on every run**.
- **WebSockets work** through quick tunnels (Cloudflare proxies the upgrade). **Server-Sent Events
  are not supported**, so the remote must use WebSockets or polling. There is a limit of about **200
  in-flight requests** (HTTP 429 beyond that), no uptime guarantee, and Cloudflare positions it for
  testing/development.
- Older Cloudflare docs said quick tunnels don't start when `~/.cloudflared/config.yaml` exists. The
  current page no longer says so ⚠️. Detect that file anyway and warn the user if the tunnel fails.
- cloudflared tries QUIC (UDP 7844) first and falls back to HTTP/2 (TCP 7844). On networks that block
  this, add `--protocol http2`.
- The tunnel is **public**. Anyone who learns the URL can reach the server, so always require the
  random token (§5.2).
- **Optional email gate (cloudflared ≥ 2026.9.3):** `--allowed-mail you@example.com` (repeatable,
  comma-separated, or `'*@example.com'`). Visitors get a Cloudflare Access one-time PIN by email
  before any request reaches the Mac. Neither side needs a Cloudflare account. The session lasts up to
  4 h and ends when cloudflared exits. It only works in an interactive browser, so a phone opening the
  remote page is fine. The page's WebSocket should carry the session cookie (same origin) but this is
  not tested ⚠️. Offer it as a "protect remote with my email" setting and keep the token check
  anyway.
- `--output json` turns every log line into a JSON object (Cloudflare blog, 2026-10-02). The JSON keys
  aren't documented ⚠️. The URL regex in 7.3 matches inside JSON lines too, so either mode works.

### 7.2 Downloads and checksums ✅ (verified by downloading the arm64 asset)

Latest release **2026.10.7** (2026-10-30). Asset URL pattern:
`https://github.com/cloudflare/cloudflared/releases/download/2026.10.7/<asset>`

| Asset | SHA-256 of the **.tgz** (GitHub asset digest) | SHA-256 listed in the release notes (= the extracted **binary**) |
|---|---|---|
| `cloudflared-darwin-arm64.tgz` | `3586ccf397e98e5f437e60e7c307ca6ac463e110580503af8bb8e6f9ebf831bd` ✅ | `2136431d5eb467bf447d2ee514b713e192719b143aec1d9e09bf7dc290d5bb12` ✅ |
| `cloudflared-darwin-amd64.tgz` | `02f3edfd87684dd5b705607688e4eb4b323f6e777b81e7b3a85af556aa356848` | `5c55e77da7012cebca19170357e196176c48c9647cc2ead404702fa125ddbd86` ⚠️ (by analogy) |

> [!WARNING]
> The release notes' "SHA256 Checksums" section labels its values `cloudflared-darwin-arm64.tgz: …`,
> but **those values are the hash of the `cloudflared` binary inside the archive, not of the .tgz**
> (checked: the downloaded tgz hashes to `3586cc…`, and the extracted binary to `2136431…`).
> Verify the archive against the GitHub asset digest (`gh api repos/cloudflare/cloudflared/releases/tags/2026.10.7`
> → `assets[].digest`) **or** verify the extracted binary against the release-notes value.

- The archive holds a single file, `cloudflared` (Mach-O arm64, 39.5 MB, mode 755) ✅. The binary has
  an embedded Apple certificate chain, so it is codesigned (presumably Developer ID ⚠️).
- `.pkg` installers and Homebrew (`brew install cloudflared`) also exist. For an app, download on
  demand into `~/Library/Application Support/Prism/bin/` instead of bundling 40 MB per arch.
  URLSession downloads from a non-sandboxed app get **no quarantine xattr** unless the app sets
  `LSFileQuarantineEnabled`, so the binary runs without Gatekeeper prompts.

```bash
# Shell (CI or the installer script)
V=2026.10.7
case "$(uname -m)" in
  arm64)  A=arm64; SHA=3586ccf397e98e5f437e60e7c307ca6ac463e110580503af8bb8e6f9ebf831bd ;;
  x86_64) A=amd64; SHA=02f3edfd87684dd5b705607688e4eb4b323f6e777b81e7b3a85af556aa356848 ;;
esac
curl -fL -o cloudflared.tgz "https://github.com/cloudflare/cloudflared/releases/download/$V/cloudflared-darwin-$A.tgz"
echo "$SHA  cloudflared.tgz" | shasum -a 256 -c -
tar -xzf cloudflared.tgz && chmod +x cloudflared && ./cloudflared --version
```

### 7.3 Swift: installer + tunnel runner ✅ (Foundation `Process`, CryptoKit)

```swift
import Foundation
import CryptoKit

enum CloudflaredInstaller {
    static let version = "2026.10.7"
    #if arch(arm64)
    static let asset = "cloudflared-darwin-arm64.tgz"
    static let tgzSHA256 = "3586ccf397e98e5f437e60e7c307ca6ac463e110580503af8bb8e6f9ebf831bd"
    #else
    static let asset = "cloudflared-darwin-amd64.tgz"
    static let tgzSHA256 = "02f3edfd87684dd5b705607688e4eb4b323f6e777b81e7b3a85af556aa356848"
    #endif

    static var binaryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Prism/bin/cloudflared")
    }

    /// Downloads, verifies and unpacks cloudflared (if needed). Returns the executable URL.
    static func ensureInstalled() async throws -> URL {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: binaryURL.path) { return binaryURL }
        let url = URL(string: "https://github.com/cloudflare/cloudflared/releases/download/\(version)/\(asset)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == tgzSHA256 else { throw URLError(.cannotDecodeContentData) }

        let dir = binaryURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tgz = dir.appendingPathComponent(asset)
        try data.write(to: tgz, options: .atomic)
        defer { try? fm.removeItem(at: tgz) }

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", tgz.path, "-C", dir.path]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0, fm.isExecutableFile(atPath: binaryURL.path) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return binaryURL
    }
}

/// Runs a quick tunnel to the local remote-control server and reports its public URL.
final class QuickTunnel: @unchecked Sendable {
    enum Event: Sendable { case starting, ready(URL), exited(Int32) }
    var onEvent: (@Sendable (Event) -> Void)?

    private let lock = NSLock()
    private var process: Process?
    private var log = ""
    private var announced = false

    /// - Parameter allowedMail: optional email gate (`--allowed-mail`, cloudflared ≥ 2026.9.3, §7.1),
    ///   e.g. ["me@example.com"] or ["*@example.com"].
    func start(cloudflared: URL, localPort: UInt16, allowedMail: [String] = []) throws {
        stop()
        let p = Process()
        p.executableURL = cloudflared
        var args = ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:\(localPort)"]
        if !allowedMail.isEmpty { args += ["--allowed-mail", allowedMail.joined(separator: ",")] }
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe                                  // banner + logs go to stderr
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }       // EOF
            self?.consume(String(decoding: data, as: UTF8.self))
        }
        p.terminationHandler = { [weak self] proc in self?.onEvent?(.exited(proc.terminationStatus)) }
        lock.lock(); process = p; log = ""; announced = false; lock.unlock()
        onEvent?(.starting)
        try p.run()
    }

    /// Call from applicationWillTerminate too: a child process outlives a crashed parent.
    func stop() {
        lock.lock(); let p = process; process = nil; lock.unlock()
        guard let p, p.isRunning else { return }
        p.terminationHandler = nil
        p.terminate()                                           // SIGTERM → graceful shutdown
    }

    private func consume(_ chunk: String) {
        lock.lock()
        log += chunk
        if log.count > 100_000 { log = String(log.suffix(20_000)) }
        let text = log
        let already = announced
        lock.unlock()
        guard !already else { return }
        // The URL is printed first; it becomes reachable after "Registered tunnel connection".
        // Skip api.trycloudflare.com, which appears in error messages.
        let pattern = #"https://(?!api\.)[a-z0-9-]+\.trycloudflare\.com"#
        guard let r = text.range(of: pattern, options: .regularExpression),
              text.contains("Registered tunnel connection"),
              let url = URL(string: String(text[r])) else { return }
        lock.lock(); announced = true; lock.unlock()
        onEvent?(.ready(url))
    }
}
```

Operational notes:
- Bind the NIO server to 127.0.0.1 when only the tunnel is used (no firewall prompt, §5.2). The
  tunnel's loopback connection isn't subject to Local Network privacy, and the outbound connection to
  Cloudflare is Internet traffic.
- Orphans: if Prism crashes, `cloudflared` keeps running. Save the child PID in `UserDefaults`. On the
  next launch, check it with `proc_pidpath` (must be our binary path) and send `kill(pid, SIGTERM)`.
- The URL changes each run, so regenerate the QR code on every `.ready`. DNS for a new hostname can
  take a few seconds to propagate even after `ready`. Let the phone retry.
- Logs use `INF`/`ERR` prefixes. Show the last lines in a "Tunnel log" sheet for support.

### 7.4 Alternatives (brief)

| Option | Account | Notes |
|---|---|---|
| **Tailscale Funnel** | Tailscale account and the app on the Mac | `tailscale funnel 8787`. Stable `https://<machine>.<tailnet>.ts.net` URL, public ports 443/8443/10000 only. Better for repeat users |
| **ngrok** | Account and authtoken required | Free tier shows a browser interstitial (skip it with the `ngrok-skip-browser-warning` header, not possible from a QR scan) and includes one static domain |
| **Cloudflare named tunnel** | Free account plus your own domain | Stable hostname, no 200-request limit. More setup (login, DNS) |
| LAN only | none | Default. QR with the LAN IP (§5.4) |

---

## 8. CoreMIDI and OSC

### 8.1 CoreMIDI with the UMP API (macOS 11+) ✅ (signatures from the CoreMIDI Swift interface; patterns from AudioKit, MorkAndMIDI, Hammerspoon2)

- `MIDIClientCreateWithBlock` delivers notifications (e.g. `.msgSetupChanged` when devices come or
  go) **on the run loop that was current when the client was created**. Create the client on the
  **main thread**. If you create it on a GCD worker without a run loop, the notifications never
  arrive.
- `MIDIInputPortCreateWithProtocol(…, ._1_0, …)` hands you a `MIDIEventList` of **Universal MIDI
  Packets** on a **high-priority CoreMIDI thread**. Decode quickly and hop to your own queue or actor.
  Asking for protocol `._1_0` gives MIDI 1.0 channel-voice messages as UMP type 0x2 (one 32-bit word
  each).
- The legacy `MIDIInputPortCreateWithBlock` / `MIDIPacketList` / `MIDISend` API still works but is
  slated for deprecation. Don't start new code on it.

```swift
import CoreMIDI
import Foundation

enum MIDIMessage: Equatable, Sendable {
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    case noteOff(channel: UInt8, note: UInt8, velocity: UInt8)
    case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
    case programChange(channel: UInt8, program: UInt8)
    case pitchBend(channel: UInt8, value: UInt16)              // 0…16383, centre 8192
    case clock, start, resume, stop                            // 0xF8, 0xFA, 0xFB (Continue), 0xFC

    /// Decodes the first word of a UMP message: type 0x2 (MIDI 1.0 channel voice) or 0x1 (system).
    static func decode(_ w: UInt32) -> MIDIMessage? {
        switch w >> 28 {
        case 0x2:
            let status = UInt8((w >> 16) & 0xF0), ch = UInt8((w >> 16) & 0x0F)
            let d1 = UInt8((w >> 8) & 0x7F), d2 = UInt8(w & 0x7F)
            switch status {
            case 0x80: return .noteOff(channel: ch, note: d1, velocity: d2)
            case 0x90: return d2 == 0 ? .noteOff(channel: ch, note: d1, velocity: 0)
                                      : .noteOn(channel: ch, note: d1, velocity: d2)
            case 0xB0: return .controlChange(channel: ch, controller: d1, value: d2)
            case 0xC0: return .programChange(channel: ch, program: d1)
            case 0xE0: return .pitchBend(channel: ch, value: UInt16(d2) << 7 | UInt16(d1))
            default:   return nil
            }
        case 0x1:
            switch (w >> 16) & 0xFF {
            case 0xF8: return .clock
            case 0xFA: return .start
            case 0xFB: return .resume
            case 0xFC: return .stop
            default:   return nil
            }
        default:
            return nil
        }
    }

    /// One UMP word (group 0) for sending, e.g. LED feedback.
    var umpWord: UInt32? {
        func cv(_ status: UInt8, _ ch: UInt8, _ d1: UInt8, _ d2: UInt8) -> UInt32 {
            0x2000_0000 | UInt32(status | (ch & 0x0F)) << 16 | UInt32(d1 & 0x7F) << 8 | UInt32(d2 & 0x7F)
        }
        switch self {
        case let .noteOn(c, n, v):         return cv(0x90, c, n, v)
        case let .noteOff(c, n, v):        return cv(0x80, c, n, v)
        case let .controlChange(c, cc, v): return cv(0xB0, c, cc, v)
        case let .programChange(c, p):     return cv(0xC0, c, p, 0)
        case let .pitchBend(c, v):         return cv(0xE0, c, UInt8(v & 0x7F), UInt8((v >> 7) & 0x7F))
        default:                           return nil
        }
    }
}

struct MIDIError: Error { let status: OSStatus }

/// Create and start on the main thread.
final class MIDIManager: @unchecked Sendable {
    /// Called on CoreMIDI's receive thread with the source endpoint the message came from.
    var onMessage: (@Sendable (MIDIMessage, MIDIEndpointRef) -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var connected = Set<MIDIEndpointRef>()            // main-thread only

    func start() throws {
        var status = MIDIClientCreateWithBlock("Prism" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged { self?.connectAllSources() }
        }
        guard status == noErr else { throw MIDIError(status: status) }

        status = MIDIInputPortCreateWithProtocol(client, "Prism Input" as CFString, ._1_0, &inputPort) {
            [weak self] eventList, srcConnRefCon in
            let source = MIDIEndpointRef(truncatingIfNeeded: UInt(bitPattern: srcConnRefCon))
            self?.receive(eventList, from: source)
        }
        guard status == noErr else { throw MIDIError(status: status) }

        status = MIDIOutputPortCreate(client, "Prism Output" as CFString, &outputPort)
        guard status == noErr else { throw MIDIError(status: status) }
        connectAllSources()
    }

    func stop() {
        if inputPort != 0 { MIDIPortDispose(inputPort); inputPort = 0 }
        if outputPort != 0 { MIDIPortDispose(outputPort); outputPort = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        connected.removeAll()
    }

    /// Connects every source (call again on .msgSetupChanged). The endpoint ref doubles as refCon.
    func connectAllSources() {
        var current = Set<MIDIEndpointRef>()
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            guard src != 0 else { continue }
            current.insert(src)
            if !connected.contains(src) {
                MIDIPortConnectSource(inputPort, src, UnsafeMutableRawPointer(bitPattern: UInt(src)))
            }
        }
        for gone in connected.subtracting(current) { MIDIPortDisconnectSource(inputPort, gone) }
        connected = current
    }

    private func receive(_ list: UnsafePointer<MIDIEventList>, from source: MIDIEndpointRef) {
        for packet in list.unsafeSequence() {                  // UnsafePointer<MIDIEventPacket>
            let words = MIDIEventPacket.WordCollection(packet)  // honours packet.wordCount
            var i = words.startIndex
            while i < words.endIndex {
                let w = words[i]
                if let m = MIDIMessage.decode(w) { onMessage?(m, source) }
                // Step over multi-word UMP messages (SysEx, MIDI 2.0, …) by message type.
                i = words.index(i, offsetBy: Self.umpWordCount(w >> 28), limitedBy: words.endIndex) ?? words.endIndex
            }
        }
    }

    static func umpWordCount(_ messageType: UInt32) -> Int {
        switch messageType {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC:                return 3
        default:                      return 4                 // 0x5, 0xD, 0xE, 0xF
        }
    }

    // MARK: Output (controller LED feedback)

    func send(_ message: MIDIMessage, to destination: MIDIEndpointRef) {
        guard let word = message.umpWord else { return }
        send(words: [word], to: destination)
    }

    func send(words: [UInt32], to destination: MIDIEndpointRef) {
        let builder = MIDIEventList.Builder(inProtocol: ._1_0, wordSize: 64)
        builder.append(timestamp: 0, words: words)             // timestamp 0 = now
        _ = builder.withUnsafePointer { MIDISendEventList(outputPort, destination, $0) }
    }

    // MARK: Endpoint info

    static func destinations() -> [(ref: MIDIEndpointRef, name: String)] {
        (0..<MIDIGetNumberOfDestinations()).map { i in
            let d = MIDIGetDestination(i)
            return (d, displayName(d))
        }
    }

    static func displayName(_ obj: MIDIObjectRef) -> String {
        var name: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(obj, kMIDIPropertyDisplayName, &name) == noErr, let name else { return "?" }
        return name.takeRetainedValue() as String
    }

    /// Persist this (not the endpoint ref or name) to remember the user's controller.
    static func uniqueID(_ obj: MIDIObjectRef) -> MIDIUniqueID {
        var id: MIDIUniqueID = 0
        MIDIObjectGetIntegerProperty(obj, kMIDIPropertyUniqueID, &id)
        return id
    }
}
```

Notes:
- A controller's input and output endpoints belong to the same **entity**. Pair them with
  `MIDIEndpointGetEntity(endpoint, &entity)` so feedback goes to the device that sent the message.
  Look endpoints up again later with `MIDIObjectFindByUniqueID(id, &object, &type)`.
- C-API alternative to `MIDIEventList.Builder`: allocate a `MIDIEventList`, call
  `MIDIEventListInit(listPtr, ._1_0)` → `MIDIEventListAdd(listPtr, MemoryLayout<MIDIEventList>.size, packet, 0, words.count, wordsPtr)`
  → `MIDISendEventList(port, dest, listPtr)`. Use `withUnsafeMutablePointer` and never let the pointer
  escape the closure.
- Throttle LED feedback (≤ ~100 messages per refresh). Many controllers drop messages when flooded
  over USB.

### 8.2 OSC 1.0/1.1 over UDP ✅ (OSC 1.0 spec + 1.1 type tags)

Encoding rules:
- **OSC-string**: UTF-8/ASCII bytes, a terminating NUL, then NUL padding up to a multiple of 4 bytes.
- **Message**: address (`/prism/fader/1`), then a type-tag string starting with `,`, then the
  arguments. Every element is 4-byte aligned and all numbers are **big-endian**.
- Types: `i` int32, `f` float32, `s` string, `b` blob (int32 size + bytes + pad), `h` int64,
  `d` float64. These carry no data: `T` true, `F` false, `N` nil, `I` impulse.
- **Bundle**: `"#bundle\0"`, then an 8-byte NTP time tag (`1` = immediately), then repeated
  (int32 size + element), where each element is a message or another bundle.

```swift
import Foundation

enum OSCArgument: Equatable, Sendable {
    case int(Int32), float(Float), string(String), blob([UInt8])
    case int64(Int64), double(Double), bool(Bool), null, impulse
}

struct OSCMessage: Equatable, Sendable {
    var address: String
    var arguments: [OSCArgument]

    func encoded() -> [UInt8] {
        var out: [UInt8] = []
        OSC.appendString(address, to: &out)
        var tags = ","
        var data: [UInt8] = []
        for arg in arguments {
            switch arg {
            case .int(let v):    tags += "i"; OSC.append32(UInt32(bitPattern: v), to: &data)
            case .float(let v):  tags += "f"; OSC.append32(v.bitPattern, to: &data)
            case .string(let s): tags += "s"; OSC.appendString(s, to: &data)
            case .blob(let b):   tags += "b"; OSC.append32(UInt32(b.count), to: &data); data += b; OSC.pad(&data)
            case .int64(let v):  tags += "h"; OSC.append64(UInt64(bitPattern: v), to: &data)
            case .double(let v): tags += "d"; OSC.append64(v.bitPattern, to: &data)
            case .bool(let v):   tags += v ? "T" : "F"
            case .null:          tags += "N"
            case .impulse:       tags += "I"
            }
        }
        OSC.appendString(tags, to: &out)
        return out + data
    }
}

indirect enum OSCPacket: Equatable, Sendable {
    case message(OSCMessage)
    case bundle(timeTag: UInt64, elements: [OSCPacket])        // timeTag 1 = immediately

    func encoded() -> [UInt8] {
        switch self {
        case .message(let m):
            return m.encoded()
        case let .bundle(timeTag, elements):
            var out = OSC.bundleTag
            OSC.append64(timeTag, to: &out)
            for e in elements {
                let bytes = e.encoded()
                OSC.append32(UInt32(bytes.count), to: &out)
                out += bytes
            }
            return out
        }
    }

    static func decode(_ bytes: [UInt8]) -> OSCPacket? {
        var reader = OSCReader(bytes)
        return reader.packet()
    }
}

enum OSC {
    static let bundleTag: [UInt8] = Array("#bundle".utf8) + [0]
    static func pad(_ out: inout [UInt8]) { while out.count % 4 != 0 { out.append(0) } }
    static func appendString(_ s: String, to out: inout [UInt8]) { out += Array(s.utf8); out.append(0); pad(&out) }
    static func append32(_ v: UInt32, to out: inout [UInt8]) {
        out += [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    static func append64(_ v: UInt64, to out: inout [UInt8]) {
        append32(UInt32(v >> 32), to: &out); append32(UInt32(v & 0xFFFF_FFFF), to: &out)
    }
}

struct OSCReader {
    private let b: [UInt8]
    private var i = 0
    init(_ bytes: [UInt8]) { b = bytes }

    mutating func packet() -> OSCPacket? {
        if b.starts(with: OSC.bundleTag) {
            i = 8
            guard let timeTag = u64() else { return nil }
            var elements: [OSCPacket] = []
            while i < b.count {
                guard let size = u32().map({ Int($0) }), size % 4 == 0, i + size <= b.count else { return nil }
                var sub = OSCReader(Array(b[i..<(i + size)]))
                guard let element = sub.packet() else { return nil }
                elements.append(element)
                i += size
            }
            return .bundle(timeTag: timeTag, elements: elements)
        }
        guard let address = string(), address.hasPrefix("/") else { return nil }
        if i >= b.count { return .message(OSCMessage(address: address, arguments: [])) }  // no type tags
        guard let tags = string(), tags.hasPrefix(",") else { return nil }
        var args: [OSCArgument] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "i": guard let v = u32() else { return nil }; args.append(.int(Int32(bitPattern: v)))
            case "f": guard let v = u32() else { return nil }; args.append(.float(Float(bitPattern: v)))
            case "s", "S": guard let s = string() else { return nil }; args.append(.string(s))
            case "b":
                guard let n = u32().map({ Int($0) }), i + n <= b.count else { return nil }
                args.append(.blob(Array(b[i..<(i + n)])))
                i = min(b.count, i + ((n + 3) & ~3))
            case "h": guard let v = u64() else { return nil }; args.append(.int64(Int64(bitPattern: v)))
            case "d": guard let v = u64() else { return nil }; args.append(.double(Double(bitPattern: v)))
            case "T": args.append(.bool(true))
            case "F": args.append(.bool(false))
            case "N": args.append(.null)
            case "I": args.append(.impulse)
            default:  return nil            // t, c, r, m, arrays: add if you need them
            }
        }
        return .message(OSCMessage(address: address, arguments: args))
    }

    private mutating func string() -> String? {
        guard i < b.count, let end = b[i...].firstIndex(of: 0) else { return nil }
        let s = String(decoding: b[i..<end], as: UTF8.self)
        i = min(b.count, (end + 4) & ~3)                       // skip NUL + padding
        return s
    }

    private mutating func u32() -> UInt32? {
        guard i + 4 <= b.count else { return nil }
        defer { i += 4 }
        return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    private mutating func u64() -> UInt64? {
        guard let hi = u32(), let lo = u32() else { return nil }
        return UInt64(hi) << 32 | UInt64(lo)
    }
}
```

Receiving OSC (unicast UDP to the Mac is **not** gated by Local Network privacy; *sending* replies to
a LAN device is):

```swift
import Foundation
import Network

final class OSCServer: @unchecked Sendable {
    var onPacket: (@Sendable (OSCPacket, NWEndpoint) -> Void)?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "Prism.OSC")

    func start(port: UInt16) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw POSIXError(.EINVAL) }
        let l = try NWListener(using: .udp, on: nwPort)
        l.newConnectionHandler = { [weak self] connection in   // one NWConnection per remote sender
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(on: connection)
        }
        l.start(queue: queue)
        listener = l
    }

    func stop() { listener?.cancel(); listener = nil }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data, let packet = OSCPacket.decode([UInt8](data)) {
                self?.onPacket?(packet, connection.endpoint)
            }
            if error == nil { self?.receive(on: connection) } else { connection.cancel() }
        }
    }
}
```

Send OSC with `UDPSocket.send(OSCPacket.message(…).encoded(), to: host, port: port)` (§3.5). Typical
ports: TouchOSC 8000/9000, QLab 53000/53001.

---

## 9. Sleep prevention, launch at login, single instance

### 9.1 Keeping the Mac awake while outputting ✅ (IOPMLib.h, QA1340; same calls as ControlPlane, cmux, apple/security-pcc)

What sleep does to Prism: the USB bus is suspended (the FTDI widget may come back as a *new*
`IOSerialBSDClient`, so you hit the `ENXIO` and reconnect path in §2.5) and sockets go quiet. An
ENTTEC Pro has no new data, so the rig doesn't black out. It freezes on the last look until the Mac
wakes.

| Mechanism | Prevents | Does not prevent |
|---|---|---|
| `kIOPMAssertionTypePreventUserIdleSystemSleep` (`caffeinate -i`) | Idle system sleep | Lid close (unless in clamshell mode with an external display and power), Apple menu › Sleep, low battery, thermal sleep. The display can still sleep, which is fine for DMX |
| `kIOPMAssertionTypePreventUserIdleDisplaySleep` (`caffeinate -d`) | Idle display sleep. Use it for an optional "keep screen on during show" setting | — |
| `ProcessInfo.beginActivity(options: .userInitiated…)` | **App Nap** and timer throttling, plus idle system sleep (`.userInitiated` includes `.idleSystemSleepDisabled`) | Same as the first row |
| `kIOPMAssertionTypePreventSystemSleep` (`caffeinate -s`) | System sleep, but only on AC power | Not needed by Prism |

Hold these only while at least one output is running, so an idle laptop can still sleep:

```swift
import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from idle-sleeping and disables App Nap while at least one output runs.
/// Reference-counted and thread-safe: `acquire()` when an output starts, `release()` when it stops.
final class KeepAwake: @unchecked Sendable {
    static let shared = KeepAwake()

    private let lock = NSLock()
    private var count = 0
    private var activity: NSObjectProtocol?
    private var systemAssertion: IOPMAssertionID = 0          // 0 == kIOPMNullAssertionID
    private var displayAssertion: IOPMAssertionID = 0
    private var keepDisplayOn = false

    func acquire(reason: String = "Prism is sending DMX") {
        lock.lock(); defer { lock.unlock() }
        count += 1
        guard count == 1 else { return }
        // .userInitiated: no App Nap, no idle system sleep. .latencyCritical: no timer coalescing.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: reason)
        systemAssertion = Self.createAssertion(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, reason)
        if keepDisplayOn {
            displayAssertion = Self.createAssertion(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, reason)
        }
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        guard count > 0 else { return }
        count -= 1
        guard count == 0 else { return }
        Self.releaseAssertion(&systemAssertion)
        Self.releaseAssertion(&displayAssertion)
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    /// Optional "keep the screen on while a show runs" setting.
    func setKeepDisplayOn(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        keepDisplayOn = on
        if on, count > 0, displayAssertion == 0 {
            displayAssertion = Self.createAssertion(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                    "Prism show running")
        } else if !on {
            Self.releaseAssertion(&displayAssertion)
        }
    }

    private static func createAssertion(_ type: CFString, _ reason: String) -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 reason as CFString, &id)
        return result == kIOReturnSuccess ? id : 0
    }

    private static func releaseAssertion(_ id: inout IOPMAssertionID) {
        if id != 0 { IOPMAssertionRelease(id); id = 0 }
    }
}
```

- The `kIOPMAssertionType…` names are `CFSTR()` macros, and Swift imports them as `String`. Writing
  `as CFString` compiles whether the SDK hands you `String` or `CFString`. `kIOPMAssertionLevelOn`
  comes in as `Int`, so wrap it in `IOPMAssertionLevel(...)`.
- To check it: `pmset -g assertions | grep -i prism` should show
  `PreventUserIdleSystemSleep named: "Prism is sending DMX"`. Activity Monitor's *Preventing Sleep*
  column should say *Yes*, and its *App Nap* column *No*.
- The kernel drops assertions when the process exits, including after a crash.
- The Info.plist template in 4.2 doesn't opt into `NSSupportsSuddenTermination` or
  `NSSupportsAutomaticTermination`, and should stay that way. If someone adds one, also call
  `ProcessInfo.processInfo.disableSuddenTermination()` while outputting.

The Mac can still sleep (lid closed, Apple menu), so recover on wake:

```swift
import AppKit

/// Re-open widgets and resend full frames after wake. LAN addresses may have changed too (§5.4).
final class SleepWakeObserver {
    private var tokens: [NSObjectProtocol] = []

    init(onSleep: @escaping () -> Void, onWake: @escaping () -> Void) {
        let center = NSWorkspace.shared.notificationCenter     // NOT NotificationCenter.default
        tokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                         queue: .main) { _ in onSleep() })
        tokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                         queue: .main) { _ in onWake() })
    }

    deinit { tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }
}
```

### 9.2 Launch at login ✅ (`SMAppService`, macOS 13+; pattern from sindresorhus/LaunchAtLogin-Modern)

```swift
import AppKit
import ServiceManagement

/// "Launch at login" through SMAppService.mainApp. Always show the *live* status: the user can
/// change it at any time in System Settings › General › Login Items & Extensions.
enum LaunchAtLogin {
    private static let wantedKey = "launchAtLogin"        // the user's intent, kept across updates

    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }

    /// Only an installed .app can register. `swift run` (no bundle) and translocated copies can't.
    static var canRegister: Bool {
        let url = Bundle.main.bundleURL
        return Bundle.main.bundleIdentifier != nil
            && url.pathExtension == "app"
            && !url.path.contains("/AppTranslocation/")
    }

    /// Call from the Settings toggle. Show any thrown error to the user.
    static func setEnabled(_ enabled: Bool) throws {
        UserDefaults.standard.set(enabled, forKey: wantedKey)
        let service = SMAppService.mainApp
        if enabled {
            if service.status == .enabled { try? service.unregister() }   // re-register = refresh (as LaunchAtLogin-Modern)
            try service.register()
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
    }

    /// Call once per launch. If the user wanted launch-at-login but the item disappeared
    /// (for example after an update changed the signature), register it again.
    static func repairIfNeeded() {
        guard canRegister, UserDefaults.standard.bool(forKey: wantedKey) else { return }
        if status == .notRegistered || status == .notFound { try? SMAppService.mainApp.register() }
    }

    /// True if this launch came from the login item. Only valid inside applicationDidFinishLaunching.
    static var wasLaunchedAtLogin: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
```

- `register()` adds Prism under *Open at Login* and macOS shows a "Login Item Added" notification.
  `.requiresApproval` means the user turned it off in System Settings, and
  `SMAppService.openSystemSettingsLoginItems()` takes them there.
- For unattended installs, `wasLaunchedAtLogin` lets Prism reopen the last show and start output by
  itself.
- ⚠️ **Ad-hoc signing:** Background Task Management stores login items with the app's code-signing
  identity. An ad-hoc identity (the cdhash) changes with every release, so after an update the item
  might stop launching or show up twice. This is not confirmed. `repairIfNeeded()` plus the stable
  self-signed certificate from 4.7 are the mitigations. To inspect, run `sfltool dumpbtm` (it may ask
  for an admin password). `sfltool resetbtm` resets *every* app's background items, so use it only as a
  last resort.
- There's always a manual fallback: the user adds Prism with **+** under Login Items.

### 9.3 Single instance and a clean quit ✅

- If Prism is already running **from the same path**, LaunchServices brings that copy forward instead
  of starting another one. That covers Finder, the Dock, `open`, `open prism://…`, and double-clicking
  a `.prismlights` file. A second process still starts when:
  - a second copy at a different path is launched. Two copies with the same bundle ID can run side
    by side, which is how Xcode and Xcode-beta coexist.
  - someone runs `open -n`.
  - someone runs `Contents/MacOS/Prism` directly.
- Two Prisms conflict everywhere. The second one's widget `open` fails with `EBUSY` (`TIOCEXCL`,
  §2.4) and its server bind fails with `EADDRINUSE`. Both would send Art-Net/sACN. With the same
  persistent sACN CID (§3.4), receivers see one CID with interleaved sequence numbers, so they drop
  packets and the output flickers.
- `LSMultipleInstancesProhibited` only blocks a second instance in **another user session** (fast
  user switching). It doesn't help here.

```swift
import AppKit

@MainActor
enum SingleInstance {
    /// Call first in applicationWillFinishLaunching, before any port, socket or output is opened.
    /// If another Prism process is running, bring it forward and quit this one.
    static func enforce() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }   // `swift run`: no Info.plist
        let myPID = ProcessInfo.processInfo.processIdentifier
        guard let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != myPID && !$0.isTerminated }) else { return }
        NSApp.yieldActivation(to: other)                 // macOS 14 cooperative activation
        other.activate(options: [.activateAllWindows])   // best effort ⚠️ (may be ignored if we aren't active yet)
        exit(EXIT_SUCCESS)                               // nothing is initialised yet, so a plain exit is safe
    }
}

@MainActor
enum TerminationSignals {
    private static var sources: [DispatchSourceSignal] = []

    /// SIGTERM (`pkill Prism`, the installer in 4.8, `kill`) and SIGINT (Ctrl-C when started from a
    /// terminal) end the process immediately by default: no applicationWillTerminate, no blackout,
    /// no save. This turns them into a normal AppKit quit.
    static func install() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)                         // otherwise the default action kills us first
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            source.resume()
            sources.append(source)                       // keep the sources alive
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        SingleInstance.enforce()                         // may exit here
        TerminationSignals.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchAtLogin.repairIfNeeded()
        if LaunchAtLogin.wasLaunchedAtLogin {
            // Unattended install: reopen the last show and start output.
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Keep this short (the installer waits at most 10 s):
        //  - outputs: optional blackout frame for ENTTEC; 3 × Stream_Terminated for sACN (§3.3)
        //  - tunnel.stop(): SIGTERM to the cloudflared child (§7.3)
        //  - save the show. Power assertions go away by themselves when the process exits.
    }
}

// In the SwiftUI App:  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
```

- `NSApplicationDelegateAdaptor` forwards `applicationWillFinishLaunching` as well, so this works
  with the SwiftUI app lifecycle.
- `NSRunningApplication.runningApplications(withBundleIdentifier:)` includes the current process, so
  filter on the PID. It only sees apps in the current user session.
- If the handler closure ends up non-isolated (because the SDK marks it `@Sendable`),
  `MainActor.assumeIsolated` is still correct, since the source fires on `.main`. It's harmless if
  the closure is already main-actor isolated.

---

## 10. Sources & open uncertainties

### 10.1 Sources

**ENTTEC / widgets (§1)**
- ENTTEC, *DMX USB Pro – API* (70304, firmware 1.44):
  https://cdn.enttec.com/pdf/assets/70304/70304_DMX_USB_PRO_API.pdf
- ENTTEC, *DMX USB Pro — User Manual* (driver note: no third-party driver needed since OS X 10.11):
  https://support.enttec.com/user-manuals/dmx-usb-pro
- ENTTEC, *DMX USB Pro Mk2 API* (now listed as a legacy product):
  https://support.enttec.com/legacy-product/dmx-usb-pro-mk2-70314/dmx-usb-pro-mk2-api and the
  Mk2 user manual https://cdn.enttec.com/pdf/assets/70314/70314_DMX_USB_PRO_MK2_USER_MANUAL.pdf
- Open Lighting Architecture, https://github.com/OpenLightingProject/ola: `plugins/usbpro/`
  `UsbProWidgetDetector.cpp`, `WidgetDetectorThread.h`, `BaseUsbProWidget.cpp`,
  `EnttecUsbProWidget.cpp`, `UltraDMXProWidget.cpp`, `GenericUsbProWidget.cpp` (labels, detection
  sequence, Mk2 port 2, DMXking extensions).

**Serial (§2)**
- Apple IOSerialFamily headers `IOSerialKeys.h`, `ioss.h` (in the macOS SDK; open source at
  https://github.com/apple-oss-distributions/IOSerialFamily).
- Apple, *Working With Serial* (archived device-file-access guide and SerialPortSample):
  https://developer.apple.com/library/archive/documentation/DeviceDrivers/Conceptual/WorkingWSerial/
- XNU `bsd/kern/tty.c` (VMIN/VTIME and `O_NONBLOCK` semantics, see §2.4).

**Art-Net / sACN (§3)**
- Artistic Licence, *Art-Net 4 specification*: https://art-net.org.uk/downloads/art-net.pdf
- OLA `plugins/artnet/ArtNetPackets.h` (byte layout cross-check).
- ANSI E1.31 (current revision E1.31-2018; packet layout unchanged since 2016), free from ESTA TSP:
  https://tsp.esta.org/tsp/documents/published_docs.php
- Hundemeier/sacn, https://github.com/Hundemeier/sacn: `sacn/messages/root_layer.py`,
  `data_packet.py`, `sync_packet.py` (offset cross-check).

**Bundling, signing, Gatekeeper (§4)**
- Apple, *Information Property List* reference:
  https://developer.apple.com/documentation/bundleresources/information_property_list
- SwiftPM, https://github.com/swiftlang/swift-package-manager:
  `Sources/Build/BuildDescription/SwiftModuleBuildDescription.swift` (native `Bundle.module`
  accessor), `Sources/LLBuildManifest/LLBuildManifest.swift` (`embedInCode`),
  `Sources/Runtimes/PackageDescription/Resource.swift`.
- swift-build, https://github.com/swiftlang/swift-build:
  `Sources/SWBTaskConstruction/TaskProducers/BuildPhaseTaskProducers/SourcesTaskProducer.swift`
  (swiftbuild accessor), `Sources/SWBTaskExecution/TaskActions/GenerateEmbedInCodeAccessorTaskAction.swift`,
  `Sources/SWBApplePlatform/AppIntentsMetadataTaskProducer.swift`.
- Apple TN3127 *Inside Code Signing: Requirements*, TN3161 *Inside Code Signing: Certificates*, TN2206
  *macOS Code Signing In Depth* (archive): https://developer.apple.com/documentation/technotes
- Apple Support, *Safely open apps on your Mac*: https://support.apple.com/en-us/102445
- Apple Support, *Create self-signed certificates in Keychain Access*:
  https://support.apple.com/guide/keychain-access/create-self-signed-certificates-kyca8916/mac
- E. Voleinik, *Preserve macOS App Permissions Across Rebuilds with Self-Signed Certificates*:
  https://evoleinik.com/posts/macos-dev-signing-preserve-permissions/
- apple-codesign / `rcodesign` 0.29: https://github.com/indygreg/apple-platform-rs

**Local network, Bonjour (§5)**
- Apple TN3179 *Understanding local network privacy* (rev. 2026-10-06):
  https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- Apple TN3178 (unique `LC_UUID` per build), in the technotes index above.
- `dns_sd.h` (mDNSResponder, https://github.com/apple-oss-distributions/mDNSResponder). Usage
  pattern from mattt/iMCP, https://github.com/mattt/iMCP.

**GitHub Actions (§6)**
- actions/runner-images, https://github.com/actions/runner-images: README,
  `images/macos/macos-26-arm64-Readme.md`, `images/macos/macos-15-arm64-Readme.md`,
  `images/macos/scripts/build/configure-tccdb-macos.sh`.
- GitHub Docs: *Actions limits* https://docs.github.com/en/actions/reference/limits, *GitHub-hosted
  runners reference* https://docs.github.com/en/actions/reference/runners/github-hosted-runners,
  *Billing and usage* https://docs.github.com/en/actions/concepts/billing-and-usage

**Cloudflare (§7)**
- *Quick Tunnels* (updated 2026-09-30): https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/
- Cloudflare blog, *Protected Quick Tunnels* (2026-10-02): https://blog.cloudflare.com/protected-quick-tunnels/
- cloudflared 2026.10.7 release (assets downloaded and hashed):
  https://github.com/cloudflare/cloudflared/releases/tag/2026.10.7

**MIDI / OSC (§8)**
- CoreMIDI generated Swift interface (`MIDIServices`, `MIDIEventList.Builder`,
  `MIDIEventPacket.WordCollection`) and https://developer.apple.com/documentation/coremidi
- AudioKit (`MIDI+Receiving.swift`), https://github.com/AudioKit/AudioKit; bradhowes/morkandmidi,
  https://github.com/bradhowes/morkandmidi; cmsj/Hammerspoon2 (`HSMIDIModule.swift`),
  https://github.com/cmsj/Hammerspoon2
- OSC 1.0 specification: https://opensoundcontrol.stanford.edu/spec-1_0.html (plus the OSC 1.1 NIME
  2009 paper for the `T F N I` tags).

**Power, login items, activation (§9)**
- `IOKit/pwr_mgt/IOPMLib.h`; Apple QA1340:
  https://developer.apple.com/library/archive/qa/qa1340/_index.html
- `ProcessInfo` activities: https://developer.apple.com/documentation/foundation/processinfo
- `SMAppService`: https://developer.apple.com/documentation/servicemanagement/smappservice;
  sindresorhus/LaunchAtLogin-Modern, https://github.com/sindresorhus/LaunchAtLogin-Modern
- Swift usage of the IOPM calls: dustinrue/ControlPlane, manaflow-ai/cmux, apple/security-pcc.
  `NSApp.yieldActivation(to:)` with `activate(options:)`: jordanbaird/Ice, jacklandrin/OnlySwitch.

### 10.2 Open uncertainties (check on hardware / in CI)

| # | Item | Where | How to settle it |
|---|---|---|---|
| 1 | Pro Mk2 second-port labels and the API-key unlock (labels > 128) | §1.3, §1.6 | Test with a Mk2, or ask ENTTEC for the Mk2 API |
| 2 | Whether DMXking 2-port units (ultraDMX Pro) treat label 6 as "port A only" | §1.3 | Test with the device. DMXking docs |
| 3 | Open DMX USB break/MAB timing through Apple's FTDI dext (`TIOCSBRK`/`TIOCCBRK` granularity, RTS handling) | §1.8 | Logic analyser on the DMX line |
| 4 | `VMIN=1` + `O_NONBLOCK` read behaviour, reasoned from XNU source and not run on hardware | §2.4 | Unplug/replug test with a real widget |
| 5 | `IOSSDATALAT` honoured by the Apple FTDI dext | §2.6 | Measure reply latency to label 3 |
| 6 | Art-Net 4 ArtPollReply fields after byte 212 (taken from the spec, not cross-checked in code) | §3.1 | Wireshark against a current node |
| 7 | Whether Local Network permission survives updates when signed with a self-signed (non-Apple) certificate | §5.1 | Update test on macOS 15 and 26 |
| 8 | `SMAppService` login items for ad-hoc-signed apps across updates | §9.2 | Update test. `sfltool dumpbtm` |
| 9 | App Intents metadata with `swift build --build-system swiftbuild` | §4.10 | Try it in CI and look for `Metadata.appintents` |
| 10 | Which Xcode/toolchain release makes `swiftbuild` the default build system | §4.3 | Swift release notes. The doc's advice doesn't depend on it |
| 11 | `codesign` with an untrusted self-signed identity selected by SHA-1 on CI. `rcodesign` designated requirement | §4.7 | CI dry run plus `codesign -d -r-` |
| 12 | "App Management" protection when the installer replaces an ad-hoc/self-signed bundle | §4.8 | Test the install script on macOS 15 and 26 |
| 13 | SwiftUI external-event routing (`handlesExternalEvents`) for files and `prism://` URLs | §4.9 | Manual test |
| 14 | Xcode 26 `actool` flags for `.icon` (Icon Composer) files | §4.6 | Not needed if you use `iconutil` |
| 15 | SHA-256 of the extracted amd64 cloudflared binary (inferred by analogy with arm64) | §7.2 | Verify the **tgz** digest instead (that's what the code does) |
| 16 | The old `config.yaml` quick-tunnel caveat. `--allowed-mail` with WebSockets. `--output json` keys | §7.1 | Manual test with cloudflared ≥ 2026.9.3 |
| 17 | Deep link to System Settings › Privacy › Local Network | §5.1 | Manual test. Otherwise open Privacy & Security |
| 18 | Hosted-runner display resolution for screenshots | §6.4 | `system_profiler SPDisplaysDataType` in CI |
| 19 | Exact Swift version for each Xcode 26.x minor release | §6.1 | Run `swift --version` in CI |
| 20 | Whether `NSBonjourServices` is enforced on macOS | §4.2 | Harmless either way |
| 21 | Cooperative activation in `SingleInstance.enforce()` (may not bring the other copy forward) | §9.3 | Manual test. Cosmetic only |
