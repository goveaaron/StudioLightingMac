import SwiftUI
import PrismCore

/// Help ▸ Hardware Test…: a guided check of the DMX box and every light.
///
/// 1. Is the DMX box plugged in? (live detection) · 2. Test each light (30 % white, one at a
/// time) · 3. Channel monitor (all 512 channels, live) · 4. Blink a light · 5. Tips.
///
/// OWNER: Hardware workstream.
struct HardwareTestSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let model = app.outputs.hardwareTest
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.stroke)
            HStack(spacing: 0) {
                HardwareTestStepList(model: model)
                    .frame(width: 214)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Theme.panel)
                Divider().overlay(Theme.stroke)
                stepContent(model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider().overlay(Theme.stroke)
            footer(model)
        }
        .frame(width: 960, height: 680)
        .background(Theme.window)
        .onAppear { model.open() }
        .onDisappear {
            model.end()
            app.outputs.sheetClosed()
        }
        .task {
            // Keeps the test signal in place if an undo or a patch edit replaced it.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                model.maintain()
            }
        }
    }

    private var header: some View {
        let summary = app.outputs.summary
        return HStack(spacing: Theme.Space.m) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(Theme.spectrum)
                Image(systemName: "stethoscope")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hardware Test")
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                Text("Check your DMX box and every light, one step at a time.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            StatusPill(text: summary.title, color: summary.level.tint, pulsing: summary.level == .connected)
                .help(summary.detail)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.control))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.m)
    }

    @ViewBuilder
    private func stepContent(_ model: HardwareTestModel) -> some View {
        switch model.step {
        case .connection:
            ScrollView { ConnectionStep().padding(Theme.Space.xl) }
        case .testLights:
            ScrollView { TestLightsStep(model: model).padding(Theme.Space.xl) }
        case .channels:
            ChannelMonitorView(model: model)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.vertical, Theme.Space.l)
        case .blink:
            ScrollView { BlinkStep(model: model).padding(Theme.Space.xl) }
        case .tips:
            ScrollView { TipsStep().padding(Theme.Space.xl) }
        }
    }

    private func footer(_ model: HardwareTestModel) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text("Step \(model.step.number) of \(HardwareTestModel.Step.allCases.count)")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            if model.step != .connection {
                Button {
                    model.back()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                        Text("Back")
                    }
                }
                .buttonStyle(.pill)
            }
            if let next = HardwareTestModel.Step(rawValue: model.step.rawValue + 1) {
                Button {
                    model.next()
                } label: {
                    HStack(spacing: 4) {
                        Text("Next: \(next.title)")
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                    }
                }
                .buttonStyle(.pill(prominent: true))
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { dismiss() }
                    .buttonStyle(.pill(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.m)
    }
}

// MARK: - Step list

private struct HardwareTestStepList: View {
    let model: HardwareTestModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(HardwareTestModel.Step.allCases) { step in
                let active = model.step == step
                let done = step.rawValue < model.step.rawValue
                Button {
                    model.go(to: step)
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(active ? Theme.accent : (done ? Theme.success.opacity(0.18) : Theme.control))
                            if done {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.success)
                            } else {
                                Text("\(step.number)")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(active ? Color.white : Theme.textSecondary)
                            }
                        }
                        .frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.title)
                                .font(Theme.Font.headline)
                                .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                            Text(step.subtitle)
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                            .fill(active ? Theme.accentSoft : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.Space.m)
    }
}

// MARK: - Shared bits

/// "100–148" (or "100" for one channel).
private func addressText(_ rf: ResolvedFixture) -> String {
    guard let range = rf.addressRange else { return "Not patched" }
    return range.count > 1 ? "\(range.lowerBound)–\(range.upperBound)" : "\(range.lowerBound)"
}

/// The mode as the light's own menu shows it.
private func menuModeName(_ rf: ResolvedFixture) -> String {
    rf.mode.fixtureMenuName ?? rf.mode.name
}

private func cardBackground(_ tint: Color? = nil) -> some View {
    RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
        .fill(Theme.panelRaised)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(tint?.opacity(0.35) ?? Theme.stroke)
        )
}

