import Foundation
import Observation
import PrismCore

/// One output device as the Outputs settings and the Hardware Test list it.
struct OutputDeviceRow: Identifiable, Equatable {
    var snapshot: DMXDeviceSnapshot
    /// Device port → Prism universe.
    var universes: [Int: Int]
    var isEnabled: Bool
    /// USB details (nil for network outputs).
    var usbProduct: String?
    var usbSerial: String?
    var isFTDI: Bool
    var isOpenDMX: Bool
    var secondPortEnabled: Bool

    var id: String { snapshot.id }
    var isUSB: Bool { !snapshot.kind.isNetwork }
}

/// Manages every DMX output — ENTTEC DMX USB Pro (and compatibles), Open DMX, Art-Net and
/// sACN — and connects them to the engine.
///
/// - Discovers USB interfaces with IOKit and follows hot-plug (status changes within a second).
/// - Each device runs on its own thread (PrismCore `DMXDevice`); the engine hands frames over
///   through non-blocking `RoutedOutput`s, so nothing here can stall the main thread or a tick.
/// - With nothing connected (or `--no-hardware`), the toolbar reads "Simulation" and the
///   virtual output keeps receiving frames.
/// - Keeps the Mac awake while outputting and reconnects after sleep.
@MainActor
@Observable
final class OutputManager: AppService {
    @ObservationIgnored let engine: EngineCore

    /// What the toolbar's status pill shows.
    private(set) var summary: OutputSummary = .simulation
    /// Every known device (USB first, then network), for settings and the Hardware Test.
    private(set) var rows: [OutputDeviceRow] = []
    /// Serial ports Prism doesn't drive automatically (not FTDI and not DMX-looking).
    private(set) var otherPorts: [SerialPortInfo] = []
    /// Art-Net nodes that answered ArtPoll.
    private(set) var artNetNodes: [ArtNet.Node] = []
    /// This Mac's output settings (stored in UserDefaults, never in a project).
    private(set) var configuration: OutputConfiguration
    /// Universes used by the patch (always includes 1).
    private(set) var usedUniverses: [Int] = [1]
    /// Hardware is off for this session (`--no-hardware`, screenshot tour, self-test).
    private(set) var hardwareDisabled = false
    /// IPv4 interfaces, for the Art-Net/sACN pickers.
    private(set) var networkInterfaces: [NetworkInterface] = []
    /// True while the Mac is being kept awake for the show.
    private(set) var isKeepingAwake = false
    /// State of the guided Hardware Test sheet.
    let hardwareTest = HardwareTestModel()

    /// The always-on virtual output (universe 1): the self-test and simulation read it.
    @ObservationIgnored let virtualOutput = VirtualDMXOutput(id: "virtual", name: "Virtual Output", universe: 1)

    @ObservationIgnored private var managed: [String: ManagedDevice] = [:]
    @ObservationIgnored private let directory = PortDirectory()
    @ObservationIgnored private var monitor: SerialPortMonitor?
    @ObservationIgnored private let keepAwake = KeepAwake()
    @ObservationIgnored private var sleepObserver: SleepWakeObserver?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var registered: [String: Int] = [:]
    @ObservationIgnored private var lastWake = -1000.0
    @ObservationIgnored private var simulatedDevicesInstalled = false
    @ObservationIgnored private var isShutDown = false

    static let configurationKey = "prism.outputs"

    /// A device plus what the manager remembers about it.
    private final class ManagedDevice {
        let key: String
        var device: DMXDevice
        var port: SerialPortInfo?
        var isEnabled: Bool
        var lastState: DMXDeviceState = .stopped
        var announcedLive = false
        var networkSignature: Data?

        init(key: String, device: DMXDevice, port: SerialPortInfo?, isEnabled: Bool) {
            self.key = key
            self.device = device
            self.port = port
            self.isEnabled = isEnabled
        }
    }

    init(engine: EngineCore) {
        self.engine = engine
        configuration = OutputConfiguration.decode(UserDefaults.standard.data(forKey: Self.configurationKey))
    }

    // MARK: - Lifecycle

