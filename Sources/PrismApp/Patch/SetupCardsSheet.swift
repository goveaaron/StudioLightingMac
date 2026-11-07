import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PrismCore

// MARK: - Setup Cards Sheet (§4.4)

struct SetupCardsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var completedIDs: Set<UUID> = []
    @State private var expandedDipIDs: Set<UUID> = []
    @State private var filterOnlySelected: Bool = false

    private var cards: [SetupCard] {
        let allResolved = app.show.resolvedFixtures
        let filtered: [ResolvedFixture]
        if filterOnlySelected && !app.show.selection.isEmpty {
            filtered = allResolved.filter { app.show.selection.contains($0.id) }
        } else {
            filtered = allResolved
        }
        return SetupCardGenerator.cards(for: filtered)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.stroke)

            if cards.isEmpty {
                EmptyStateView(
                    systemImage: "list.bullet.rectangle.portrait",
                    title: "No Patched Lights Yet",
                    message: "Add lights to your show first, and Prism will generate step-by-step physical setup cards for each one.",
                    actionTitle: "Add Light"
                ) {
                    app.ui.activeSheet = .addFixture
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.Space.m) {
                        ForEach(cards) { card in
                            setupCardView(card)
                        }
                    }
                    .padding(Theme.Space.l)
                }
            }

            Divider().overlay(Theme.stroke)
            footer
        }
        .background(Theme.window)
        .frame(width: 820, height: 620)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Physical Light Setup Cards")
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                Text("Walk up to each light in your studio and enter the exact DMX address and mode below. Click \"Test Light\" to blink it.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if !cards.isEmpty {
                StatusPill(
                    text: "\(completedIDs.intersection(Set(cards.map(\.id))).count) of \(cards.count) done",
                    color: completedIDs.count >= cards.count ? Theme.success : Theme.accent,
                    systemImage: "checkmark.circle.fill"
                )
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.m)
    }

    private func setupCardView(_ card: SetupCard) -> some View {
        let isDone = completedIDs.contains(card.id)
        let showDip = card.usesDipSwitches || expandedDipIDs.contains(card.id)

        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            // Top bar: Checkbox, Light Name, Model, Big Address & Mode Badges, Test Button
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Button {
                    if isDone { completedIDs.remove(card.id) } else { completedIDs.insert(card.id) }
                } label: {
                    Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isDone ? Theme.success : Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Mark this light as configured")

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(card.shortName)
                            .font(Theme.Font.mono(12))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.accentSoft))
                        Text(card.fixtureName)
                            .font(Theme.Font.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Text("· \(card.modelDisplayName)")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Text(card.headline)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textPrimary)
                }

                Spacer()

                // Physical display badge (looks like the OLED screen on the light)
                HStack(spacing: 8) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("ADDRESS")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                        Text(card.formattedAddress.first?.isLetter == true ? card.formattedAddress : "A\(card.formattedAddress)")
                            .font(Theme.Font.mono(16).weight(.bold))
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.canvas))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.strokeStrong))

                    VStack(alignment: .leading, spacing: 1) {
                        Text("MODE (\(card.channelCount) CH)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                        Text(card.fixtureMenuModeName)
                            .font(Theme.Font.mono(13).weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.canvas))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.strokeStrong))
                }

                Button {
                    app.show.identify([card.fixtureID])
                    app.ui.toast("Blinking \(card.fixtureName) (U\(card.universe)·A\(card.formattedAddress)) for 2s", systemImage: "light.max")
                } label: {
                    Label("Test Light", systemImage: "bolt.fill")
                }
                .buttonStyle(.pill(tint: Theme.accent, prominent: true, compact: true))
            }

            Divider().overlay(Theme.stroke)

            // Numbered Steps
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(card.steps.enumerated()), id: \.offset) { idx, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(idx + 1)")
                            .font(Theme.Font.number(10, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Theme.accentSoft))
                        Text(step)
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let tip = card.importantTip {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.display")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.warning)
                    Text(tip)
                        .font(Theme.Font.captionStrong)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Theme.warning.opacity(0.12)))
            }

            // Optional DIP switch diagram toggle
            HStack {
                Button {
                    if showDip {
                        expandedDipIDs.remove(card.id)
                    } else {
                        expandedDipIDs.insert(card.id)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showDip ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                        Text("DIP Switch Diagram (Address \(card.address))")
                            .font(Theme.Font.caption)
                    }
                    .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                Spacer()
            }

            if showDip {
                dipSwitchDiagram(card.dipSwitches, address: card.address)
            }
        }
        .padding(Theme.Space.m)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(isDone ? Theme.panel.opacity(0.65) : Theme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(isDone ? Theme.success.opacity(0.45) : Theme.stroke, lineWidth: 1)
        )
    }

    private func dipSwitchDiagram(_ switches: [Bool], address: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<min(switches.count, 9), id: \.self) { idx in
                let isOn = switches[idx]
                let weight = 1 << idx
                VStack(spacing: 3) {
                    Text("\(idx + 1)")
                        .font(Theme.Font.number(10, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                    ZStack(alignment: isOn ? .top : .bottom) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.canvas)
                            .frame(width: 22, height: 28)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(isOn ? Theme.accent : Theme.controlHover)
                            .frame(width: 18, height: 12)
                            .padding(2)
                    }
                    Text(isOn ? "ON" : "OFF")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isOn ? Theme.accent : Theme.textTertiary)
                    Text("+\(weight)")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panelRaised))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("DIP Sum = \(address)")
                    .font(Theme.Font.mono(11))
                    .foregroundStyle(Theme.textPrimary)
                Text("Flip highlighted switches to ON")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Theme.canvas))
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.m) {
            if !app.show.selection.isEmpty {
                Toggle("Only selected lights (\(app.show.selection.count))", isOn: $filterOnlySelected)
                    .toggleStyle(.checkbox)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Button {
                let text = PatchCSV.patchSummaryText(projectName: app.show.project.name, fixtures: app.show.resolvedFixtures)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                app.ui.toast("Copied patch & setup summary to clipboard", style: .success, systemImage: "doc.on.clipboard")
            } label: {
                Label("Copy Summary", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.pill)

            Button {
                exportPrintableHTML()
            } label: {
                Label("Save Printable Setup Sheet…", systemImage: "printer")
            }
            .buttonStyle(.pill)

            Spacer()

            Button("Light Not Responding?") {
                app.ui.activeSheet = .troubleshooter
            }
            .buttonStyle(.pill)

            Button("Done") { dismiss() }
                .buttonStyle(.pill(prominent: true))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.m)
    }

    private func exportPrintableHTML() {
        let html = SetupCardGenerator.renderPrintableHTML(projectTitle: app.show.project.name, cards: cards)
        let panel = NSSavePanel()
        panel.title = "Save Printable Setup Cards"
        panel.nameFieldStringValue = "\(app.show.project.name) Setup Cards.html"
        panel.allowedContentTypes = [.html]
        if panel.runModal() == .OK, let url = panel.url {
            try? html.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
        }
    }
}