// MARK: - Step 1: DMX box

private struct ConnectionStep: View {
    @Environment(AppModel.self) private var app
    @State private var looking = false

    private enum Situation {
        case connected, busy, unplugged, networkBlocked(String), connecting, unrecognized(String), notFound
    }

    var body: some View {
        let outputs = app.outputs
        let usb = outputs.rows.filter(\.isUSB)
        let network = outputs.rows.filter { !$0.isUSB && $0.isEnabled }
        let situation = classify(summary: outputs.summary, usb: usb, network: network)
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            StepIntro(title: "Is the DMX box plugged in?",
                      text: "Prism finds your DMX box by itself, usually within a second of plugging it in. No drivers needed.")
            hero(situation, summary: outputs.summary)
            if !usb.isEmpty || !network.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionHeader(usb.count + network.count == 1 ? "Your output" : "Your outputs")
                    ForEach(usb + network) { row in
                        OutputDeviceCard(row: row, networkUniverses: outputs.usedUniverses, showsMessage: false)
                    }
                }
            }
            checklist(situation)
            if outputs.hardwareDisabled && !app.launch.isAutomated {
                Label("Prism was started without hardware (--no-hardware), so it's simulating your lights.",
                      systemImage: "info.circle")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func classify(summary: OutputSummary, usb: [OutputDeviceRow], network: [OutputDeviceRow]) -> Situation {
        let enabled = usb.filter(\.isEnabled)
        if summary.level == .connected { return .connected }
        if enabled.contains(where: { $0.snapshot.state == .busy }) { return .busy }
        if enabled.contains(where: { $0.snapshot.isUnplugged }) { return .unplugged }
        for row in network {
            if case .failed(let message) = row.snapshot.state { return .networkBlocked(message) }
        }
        if enabled.contains(where: { $0.snapshot.state == .connecting }) { return .connecting }
        if let odd = enabled.first(where: { $0.snapshot.state == .unsupported }) { return .unrecognized(odd.snapshot.name) }
        return .notFound
    }

    @ViewBuilder
    private func hero(_ situation: Situation, summary: OutputSummary) -> some View {
        switch situation {
        case .connected:
            heroCard(icon: "checkmark", tint: Theme.success, headline: "Your DMX box is connected",
                     message: "Prism is sending your lights right now. Next, check that each light answers.",
                     detail: summary.detail)
        case .busy:
            heroCard(icon: "lock.fill", tint: Theme.danger, headline: "Another app is using your DMX box",
                     message: "Quit Lightkey, QLC+ or any other lighting app. Prism connects by itself the moment the box is free.")
        case .unplugged:
            heroCard(icon: "cable.connector.horizontal", tint: Theme.warning, headline: "Your DMX box was unplugged",
                     message: "Plug it back in and Prism reconnects by itself. Your show keeps running meanwhile.")
        case .networkBlocked(let message):
            heroCard(icon: "network", tint: Theme.warning, headline: "Network output can't get through", message: message)
        case .connecting:
            heroCard(icon: "arrow.triangle.2.circlepath", tint: Theme.accent, headline: "Connecting to your DMX box…",
                     message: "This takes about a second.")
        case .unrecognized(let name):
            heroCard(icon: "questionmark", tint: Theme.warning, headline: "Prism found a USB device it doesn't recognize",
                     message: "\(name) didn't answer like a DMX USB Pro. If it's an Open DMX cable, turn on “Open DMX” for it in Settings › Outputs.")
        case .notFound:
            heroCard(icon: "cable.connector.horizontal", tint: Theme.accent, headline: "No DMX box found yet",
                     message: "Plug your ENTTEC DMX USB Pro into this Mac with its USB cable. Until then, Prism simulates your lights.")
        }
    }

    private func heroCard(icon: String, tint: Color, headline: String, message: String, detail: String? = nil) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            ZStack {
                Circle().fill(tint.opacity(0.16))
                Circle().strokeBorder(tint.opacity(0.45), lineWidth: 1)
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 54, height: 54)
            .shadow(color: tint.opacity(0.35), radius: 12)
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.m)
            Button {
                looking = true
                app.outputs.rescan()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    looking = false
                }
            } label: {
                HStack(spacing: 6) {
                    if looking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Look again")
                }
            }
            .buttonStyle(.pill)
            .disabled(looking)
        }
        .padding(Theme.Space.l)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.12), Theme.panelRaised], startPoint: .leading, endPoint: .trailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(tint.opacity(0.28))
        )
    }

    @ViewBuilder
    private func checklist(_ situation: Situation) -> some View {
        switch situation {
        case .busy:
            guidance("Free up the DMX box", [
                "Quit Lightkey, QLC+, Blackout or any other app that talks to DMX boxes.",
                "Still busy? Unplug the box, wait two seconds and plug it back in.",
            ])
        case .unplugged:
            guidance("If it doesn't come back", [
                "Check that the USB cable is pushed all the way in at both ends.",
                "Try a USB port on the Mac itself, or a powered USB hub.",
                "Try another USB cable — some cables only charge and don't carry data.",
            ])
        case .notFound, .unrecognized:
            guidance("If it isn't found", [
                "Plug the box straight into the Mac, or into a powered USB hub.",
                "Try another USB cable — some cables only charge and don't carry data.",
                "Quit other lighting apps; only one app can use a DMX box at a time.",
                "Using Art-Net or sACN instead? Turn it on in Settings › Outputs.",
            ])
        case .connected, .connecting, .networkBlocked:
            EmptyView()
        }
    }

    private func guidance(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title)
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                GuidanceRow(number: index + 1, text: line)
            }
        }
    }
}