    func start(app: AppModel) {
        self.app = app
        hardwareTest.attach(app)
        engine.addOutput(virtualOutput)
        hardwareDisabled = app.launch.noHardware
        usedUniverses = HardwareTestPlan.universes(app.show.resolvedFixtures)
        networkInterfaces = NetworkInterface.lightingCandidates()

        if !hardwareDisabled {
            let monitor = SerialPortMonitor()
            monitor.onAdded = { [weak self] info in
                Task { @MainActor in self?.portAdded(info) }
            }
            monitor.onRemoved = { [weak self] info in
                Task { @MainActor in self?.portRemoved(info) }
            }
            self.monitor = monitor
            monitor.start()
            syncNetworkDevices()
            sleepObserver = SleepWakeObserver(onSleep: {}, onWake: { [weak self] in self?.didWake() })
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        refresh()
    }

    /// Quits quickly: sends the last frame (e.g. the blackout) and closes every device, all in
    /// parallel and bounded (< 200 ms in total). The DMX USB Pro keeps outputting its last
    /// frame after Prism closes it, so "hold last look" needs nothing else.
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        timer?.invalidate()
        timer = nil
        hardwareTest.end()
        sleepObserver?.invalidate()
        sleepObserver = nil
        monitor?.stop()
        monitor = nil
        let terminate = app?.preferences.blackoutOnQuit ?? false
        let devices = managed.values.map(\.device)
        let group = DispatchGroup()
        for device in devices {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                if let network = device as? NetworkDMXDevice {
                    network.stop(flushTimeout: 0.1, terminateStreams: terminate)
                } else {
                    device.stop(flushTimeout: 0.1)
                }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 0.18)
        keepAwake.update(active: false, keepDisplayOn: false)
        isKeepingAwake = false
    }

    // MARK: - Hot-plug

    private func portAdded(_ info: SerialPortInfo) {
        guard !isShutDown, !hardwareDisabled else { return }
        guard info.isUSB, info.looksLikeDMXWidget || configuration.openDMXDevices.contains(info.deviceKey) else {
            if info.isUSB, !otherPorts.contains(where: { $0.registryID == info.registryID }) {
                otherPorts.append(info)
            }
            return
        }
        let key = info.deviceKey
        directory.set(info, for: key)
        if let existing = managed[key] {
            existing.port = info
            existing.device.reconnectNow()
            refresh()
            return
        }
        let enabled = !configuration.disabledDevices.contains(key)
        let device = makeUSBDevice(key: key, info: info)
        let m = ManagedDevice(key: key, device: device, port: info, isEnabled: enabled)
        managed[key] = m
        observe(m)
        if enabled { device.start() }
        if configuration.assignDefaults(deviceKey: key, portCount: 1, presentDevices: presentKeys) { save() }
        refresh()
    }

    private func portRemoved(_ info: SerialPortInfo) {
        otherPorts.removeAll { $0.registryID == info.registryID }
        let key = info.deviceKey
        directory.remove(registryID: info.registryID, for: key)
        guard let m = managed[key], m.port?.registryID == info.registryID else {
            refresh()
            return
        }
        if m.device.snapshot.hasBeenLive {
            m.device.markRemoved() // stays listed as "unplugged" until it comes back
        } else {
            // Never worked (not a DMX box, or switched off): just forget it.
            let device = m.device
            managed[key] = nil
            DispatchQueue.global(qos: .utility).async { device.stop(flushTimeout: 0) }
        }
        refresh()
    }

    private func didWake() {
        lastWake = PrismClock.now()
        networkInterfaces = NetworkInterface.lightingCandidates()
        for m in managed.values where m.isEnabled { m.device.reconnectNow() }
    }

    /// Looks for interfaces again (the "Look again" buttons).
    func rescan() {
        guard !hardwareDisabled else { return }
        for info in SerialPortScanner.scan() where managed[info.deviceKey] == nil {
            portAdded(info)
        }
        for m in managed.values where m.isEnabled { m.device.reconnectNow() }
        networkInterfaces = NetworkInterface.lightingCandidates()
        refresh()
    }

    // MARK: - Devices

    private var presentKeys: Set<String> {
        directory.keys.union(managed.values.filter { $0.device.snapshot.state.isLive }.map(\.key))
    }

