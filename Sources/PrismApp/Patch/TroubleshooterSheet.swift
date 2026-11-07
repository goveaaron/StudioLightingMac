import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PrismCore

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

