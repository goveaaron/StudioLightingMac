import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PrismCore

/// Observable state for Patch workspace sub-panels so tour scenes and self-tests can also drive them cleanly.
@MainActor
@Observable
final class PatchWorkspaceState {
    static let shared = PatchWorkspaceState()

    var selectedUniverse: Int = 1
    var showChannelTester: Bool = false
    var show512CellGrid: Bool = true
    var activeTestPattern: ChannelTestPattern = .manual
    var activeWalkPixel: Int = 0
    var sortOrder: SortColumn = .address
    var sortAscending: Bool = true
    var replacingFixtureID: UUID?
    var manualChannelValues: [Int: UInt8] = [:]

    enum SortColumn: String, CaseIterable {
        case address = "Address"
        case label = "Label"
        case name = "Name"
        case type = "Type"
        case role = "Role"
    }
}

struct PatchWorkspace: View {
    @Environment(AppModel.self) private var app
    @State private var state = PatchWorkspaceState.shared
    @State private var draggingFixtureID: UUID?

    private var allResolved: [ResolvedFixture] {
        app.show.resolvedFixtures
    }

    private var availableUniverses: [Int] {
        let used = Set(allResolved.map { $0.fixture.universe }).union([1, state.selectedUniverse])
        return used.sorted()
    }

    private var universeSummary: PatchMath.UniverseSummary {
        PatchMath.universeSummary(universe: state.selectedUniverse, fixtures: allResolved)
    }

    private var allConflicts: [PatchMath.Conflict] {
        PatchMath.conflicts(allResolved)
    }

    private var allOverflowing: [UUID] {
        PatchMath.overflowing(allResolved)
    }

    private var sortedFixtures: [ResolvedFixture] {
        allResolved.sorted { a, b in
            let asc = state.sortAscending
            switch state.sortOrder {
            case .address:
                let ua = a.fixture.universe, ub = b.fixture.universe
                if ua != ub { return asc ? ua < ub : ua > ub }
                let aa = a.fixture.address ?? 9999, ab = b.fixture.address ?? 9999
                if aa != ab { return asc ? aa < ab : aa > ab }
                return a.fixture.stageLabel < b.fixture.stageLabel
            case .label:
                let cmp = a.fixture.stageLabel.localizedStandardCompare(b.fixture.stageLabel) == .orderedAscending
                return asc ? cmp : !cmp
            case .name:
                let cmp = a.fixture.name.localizedStandardCompare(b.fixture.name) == .orderedAscending
                return asc ? cmp : !cmp
            case .type:
                let cmp = a.definition.displayName.localizedStandardCompare(b.definition.displayName) == .orderedAscending
                return asc ? cmp : !cmp
            case .role:
                let cmp = a.fixture.role.displayName.localizedStandardCompare(b.fixture.role.displayName) == .orderedAscending
                return asc ? cmp : !cmp
            }
        }
    }

