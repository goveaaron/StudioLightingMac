import SwiftUI
import PrismCore

/// Settings › Outputs: DMX boxes, Art-Net / sACN, refresh rate, sleep and quit behavior.
///
/// OWNER: Hardware workstream. Also shown as a sheet (`AppSheet.outputSettings`) from the
/// Hardware Test, so it can be reached without leaving the show.
struct OutputSettingsPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var prefs = app.preferences
        let outputs = app.outputs
        let usbRows = outputs.rows.filter(\.isUSB)
        Form {
            Section {
                if usbRows.isEmpty {
                    NoBoxRow()
                } else {
                    ForEach(usbRows) { row in USBDeviceSettingsRow(row: row) }
                }
                if !outputs.otherPorts.isEmpty {
                    DisclosureGroup("Other USB serial devices (\(outputs.otherPorts.count))") {
                        ForEach(outputs.otherPorts) { port in
                            LabeledContent(port.friendlyName, value: port.ttyName ?? port.path)
                        }
                    }
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                }
            } header: {
                Text("DMX boxes")
            } footer: {
                Text("Prism finds ENTTEC DMX USB Pro–compatible boxes by itself and reconnects after unplugging or sleep.")
            }

            ArtNetSection()
            SACNSection()

            Section {
                LabeledContent("Refresh rate") {
                    Picker("", selection: $prefs.frameRate) {
                        Text("30 fps").tag(30.0)
                        Text("40 fps (recommended)").tag(40.0)
                        Text("44 fps").tag(44.0)
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                Toggle("Keep this Mac awake while the lights are live",
                       isOn: Binding(get: { outputs.configuration.keepAwake }, set: { outputs.setKeepAwake($0) }))
                if outputs.configuration.keepAwake {
                    Toggle("Keep the display on too",
                           isOn: Binding(get: { outputs.configuration.keepDisplayAwake }, set: { outputs.setKeepDisplayAwake($0) }))
                }
                Picker("When Prism quits", selection: $prefs.blackoutOnQuit) {
                    Text("Hold the last look").tag(false)
                    Text("Black out the lights").tag(true)
                }
            } header: {
                Text("Sending")
            } footer: {
                Text(outputs.isKeepingAwake
                     ? "Your Mac is staying awake right now because the lights are live."
                     : "Prism keeps the Mac awake only while a DMX box or network output is live.")
            }

            Section {
                if !outputs.unroutedUniverses.isEmpty {
                    Label("\(OutputHealth.universeList(outputs.unroutedUniverses).capitalizedFirstLetter) has lights but no output. Choose it for a DMX box above, or turn on Art-Net or sACN.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.warning)
                }
                HStack {
                    Text("Not sure everything works?")
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Run Hardware Test…") { app.ui.activeSheet = .hardwareTest }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: prefs.frameRate) { _, fps in app.engine.setFrameRate(fps) }
    }
}

extension String {
    /// "universe 2" → "Universe 2".
    var capitalizedFirstLetter: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

// MARK: - DMX boxes

private struct NoBoxRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("No DMX box connected")
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(app.outputs.hardwareDisabled && !app.launch.isAutomated
                     ? "Prism was started without hardware, so it's simulating your lights."
                     : "Plug in your DMX box — it shows up here within a second.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Look again") { app.outputs.rescan() }
                .disabled(app.outputs.hardwareDisabled)
        }
        .padding(.vertical, 2)
    }
}

private struct USBDeviceSettingsRow: View {
    @Environment(AppModel.self) private var app
    let row: OutputDeviceRow

    var body: some View {
        let s = row.snapshot
        let outputs = app.outputs
        let tint = row.isEnabled ? s.state.tint : Theme.textTertiary
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Image(systemName: s.kind.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(tint.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name)
                        .font(Theme.Font.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(identity)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: Theme.Space.s)
                StatusPill(text: row.isEnabled ? s.badgeTitle : "Off", color: tint, pulsing: s.state == .live)
                Toggle("Use this box", isOn: Binding(get: { row.isEnabled },
                                                     set: { outputs.setEnabled($0, deviceKey: row.id) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help(row.isEnabled ? "Turn this box off in Prism" : "Turn this box on")
            }

            if row.isEnabled {
                ForEach(1...max(1, s.portCount), id: \.self) { port in
                    LabeledContent(s.portCount > 1 ? "Output \(port) sends" : "Sends") {
                        UniversePicker(selection: Binding(get: { row.universes[port] ?? port },
                                                          set: { outputs.setUniverse($0, deviceKey: row.id, port: port) }))
                    }
                }
                if s.state != .live {
                    Text(s.message)
                        .font(Theme.Font.caption)
                        .foregroundStyle(s.state == .busy ? Theme.danger : Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let warning = s.warning {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Theme.Space.s)
                        if s.kind == .enttecPro, s.state == .live {
                            Button("Set to 40 fps") { outputs.fixSlowRefresh(deviceKey: row.id) }
                                .controlSize(.small)
                        }
                    }
                }
            }

            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 6) {
                    if s.name.localizedCaseInsensitiveContains("mk2") {
                        Toggle("Use the second DMX output (Pro Mk2)",
                               isOn: Binding(get: { row.secondPortEnabled }, set: { outputs.setSecondPort($0, deviceKey: row.id) }))
                    }
                    if row.isFTDI && (row.isOpenDMX || s.state == .unsupported) {
                        Toggle("This is an Open DMX cable (no box, just a cable)",
                               isOn: Binding(get: { row.isOpenDMX }, set: { outputs.setOpenDMX($0, deviceKey: row.id) }))
                    }
                    detail("Device", s.path ?? "—")
                    if let product = row.usbProduct { detail("USB name", product) }
                    if let timing = s.timing { detail("Output timing", timing) }
                    detail("Frames sent", "\(s.stats.framesSent)")
                    detail("Frames skipped", "\(s.stats.framesDropped)")
                    detail("Reconnects", "\(s.stats.reconnects)")
                    detail("Updates per second", String(format: "%.0f", s.stats.updatesPerSecond))
                    detail("Delay to the box", String(format: "%.1f ms", s.stats.averageLatencyMs))
                    if let error = s.lastError, !error.isEmpty { detail("Last problem", error) }
                }
                .padding(.top, 4)
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 4)
    }

    private var identity: String {
        var parts: [String] = []
        if let serial = row.snapshot.serialNumber, !serial.isEmpty { parts.append("Serial \(serial)") }
        if let firmware = row.snapshot.firmware, !firmware.isEmpty { parts.append("Firmware \(firmware)") }
        if parts.isEmpty { parts.append(row.snapshot.kind.title) }
        return parts.joined(separator: " · ")
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Theme.textTertiary)
            Spacer(minLength: Theme.Space.m)
            Text(value)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(Theme.Font.caption)
    }
}

/// Picks a Prism universe, showing how many lights each one has.
private struct UniversePicker: View {
    @Environment(AppModel.self) private var app
    @Binding var selection: Int

    var body: some View {
        let counts = Dictionary(grouping: app.show.resolvedFixtures.filter { $0.fixture.address != nil },
                                by: { $0.fixture.universe }).mapValues(\.count)
        let highest = max(4, (counts.keys.max() ?? 1) + 1, selection)
        Picker("", selection: $selection) {
            ForEach(1...min(highest, 64), id: \.self) { u in
                let n = counts[u] ?? 0
                Text(n > 0 ? "Universe \(u) · \(n) light\(n == 1 ? "" : "s")" : "Universe \(u)").tag(u)
            }
        }
        .labelsHidden()
        .frame(width: 200)
    }
}

// MARK: - Network

private struct ArtNetSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let outputs = app.outputs
        let settings = outputs.configuration.artNet
        Section {
            Toggle("Send Art-Net", isOn: bind(\.enabled))
            if settings.enabled {
                Picker("Send to", selection: bind(\.mode)) {
                    ForEach(ArtNetSettings.Mode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }
                if settings.mode == .unicast {
                    AddressField(title: "Node address", value: settings.unicastAddress) { text in
                        var s = outputs.configuration.artNet
                        s.unicastAddress = text
                        outputs.updateArtNet(s)
                    }
                }
                InterfacePicker(selection: bind(\.interfaceName))
                Stepper(value: bind(\.universeOffset), in: 0...32_767) {
                    LabeledContent("Prism universe 1 is Art-Net",
                                   value: ArtNet.PortAddress(prismUniverse: 1, offset: settings.universeOffset).description)
                }
                NetworkStatusRow(key: "artnet")
                if !outputs.artNetNodes.isEmpty {
                    ForEach(outputs.artNetNodes, id: \.self) { node in
                        LabeledContent(node.shortName.isEmpty ? "Art-Net node" : node.shortName, value: node.ip.description)
                            .font(Theme.Font.caption)
                    }
                }
            }
        } header: {
            Text("Art-Net")
        } footer: {
            Text("Sends DMX over your network to Art-Net nodes. “Automatic” sends straight to nodes that answer, or broadcasts if none do.")
        }
    }

    private func bind<T>(_ keyPath: WritableKeyPath<ArtNetSettings, T>) -> Binding<T> {
        let outputs = app.outputs
        return Binding(get: { outputs.configuration.artNet[keyPath: keyPath] },
                       set: { value in
                           var s = outputs.configuration.artNet
                           s[keyPath: keyPath] = value
                           outputs.updateArtNet(s)
                       })
    }
}

private struct SACNSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let outputs = app.outputs
        let settings = outputs.configuration.sacn
        Section {
            Toggle("Send sACN (E1.31)", isOn: bind(\.enabled))
            if settings.enabled {
                Picker("Send to", selection: bind(\.mode)) {
                    ForEach(SACNSettings.Mode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }
                if settings.mode == .unicast {
                    AddressField(title: "Receiver address", value: settings.unicastAddress) { text in
                        var s = outputs.configuration.sacn
                        s.unicastAddress = text
                        outputs.updateSACN(s)
                    }
                }
                InterfacePicker(selection: bind(\.interfaceName))
                Stepper(value: bind(\.universeOffset), in: 0...63_998) {
                    LabeledContent("Prism universe 1 is sACN universe",
                                   value: "\(SACN.universe(forPrismUniverse: 1, offset: settings.universeOffset))")
                }
                Stepper(value: bind(\.priority), in: 0...200) {
                    LabeledContent("Priority", value: "\(settings.priority)")
                }
                NetworkStatusRow(key: "sacn")
            }
        } header: {
            Text("sACN")
        } footer: {
            Text("Streaming ACN for network DMX gear. When several sources send the same universe, the highest priority wins (100 is normal).")
        }
    }

    private func bind<T>(_ keyPath: WritableKeyPath<SACNSettings, T>) -> Binding<T> {
        let outputs = app.outputs
        return Binding(get: { outputs.configuration.sacn[keyPath: keyPath] },
                       set: { value in
                           var s = outputs.configuration.sacn
                           s[keyPath: keyPath] = value
                           outputs.updateSACN(s)
                       })
    }
}