    private func makeUSBDevice(key: String, info: SerialPortInfo?) -> DMXDevice {
        let directory = self.directory
        let locate: @Sendable () -> String? = { directory.path(for: key) }
        if configuration.openDMXDevices.contains(key) {
            return OpenDMXDevice(id: key, name: "Open DMX", locate: locate)
        }
        var options = EnttecProDevice.Options()
        options.enableSecondPort = configuration.secondPortDevices.contains(key)
        return EnttecProDevice(id: key, name: info?.friendlyName ?? "DMX USB Pro", usbProductName: info?.productName,
                               options: options, locate: locate)
    }

    private func observe(_ m: ManagedDevice) {
        let key = m.key
        m.device.setChangeHandler { [weak self] _ in
            Task { @MainActor in self?.deviceChanged(key) }
        }
    }

    private func deviceChanged(_ key: String) {
        guard let m = managed[key], !isShutDown else { return }
        let snap = m.device.snapshot
        let old = m.lastState
        m.lastState = snap.state
        if old != snap.state { announce(m, from: old, to: snap) }
        if !snap.kind.isNetwork,
           configuration.assignDefaults(deviceKey: key, portCount: snap.portCount, presentDevices: presentKeys) {
            save()
        }
        refresh()
    }

    /// Friendly toasts for the moments that matter (never during automated runs).
    private func announce(_ m: ManagedDevice, from old: DMXDeviceState, to snap: DMXDeviceSnapshot) {
        guard let app, !app.launch.isAutomated, !snap.kind.isNetwork, m.isEnabled else { return }
        switch snap.state {
        case .live where old != .live:
            app.ui.toast("DMX box connected — your lights are live", style: .success, systemImage: "cable.connector")
            m.announcedLive = true
        case .searching, .failed:
            guard old == .live, PrismClock.now() - lastWake > 10 else { return }
            app.ui.toast("DMX box unplugged — plug it back in and Prism reconnects by itself", style: .warning,
                         systemImage: "cable.connector", duration: 5)
        case .busy where old != .busy:
            app.ui.toast("Another app is using your DMX box. Quit Lightkey or QLC+ and Prism connects by itself.",
                         style: .error, systemImage: "exclamationmark.triangle.fill", duration: 7)
        default:
            break
        }
    }

