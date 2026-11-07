import Foundation

/// Drives an ENTTEC DMX USB Pro, DMX USB Pro Mk2 or a Pro-compatible widget (DMXking
/// ultraDMX family …) over its USB serial port.
///
/// One dedicated thread owns the port: it finds the device (via `locate`), opens it with
/// exclusive access, identifies it (labels 10/3, then 77/78/14), sends the newest frame per
/// port with label 6 (never queueing), keeps the link alive once a second and reconnects with
/// backoff when the box is unplugged, busy or asleep. Nothing here can block the engine tick:
/// `submit` only swaps a frame into a slot.
public final class EnttecProDevice: DMXDevice, @unchecked Sendable {
    public struct Options: Sendable {
        /// Turn on the Pro Mk2's second universe (sends the Mk2 API-key handshake).
        public var enableSecondPort = false
        public var mk2Profile = EnttecMk2Profile.default
        /// Never write a port more often than this (seconds).
        public var minFrameInterval = 1.0 / 70
        /// Resend an unchanged frame this often (keeps DMXking snapshot-recall off, detects unplugging).
        public var keepAliveInterval = 1.0
        /// How long to wait for identification replies.
        public var identifyTimeout = 0.6
        /// Delays between reconnect attempts (the last value repeats).
        public var backoff: [Double] = [0.2, 0.5, 1, 2, 3]
        public var busyRetry = 2.0
        public var unsupportedRetry = 5.0
        /// A frame that can't start writing within this time is dropped (the next one follows).
        public var writeStartTimeout = 0.005
        /// A frame that can't finish within this time means the box stopped responding.
        public var writeFinishTimeout = 0.1
        /// Serial line speed (irrelevant to the Pro's USB link, but set for clones).
        public var baud = 115_200

        public init() {}
    }

    public let id: String
    public let kind: DMXDeviceKind = .enttecPro
    private let runtime: DeviceRuntime
    private let options: Options
    private let locate: @Sendable () -> String?
    private let usbProductName: String?

    /// - Parameters:
    ///   - id: stable key for bindings, e.g. "usb:EN055555".
    ///   - name: what to call the device until it has identified itself.
    ///   - usbProductName: the USB product string (helps name clones).
    ///   - locate: returns the current device path (e.g. "/dev/cu.usbserial-EN055555") or nil
    ///     while it isn't plugged in. Called on the device thread; must be fast and thread-safe.
    public init(id: String, name: String = "DMX USB Pro", usbProductName: String? = nil,
                options: Options = Options(), locate: @escaping @Sendable () -> String?) {
        self.id = id
        self.options = options
        self.locate = locate
        self.usbProductName = usbProductName
        runtime = DeviceRuntime(snapshot: DMXDeviceSnapshot(id: id, kind: .enttecPro, name: name, shortName: name))
    }

    public var snapshot: DMXDeviceSnapshot { runtime.snapshot }

    public func submit(port: Int, data: [UInt8]) {
        runtime.slot.submit(port: port, data: data)
    }

    public func start() {
        runtime.start(name: "Prism DMX \(id)") { [self] in self.run() }
    }

    public func stop(flushTimeout: Double) { runtime.stop(flushTimeout: flushTimeout) }
    public func reconnectNow() { runtime.requestReconnect() }
    public func markRemoved() { runtime.markRemoved() }
    public func setChangeHandler(_ handler: (@Sendable (DMXDeviceSnapshot) -> Void)?) { runtime.setChangeHandler(handler) }

    /// Asks the widget to refresh at 40 frames per second (writes its settings memory).
    /// Only call on an explicit user action.
    public func fixSlowRefresh() { runtime.requestRefreshFix() }

    // MARK: - Connection loop

    private func backoff(_ attempt: Int) -> Double {
        guard let last = options.backoff.last else { return 1 }
        return attempt < options.backoff.count ? options.backoff[max(0, attempt)] : last
    }

