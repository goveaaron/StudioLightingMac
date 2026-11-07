import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PrismCore

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