    /// Stops a device off the main thread, then runs `then` on the main actor.
    private func stopThen(_ device: DMXDevice, flush: Double = 0.05, _ then: @escaping @MainActor () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            device.stop(flushTimeout: flush)
            DispatchQueue.main.async { MainActor.assumeIsolated { then() } }
        }
    }

    /// Rebuilds a USB device after a settings change (type, second port, on/off).
    private func rebuildUSB(_ key: String) {
        guard let m = managed[key] else { return }
        let old = m.device
        let info = directory.info(for: key) ?? m.port
        m.isEnabled = !configuration.disabledDevices.contains(key)
        stopThen(old) { [weak self] in
            guard let self, !self.isShutDown, let current = self.managed[key], current.device === old else { return }
            let fresh = self.makeUSBDevice(key: key, info: info)
            current.device = fresh
            current.lastState = .stopped
            self.observe(current)
            if current.isEnabled { fresh.start() }
            self.refresh()
        }
        refresh()
    }

    private func networkSignature(_ kind: DMXDeviceKind) -> Data? {
        switch kind {
        case .artNet: return try? JSONEncoder().encode(configuration.artNet)
        case .sACN: return try? JSONEncoder().encode(configuration.sacn)
        default: return nil
        }
    }

    /// Starts, restarts or stops the Art-Net and sACN outputs to match the settings.
    private func syncNetworkDevices() {
        guard !hardwareDisabled, !isShutDown else { return }
        for kind in [DMXDeviceKind.artNet, .sACN] {
            let key = kind == .artNet ? "artnet" : "sacn"
            let wanted = kind == .artNet ? configuration.artNet.enabled : configuration.sacn.enabled
            let signature = networkSignature(kind)
            if let m = managed[key], !wanted || m.networkSignature != signature {
                managed[key] = nil
                let device = m.device
                DispatchQueue.global(qos: .utility).async {
                    if let n = device as? NetworkDMXDevice {
                        n.stop(flushTimeout: 0.05, terminateStreams: !wanted)
                    } else {
                        device.stop(flushTimeout: 0.05)
                    }
                }
            }
            guard wanted, managed[key] == nil else { continue }
            let transport: NetworkDMXDevice.Transport = kind == .artNet
                ? .artNet(configuration.artNet) : .sACN(configuration.sacn)
            let device = NetworkDMXDevice(transport: transport)
            let m = ManagedDevice(key: key, device: device, port: nil, isEnabled: true)
            m.networkSignature = signature
            managed[key] = m
            observe(m)
            device.start()
        }
        refresh()
    }

    // MARK: - Routing & status

    /// Registers one engine output per (device port → universe) and removes stale ones.
    private func updateRouting() {
        var desired: [String: RoutedOutput] = [:]
        for m in managed.values where m.isEnabled {
            let snap = m.device.snapshot
            if snap.kind.isNetwork {
                for u in usedUniverses {
                    let r = RoutedOutput(device: m.device, port: u, universe: u)
                    desired[r.outputID] = r
                }
            } else {
                for (port, universe) in configuration.universes(for: m.key) where port <= max(1, snap.portCount) {
                    let r = RoutedOutput(device: m.device, port: port, universe: universe)
                    desired[r.outputID] = r
                }
            }
        }
        for id in registered.keys where desired[id] == nil { engine.removeOutput(id: id) }
        for (id, r) in desired {
            // Re-register when the universe or the device instance changed.
            let current = engine.currentOutputs.first { $0.outputID == id } as? RoutedOutput
            if registered[id] != r.universe || current?.device !== r.device { engine.addOutput(r) }
        }
        registered = desired.mapValues(\.universe)
    }

    /// Recomputes rows, routing, summary and sleep prevention. Cheap; called on changes and at 1 Hz.
    private func refresh() {
        updateRouting()
        let newRows = managed.values.map { m -> OutputDeviceRow in
            OutputDeviceRow(snapshot: m.device.snapshot, universes: configuration.universes(for: m.key),
                            isEnabled: m.isEnabled, usbProduct: m.port?.productName, usbSerial: m.port?.usbSerial,
                            isFTDI: m.port?.isFTDI ?? false, isOpenDMX: configuration.openDMXDevices.contains(m.key),
                            secondPortEnabled: configuration.secondPortDevices.contains(m.key))
        }.sorted { a, b in
            if a.isUSB != b.isUSB { return a.isUSB }
            if a.snapshot.kind != b.snapshot.kind { return a.snapshot.kind.rawValue < b.snapshot.kind.rawValue }
            return a.snapshot.name == b.snapshot.name ? a.id < b.id : a.snapshot.name < b.snapshot.name
        }
        if newRows != rows { rows = newRows }

        let enabled = managed.values.filter(\.isEnabled)
        var universes: [String: [Int]] = [:]
        for m in enabled {
            universes[m.key] = m.device.kind.isNetwork ? usedUniverses
                : Array(configuration.universes(for: m.key).filter { $0.key <= max(1, m.device.snapshot.portCount) }.values)
        }
        let newSummary = OutputHealth.summarize(enabled.map { $0.device.snapshot }, universes: universes,
                                                noHardware: hardwareDisabled && !simulatedDevicesInstalled)
        if newSummary != summary { summary = newSummary }

        let outputting = enabled.contains { $0.device.snapshot.state.isLive } && !simulatedDevicesInstalled
        keepAwake.update(active: outputting && configuration.keepAwake && !hardwareDisabled,
                         keepDisplayOn: configuration.keepDisplayAwake)
        if keepAwake.isActive != isKeepingAwake { isKeepingAwake = keepAwake.isActive }
    }

    private func tick() {
        guard let app, !isShutDown else { return }
        let universes = HardwareTestPlan.universes(app.show.resolvedFixtures)
        if universes != usedUniverses { usedUniverses = universes }
        if let art = managed["artnet"]?.device as? NetworkDMXDevice {
            let nodes = art.nodes
            if nodes != artNetNodes { artNetNodes = nodes }
        } else if !artNetNodes.isEmpty {
            artNetNodes = []
        }
        refresh()
    }

    // MARK: - Settings actions

    private func save() {
        if let data = configuration.encoded() { UserDefaults.standard.set(data, forKey: Self.configurationKey) }
    }

    func setUniverse(_ universe: Int, deviceKey: String, port: Int) {
        configuration.setUniverse(clamp(universe, 1, 64), deviceKey: deviceKey, port: port)
        save()
        refresh()
    }

    func setEnabled(_ enabled: Bool, deviceKey: String) {
        if enabled { configuration.disabledDevices.remove(deviceKey) } else { configuration.disabledDevices.insert(deviceKey) }
        save()
        rebuildUSB(deviceKey)
    }

    /// Marks an FTDI device as an Open DMX cable (or back to a Pro-style interface).
    func setOpenDMX(_ on: Bool, deviceKey: String) {
        if on { configuration.openDMXDevices.insert(deviceKey) } else { configuration.openDMXDevices.remove(deviceKey) }
        save()
        if managed[deviceKey] != nil {
            rebuildUSB(deviceKey)
        } else if on, let info = otherPorts.first(where: { $0.deviceKey == deviceKey }) {
            otherPorts.removeAll { $0.registryID == info.registryID }
            portAdded(info)
        }
    }

    /// Turns the Pro Mk2's second universe on or off.
    func setSecondPort(_ on: Bool, deviceKey: String) {
        if on { configuration.secondPortDevices.insert(deviceKey) } else { configuration.secondPortDevices.remove(deviceKey) }
        save()
        rebuildUSB(deviceKey)
    }

    func fixSlowRefresh(deviceKey: String) {
        (managed[deviceKey]?.device as? EnttecProDevice)?.fixSlowRefresh()
    }

    func updateArtNet(_ settings: ArtNetSettings) {
        guard settings != configuration.artNet else { return }
        configuration.artNet = settings
        save()
        syncNetworkDevices()
    }

    func updateSACN(_ settings: SACNSettings) {
        guard settings != configuration.sacn else { return }
        configuration.sacn = settings
        save()
        syncNetworkDevices()
    }

    func setKeepAwake(_ on: Bool) {
        configuration.keepAwake = on
        save()
        refresh()
    }

    func setKeepDisplayAwake(_ on: Bool) {
        configuration.keepDisplayAwake = on
        save()
        refresh()
    }

    /// Universes with patched lights that no output sends.
    var unroutedUniverses: [Int] {
        let routed = Set(registered.values)
        return usedUniverses.filter { !routed.contains($0) && $0 != 1 }
    }

    /// Frames for the channel monitor: what the engine sent for `universe` most recently.
    func latestFrame(universe: Int) -> [UInt8] {
        engine.latestFrame.universes[universe] ?? [UInt8](repeating: 0, count: 512)
    }

    // MARK: - Simulation (screenshot tour & self-test)

    /// Replaces the device list with simulated devices (tour and self-test only).
    func installSimulatedDevices(_ devices: [SimulatedDMXDevice]) {
        removeSimulatedDevices()
        simulatedDevicesInstalled = true
        for device in devices {
            let m = ManagedDevice(key: device.id, device: device, port: nil, isEnabled: true)
            managed[device.id] = m
            observe(m)
            device.start()
            m.lastState = device.snapshot.state
            if !device.kind.isNetwork {
                configuration.assignDefaults(deviceKey: device.id, portCount: device.snapshot.portCount,
                                             presentDevices: Set(devices.map(\.id)))
            }
        }
        refresh()
    }

    /// Removes simulated devices and their routes again.
    func removeSimulatedDevices() {
        let simulated = managed.values.filter { $0.device is SimulatedDMXDevice }
        for m in simulated {
            managed[m.key] = nil
            configuration.bindings.removeAll { $0.deviceKey == m.key }
        }
        simulatedDevicesInstalled = false
        refresh()
    }

    /// The simulated device with `id`, if installed.
    func simulatedDevice(_ id: String) -> SimulatedDMXDevice? {
        managed[id]?.device as? SimulatedDMXDevice
    }
}