    private func run() {
        var attempt = 0
        var silentAfterLoss = 0
        while !runtime.isStopping {
            _ = runtime.consumeReconnect()
            _ = runtime.consumeRemoved()
            guard let path = locate() else {
                runtime.update { $0.state = .searching; $0.path = nil }
                runtime.pause(backoff(attempt))
                attempt += 1
                continue
            }
            runtime.update { $0.state = .connecting; $0.path = path }
            let port: SerialPort
            do {
                port = try SerialPort.open(path: path, baud: options.baud)
            } catch let error as SerialPortError {
                switch error {
                case .busy:
                    runtime.setState(.busy, error: error.message)
                    runtime.pause(options.busyRetry)
                case .notFound:
                    runtime.setState(.searching)
                    runtime.pause(backoff(attempt))
                    attempt += 1
                default:
                    runtime.setState(.failed(error.message), error: error.message)
                    runtime.pause(max(2, backoff(attempt)))
                    attempt += 1
                }
                continue
            } catch {
                runtime.setState(.failed("Prism couldn't open the DMX box."))
                runtime.pause(max(2, backoff(attempt)))
                attempt += 1
                continue
            }

            switch identify(port) {
            case .stopped:
                port.close()
            case .lost(let reason):
                port.close()
                runtime.update { $0.state = .searching; $0.lastError = reason }
                runtime.pause(backoff(attempt))
                attempt += 1
            case .noReply:
                port.close()
                if runtime.snapshot.hasBeenLive && silentAfterLoss < 3 {
                    // Right after an unplug the old node can linger for a moment; keep looking.
                    silentAfterLoss += 1
                    runtime.update { $0.state = .searching }
                    runtime.pause(backoff(attempt))
                    attempt += 1
                } else {
                    runtime.update {
                        $0.state = .unsupported
                        $0.lastError = DMXDeviceState.unsupported.message(deviceName: $0.name, hasBeenLive: false)
                    }
                    runtime.pause(options.unsupportedRetry)
                }
            case .identified(let identity):
                attempt = 0
                silentAfterLoss = 0
                apply(identity, path: path)
                let end = output(port, identity)
                port.close()
                switch end {
                case .stopped:
                    break
                case .lost(let reason):
                    runtime.recordReconnect()
                    runtime.update { $0.state = .searching; $0.lastError = reason }
                    runtime.pause(backoff(0))
                }
            }
        }
        runtime.setState(.stopped)
    }

    private func apply(_ identity: EnttecWidgetIdentity, path: String) {
        let warning: String? = identity.parameters.map { p -> String? in
            guard p.isSlowRefresh else { return nil }
            return "Your DMX box is set to refresh only \(p.rate) times per second, so fades can look steppy. Use “Fix refresh rate” to set it to 40."
        } ?? nil
        let unverified = identity.serialNumber == nil && identity.parameters == nil
        runtime.update { s in
            s.name = identity.displayName
            s.shortName = identity.shortName
            s.serialNumber = identity.serialNumber
            s.firmware = identity.parameters?.firmwareVersion
            s.timing = identity.parameters?.timingSummary
            s.portCount = identity.portCount
            s.path = path
            s.warning = warning ?? (unverified
                ? "This box didn't report a serial number — it's probably a compatible clone. If the lights don't respond, run the Hardware Test."
                : nil)
            s.lastError = nil
            s.state = .live
        }
    }

    // MARK: - Identification

    private enum IdentifyResult {
        case identified(EnttecWidgetIdentity)
        case noReply
        case lost(String)
        case stopped
    }

    private static let identificationLabels: Set<UInt8> = [
        EnttecLabel.getSerialNumber.rawValue, EnttecLabel.getWidgetParameters.rawValue,
        EnttecLabel.hardwareVersion.rawValue, EnttecLabel.manufacturer.rawValue, EnttecLabel.device.rawValue,
    ]