/// Live state and route of a network output.
private struct NetworkStatusRow: View {
    @Environment(AppModel.self) private var app
    let key: String

    var body: some View {
        if let row = app.outputs.rows.first(where: { $0.id == key }) {
            let s = row.snapshot
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Circle().fill(s.state.tint).frame(width: 7, height: 7)
                Text(s.state == .live ? (s.path ?? "Sending") : s.message)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        } else if app.outputs.hardwareDisabled {
            Text("Network output is off while Prism runs without hardware.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

/// Network interface choice ("Automatic" = Prism picks the best one).
private struct InterfacePicker: View {
    @Environment(AppModel.self) private var app
    @Binding var selection: String?

    var body: some View {
        let interfaces = app.outputs.networkInterfaces
        Picker("Network", selection: $selection) {
            Text("Automatic").tag(String?.none)
            ForEach(interfaces) { interface in
                Text(interface.displayName).tag(Optional(interface.name))
            }
            if let current = selection, !interfaces.contains(where: { $0.name == current }) {
                Text("\(current) (not connected)").tag(Optional(current))
            }
        }
    }
}

/// An IPv4 address field that saves on Return or when it loses focus (never per keystroke,
/// which would restart the network output on every character).
private struct AddressField: View {
    let title: String
    let value: String
    let commit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let valid = trimmed.isEmpty || IPv4(trimmed) != nil
        LabeledContent(title) {
            HStack(spacing: 6) {
                if !valid {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                        .help("Type an address like 192.168.1.50")
                }
                TextField("", text: $text, prompt: Text("192.168.1.50"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .focused($focused)
                    .onSubmit { save() }
            }
        }
        .onAppear { text = value }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { save() }
        }
        .onChange(of: value) { _, newValue in
            if !focused { text = newValue }
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed != value else { return }
        commit(trimmed)
    }
}

// MARK: - Sheet

/// Settings › Outputs as a sheet, reachable from the Hardware Test.
struct OutputSettingsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Outputs")
                        .font(Theme.Font.title)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Your DMX boxes, network outputs and how Prism sends to your lights.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.pill(prominent: true))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.m)
            Divider().overlay(Theme.stroke)
            OutputSettingsPane()
        }
        .frame(width: 720, height: 660)
        .background(Theme.window)
        .onDisappear { app.outputs.sheetClosed() }
    }
}