// MARK: - Step 2: Test each light

private struct TestLightsStep: View {
    @Environment(AppModel.self) private var app
    let model: HardwareTestModel

    var body: some View {
        let fixtures = model.fixtures
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            StepIntro(title: "Does each light answer?",
                      text: "Prism turns one light on at 30% white and keeps the others dark. Look at your studio and answer.")
            if fixtures.isEmpty {
                EmptyStateView(systemImage: "lightbulb.slash", title: "No lights patched yet",
                               message: "Add your lights in Patch first, then come back to test them.",
                               actionTitle: "Open Patch") {
                    app.ui.activeSheet = nil
                    app.ui.selectedTab = .patch
                }
                .frame(height: 300)
            } else if let rf = model.currentFixture {
                if app.outputs.summary.level != .connected {
                    notConnectedBanner
                }
                lightCard(rf, index: min(max(model.testIndex, 0), fixtures.count - 1), count: fixtures.count)
                progressStrip(fixtures)
                if model.answers[rf.id] == false {
                    troubleshooting(rf)
                }
                if model.allAnswered {
                    resultCard(fixtures)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var notConnectedBanner: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            Text("Your DMX box isn't connected, so the lights can't answer yet. The stage preview still shows the test.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.s)
            Button("Check the box") { model.go(to: .connection) }
                .buttonStyle(.pill(compact: true))
        }
        .padding(Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Theme.warning.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).strokeBorder(Theme.warning.opacity(0.3)))
    }

    private func lightCard(_ rf: ResolvedFixture, index: Int, count: Int) -> some View {
        let answer = model.answers[rf.id]
        return VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                // A softly glowing badge: "this one should be on".
                Text(rf.fixture.stageLabel)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.78))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 46, minHeight: 46)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                            .fill(Color(hex: 0xFFF6E8))
                            .shadow(color: Color(hex: 0xFFF1D6).opacity(0.55), radius: 14)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(rf.fixture.name)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text("\(rf.definition.model) · \(rf.mode.name)")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Space.m)
                Text("Light \(index + 1) of \(count)")
                    .font(Theme.Font.captionStrong)
                    .foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: Theme.Space.s) {
                fact("Universe", "\(rf.fixture.universe)")
                fact("Address", addressText(rf))
                fact("On the light's menu", "Address \(rf.fixture.address ?? 0) · \(menuModeName(rf))", wide: true)
            }
            HStack(spacing: Theme.Space.s) {
                Text("Did it light up?")
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    model.answer(true)
                } label: {
                    Label("Yes, it's on", systemImage: "checkmark")
                }
                .buttonStyle(.pill(tint: Theme.success, prominent: answer == true))
                Button {
                    model.answer(false)
                } label: {
                    Label("No, it's dark", systemImage: "xmark")
                }
                .buttonStyle(.pill(tint: Theme.danger, prominent: answer == false))
            }
        }
        .padding(Theme.Space.l)
        .background(cardBackground())
    }

    private func fact(_ label: String, _ value: String, wide: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(Theme.Font.sectionLabel)
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(Theme.Font.number(14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: wide ? .infinity : nil, alignment: .leading)
        .frame(minWidth: 96, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Theme.control.opacity(0.6)))
    }

    private func progressStrip(_ fixtures: [ResolvedFixture]) -> some View {
        HStack(spacing: Theme.Space.s) {
            Button {
                model.previousLight()
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.pill(compact: true))
            .keyboardShortcut(.leftArrow, modifiers: [])
            .help("Previous light (←)")

            HStack(spacing: 4) {
                ForEach(Array(fixtures.enumerated()), id: \.element.id) { index, rf in
                    let isCurrent = index == model.testIndex
                    let answer = model.answers[rf.id]
                    Button {
                        model.showLight(at: index)
                    } label: {
                        Capsule()
                            .fill(answer == true ? Theme.success : (answer == false ? Theme.danger : Theme.control))
                            .overlay(Capsule().strokeBorder(isCurrent ? Color.white : Color.clear, lineWidth: 1.5))
                            .frame(height: isCurrent ? 8 : 6)
                            .frame(maxWidth: .infinity)
                            .frame(height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(rf.fixture.name)
                }
            }

            Button {
                model.nextLight()
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.pill(compact: true))
            .keyboardShortcut(.rightArrow, modifiers: [])
            .help("Next light (→)")
        }
    }

    private func troubleshooting(_ rf: ResolvedFixture) -> some View {
        var lines = [
            "On the light's own menu, set the DMX address to \(rf.fixture.address ?? 0) and the mode to “\(menuModeName(rf))”.",
            "Check the cable: it runs from the DMX box (or the previous light's DMX OUT) into this light's DMX IN.",
        ]
        if rf.definition.category == .tube {
            lines.append("amaran PT tubes only listen while their DMX screen is showing — hold OK for 2 seconds to lock it.")
        }
        lines.append("If the lights after this one are dark too, the cable going into this light is the likely culprit.")
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            Label("Let's get \(rf.fixture.name) working", systemImage: "wrench.and.screwdriver")
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.warning)
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                GuidanceRow(number: index + 1, text: line)
            }
            HStack(spacing: Theme.Space.s) {
                Text("Fixed it? Press “Yes, it's on”.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("A light isn't responding…") { app.ui.activeSheet = .troubleshooter }
                    .buttonStyle(.pill(compact: true))
            }
            .padding(.top, 2)
        }
        .padding(Theme.Space.l)
        .background(cardBackground(Theme.warning))
    }

    private func resultCard(_ fixtures: [ResolvedFixture]) -> some View {
        let dark = model.darkFixtures
        return HStack(spacing: Theme.Space.m) {
            Image(systemName: dark.isEmpty ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(dark.isEmpty ? Theme.success : Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(dark.isEmpty ? "Every light answered — your rig is ready."
                     : "\(dark.count) of \(fixtures.count) lights stayed dark")
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.textPrimary)
                if !dark.isEmpty {
                    Text(dark.map(\.fixture.stageLabel).joined(separator: ", "))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            if !dark.isEmpty {
                Button("Test the dark ones again") { model.retestDarkLights() }
                    .buttonStyle(.pill(compact: true))
            }
        }
        .padding(Theme.Space.l)
        .background(cardBackground(dark.isEmpty ? Theme.success : Theme.warning))
    }
}

// MARK: - Step 4: Blink

private struct BlinkStep: View {
    @Environment(AppModel.self) private var app
    let model: HardwareTestModel

    var body: some View {
        let fixtures = model.fixtures
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            StepIntro(title: "Which light is which?",
                      text: "Click a light to make it blink for two seconds — it shows even during a blackout.")
            if fixtures.isEmpty {
                EmptyStateView(systemImage: "lightbulb.slash", title: "No lights patched yet",
                               message: "Add your lights in Patch first.")
                    .frame(height: 260)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: Theme.Space.s)],
                          alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(fixtures) { rf in tile(rf) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tile(_ rf: ResolvedFixture) -> some View {
        let isBlinking = model.blinking == rf.id
        return Button {
            model.blink(rf.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(rf.fixture.stageLabel)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(isBlinking ? Color.black.opacity(0.8) : Theme.textPrimary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(isBlinking ? Color(hex: 0xFFF6E8) : Theme.control))
                    Spacer()
                    Image(systemName: "sparkles")
                        .foregroundStyle(isBlinking ? Theme.warning : Theme.textTertiary)
                }
                Text(rf.fixture.name)
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(isBlinking ? "Blinking…" : "Universe \(rf.fixture.universe) · \(addressText(rf))")
                    .font(Theme.Font.caption)
                    .foregroundStyle(isBlinking ? Theme.warning : Theme.textTertiary)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .fill(isBlinking ? Theme.accentSoft : Theme.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .strokeBorder(isBlinking ? Theme.accent : Theme.stroke)
            )
            .shadow(color: isBlinking ? Theme.accent.opacity(0.45) : Color.clear, radius: 10)
            .contentShape(Rectangle())
            .animation(Theme.Motion.quick, value: isBlinking)
        }
        .buttonStyle(.plain)
        .help("Blink \(rf.fixture.name)")
    }
}

// MARK: - Step 5: Tips

private struct TipsStep: View {
    @Environment(AppModel.self) private var app

    private struct Tip {
        let title: String
        let systemImage: String
        let text: String
    }

    private static let tips: [Tip] = [
        Tip(title: "Address & mode", systemImage: "number.square",
            text: "Each light's DMX address and mode, set on the light's own menu, must match Patch. Two lights on one address copy each other."),
        Tip(title: "Cable direction", systemImage: "arrow.right.circle",
            text: "DMX flows one way: from the box's DMX OUT into the first light's DMX IN, then from its DMX OUT on to the next light's IN."),
        Tip(title: "Terminator", systemImage: "stop.circle",
            text: "Put a DMX terminator (a 120 Ω plug) in the last light's DMX OUT. It stops flicker and lights that ignore commands."),
        Tip(title: "amaran PT tubes", systemImage: "lock.display",
            text: "They listen to DMX only while their DMX screen is showing. Hold OK for 2 seconds to lock the screen."),
        Tip(title: "One app at a time", systemImage: "rectangle.on.rectangle",
            text: "Only one app can use a DMX box. Quit Lightkey, QLC+ or Blackout and Prism connects by itself."),
        Tip(title: "Steady USB power", systemImage: "powerplug",
            text: "If the box keeps disconnecting, plug it straight into the Mac or into a powered USB hub."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            StepIntro(title: "If a light stays dark",
                      text: "Almost every DMX problem is one of these. Work through them in order.")
            Grid(horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.m) {
                ForEach(0..<((Self.tips.count + 1) / 2), id: \.self) { row in
                    GridRow {
                        card(Self.tips[row * 2])
                        if row * 2 + 1 < Self.tips.count {
                            card(Self.tips[row * 2 + 1])
                        } else {
                            Color.clear
                        }
                    }
                }
            }
            HStack(spacing: Theme.Space.s) {
                Button("Settings › Outputs…") { app.ui.activeSheet = .outputSettings }
                    .buttonStyle(.pill)
                Button("A light isn't responding…") { app.ui.activeSheet = .troubleshooter }
                    .buttonStyle(.pill)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card(_ tip: Tip) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: tip.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.accentSoft))
            VStack(alignment: .leading, spacing: 4) {
                Text(tip.title)
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(tip.text)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cardBackground())
    }
}
