import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PrismCore

// MARK: - Visual Fixture Profile Editor Sheet (§4.10)

struct ProfileEditorSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var manufacturer: String = "Custom"
    @State private var model: String = "Studio RGBWW Light"
    @State private var category: FixtureCategory = .panel
    @State private var cctMin: Double = 2700
    @State private var cctMax: Double = 6500
    @State private var addressFormat: String = "A001"
    @State private var connectorNote: String = "5-pin DMX in/out"
    @State private var modeName: String = "CCT & RGB"
    @State private var friendlyModeName: String = "Full color + white balance"
    @State private var fixtureMenuModeName: String = "1: CCT&RGB"
    @State private var channels: [ChannelDefinition] = [
        ChannelDefinition(kind: .intensity, label: "Dimmer", defaultValue: 0),
        ChannelDefinition(kind: .cct, label: "CCT", physical: PhysicalRange(from: 2700, to: 6500, unit: "K")),
        ChannelDefinition(kind: .tint, label: "G/M Tint", defaultValue: 128),
        ChannelDefinition(kind: .crossfade, label: "Crossfade to RGB", defaultValue: 255),
        ChannelDefinition(kind: .red, label: "Red"),
        ChannelDefinition(kind: .green, label: "Green"),
        ChannelDefinition(kind: .blue, label: "Blue"),
    ]
    @State private var pixelGeneratorCount: Int = 8
    @State private var alsoPatchAfterSaving: Bool = true

    private var draftDefinition: FixtureDefinition {
        let mode = FixtureMode(
            name: modeName.trimmingCharacters(in: .whitespaces).isEmpty ? "Standard" : modeName,
            shortName: "\(channels.count)ch",
            summary: friendlyModeName,
            recommended: true,
            channels: channels,
            friendlyName: friendlyModeName,
            fixtureMenuName: fixtureMenuModeName
        )
        let guide = FixtureSetupGuide(
            addressMenuPath: ["MENU", "DMX Settings", "DMX Address"],
            modeMenuPath: ["MENU", "DMX Settings", "DMX Mode"],
            connector: connectorNote,
            addressDisplayFormat: addressFormat,
            signalLossBehavior: "Hold Last Setting"
        )
        let id = FixtureDefinition.makeID(manufacturer: manufacturer, model: model)
        return FixtureDefinition(
            id: id.isEmpty ? "user.custom-light" : id,
            manufacturer: manufacturer.trimmingCharacters(in: .whitespaces).isEmpty ? "Custom" : manufacturer,
            model: model.trimmingCharacters(in: .whitespaces).isEmpty ? "Light" : model,
            category: category,
            cctRange: [min(cctMin, cctMax), max(cctMin, cctMax)],
            modes: [mode],
            source: "user",
            setupGuide: guide,
            verification: .manufacturerChart
        )
    }

    private var validationWarnings: [String] {
        var issues: [String] = []
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("Model name cannot be empty.")
        }
        if channels.isEmpty {
            issues.append("Add at least 1 DMX channel.")
        } else if channels.count > 512 {
            issues.append("A single DMX mode cannot exceed 512 channels.")
        }
        for (i, ch) in channels.enumerated() where ch.fine {
            if i == 0 || channels[i - 1].kind != ch.kind {
                issues.append("Ch \(i + 1) (\(ch.displayName)) is marked 16-bit fine without a matching coarse channel right before it.")
            }
        }
        return issues
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.stroke)

            HStack(alignment: .top, spacing: 0) {
                metadataColumn
                    .frame(width: 310)
                Divider().overlay(Theme.stroke)
                channelBuilderColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider().overlay(Theme.stroke)
            footer
        }
        .background(Theme.window)
        .frame(width: 860, height: 610)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Fixture Profile Builder")
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                Text("Describe each DMX channel from your light's manual. Saved profiles live in your user library and travel inside .prismlights project files.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            StatusPill(
                text: validationWarnings.isEmpty ? "Valid (\(channels.count) ch · \(draftDefinition.modes[0].capabilities.badge))" : "\(validationWarnings.count) issue",
                color: validationWarnings.isEmpty ? Theme.success : Theme.warning,
                systemImage: validationWarnings.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
            )
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.m)
    }

    private var metadataColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader("Light Identity", systemImage: "tag")

                labeledField("Manufacturer / Brand", text: $manufacturer)
                labeledField("Model Name", text: $model)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Fixture Category")
                        .font(Theme.Font.captionStrong)
                        .foregroundStyle(Theme.textSecondary)
                    Picker("Category", selection: $category) {
                        ForEach(FixtureCategory.allCases, id: \.self) { cat in
                            Text(cat.displayName).tag(cat)
                        }
                    }
                    .labelsHidden()
                }

                Divider().overlay(Theme.stroke)
                SectionHeader("Mode & Physical Menu", systemImage: "dial.medium")

                labeledField("Mode Name", text: $modeName)
                labeledField("Plain-English Description", text: $friendlyModeName)
                labeledField("Text on Light's Menu Screen", text: $fixtureMenuModeName)
                labeledField("Address Display Format (e.g. A001)", text: $addressFormat)

                Divider().overlay(Theme.stroke)
                SectionHeader("Quick Templates", systemImage: "wand.and.stars")

                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        channels = [ChannelDefinition(kind: .intensity, label: "Dimmer")]
                        modeName = "1ch Dimmer"
                        friendlyModeName = "Brightness only"
                    } label: {
                        Text("1-Channel Dimmer")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.pill(compact: true))

                    Button {
                        channels = [
                            ChannelDefinition(kind: .intensity, label: "Dimmer"),
                            ChannelDefinition(kind: .cct, label: "CCT", physical: PhysicalRange(from: cctMin, to: cctMax, unit: "K")),
                            ChannelDefinition(kind: .tint, label: "Tint", defaultValue: 128),
                            ChannelDefinition(kind: .crossfade, label: "Crossfade", defaultValue: 255),
                            ChannelDefinition(kind: .red, label: "Red"),
                            ChannelDefinition(kind: .green, label: "Green"),
                            ChannelDefinition(kind: .blue, label: "Blue"),
                        ]
                        modeName = "CCT & RGB (7ch)"
                        friendlyModeName = "Full color + white balance"
                    } label: {
                        Text("Dimmer + CCT + RGB (7 ch)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.pill(compact: true))

                    HStack {
                        Stepper("Zones: \(pixelGeneratorCount)", value: $pixelGeneratorCount, in: 2...32)
                            .font(Theme.Font.caption)
                        Button("Build \(pixelGeneratorCount)× RGB Tube") {
                            var list: [ChannelDefinition] = [ChannelDefinition(kind: .intensity, label: "Master Dimmer")]
                            for px in 0..<pixelGeneratorCount {
                                list.append(ChannelDefinition(kind: .red, cell: px, label: "Red"))
                                list.append(ChannelDefinition(kind: .green, cell: px, label: "Green"))
                                list.append(ChannelDefinition(kind: .blue, cell: px, label: "Blue"))
                            }
                            channels = list
                            category = .tube
                            modeName = "RGB \(pixelGeneratorCount) Pixels"
                            friendlyModeName = "Full RGB color · \(pixelGeneratorCount) zones"
                        }
                        .buttonStyle(.pill(compact: true))
                    }
                }
            }
            .padding(Theme.Space.m)
        }
    }

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Theme.Font.captionStrong)
                .foregroundStyle(Theme.textSecondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var channelBuilderColumn: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                SectionHeader("DMX Channels (1 → \(channels.count))", systemImage: "slider.horizontal.3")
                Spacer()
                Button {
                    channels.append(ChannelDefinition(kind: .generic, label: "Ch \(channels.count + 1)"))
                } label: {
                    Label("Add Channel", systemImage: "plus")
                }
                .buttonStyle(.pill(prominent: true, compact: true))
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(channels.enumerated()), id: \.offset) { idx, ch in
                        channelRow(index: idx, channel: ch)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(Theme.Space.m)
    }

    private func channelRow(index: Int, channel: ChannelDefinition) -> some View {
        HStack(spacing: 10) {
            Text("Ch \(index + 1)")
                .font(Theme.Font.mono(11).weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, alignment: .leading)

            Picker("Kind", selection: Binding(
                get: { channels[index].kind },
                set: { newKind in
                    channels[index].kind = newKind
                    channels[index].label = newKind.defaultLabel
                }
            )) {
                ForEach(ChannelKind.allCases, id: \.self) { kind in
                    Text(kind.defaultLabel).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 145)

            TextField("Label", text: Binding(
                get: { channels[index].label ?? channels[index].kind.defaultLabel },
                set: { channels[index].label = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 150)

            Toggle("16-bit Fine", isOn: Binding(
                get: { channels[index].fine },
                set: { channels[index].fine = $0 }
            ))
            .toggleStyle(.checkbox)
            .font(Theme.Font.caption)

            HStack(spacing: 4) {
                Text("Zone:")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                Picker("Zone", selection: Binding(
                    get: { channels[index].cell ?? -1 },
                    set: { channels[index].cell = $0 < 0 ? nil : $0 }
                )) {
                    Text("All").tag(-1)
                    ForEach(0..<16, id: \.self) { z in
                        Text("Px \(z + 1)").tag(z)
                    }
                }
                .labelsHidden()
                .frame(width: 72)
            }

            Spacer()

            Button {
                if channels.count > 1 {
                    channels.remove(at: index)
                }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(channels.count > 1 ? Theme.danger : Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(channels.count <= 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(Theme.stroke))
    }

    private var footer: some View {
        HStack {
            Toggle("Also add 1 light of this type to current show", isOn: $alsoPatchAfterSaving)
                .toggleStyle(.checkbox)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)

            Spacer()

            Button("Cancel") { dismiss() }
                .buttonStyle(.pill)
                .keyboardShortcut(.cancelAction)

            Button {
                saveProfile()
            } label: {
                Label("Save Profile to Library", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.pill(prominent: true))
            .disabled(!validationWarnings.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.m)
    }

    private func saveProfile() {
        let def = draftDefinition
        do {
            try app.library.saveUserDefinition(def)
            if alsoPatchAfterSaving, let firstMode = def.modes.first {
                _ = app.show.addFixturesWithOptions(
                    definitionID: def.id,
                    modeName: firstMode.name,
                    count: 1,
                    baseName: def.model
                )
            }
            app.ui.toast("Saved \(def.displayName) to your fixture library.", style: .success, systemImage: "checkmark.seal.fill")
            dismiss()
        } catch {
            app.ui.toast("Couldn't save profile: \(error.localizedDescription)", style: .error, systemImage: "exclamationmark.triangle.fill")
        }
    }
}