    private func identify(_ port: SerialPort) -> IdentifyResult {
        port.flushInput()
        var parser = EnttecParser()
        var replies: [UInt8: [UInt8]] = [:]
        let core: Set<UInt8> = [EnttecLabel.getSerialNumber.rawValue, EnttecLabel.getWidgetParameters.rawValue]

        for attempt in 0..<2 {
            if let abort = command(port, EnttecPro.getSerial + EnttecPro.getParameters) { return abort }
            let timeout = attempt == 0 ? options.identifyTimeout : options.identifyTimeout * 0.67
            if let abort = collect(port, &parser, &replies, wanted: core, timeout: timeout) { return abort }
            if !replies.isEmpty { break }
        }

        if replies.isEmpty {
            // Some clones never answer but do output label 6. Trust a USB name that says so.
            let product = (usbProductName ?? "").uppercased()
            if product.contains("DMX"), product.contains("PRO") {
                return .identified(EnttecWidgetIdentity(family: .compatible, displayName: "DMX USB Pro",
                                                        shortName: "DMX USB Pro"))
            }
            return .noReply
        }

        // Extended identification: DMXking and other compatibles answer 77/78; genuine ENTTEC ignores them.
        let extended: Set<UInt8> = [EnttecLabel.manufacturer.rawValue, EnttecLabel.device.rawValue,
                                    EnttecLabel.hardwareVersion.rawValue]
        if let abort = command(port, EnttecPro.getManufacturer + EnttecPro.getDevice + EnttecPro.getHardwareVersion) {
            return abort
        }
        if let abort = collect(port, &parser, &replies, wanted: extended, timeout: 0.25) { return abort }

        var secondPort: UInt8?
        if options.enableSecondPort,
           let hw = replies[EnttecLabel.hardwareVersion.rawValue].flatMap(EnttecDecode.hardwareVersion),
           hw == 2 || hw == 3, replies[EnttecLabel.manufacturer.rawValue] == nil {
            let profile = options.mk2Profile
            if let abort = command(port, profile.apiKeyMessage + profile.enableBothPortsMessage) { return abort }
            if let abort = collect(port, &parser, &replies, wanted: [], timeout: 0.05) { return abort }
            secondPort = profile.port2SendLabel
        }

        guard let identity = EnttecWidgetIdentity.classify(replies: replies, usbProductName: usbProductName,
                                                           mk2SecondPort: secondPort) else { return .noReply }
        return .identified(identity)
    }

    /// Writes an identification request. Returns non-nil to abort identification.
    private func command(_ port: SerialPort, _ bytes: [UInt8]) -> IdentifyResult? {
        if runtime.isStopping { return .stopped }
        do {
            _ = try port.write(bytes, startTimeout: 0.2, finishTimeout: 0.3)
            return nil
        } catch let error as SerialPortError {
            return error == .stalled ? .noReply : .lost(error.message)
        } catch {
            return .lost(SerialPortError.disconnected.message)
        }
    }

    /// Reads replies until all `wanted` labels arrived or `timeout` passed. Non-nil = abort.
    private func collect(_ port: SerialPort, _ parser: inout EnttecParser, _ replies: inout [UInt8: [UInt8]],
                         wanted: Set<UInt8>, timeout: Double) -> IdentifyResult? {
        let deadline = PrismClock.now() + timeout
        var lastByte = PrismClock.now()
        while true {
            if runtime.isStopping { return .stopped }
            if !wanted.isEmpty, wanted.isSubset(of: Set(replies.keys)) { return nil }
            let now = PrismClock.now()
            if now >= deadline { return nil }
            let w = IOWait.wait(fd: port.fd, read: true, write: false, wakeFD: runtime.wakeFD,
                                timeout: min(deadline - now, 0.05))
            if w.woken { runtime.wake?.drain() }
            if w.readable || w.hangup {
                do {
                    let bytes = try port.readAvailable()
                    if !bytes.isEmpty {
                        lastByte = PrismClock.now()
                        for m in parser.feed(bytes) where Self.identificationLabels.contains(m.label) {
                            replies[m.label] = m.payload
                        }
                    } else if w.hangup, port.probeGone() {
                        return .lost(SerialPortError.disconnected.message)
                    }
                } catch let error as SerialPortError {
                    return .lost(error.message)
                } catch {
                    return .lost(SerialPortError.disconnected.message)
                }
            } else if parser.hasPartialMessage, PrismClock.now() - lastByte > 0.1 {
                for m in parser.resync() where Self.identificationLabels.contains(m.label) {
                    replies[m.label] = m.payload
                }
            }
        }
    }

    // MARK: - Output

    private enum LoopEnd {
        case stopped
        case lost(String)
    }