    private var selectedFixture: ResolvedFixture? {
        if let firstID = app.show.selection.first,
           let match = allResolved.first(where: { $0.id == firstID }) {
            return match
        }
        return allResolved.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topHeaderBar
            Divider().overlay(Theme.stroke)

            if !allConflicts.isEmpty || !allOverflowing.isEmpty {
                conflictBanner
                Divider().overlay(Theme.stroke)
            }

            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    universeMapSection
                    patchTableSection
                }
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if state.showChannelTester {
                    Divider().overlay(Theme.stroke)
                    ChannelTesterPanel(fixture: selectedFixture, state: state)
                        .frame(width: 350)
                }
            }
        }
        .background(Theme.canvas)
    }

    // MARK: - Top Header & Toolbar

    private var topHeaderBar: some View {
        HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Patch & DMX Universe Map")
                        .font(Theme.Font.title)
                        .foregroundStyle(Theme.textPrimary)
                    StatusPill(
                        text: "\(allResolved.count) lights · \(universeSummary.usedChannelCount)/512 ch",
                        color: allConflicts.isEmpty && allOverflowing.isEmpty ? Theme.success : Theme.danger,
                        systemImage: allConflicts.isEmpty && allOverflowing.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                }
                Text("Each light listens to a slice of the 512 DMX channels. Drag blocks on the map or edit rows below.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            Button {
                app.ui.activeSheet = .setupCards
            } label: {
                Label("Setup Cards", systemImage: "list.bullet.rectangle.portrait")
            }
            .buttonStyle(.pill)
            .help("Step-by-step instructions for setting the address and mode on each physical light")

            Button {
                withAnimation(Theme.Motion.snappy) {
                    state.showChannelTester.toggle()
                    if !state.showChannelTester {
                        app.show.clearRawOverrides()
                    }
                }
            } label: {
                Label("Channel Tester", systemImage: "slider.vertical.3")
            }
            .buttonStyle(.pill(tint: Theme.accent, prominent: state.showChannelTester))
            .help("Test individual DMX channels, R/G/B/W, Pixel Walk, and flip pixel orientation")

            Button {
                app.ui.activeSheet = .addressScan
            } label: {
                Label("Find My Lights", systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(.pill)

            Button {
                app.ui.activeSheet = .troubleshooter
            } label: {
                Label("Troubleshoot", systemImage: "stethoscope")
            }
            .buttonStyle(.pill)

            Menu {
                Button {
                    app.ui.activeSheet = .importLightkey
                } label: {
                    Label("Import from Lightkey (.lightkeyproj)…", systemImage: "square.and.arrow.down")
                }
                Button {
                    app.ui.activeSheet = .profileEditor
                } label: {
                    Label("Build Custom Fixture Profile…", systemImage: "slider.horizontal.below.rectangle")
                }
                Divider()
                Button {
                    copyPatchSummary()
                } label: {
                    Label("Copy Patch Summary to Clipboard", systemImage: "doc.on.clipboard")
                }
                Button {
                    exportCSV()
                } label: {
                    Label("Export Patch as CSV…", systemImage: "tablecells")
                }
                Button {
                    importCSV()
                } label: {
                    Label("Import Patch from CSV / TSV…", systemImage: "square.and.arrow.down.on.square")
                }
            } label: {
                Label("Tools", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.control))

            Button {
                app.ui.activeSheet = .addFixture
            } label: {
                Label("Add Light", systemImage: "plus")
            }
            .buttonStyle(.pill(prominent: true))
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .background(Theme.panel)
    }

    // MARK: - Conflict & Overflow Warning Banner

    private var conflictBanner: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.danger)

            VStack(alignment: .leading, spacing: 2) {
                Text(conflictHeadline)
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("Overlapping DMX addresses cause lights to flicker or mimic each other. Prism can pack them onto clean addresses in one click.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            Button {
                let changes = app.show.fixPatchConflicts(style: .packed)
                app.ui.toast(
                    "Resolved address conflicts (\(changes.count) \(changes.count == 1 ? "light" : "lights") moved).",
                    style: .success,
                    systemImage: "checkmark.shield.fill"
                )
            } label: {
                Label("Fix Conflicts Automatically", systemImage: "wand.and.stars")
            }
            .buttonStyle(.pill(tint: Theme.danger, prominent: true))
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.danger.opacity(0.14))
    }

    private var conflictHeadline: String {
        if let first = allConflicts.first {
            let nameA = allResolved.first { $0.id == first.a }?.fixture.name ?? "Light A"
            let nameB = allResolved.first { $0.id == first.b }?.fixture.name ?? "Light B"
            let extra = allConflicts.count > 1 ? " (+\(allConflicts.count - 1) more)" : ""
            return "Address conflict on Universe \(first.universe): \(nameA) and \(nameB) overlap on channels \(first.overlap.lowerBound)–\(first.overlap.upperBound)\(extra)"
        }
        if let firstOverflow = allOverflowing.first {
            let name = allResolved.first { $0.id == firstOverflow }?.fixture.name ?? "A light"
            return "\(name) extends past channel 512 (the maximum in a single DMX universe)."
        }
        return "DMX address issue detected."
    }

    // MARK: - 512-Cell Visual Universe Map (§4.5)

    private var universeMapSection: some View {
        let summary = universeSummary
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                SectionHeader("Universe \(state.selectedUniverse) DMX Map (Channels 1–512)", systemImage: "square.grid.4x3.fill")

                // Universe tabs if multiple universes exist
                HStack(spacing: 4) {
                    ForEach(availableUniverses, id: \.self) { u in
                        Button("U\(u)") {
                            state.selectedUniverse = u
                        }
                        .buttonStyle(.pill(tint: state.selectedUniverse == u ? Theme.accent : Theme.control,
                                           prominent: state.selectedUniverse == u, compact: true))
                    }
                    Button {
                        let nextU = (availableUniverses.max() ?? 1) + 1
                        state.selectedUniverse = min(nextU, 16)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.pill(compact: true))
                    .help("View next DMX universe")
                }

                Spacer()

                Text("\(summary.usedChannelCount) used · \(summary.freeChannelCount) free")
                    .font(Theme.Font.number(11))
                    .foregroundStyle(Theme.textSecondary)

                Toggle("512-Cell Grid", isOn: $state.show512CellGrid)
                    .toggleStyle(.checkbox)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            // 1. Proportional 1–512 Address Strip with draggable fixture blocks & free gap labels
            GeometryReader { geo in
                let w = max(geo.size.width, 1)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Theme.Radius.small)
                        .fill(Theme.canvas)

                    // Free gap markers
                    ForEach(Array(summary.gaps.enumerated()), id: \.offset) { _, gap in
                        if gap.count >= 24 {
                            let startX = CGFloat(gap.lowerBound - 1) / 512.0 * w
                            let width = CGFloat(gap.count) / 512.0 * w
                            Text("\(gap.lowerBound)–\(gap.upperBound) free")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: width, height: 34)
                                .offset(x: startX)
                        }
                    }

                    // Fixture blocks
                    ForEach(summary.blocks) { block in
                        let startX = CGFloat(max(block.startAddress - 1, 0)) / 512.0 * w
                        let clampedEnd = min(block.endAddress, 512)
                        let visibleCount = max(clampedEnd - block.startAddress + 1, 1)
                        let blockW = max(CGFloat(visibleCount) / 512.0 * w, 18)
                        let isSelected = app.show.selection.contains(block.fixtureID)
                        let color = blockColor(for: block)

                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(color.opacity(isSelected ? 0.92 : 0.68))
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(
                                    block.isConflicting || block.isOverflowing ? Theme.danger : (isSelected ? Color.white : Color.white.opacity(0.25)),
                                    lineWidth: block.isConflicting || isSelected ? 2 : 1
                                )
                            HStack(spacing: 4) {
                                if block.isConflicting || block.isOverflowing {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(Color.white)
                                }
                                Text(block.shortName)
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.white)
                                if blockW > 56 {
                                    Text("\(block.startAddress)–\(block.endAddress)")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(Color.white.opacity(0.85))
                                }
                            }
                            .padding(.horizontal, 5)
                            .lineLimit(1)
                        }
                        .frame(width: blockW, height: 30)
                        .offset(x: startX, y: 0)
                        .gesture(
                            DragGesture(minimumDistance: 3)
                                .onChanged { g in
                                    let proposedChannel = clamp(Int(((startX + g.translation.width) / w) * 512.0) + 1, 1, max(1, 512 - block.channelCount + 1))
                                    let snapped = PatchMath.snapAddress(
                                        proposed: proposedChannel,
                                        channelCount: block.channelCount,
                                        universe: state.selectedUniverse,
                                        movingFixtureID: block.fixtureID,
                                        fixtures: allResolved
                                    )
                                    app.show.setAddress(block.fixtureID, universe: state.selectedUniverse, address: snapped)
                                }
                        )
                        .onTapGesture {
                            app.show.selection = [block.fixtureID]
                        }
                        .help("\(block.name) (\(block.shortName)) · \(block.modelName) · U\(block.universe) \(block.startAddress)–\(block.endAddress) (\(block.channelCount) ch). Drag horizontally to re-address.")
                    }
                }
            }
            .frame(height: 34)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(Theme.stroke))

            // 2. 512-Cell Interactive Matrix (64 columns × 8 rows = 512 DMX channels)
            if state.show512CellGrid {
                Universe512CellGrid(
                    summary: summary,
                    selectedFixtureIDs: app.show.selection,
                    onSelectFixture: { id in
                        if let id { app.show.selection = [id] }
                    }
                )
                .frame(height: 84)
            }
        }
        .prismPanel()
    }

    private func blockColor(for block: PatchMath.UniverseBlock) -> Color {
        if block.isConflicting || block.isOverflowing {
            return Theme.danger
        }
        switch block.role {
        case .key, .front: return Color(hex: 0x38BDF8)
        case .fill: return Color(hex: 0x60A5FA)
        case .back, .rim, .hair: return Color(hex: 0x8B5CF6)
        case .background, .wall: return Color(hex: 0x7C8CFF)
        case .practical, .accent: return Color(hex: 0xF59E0B)
        case .floor, .overhead, .side, .cyclorama, .other: return Color(hex: 0x34D399)
        }
    }

    // MARK: - Editable Patch Table (§4.6)

    private var patchTableSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Table Action & Sort Header Bar
            HStack(spacing: Theme.Space.s) {
                SectionHeader("Patched Lights (\(sortedFixtures.count))", systemImage: "list.bullet")

                Spacer()

                if !app.show.selection.isEmpty {
                    let sel = app.show.selection
                    Button {
                        app.show.identify(sel)
                        app.ui.toast("Blinking \(sel.count) selected \(sel.count == 1 ? "light" : "lights")", systemImage: "light.max")
                    } label: {
                        Label("Blink Selected", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.pill(compact: true))

                    Button {
                        _ = app.show.duplicateFixtures(sel)
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    .buttonStyle(.pill(compact: true))

                    Button {
                        app.show.unpatchFixtures(sel)
                    } label: {
                        Label("Unpatch", systemImage: "cable.connector.slash")
                    }
                    .buttonStyle(.pill(compact: true))

                    Button {
                        app.show.removeFixtures(sel)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.pill(tint: Theme.danger, compact: true))
                }
            }
            .padding(.bottom, Theme.Space.s)

            // Column headers
            HStack(spacing: 10) {
                sortHeaderButton(.label, width: 56, alignment: .leading)
                sortHeaderButton(.name, width: 155, alignment: .leading)
                sortHeaderButton(.type, width: 155, alignment: .leading)
                Text("MODE")
                    .font(Theme.Font.sectionLabel)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 170, alignment: .leading)
                sortHeaderButton(.role, width: 105, alignment: .leading)
                sortHeaderButton(.address, width: 165, alignment: .leading)
                Spacer()
                Text("ACTIONS")
                    .font(Theme.Font.sectionLabel)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))

            if sortedFixtures.isEmpty {
                EmptyStateView(
                    systemImage: "cable.connector",
                    title: "No Lights in Your Patch",
                    message: "Add your first light or import an existing Lightkey project to get started.",
                    actionTitle: "Add Light"
                ) {
                    app.ui.activeSheet = .addFixture
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(sortedFixtures) { rf in
                            patchRow(rf)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .prismPanel()
    }

    private func sortHeaderButton(_ col: PatchWorkspaceState.SortColumn, width: CGFloat, alignment: Alignment) -> some View {
        Button {
            if state.sortOrder == col {
                state.sortAscending.toggle()
            } else {
                state.sortOrder = col
                state.sortAscending = true
            }
        } label: {
            HStack(spacing: 3) {
                Text(col.rawValue.uppercased())
                    .font(Theme.Font.sectionLabel)
                    .foregroundStyle(state.sortOrder == col ? Theme.accent : Theme.textTertiary)
                if state.sortOrder == col {
                    Image(systemName: state.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(width: width, alignment: alignment)
        }
        .buttonStyle(.plain)
    }

    private func patchRow(_ rf: ResolvedFixture) -> some View {
        let isSelected = app.show.selection.contains(rf.id)
        let isConflicting = allConflicts.contains { $0.a == rf.id || $0.b == rf.id }
        let isOverflowing = allOverflowing.contains(rf.id)

        return HStack(spacing: 10) {
            // Short stage label editable field
            TextField("ID", text: Binding(
                get: { rf.fixture.shortName },
                set: { newVal in
                    app.show.updateFixture(rf.id, undoName: "Change Label", coalesceKey: "label-\(rf.id)") {
                        $0.shortName = newVal
                    }
                }
            ))
            .textFieldStyle(.plain)
            .font(Theme.Font.mono(12).weight(.bold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(width: 56)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.accentSoft))

            // Fixture name editable field
            TextField("Light Name", text: Binding(
                get: { rf.fixture.name },
                set: { newVal in
                    app.show.updateFixture(rf.id, undoName: "Rename Light", coalesceKey: "name-\(rf.id)") {
                        $0.name = newVal
                    }
                }
            ))
            .textFieldStyle(.plain)
            .font(Theme.Font.headline)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(width: 155)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.control))

            // Fixture type + Replace popover button
            HStack(spacing: 4) {
                Text(rf.definition.displayName)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Button {
                    state.replacingFixtureID = rf.id
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Replace light model while keeping stage position and saved looks")
                .popover(isPresented: Binding(
                    get: { state.replacingFixtureID == rf.id },
                    set: { if !$0 { state.replacingFixtureID = nil } }
                )) {
                    ReplaceFixturePopover(fixture: rf) {
                        state.replacingFixtureID = nil
                    }
                }
            }
            .frame(width: 155, alignment: .leading)

            // Mode picker
            Picker("Mode", selection: Binding(
                get: { rf.mode.name },
                set: { newModeName in
                    _ = app.show.replaceFixtureType(rf.id, newDefinition: rf.definition, newModeName: newModeName)
                }
            )) {
                ForEach(rf.definition.modes) { mode in
                    Text("\(mode.name) (\(mode.channelCount) ch)").tag(mode.name)
                }
            }
            .labelsHidden()
            .frame(width: 170)

            // Role picker
            Picker("Role", selection: Binding(
                get: { rf.fixture.role },
                set: { newRole in
                    app.show.updateFixture(rf.id, undoName: "Change Role") { $0.role = newRole }
                }
            )) {
                ForEach(FixtureRole.allCases, id: \.self) { role in
                    Text(role.displayName).tag(role)
                }
            }
            .labelsHidden()
            .frame(width: 105)

            // Universe + Start Address editor
            HStack(spacing: 6) {
                Menu("U\(rf.fixture.universe)") {
                    ForEach(1...16, id: \.self) { u in
                        Button("Universe \(u)") {
                            app.show.setAddress(rf.id, universe: u, address: rf.fixture.address)
                        }
                    }
                }
                .font(Theme.Font.mono(11))
                .frame(width: 44)

                if let addr = rf.fixture.address {
                    NumericField(
                        value: Binding(
                            get: { Double(addr) },
                            set: { newVal in
                                app.show.setAddress(rf.id, universe: rf.fixture.universe, address: Int(newVal.rounded()))
                            }
                        ),
                        range: 1...512,
                        unit: "",
                        decimals: 0,
                        width: 50
                    )
                    Text("–\(String(format: "%03d", rf.addressRange?.upperBound ?? addr))")
                        .font(Theme.Font.mono(11))
                        .foregroundStyle(isConflicting || isOverflowing ? Theme.danger : Theme.textTertiary)
                } else {
                    Button("Auto-Patch") {
                        let next = PatchMath.nextFreeAddress(
                            channelCount: rf.channelCount,
                            universe: rf.fixture.universe,
                            fixtures: allResolved
                        ) ?? 1
                        app.show.setAddress(rf.id, universe: rf.fixture.universe, address: next)
                    }
                    .buttonStyle(.pill(tint: Theme.warning, compact: true))
                }
            }
            .frame(width: 165, alignment: .leading)

            Spacer()

            // Per-row quick actions
            HStack(spacing: 4) {
                if isConflicting || isOverflowing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                        .help("Overlapping or overflowing DMX address")
                }

                IconButton(systemImage: "bolt.fill", help: "Blink this light for 2 seconds", size: 24) {
                    app.show.identify([rf.id])
                }

                IconButton(
                    systemImage: "slider.vertical.3",
                    help: "Open in Channel Tester",
                    isActive: state.showChannelTester && app.show.selection.contains(rf.id),
                    size: 24
                ) {
                    app.show.selection = [rf.id]
                    state.showChannelTester = true
                }

                IconButton(systemImage: "list.bullet.rectangle.portrait", help: "View Setup Card", size: 24) {
                    app.show.selection = [rf.id]
                    app.ui.activeSheet = .setupCards
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(isSelected ? Theme.accent.opacity(0.16) : Theme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(
                    isConflicting || isOverflowing ? Theme.danger : (isSelected ? Theme.accent : Theme.stroke),
                    lineWidth: isConflicting || isSelected ? 1.5 : 1
                )
        )
        .onTapGesture {
            app.show.selection = [rf.id]
        }
    }

    // MARK: - CSV Import / Export & Clipboard Helpers

    private func copyPatchSummary() {
        let summary = PatchCSV.patchSummaryText(projectName: app.show.project.name, fixtures: allResolved)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        app.ui.toast("Copied patch summary to clipboard", style: .success, systemImage: "doc.on.clipboard")
    }

    private func exportCSV() {
        let csv = PatchCSV.exportCSV(fixtures: allResolved)
        let panel = NSSavePanel()
        panel.title = "Export Patch CSV"
        panel.nameFieldStringValue = "\(app.show.project.name) Patch.csv"
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? csv.write(to: url, atomically: true, encoding: .utf8)
            app.ui.toast("Exported patch to \(url.lastPathComponent)", style: .success, systemImage: "tablecells")
        }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.title = "Import Patch CSV or TSV"
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        if panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) {
            let imported = PatchCSV.importCSV(text, stage: app.show.project.stage, library: app.library.lookup)
            guard !imported.fixtures.isEmpty else {
                app.ui.toast("No valid fixture rows found in CSV.", style: .warning)
                return
            }
            app.library.registerEmbedded(imported.definitions)
            app.show.editProject("Import CSV Patch") { p in
                p.fixtures.append(contentsOf: imported.fixtures)
                for d in imported.definitions where !p.definitions.contains(where: { $0.id == d.id }) {
                    p.definitions.append(d)
                }
            }
            app.ui.toast("Imported \(imported.fixtures.count) lights from \(url.lastPathComponent)", style: .success)
        }
    }
}

// MARK: - 512-Cell Universe Matrix Canvas

private struct Universe512CellGrid: View {
    let summary: PatchMath.UniverseSummary
    let selectedFixtureIDs: Set<UUID>
    let onSelectFixture: (UUID?) -> Void

    var body: some View {
        Canvas { context, size in
            let cols = 64
            let rows = 8
            let spacing: CGFloat = 2
            let cellW = max((size.width - CGFloat(cols - 1) * spacing) / CGFloat(cols), 2)
            let cellH = max((size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows), 2)

            var blockByID: [UUID: PatchMath.UniverseBlock] = [:]
            for b in summary.blocks { blockByID[b.fixtureID] = b }

            for ch in 1...512 {
                let idx = ch - 1
                let col = idx % cols
                let row = idx / cols
                let x = CGFloat(col) * (cellW + spacing)
                let y = CGFloat(row) * (cellH + spacing)
                let rect = CGRect(x: x, y: y, width: cellW, height: cellH)
                let path = Path(roundedRect: rect, cornerRadius: 2)

                let isConflict = summary.conflictChannels.contains(ch)
                let ownerID = summary.channelOwners[idx]

                let fill: Color
                if isConflict {
                    fill = Theme.danger
                } else if let ownerID {
                    if selectedFixtureIDs.contains(ownerID) {
                        fill = Theme.accent
                    } else if let block = blockByID[ownerID] {
                        fill = block.role == .background ? Color(hex: 0x7C8CFF).opacity(0.65) : Color(hex: 0x38BDF8).opacity(0.65)
                    } else {
                        fill = Theme.accent.opacity(0.55)
                    }
                } else {
                    fill = Color.white.opacity(0.06)
                }

                context.fill(path, with: .color(fill))
            }
        }
        .gesture(
            SpatialTapGesture()
                .onEnded { event in
                    let cols = 64
                    let rows = 8
                    let col = clamp(Int((event.location.x / 800.0) * CGFloat(cols)), 0, cols - 1)
                    let row = clamp(Int((event.location.y / 84.0) * CGFloat(rows)), 0, rows - 1)
                    let idx = clamp(row * cols + col, 0, 511)
                    onSelectFixture(summary.channelOwners[idx])
                }
        )
    }
}

// MARK: - Replace Fixture Type Popover

private struct ReplaceFixturePopover: View {
    @Environment(AppModel.self) private var app
    let fixture: ResolvedFixture
    let onDone: () -> Void

    @State private var query: String = ""
    @State private var selectedDefID: String = ""
    @State private var selectedModeName: String = ""

    private var entries: [FixtureLibraryEntry] {
        app.library.search(query, limit: 80)
    }

    private var chosenDef: FixtureDefinition? {
        app.library.definition(selectedDefID) ?? app.show.project.definition(selectedDefID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Replace \(fixture.fixture.name)")
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Preserves stage position, rotation, and saved look colors.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)

            TextField("Search replacement model…", text: $query)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(entries) { entry in
                        let isSel = (selectedDefID == entry.id)
                        Button {
                            selectedDefID = entry.id
                            if let d = app.library.definition(entry.id) {
                                selectedModeName = d.recommendedMode?.name ?? d.modes.first?.name ?? ""
                            }
                        } label: {
                            HStack {
                                Text(entry.displayName)
                                    .font(Theme.Font.captionStrong)
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Text(entry.badge)
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 5).fill(isSel ? Theme.accent.opacity(0.25) : Theme.panel))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 150)

            if let def = chosenDef {
                Picker("Mode:", selection: $selectedModeName) {
                    ForEach(def.modes) { m in
                        Text("\(m.name) (\(m.channelCount) ch)").tag(m.name)
                    }
                }
                .font(Theme.Font.caption)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onDone)
                    .buttonStyle(.pill(compact: true))
                Button("Replace") {
                    if let def = chosenDef {
                        if let msg = app.show.replaceFixtureType(fixture.id, newDefinition: def, newModeName: selectedModeName) {
                            app.ui.toast(msg, style: .success, systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    onDone()
                }
                .buttonStyle(.pill(prominent: true, compact: true))
                .disabled(chosenDef == nil)
            }
        }
        .padding(Theme.Space.m)
        .frame(width: 320)
        .background(Theme.panelRaised)
        .onAppear {
            selectedDefID = fixture.definition.id
            selectedModeName = fixture.mode.name
        }
    }
}

// MARK: - Integrated Channel Tester Panel (§4.7)

struct ChannelTesterPanel: View {
    @Environment(AppModel.self) private var app
    let fixture: ResolvedFixture?
    @Bindable var state: PatchWorkspaceState

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Channel Tester")
                        .font(Theme.Font.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Send raw DMX to verify channels & pixel direction")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button {
                    app.show.clearRawOverrides()
                    state.manualChannelValues.removeAll()
                    state.activeTestPattern = .manual
                } label: {
                    Text("Reset")
                }
                .buttonStyle(.pill(compact: true))
            }

            if let rf = fixture {
                // Selected fixture badge
                HStack(spacing: 8) {
                    Text(rf.fixture.stageLabel)
                        .font(Theme.Font.mono(12).weight(.bold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.accentSoft))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rf.fixture.name)
                            .font(Theme.Font.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(rf.definition.displayName) · U\(rf.fixture.universe) A\(String(format: "%03d", rf.fixture.address ?? 1)) (\(rf.channelCount) ch)")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Theme.panelRaised))

                // Quick Pattern Buttons (Red, Green, Blue, White, Pixel Walk)
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader("Quick Diagnostic Patterns", systemImage: "bolt.horizontal.fill")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(ChannelTestPattern.allCases) { pat in
                            let isActive = (state.activeTestPattern == pat)
                            Button {
                                applyPattern(pat, for: rf)
                            } label: {
                                Text(pat.rawValue)
                                    .font(Theme.Font.captionStrong)
                                    .foregroundStyle(isActive ? Color.white : Theme.textPrimary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(isActive ? Theme.accent : Theme.control)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Multi-pixel orientation & Pixel Walk controls
                if rf.cellCount > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SectionHeader("Pixel Walk & Orientation (\(rf.cellCount) Zones)", systemImage: "arrow.left.and.right.square")
                            Spacer()
                        }

                        HStack(spacing: 6) {
                            ForEach(0..<min(rf.cellCount, 16), id: \.self) { px in
                                let active = (state.activeTestPattern == .pixelWalk && state.activeWalkPixel == px)
                                Button {
                                    state.activeTestPattern = .pixelWalk
                                    state.activeWalkPixel = px
                                    let overrides = AddressScanPlanner.pixelWalkOverrides(for: rf, activePixel: px)
                                    app.show.setRawOverrides(overrides)
                                } label: {
                                    Text("\(px + 1)")
                                        .font(Theme.Font.number(10, weight: .bold))
                                        .foregroundStyle(active ? Color.white : Theme.textSecondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 5)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(active ? Theme.accent : Theme.control)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // "Flip pixel order" toggle right next to Pixel Walk!
                        Toggle(isOn: Binding(
                            get: { rf.fixture.reversePixels },
                            set: { newVal in
                                app.show.updateFixture(rf.id, undoName: "Flip Pixel Order") {
                                    $0.reversePixels = newVal
                                }
                                if state.activeTestPattern == .pixelWalk {
                                    var updatedRF = rf
                                    updatedRF.fixture.reversePixels = newVal
                                    app.show.setRawOverrides(AddressScanPlanner.pixelWalkOverrides(for: updatedRF, activePixel: state.activeWalkPixel))
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Flip pixel order (1 ↔ \(rf.cellCount))")
                                    .font(Theme.Font.captionStrong)
                                    .foregroundStyle(Theme.textPrimary)
                                Text("Fixes tubes mounted upside-down or facing left-to-right backwards")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Theme.panelRaised))
                }

                // Individual Named Channel Sliders
                SectionHeader("Raw DMX Channels (\(rf.channelCount))", systemImage: "slider.horizontal.3")

                ScrollView {
                    LazyVStack(spacing: 6) {
                        let baseAddr = rf.fixture.address ?? 1
                        ForEach(Array(rf.mode.channels.enumerated()), id: \.offset) { offset, ch in
                            let dmxAddr = baseAddr + offset
                            let currentVal = Double(state.manualChannelValues[dmxAddr] ?? ch.defaultValue)
                            VStack(alignment: .leading, spacing: 2) {
                                PrismSlider(
                                    value: Binding(
                                        get: { currentVal / 255.0 },
                                        set: { frac in
                                            let byte = UInt8(clamp(Int((frac * 255.0).rounded()), 0, 255))
                                            state.manualChannelValues[dmxAddr] = byte
                                            state.activeTestPattern = .manual
                                            pushManualOverrides(for: rf)
                                        }
                                    ),
                                    range: 0...1,
                                    label: "Ch \(offset + 1) (A\(String(format: "%03d", dmxAddr))) · \(ch.displayName)",
                                    format: { "\(Int(($0 * 255).rounded()))" },
                                    height: 22
                                )
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else {
                EmptyStateView(
                    systemImage: "slider.vertical.3",
                    title: "Select a Light",
                    message: "Click any light in the patch table or universe map to test its raw DMX channels."
                )
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.panel)
    }

    private func applyPattern(_ pattern: ChannelTestPattern, for rf: ResolvedFixture) {
        state.activeTestPattern = pattern
        guard let baseAddr = rf.fixture.address else { return }
        let u = rf.fixture.universe

        switch pattern {
        case .manual:
            app.show.clearRawOverrides()
        case .pixelWalk:
            let overrides = AddressScanPlanner.pixelWalkOverrides(for: rf, activePixel: state.activeWalkPixel)
            app.show.setRawOverrides(overrides)
        case .red, .green, .blue, .white:
            var overrides: [RawOverride] = []
            for (offset, ch) in rf.mode.channels.enumerated() {
                let addr = baseAddr + offset
                guard (1...512).contains(addr) else { continue }
                let val: UInt8
                switch ch.kind {
                case .intensity: val = 255
                case .crossfade: val = (pattern == .white) ? 0 : 255
                case .red: val = (pattern == .red || pattern == .white) ? 255 : 0
                case .green: val = (pattern == .green || pattern == .white) ? 255 : 0
                case .blue: val = (pattern == .blue || pattern == .white) ? 255 : 0
                case .white, .warmWhite, .coolWhite: val = (pattern == .white) ? 255 : 0
                case .cct: val = 128
                case .tint: val = ch.defaultValue
                default: val = ch.defaultValue
                }
                state.manualChannelValues[addr] = val
                overrides.append(RawOverride(universe: u, address: addr, value: val))
            }
            app.show.setRawOverrides(overrides)
        }
    }

    private func pushManualOverrides(for rf: ResolvedFixture) {
        let u = rf.fixture.universe
        let overrides = state.manualChannelValues.compactMap { addr, val -> RawOverride? in
            guard (1...512).contains(addr) else { return nil }
            return RawOverride(universe: u, address: addr, value: val)
        }
        app.show.setRawOverrides(overrides)
    }
}
