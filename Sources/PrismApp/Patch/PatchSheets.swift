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

// MARK: - Guided Troubleshooter Sheet (§4.8 — 7-Step Decision Tree)

struct TroubleshooterSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var selectedFixtureID: UUID?
    @State private var currentStep: Int = 1

    private var targetFixture: ResolvedFixture? {
        let list = app.show.resolvedFixtures
        if let id = selectedFixtureID, let found = list.first(where: { $0.id == id }) {
            return found
        }
        if let firstSelected = app.show.selection.first, let found = list.first(where: { $0.id == firstSelected }) {
            return found
        }
        return list.first
    }

    private var targetCard: SetupCard? {
        guard let rf = targetFixture, let addr = rf.fixture.address else { return nil }
        return SetupCardGenerator.makeCard(for: rf, address: addr)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.stroke)

            HStack(alignment: .top, spacing: 0) {
                stepSidebar
                    .frame(width: 250)
                Divider().overlay(Theme.stroke)
                stepDetailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider().overlay(Theme.stroke)
            footer
        }
        .background(Theme.window)
        .frame(width: 820, height: 560)
        .onAppear {
            if selectedFixtureID == nil {
                selectedFixtureID = app.show.selection.first ?? app.show.fixtures.first?.id
            }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("A Light Isn't Responding")
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                Text("Follow these 7 quick checks in order — 95% of studio DMX issues are solved by Step 6.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if !app.show.resolvedFixtures.isEmpty {
                Picker("Light:", selection: $selectedFixtureID) {
                    ForEach(app.show.resolvedFixtures) { rf in
                        Text("\(rf.fixture.stageLabel) · \(rf.fixture.name)").tag(Optional(rf.id))
                    }
                }
                .frame(width: 220)
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.m)
    }

    private let stepTitles: [(Int, String, String)] = [
        (1, "Power & Standby", "power"),
        (2, "USB / Network DMX Box", "cable.connector.horizontal"),
        (3, "Cable Direction & Chain", "arrow.left.arrow.right"),
        (4, "DMX Address Match", "number.square"),
        (5, "Mode & Channel Count", "dial.medium"),
        (6, "amaran Tube Screen Lock", "lock.display"),
        (7, "Scan & Find My Lights", "dot.radiowaves.left.and.right"),
    ]

    private var stepSidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("7-Step Checklist", systemImage: "stethoscope")
                .padding(.bottom, 4)

            ForEach(stepTitles, id: \.0) { step, title, icon in
                let active = (currentStep == step)
                let passed = (step < currentStep)
                Button {
                    currentStep = step
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: passed ? "checkmark.circle.fill" : icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(passed ? Theme.success : (active ? Color.white : Theme.textSecondary))
                            .frame(width: 22)
                        Text("\(step). \(title)")
                            .font(Theme.Font.captionStrong)
                            .foregroundStyle(active ? Color.white : Theme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.small)
                            .fill(active ? Theme.accent : (passed ? Theme.success.opacity(0.10) : Theme.panel))
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(Theme.Space.m)
    }

    private var stepDetailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                switch currentStep {
                case 1: step1PowerView
                case 2: step2InterfaceView
                case 3: step3CablesView
                case 4: step4AddressView
                case 5: step5ModeView
                case 6: step6TubeScreenLockView
                default: step7AddressScanView
                }
            }
            .padding(Theme.Space.xl)
        }
    }

    private var step1PowerView: some View {
        troubleshooterCard(
            step: 1,
            title: "Is the light powered on and awake?",
            icon: "power",
            summary: "Check that the light's AC adapter or battery is connected, the physical power switch is ON, and the light isn't muted by Sidus Link / Bluetooth standby."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                bulletRow("Make sure the LCD/OLED menu screen on the back of the light lights up when you press MENU.")
                bulletRow("If you previously controlled the light from a phone app (like Sidus Link), switch CRMX / Bluetooth off or set Control Mode to Wired DMX.")
            }
        }
    }

    private var step2InterfaceView: some View {
        let out = app.outputs.summary
        let isConnected = (out.level == .connected)
        return troubleshooterCard(
            step: 2,
            title: "Is your DMX interface connected to your Mac?",
            icon: "cable.connector.horizontal",
            summary: "Prism sends DMX through your USB DMX adapter (such as ENTTEC DMX USB Pro) or Art-Net / sACN node."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    StatusPill(
                        text: "\(out.title): \(out.detail)",
                        color: isConnected ? Theme.success : Theme.warning,
                        systemImage: isConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    Spacer()
                    Button {
                        app.ui.activeSheet = .hardwareTest
                    } label: {
                        Label("Test DMX Box…", systemImage: "bolt.horizontal.circle")
                    }
                    .buttonStyle(.pill(compact: true))
                }
                bulletRow("If your USB DMX box is plugged into an unpowered USB hub, try plugging it directly into a USB-C port on your Mac.")
                bulletRow("Check that the green LED on your ENTTEC or DMX interface is flickering steadily (indicating active DMX frames).")
            }
        }
    }

    private var step3CablesView: some View {
        troubleshooterCard(
            step: 3,
            title: "Are DMX cables plugged into the right ports?",
            icon: "arrow.left.arrow.right",
            summary: "DMX signal flows in one direction from your Mac: Interface OUT → Light 1 DMX IN → Light 1 DMX OUT → Light 2 DMX IN."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                bulletRow("Verify the cable from your Mac's DMX interface goes into the first light's DMX IN (female XLR), not DMX OUT.")
                bulletRow("For amaran PT1c / PT2c / PT4c tubes: use the official amaran USB-C to 5-Pin DMX Adapter plugged firmly into the tube's USB-C port.")
                bulletRow("If lights at the end of a long daisy-chain flicker randomly, plug a 120 Ω DMX terminator into the last light's DMX OUT.")
            }
        }
    }

    private var step4AddressView: some View {
        let card = targetCard
        let expectedDisplay = card.map { $0.formattedAddress.first?.isLetter == true ? $0.formattedAddress : "A\($0.formattedAddress)" } ?? "A001"
        return troubleshooterCard(
            step: 4,
            title: "Does the DMX address on the light match Prism?",
            icon: "number.square",
            summary: "Even being off by 1 channel (e.g. 056 instead of 057) will make the light ignore brightness or show random colors."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if let rf = targetFixture, let card {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("EXPECTED ON \(rf.fixture.name.uppercased())'S SCREEN")
                                .font(Theme.Font.sectionLabel)
                                .foregroundStyle(Theme.textTertiary)
                            Text("Universe \(card.universe) · Address \(expectedDisplay) (or \(card.formattedAddress))")
                                .font(Theme.Font.mono(16).weight(.bold))
                                .foregroundStyle(Theme.accent)
                        }
                        Spacer()
                        Button {
                            app.show.identify([rf.id])
                        } label: {
                            Label("Blink \(rf.fixture.stageLabel) Now", systemImage: "light.max")
                        }
                        .buttonStyle(.pill(prominent: true, compact: true))
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Theme.canvas))
                }
                bulletRow("Check that Grand Master at the bottom of Prism isn't at 0% and Blackout isn't active.")
            }
        }
    }

    private var step5ModeView: some View {
        let card = targetCard
        return troubleshooterCard(
            step: 5,
            title: "Is the light in the exact same DMX mode / profile?",
            icon: "dial.medium",
            summary: "A light in 1-pixel (10 ch) mode won't respond properly if Prism is sending 8-pixel (56 ch) data."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if let card {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("EXPECTED MODE ON LIGHT'S MENU")
                                .font(Theme.Font.sectionLabel)
                                .foregroundStyle(Theme.textTertiary)
                            Text("\(card.fixtureMenuModeName)  (\(card.channelCount) channels)")
                                .font(Theme.Font.mono(15).weight(.bold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        Spacer()
                        Button {
                            app.ui.activeSheet = .setupCards
                        } label: {
                            Label("Open All Setup Cards", systemImage: "list.bullet.rectangle.portrait")
                        }
                        .buttonStyle(.pill(compact: true))
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Theme.canvas))
                }
                bulletRow("If you prefer to keep the mode currently set on your physical light, change its mode in Prism's Patch table to match.")
            }
        }
    }

    private var step6TubeScreenLockView: some View {
        troubleshooterCard(
            step: 6,
            title: "Using amaran PT1c / PT2c / PT4c Pixel Tubes?",
            icon: "lock.display",
            summary: "This is the #1 gotcha on amaran PT tubes: the tube ONLY listens to wired DMX while the DMX Address screen is open!"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                bulletRow("On the back of the amaran PT tube, navigate to DMX Settings → DMX Address so the 3-digit address (e.g. 001) is shown on screen.")
                bulletRow("If you press BACK to return to the CCT or HSI manual screen, the tube stops listening to DMX.")
                bulletRow("Hold the OK button for 2 seconds while on the DMX Address screen to lock the screen so nobody accidentally exits DMX mode.")
            }
        }
    }

    private var step7AddressScanView: some View {
        troubleshooterCard(
            step: 7,
            title: "Still unsure what address the light is set to?",
            icon: "dot.radiowaves.left.and.right",
            summary: "Prism can sweep through DMX addresses automatically until your light blinks, or use your Mac's camera to locate every light."
        ) {
            HStack(spacing: Theme.Space.m) {
                Button {
                    app.ui.activeSheet = .addressScan
                } label: {
                    Label("Launch Find My Lights (Address Scan)…", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(.pill(prominent: true))

                Button {
                    app.ui.activeSheet = .lightFinder
                } label: {
                    Label("Use Camera Light Finder…", systemImage: "camera.viewfinder")
                }
                .buttonStyle(.pill)
            }
        }
    }

    private func troubleshooterCard<Content: View>(
        step: Int,
        title: String,
        icon: String,
        summary: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentSoft))
                VStack(alignment: .leading, spacing: 2) {
                    Text("STEP \(step) OF 7")
                        .font(Theme.Font.sectionLabel)
                        .foregroundStyle(Theme.accent)
                    Text(title)
                        .font(Theme.Font.title)
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            Text(summary)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
            Divider().overlay(Theme.stroke)
            content()
        }
        .prismPanel()
    }

    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.top, 2)
            Text(text)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            if currentStep > 1 {
                Button("← Previous Step") {
                    currentStep -= 1
                }
                .buttonStyle(.pill)
            }
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(.pill)
                .keyboardShortcut(.cancelAction)
            if currentStep < 7 {
                Button("Didn't Fix It · Next Step →") {
                    currentStep += 1
                }
                .buttonStyle(.pill(prominent: true))
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Open Address Scanner…") {
                    app.ui.activeSheet = .addressScan
                }
                .buttonStyle(.pill(prominent: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.m)
    }
}