    private func output(_ port: SerialPort, _ identity: EnttecWidgetIdentity) -> LoopEnd {
        let labels = identity.portLabels.isEmpty ? [EnttecLabel.outputOnlySendDMX.rawValue] : identity.portLabels
        var lastWrite = [Double](repeating: 0, count: labels.count)
        var parser = EnttecParser()
        var params = identity.parameters
        runtime.slot.markAllDirty()
        runtime.slot.setWakeEnabled(true)
        defer { runtime.slot.setWakeEnabled(false) }

        while true {
            if runtime.isStopping {
                flush(port, labels: labels)
                return .stopped
            }
            if runtime.consumeRemoved() { return .lost(SerialPortError.disconnected.message) }
            _ = runtime.consumeReconnect() // already connected: nothing to do
            if runtime.consumeRefreshFix(), let p = params {
                let fixed = EnttecPro.setParameters(breakTime: p.breakTime, mabTime: p.mabTime, rate: 40)
                if (try? port.write(fixed, startTimeout: 0.05, finishTimeout: 0.2)) == .sent {
                    let updated = EnttecParameters(firmware: p.firmware, breakTime: p.breakTime, mabTime: p.mabTime, rate: 40)
                    params = updated
                    runtime.update { $0.timing = updated.timingSummary; $0.warning = nil }
                }
            }

            var nextDue = PrismClock.now() + 0.25
            for index in labels.indices {
                let portNumber = index + 1
                let now = PrismClock.now()
                var frame = runtime.slot.take(port: portNumber)
                var keepAlive = false
                if frame == nil, let latest = runtime.slot.latestFrame(port: portNumber),
                   now - lastWrite[index] >= options.keepAliveInterval {
                    frame = DMXFrameSlot.Frame(data: latest, submittedAt: now)
                    keepAlive = true
                }
                guard let f = frame else {
                    if lastWrite[index] > 0 { nextDue = min(nextDue, lastWrite[index] + options.keepAliveInterval) }
                    continue
                }
                if !keepAlive, now - lastWrite[index] < options.minFrameInterval {
                    runtime.slot.restore(port: portNumber, frame: f)
                    nextDue = min(nextDue, lastWrite[index] + options.minFrameInterval)
                    continue
                }
                let packet = EnttecPro.dmx(f.data, label: labels[index])
                do {
                    switch try port.write(packet, startTimeout: options.writeStartTimeout,
                                          finishTimeout: options.writeFinishTimeout) {
                    case .sent:
                        let done = PrismClock.now()
                        lastWrite[index] = done
                        runtime.recordSent(latency: keepAlive ? nil : done - f.submittedAt, now: done)
                        nextDue = min(nextDue, done + options.keepAliveInterval)
                    case .dropped:
                        runtime.recordDropped()
                        if !keepAlive { runtime.slot.restore(port: portNumber, frame: f) }
                        nextDue = min(nextDue, PrismClock.now() + 0.004)
                    }
                } catch let error as SerialPortError {
                    runtime.recordWriteError()
                    return .lost(error.message)
                } catch {
                    runtime.recordWriteError()
                    return .lost(SerialPortError.disconnected.message)
                }
            }

            let timeout = max(0.001, nextDue - PrismClock.now())
            let w = IOWait.wait(fd: port.fd, read: true, write: false, wakeFD: runtime.wakeFD, timeout: timeout)
            if w.woken { runtime.wake?.drain() }
            if w.readable || w.hangup {
                do {
                    let bytes = try port.readAvailable()
                    if !bytes.isEmpty {
                        _ = parser.feed(bytes) // widget chatter (received DMX, replies) is ignored
                    } else if w.hangup {
                        if port.probeGone() { return .lost(SerialPortError.disconnected.message) }
                        Sys.sleep(seconds: 0.01)
                    }
                } catch let error as SerialPortError {
                    return .lost(error.message)
                } catch {
                    return .lost(SerialPortError.disconnected.message)
                }
            }
        }
    }

    /// Sends whatever is still pending before closing (bounded by the stop's flush timeout).
    private func flush(_ port: SerialPort, labels: [UInt8]) {
        let budget = runtime.flushTimeout
        guard budget > 0 else { return }
        let deadline = PrismClock.now() + budget
        for index in labels.indices {
            guard let f = runtime.slot.take(port: index + 1) else { continue }
            let remaining = deadline - PrismClock.now()
            guard remaining > 0 else { return }
            if (try? port.write(EnttecPro.dmx(f.data, label: labels[index]), startTimeout: remaining,
                                finishTimeout: remaining)) == .sent {
                runtime.recordSent(latency: PrismClock.now() - f.submittedAt, now: PrismClock.now())
            }
        }
    }
}