// MARK: - Address Scan / Find My Lights Sheet (§4.9)

struct AddressScanSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    enum ScanMode: String, CaseIterable, Identifiable {
        case patchedFixtures = "Flash Patched Lights One by One"
        case rawSweep = "Sweep Raw DMX Addresses (1–512)"
        var id: String { rawValue }
    }

    @State private var scanMode: ScanMode = .patchedFixtures
    @State private var currentIndex: Int = 0
    @State private var rawStartAddress: Int = 1
    @State private var rawWindowSize: Int = 56
    @State private var scanUniverse: Int = 1
    @State private var isFlashing: Bool = false
    /// Records `(universe, address, matchedFixtureID)` as the user identifies which physical light lit up.
    @State private var recordedProbes: [(universe: Int, address: Int, matchedFixtureID: UUID?)] = []

    private var patchedFixtures: [ResolvedFixture] {
        app.show.resolvedFixtures.filter { $0.fixture.address != nil }
    }

    private var currentTestedAddress: (universe: Int, range: ClosedRange<Int>, label: String) {
        switch scanMode {
        case .patchedFixtures:
            guard !patchedFixtures.isEmpty else {
                return (scanUniverse, 1...10, "U\(scanUniverse) · 001–010")
            }
            let idx = clamp(currentIndex, 0, patchedFixtures.count - 1)
            let rf = patchedFixtures[idx]
            let r = rf.addressRange ?? 1...1
            return (rf.fixture.universe, r, "U\(rf.fixture.universe) · A\(String(format: "%03d", r.lowerBound))–\(String(format: "%03d", r.upperBound)) (expected: \(rf.fixture.stageLabel) \(rf.fixture.name))")
        case .rawSweep:
            let lo = clamp(rawStartAddress, 1, 512)
            let hi = clamp(lo + max(1, rawWindowSize) - 1, lo, 512)
            return (scanUniverse, lo...hi, "U\(scanUniverse) · A\(String(format: "%03d", lo))–\(String(format: "%03d", hi))")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Find My Lights (Address Scanner)")
                        .font(Theme.Font.title)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Prism flashes one DMX address range at a time. Click which light in your room actually lit up, and Prism fixes your patch.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button {
                    app.show.clearRawOverrides()
                    app.ui.activeSheet = .lightFinder
                } label: {
                    Label("Let the Camera Do It…", systemImage: "camera.viewfinder")
                }
                .buttonStyle(.pill(tint: Theme.accent, prominent: false, compact: true))
            }

            Picker("Scan Mode", selection: $scanMode) {
                ForEach(ScanMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: scanMode) { _, _ in
                triggerCurrentFlash()
            }

            // Active probe card
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                let probe = currentTestedAddress
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CURRENTLY FLASHING DMX OUTPUT")
                            .font(Theme.Font.sectionLabel)
                            .foregroundStyle(Theme.accent)
                        Text(probe.label)
                            .font(Theme.Font.mono(16).weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Spacer()
                    Button {
                        triggerCurrentFlash()
                    } label: {
                        Label(isFlashing ? "Flashing Active" : "Flash Again", systemImage: "light.max")
                    }
                    .buttonStyle(.pill(tint: Theme.accent, prominent: true))
                }

                if scanMode == .rawSweep {
                    HStack(spacing: Theme.Space.m) {
                        Stepper("Universe \(scanUniverse)", value: $scanUniverse, in: 1...16)
                        Stepper("Start Address: \(String(format: "%03d", rawStartAddress))", value: $rawStartAddress, in: 1...512, step: max(1, rawWindowSize))
                        Stepper("Footprint: \(rawWindowSize) ch", value: $rawWindowSize, in: 1...128)
                    }
                    .font(Theme.Font.caption)
                    .onChange(of: rawStartAddress) { _, _ in triggerCurrentFlash() }
                }

                Divider().overlay(Theme.stroke)

                Text("Which physical light in your studio is lit up right now?")
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.textPrimary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 8)], spacing: 8) {
                    ForEach(app.show.resolvedFixtures) { rf in
                        Button {
                            recordMatch(rf.id)
                        } label: {
                            HStack(spacing: 8) {
                                Text(rf.fixture.stageLabel)
                                    .font(Theme.Font.mono(11).weight(.bold))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.accentSoft))
                                Text(rf.fixture.name)
                                    .font(Theme.Font.captionStrong)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Theme.panelRaised))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(Theme.stroke))
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        recordMatch(nil)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "eye.slash")
                                .foregroundStyle(Theme.textTertiary)
                            Text("Nothing Lit Up · Skip")
                                .font(Theme.Font.captionStrong)
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Theme.control))
                    }
                    .buttonStyle(.plain)
                }
            }
            .prismPanel()

            // Recorded matches log
            if !recordedProbes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader("Identified Address Assignments (\(recordedProbes.compactMap(\.matchedFixtureID).count))", systemImage: "checkmark.seal")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(recordedProbes.enumerated()), id: \.offset) { _, item in
                                let matchedName = item.matchedFixtureID.flatMap { id in app.show.fixtures.first { $0.id == id }?.name } ?? "No response"
                                HStack {
                                    Text("U\(item.universe) · A\(String(format: "%03d", item.address))")
                                        .font(Theme.Font.mono(11))
                                        .foregroundStyle(Theme.accent)
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.textTertiary)
                                    Text(matchedName)
                                        .font(Theme.Font.captionStrong)
                                        .foregroundStyle(item.matchedFixtureID != nil ? Theme.success : Theme.textTertiary)
                                    Spacer()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 90)
                }
                .prismPanel()
            }

            Spacer(minLength: 0)

            HStack {
                Button("Stop Flashing") {
                    isFlashing = false
                    app.show.clearRawOverrides()
                }
                .buttonStyle(.pill)

                Spacer()

                Button("Cancel") {
                    app.show.clearRawOverrides()
                    dismiss()
                }
                .buttonStyle(.pill)
                .keyboardShortcut(.cancelAction)

                Button {
                    applyRecordedChanges()
                } label: {
                    Label("Apply Corrected Addresses", systemImage: "checkmark")
                }
                .buttonStyle(.pill(prominent: true))
                .disabled(recordedProbes.compactMap(\.matchedFixtureID).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.xl)
        .background(Theme.window)
        .frame(width: 760, height: 560)
        .onAppear {
            triggerCurrentFlash()
        }
        .onDisappear {
            app.show.clearRawOverrides()
        }
    }

    private func triggerCurrentFlash() {
        let probe = currentTestedAddress
        let overrides = AddressScanPlanner.rawOverridesForRange(universe: probe.universe, range: probe.range, value: 255)
        app.show.setRawOverrides(overrides)
        isFlashing = true
    }

    private func recordMatch(_ fixtureID: UUID?) {
        let probe = currentTestedAddress
        recordedProbes.append((universe: probe.universe, address: probe.range.lowerBound, matchedFixtureID: fixtureID))
        switch scanMode {
        case .patchedFixtures:
            if currentIndex + 1 < patchedFixtures.count {
                currentIndex += 1
                triggerCurrentFlash()
            } else {
                isFlashing = false
                app.show.clearRawOverrides()
            }
        case .rawSweep:
            if rawStartAddress + rawWindowSize <= 512 {
                rawStartAddress += rawWindowSize
                triggerCurrentFlash()
            } else {
                isFlashing = false
                app.show.clearRawOverrides()
            }
        }
    }

    private func applyRecordedChanges() {
        app.show.clearRawOverrides()
        let (updated, summary) = AddressScanPlanner.buildCorrectedPatch(probes: recordedProbes, fixtures: app.show.fixtures)
        app.show.applyCorrectedPatch(updated, summary: summary)
        app.ui.toast(
            summary.isEmpty ? "All addresses already matched!" : "Updated \(summary.count) light \(summary.count == 1 ? "address" : "addresses").",
            style: .success,
            systemImage: "checkmark.circle.fill"
        )
        dismiss()
    }
}

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
        draftDefinition.validate()
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
