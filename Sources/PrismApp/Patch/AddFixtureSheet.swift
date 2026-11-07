import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PrismCore

// MARK: - Beginner-Proof Add Light Wizard

struct AddFixtureSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    enum BrandFilter: String, CaseIterable, Identifiable {
        case popular = "Popular"
        case amaran = "amaran"
        case aputure = "Aputure"
        case nanlite = "Nanlite"
        case godox = "Godox"
        case astera = "Astera"
        case generic = "Generic"
        case all = "All Brands"

        var id: String { rawValue }
    }

    @State private var query = ""
    @State private var brandFilter: BrandFilter = .popular
    @State private var categoryFilter: FixtureCategory?
    @State private var selectedEntryID: String?
    @State private var selectedModeName: String = ""
    @State private var quantity: Int = 1
    @State private var customBaseName: String = ""
    @State private var selectedRole: FixtureRole = .background
    @State private var addressingStyle: AddressingStyle = .easyNumbers
    @State private var targetUniverse: Int = 1
    @State private var useCustomStartAddress: Bool = false
    @State private var customStartAddress: Double = 1

    private var filteredEntries: [FixtureLibraryEntry] {
        let base: [FixtureLibraryEntry]
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            base = app.library.search(query, category: categoryFilter, limit: 250)
        } else {
            let all = app.library.entries.filter { entry in
                if let categoryFilter, entry.category != categoryFilter { return false }
                switch brandFilter {
                case .popular:
                    let m = entry.manufacturer.lowercased()
                    return m.contains("amaran") || m.contains("aputure") || m.contains("nanlite")
                        || m.contains("godox") || m.contains("astera") || m.contains("quasar")
                        || m.contains("elgato") || m.contains("generic")
                case .amaran:
                    return entry.manufacturer.lowercased().contains("amaran")
                case .aputure:
                    return entry.manufacturer.lowercased().contains("aputure")
                case .nanlite:
                    return entry.manufacturer.lowercased().contains("nanlite") || entry.manufacturer.lowercased().contains("nanlux")
                case .godox:
                    return entry.manufacturer.lowercased().contains("godox")
                case .astera:
                    return entry.manufacturer.lowercased().contains("astera")
                case .generic:
                    return entry.manufacturer.lowercased().contains("generic")
                case .all:
                    return true
                }
            }
            base = sortBrandFirst(all)
        }
        return base
    }

    private func sortBrandFirst(_ list: [FixtureLibraryEntry]) -> [FixtureLibraryEntry] {
        let priority: [String] = ["amaran", "aputure", "nanlite", "godox", "astera", "quasar", "elgato", "generic"]
        return list.sorted { a, b in
            let ma = a.manufacturer.lowercased()
            let mb = b.manufacturer.lowercased()
            let pa = priority.firstIndex(where: { ma.contains($0) }) ?? 99
            let pb = priority.firstIndex(where: { mb.contains($0) }) ?? 99
            if pa != pb { return pa < pb }
            if a.source == "curated" && b.source != "curated" { return true }
            if a.source != "curated" && b.source == "curated" { return false }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    private var selectedDefinition: FixtureDefinition? {
        guard let id = selectedEntryID else { return nil }
        return app.library.definition(id) ?? app.show.project.definition(id)
    }

    private var selectedMode: FixtureMode? {
        guard let def = selectedDefinition else { return nil }
        return def.mode(named: selectedModeName) ?? def.recommendedMode ?? def.modes.first
    }

    private var effectiveStyle: AddressingStyle {
        guard let mode = selectedMode else { return addressingStyle }
        // If a single fixture is > 50 channels and the user is adding 5+, packed fits much better,
        // but we honor the user's explicit choice.
        _ = mode
        return addressingStyle
    }

    private var allocationPreview: PatchMath.AddressAllocationResult {
        guard let mode = selectedMode else {
            return PatchMath.AddressAllocationResult(assignments: [])
        }
        return PatchMath.allocateAddresses(
            channelCount: mode.channelCount,
            count: quantity,
            style: effectiveStyle,
            startingUniverse: targetUniverse,
            startingAt: useCustomStartAddress ? Int(customStartAddress.rounded()) : 1,
            existing: app.show.resolvedFixtures
        )
    }

    private var sampleSetupCard: SetupCard? {
        guard let def = selectedDefinition,
              let mode = selectedMode,
              let firstAssign = allocationPreview.assignments.first else { return nil }
        let base = customBaseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? def.model : customBaseName
        let firstName = quantity > 1 ? "\(base) 1" : base
        let short = PatchMath.suggestShortName(role: selectedRole, category: def.category, existingFixtures: app.show.fixtures)
        let dummy = PatchedFixture(
            name: firstName,
            shortName: short,
            definitionID: def.id,
            modeName: mode.name,
            universe: firstAssign.universe,
            address: firstAssign.address,
            role: selectedRole
        )
        let rf = ResolvedFixture(fixture: dummy, definition: def, mode: mode)
        return SetupCardGenerator.makeCard(for: rf, address: firstAssign.address)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider().overlay(Theme.stroke)

            HStack(alignment: .top, spacing: 0) {
                leftBrowserColumn
                    .frame(width: 360)

                Divider().overlay(Theme.stroke)

                rightConfigurationColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider().overlay(Theme.stroke)
            footerBar
        }
        .background(Theme.window)
        .frame(width: 900, height: 640)
        .onAppear {
            if selectedEntryID == nil {
                // Default to amaran PT4c or first entry so the right pane is immediately rich
                let defaultEntry = app.library.entries.first { $0.id == "amaran.pt4c" }
                    ?? filteredEntries.first
                if let entry = defaultEntry {
                    selectFixture(entry)
                }
            }
        }
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add Light to Your Studio")
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                Text("Pick your light model and how you'll use it. Prism handles DMX channels and addresses automatically.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button {
                app.ui.activeSheet = .profileEditor
            } label: {
                Label("Custom Profile…", systemImage: "slider.horizontal.below.rectangle")
            }
            .buttonStyle(.pill(compact: true))
            .help("Create a custom fixture profile if your light isn't listed")
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.m)
    }

    // MARK: Left Column: Brand-First Browser & Search

    private var leftBrowserColumn: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("1. Choose Your Light", systemImage: "lightbulb.led")

            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search brand or model (e.g. PT4c, 300x, F22c, tube)…", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Theme.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(Theme.stroke))

            // Popular brand chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(BrandFilter.allCases) { brand in
                        let active = (brandFilter == brand && query.isEmpty)
                        Button {
                            query = ""
                            brandFilter = brand
                        } label: {
                            Text(brand.rawValue)
                                .font(Theme.Font.captionStrong)
                                .foregroundStyle(active ? Color.white : Theme.textSecondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(active ? Theme.accent : Theme.control)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Category filter pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    categoryChip(nil, title: "All Types")
                    ForEach([FixtureCategory.tube, .panel, .spot, .par, .bar, .dimmer], id: \.self) { cat in
                        categoryChip(cat, title: cat.displayName)
                    }
                }
            }

            // Fixture list
            ScrollView {
                LazyVStack(spacing: 4) {
                    let items = filteredEntries
                    if items.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "sparkle.magnifyingglass")
                                .font(.system(size: 24))
                                .foregroundStyle(Theme.textTertiary)
                            Text("No matching lights found")
                                .font(Theme.Font.headline)
                                .foregroundStyle(Theme.textSecondary)
                            Text("Try searching for \"Generic RGB\" or create a custom profile.")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.textTertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        ForEach(items) { entry in
                            fixtureEntryRow(entry)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(Theme.Space.m)
    }

    private func categoryChip(_ cat: FixtureCategory?, title: String) -> some View {
        let active = (categoryFilter == cat)
        return Button {
            categoryFilter = cat
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(active ? Theme.accent : Theme.textTertiary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(active ? Theme.accentSoft : Color.white.opacity(0.04))
                )
        }
        .buttonStyle(.plain)
    }

    private func fixtureEntryRow(_ entry: FixtureLibraryEntry) -> some View {
        let isSelected = (selectedEntryID == entry.id)
        return Button {
            selectFixture(entry)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: iconForCategory(entry.category))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : Theme.accent)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isSelected ? Theme.accent : Theme.accentSoft)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(entry.model)
                            .font(Theme.Font.headline)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if entry.source == "curated" {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.success)
                                .help("Verified against official manufacturer DMX chart")
                        }
                    }
                    Text("\(entry.manufacturer) · \(entry.category.displayName)")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(entry.badge)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(isSelected ? Color.white : Theme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(isSelected ? Color.white.opacity(0.18) : Theme.control)
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.22) : Theme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : Theme.stroke, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func selectFixture(_ entry: FixtureLibraryEntry) {
        selectedEntryID = entry.id
        if let def = app.library.definition(entry.id) ?? app.show.project.definition(entry.id) {
            let rec = def.recommendedMode ?? def.modes.first
            selectedModeName = rec?.name ?? ""
            customBaseName = def.model
            switch def.category {
            case .tube, .bar, .strip:
                selectedRole = .background
                // Multi-pixel modes > 50 channels pack better when adding multiple tubes
                if (rec?.channelCount ?? 1) >= 48 {
                    addressingStyle = .packed
                } else {
                    addressingStyle = .easyNumbers
                }
            case .panel, .spot, .fresnel:
                selectedRole = .key
                addressingStyle = .easyNumbers
            case .bulb, .dimmer:
                selectedRole = .practical
                addressingStyle = .easyNumbers
            default:
                selectedRole = .accent
                addressingStyle = .easyNumbers
            }
        }
    }

    // MARK: Right Column: Quantity, Plain-Language Modes, Budget Bar & Setup Card Preview

    private var rightConfigurationColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if let def = selectedDefinition {
                    quantityAndRoleSection(def)
                    modePickerSection(def)
                    addressingAndBudgetSection(def)
                    if let card = sampleSetupCard {
                        setupPreviewSection(card)
                    }
                } else {
                    EmptyStateView(
                        systemImage: "lightbulb.led",
                        title: "Select a Light",
                        message: "Choose a light model on the left to see its modes and automatic DMX setup."
                    )
                }
            }
            .padding(Theme.Space.l)
        }
    }

    private func quantityAndRoleSection(_ def: FixtureDefinition) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("2. Quantity & Studio Role", systemImage: "square.grid.3x3.topleft.filled")

            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("How many \(def.model) lights?")
                        .font(Theme.Font.captionStrong)
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 8) {
                        Stepper(value: $quantity, in: 1...32) {
                            Text("\(quantity) \(quantity == 1 ? "light" : "lights")")
                                .font(Theme.Font.number(14, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        ForEach([1, 2, 4, 8], id: \.self) { preset in
                            Button("\(preset)×") { quantity = preset }
                                .buttonStyle(.pill(tint: quantity == preset ? Theme.accent : Theme.control,
                                                   prominent: quantity == preset, compact: true))
                        }
                    }
                }

                Spacer()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Label on Stage")
                        .font(Theme.Font.captionStrong)
                        .foregroundStyle(Theme.textSecondary)
                    TextField(def.model, text: $customBaseName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                }
            }

            // Role selector chips
            VStack(alignment: .leading, spacing: 6) {
                Text("Where are these lights in your room? (Used for voice/AI commands & stage auto-placement)")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(FixtureRole.allCases, id: \.self) { role in
                            let active = (selectedRole == role)
                            Button {
                                selectedRole = role
                            } label: {
                                Text(role.displayName)
                                    .font(Theme.Font.captionStrong)
                                    .foregroundStyle(active ? Color.white : Theme.textSecondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule().fill(active ? Theme.accent : Theme.control)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .prismPanel()
    }

    private func modePickerSection(_ def: FixtureDefinition) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("3. Choose How You Want to Control It", systemImage: "dial.medium") {
                Text("\(def.modes.count) \(def.modes.count == 1 ? "mode" : "modes")")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            VStack(spacing: 6) {
                ForEach(def.modes) { mode in
                    modeCard(def: def, mode: mode)
                }
            }
        }
        .prismPanel()
    }

    private func modeCard(def: FixtureDefinition, mode: FixtureMode) -> some View {
        let isSelected = (selectedMode?.name == mode.name)
        let friendlyTitle = plainLanguageTitle(for: mode)
        let menuName = SetupCardGenerator.fixtureMenuName(for: def, mode: mode)

        return Button {
            selectedModeName = mode.name
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(friendlyTitle)
                            .font(Theme.Font.headline)
                            .foregroundStyle(Theme.textPrimary)
                        if mode.recommended {
                            Text("Recommended")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.success)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.success.opacity(0.16)))
                        }
                    }
                    HStack(spacing: 8) {
                        Text("On light's screen: \(menuName)")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textSecondary)
                        if mode.cellCount > 1 {
                            Text("· \(mode.cellCount) independent pixel zones")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }

                Spacer()

                Text("\(mode.channelCount) ch")
                    .font(Theme.Font.number(11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.control))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.16) : Theme.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : Theme.stroke, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func plainLanguageTitle(for mode: FixtureMode) -> String {
        if let friendly = mode.friendlyName, !friendly.isEmpty {
            return friendly
        }
        if let summary = mode.summary, !summary.isEmpty {
            return summary
        }
        let caps = mode.capabilities
        if caps.hasRGB && caps.hasCCT {
            if mode.cellCount > 1 {
                return "Full color + white balance · \(mode.cellCount) zones"
            }
            return "Full color + white balance"
        }
        if caps.hasRGB {
            if mode.cellCount > 1 {
                return "Full RGB color · \(mode.cellCount) zones"
            }
            return "Full RGB color"
        }
        if caps.hasHSI {
            if mode.cellCount > 1 {
                return "Hue / Saturation color · \(mode.cellCount) zones"
            }
            return "Hue / Saturation color"
        }
        if caps.hasCCT {
            return "White balance only (warm ↔ cool)"
        }
        if caps.isDimmerOnly {
            return "Brightness only (1-channel dimmer)"
        }
        return mode.name
    }

    private func addressingAndBudgetSection(_ def: FixtureDefinition) -> some View {
        let summary = PatchMath.universeSummary(universe: targetUniverse, fixtures: app.show.resolvedFixtures)
        let alloc = allocationPreview
        let newInTarget = alloc.assignments.filter { $0.universe == targetUniverse }
        let modeFootprint = selectedMode?.channelCount ?? 1
        let addedChannelsInTarget = min(512 - summary.usedChannelCount, newInTarget.count * modeFootprint)
        let totalAfter = min(512, summary.usedChannelCount + addedChannelsInTarget)

        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("4. Automatic DMX Addressing & 512-Channel Budget", systemImage: "number.square") {
                Text("Universe \(targetUniverse) · \(totalAfter) / 512 channels used")
                    .font(Theme.Font.number(11, weight: .semibold))
                    .foregroundStyle(alloc.didOverflowUniverse ? Theme.warning : Theme.textSecondary)
            }

            // Easy numbers vs Packed toggle
            HStack(spacing: 8) {
                ForEach(AddressingStyle.allCases) { style in
                    let isSelected = (addressingStyle == style)
                    Button {
                        addressingStyle = style
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                                Text(style.title)
                                    .font(Theme.Font.captionStrong)
                                    .foregroundStyle(Theme.textPrimary)
                            }
                            Text(style.subtitle)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(2)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.small)
                                .fill(isSelected ? Theme.accent.opacity(0.15) : Theme.panelRaised)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.small)
                                .strokeBorder(isSelected ? Theme.accent : Theme.stroke)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            // Visual 512-channel universe budget bar
            GeometryReader { geo in
                let w = max(geo.size.width, 1)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.control)

                    // Existing fixtures in this universe
                    ForEach(summary.blocks) { block in
                        let startFrac = CGFloat(block.startAddress - 1) / 512.0
                        let widthFrac = max(CGFloat(block.channelCount) / 512.0, 0.006)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.28))
                            .frame(width: widthFrac * w, height: 18)
                            .offset(x: startFrac * w)
                    }

                    // Newly allocated fixtures in this universe
                    ForEach(Array(newInTarget.enumerated()), id: \.offset) { _, assign in
                        let startFrac = CGFloat(assign.address - 1) / 512.0
                        let widthFrac = max(CGFloat(modeFootprint) / 512.0, 0.008)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.accent)
                            .frame(width: min(widthFrac * w, w - startFrac * w), height: 18)
                            .offset(x: startFrac * w)
                    }
                }
            }
            .frame(height: 18)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))

            // Assigned addresses summary pills
            HStack(spacing: 8) {
                Text("Assigned addresses:")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(alloc.assignments.enumerated()), id: \.offset) { idx, assign in
                            Text("#\(idx + 1): U\(assign.universe)·A\(assign.displayAddress)")
                                .font(Theme.Font.mono(11))
                                .foregroundStyle(Theme.textPrimary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Theme.accentSoft))
                        }
                    }
                }
                Spacer()
                Stepper("Universe \(targetUniverse)", value: $targetUniverse, in: 1...16)
                    .font(Theme.Font.caption)
            }

            if let overflowMsg = alloc.overflowMessage {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Theme.warning)
                    Text(overflowMsg)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textPrimary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Theme.warning.opacity(0.14)))
            }
        }
        .prismPanel()
    }

    private func setupPreviewSection(_ card: SetupCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("What You'll Set on the Physical Light", systemImage: "list.bullet.rectangle.portrait")
            Text(card.headline)
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.accent)
            ForEach(Array(card.steps.prefix(3).enumerated()), id: \.offset) { idx, step in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(idx + 1).")
                        .font(Theme.Font.number(11, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(step)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if let tip = card.importantTip {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                    Text(tip)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.warning)
                }
                .padding(.top, 2)
            }
        }
        .prismPanel()
    }

    // MARK: Footer

    private var footerBar: some View {
        HStack(spacing: Theme.Space.m) {
            if let def = selectedDefinition, let mode = selectedMode {
                Text("Adding \(quantity)× \(def.displayName) in \(plainLanguageTitle(for: mode)) (\(mode.channelCount) ch each)")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.pill)
                .keyboardShortcut(.cancelAction)

            Button {
                commitAdd(openSetupCards: true)
            } label: {
                Label("Add & Show Setup Cards", systemImage: "list.bullet.rectangle.portrait")
            }
            .buttonStyle(.pill)
            .disabled(selectedDefinition == nil)

            Button {
                commitAdd(openSetupCards: false)
            } label: {
                Label(quantity > 1 ? "Add \(quantity) Lights" : "Add Light", systemImage: "plus")
            }
            .buttonStyle(.pill(prominent: true))
            .keyboardShortcut(.defaultAction)
            .disabled(selectedDefinition == nil)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.m)
    }

    private func commitAdd(openSetupCards: Bool) {
        guard let def = selectedDefinition, let mode = selectedMode else { return }
        let startAddr = useCustomStartAddress ? Int(customStartAddress.rounded()) : nil
        let (ids, alloc) = app.show.addFixturesWithOptions(
            definitionID: def.id,
            modeName: mode.name,
            count: quantity,
            baseName: customBaseName,
            role: selectedRole,
            universe: targetUniverse,
            startAddress: startAddr,
            style: effectiveStyle
        )
        if let msg = alloc.overflowMessage {
            app.ui.toast(msg, style: .warning, systemImage: "arrow.right.circle")
        } else {
            app.ui.toast(
                "Added \(ids.count) \(ids.count == 1 ? "light" : "lights") — set \(ids.count == 1 ? "it" : "them") using Setup Cards.",
                style: .success,
                systemImage: "checkmark.circle.fill"
            )
        }
        if openSetupCards {
            app.ui.activeSheet = .setupCards
        } else {
            dismiss()
        }
    }

    private func iconForCategory(_ category: FixtureCategory) -> String {
        switch category {
        case .tube, .bar, .strip: return "light.strip.2"
        case .panel, .wash: return "rectangle.portrait.on.rectangle.portrait.angled"
        case .spot, .fresnel, .movingHead: return "flashlight.on.fill"
        case .par: return "circle.hexagongrid.fill"
        case .bulb, .dimmer: return "lightbulb.fill"
        case .effect, .other: return "sparkles"
        }
    }
}

// MARK: - Import From Lightkey Sheet

struct ImportLightkeySheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var importResult: LightkeyImportResult?
    @State private var sourceLabel: String = ""
    @State private var errorMessage: String?
    @State private var isDropTargeted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import from Lightkey")
                        .font(Theme.Font.title)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Bring your existing .lightkeyproj patch, stage layout, folders, and preset looks straight into Prism.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Load Sample Show (London Studio)") {
                    loadSampleLondonStudio()
                }
                .buttonStyle(.pill(compact: true))
            }

            if let errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(Theme.danger)
                    Text(errorMessage)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button("Dismiss") { self.errorMessage = nil }
                        .buttonStyle(.plain)
                        .font(Theme.Font.captionStrong)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Theme.danger.opacity(0.15)))
            }

            if let result = importResult {
                previewContent(result)
            } else {
                dropZoneView
            }

            HStack {
                if importResult != nil {
                    Button("Choose Another File…") {
                        chooseFile()
                    }
                    .buttonStyle(.pill)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.pill)
                    .keyboardShortcut(.cancelAction)

                if let result = importResult {
                    Button {
                        app.show.importLightkeyResult(result)
                        app.ui.toast(result.summaryText, style: .success, systemImage: "square.and.arrow.down.on.square.fill")
                        dismiss()
                    } label: {
                        Label("Import \(result.importedFixtureCount) Lights & \(result.importedLookCount) Looks", systemImage: "checkmark")
                    }
                    .buttonStyle(.pill(prominent: true))
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Theme.Space.xl)
        .background(Theme.window)
        .frame(width: 780, height: 580)
        .onAppear {
            if app.ui.isRunningTour && importResult == nil {
                loadSampleLondonStudio()
            }
        }
    }

    private var dropZoneView: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.spectrum)
            Text("Drop a .lightkeyproj file here")
                .font(Theme.Font.title)
                .foregroundStyle(Theme.textPrimary)
            Text("Prism reads your DMX universes, fixture addresses, stage coordinates, and 16-bit preset colors without needing Lightkey installed.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            HStack(spacing: Theme.Space.m) {
                Button {
                    chooseFile()
                } label: {
                    Label("Choose .lightkeyproj File…", systemImage: "folder")
                }
                .buttonStyle(.pill(prominent: true))

                Button {
                    loadSampleLondonStudio()
                } label: {
                    Label("Preview London Studio Rig", systemImage: "sparkles")
                }
                .buttonStyle(.pill)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(isDropTargeted ? Theme.accentSoft : Theme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(isDropTargeted ? Theme.accent : Theme.strokeStrong, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let first = providers.first else { return false }
            _ = first.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    DispatchQueue.main.async {
                        importFromURL(url)
                    }
                }
            }
            return true
        }
    }

    private func previewContent(_ result: LightkeyImportResult) -> some View {
        let resolved = result.project.resolvedFixtures(library: app.library.lookup)

        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            // Summary stat badges
            HStack(spacing: Theme.Space.m) {
                summaryStatCard(title: "Project", value: result.project.name, icon: "doc.badge.gearshape")
                summaryStatCard(title: "Patched Lights", value: "\(result.importedFixtureCount)", icon: "lightbulb.led.fill")
                summaryStatCard(title: "Saved Looks", value: "\(result.importedLookCount)", icon: "sparkles.rectangle.stack")
                summaryStatCard(title: "Preset Folders", value: "\(result.importedFolderCount)", icon: "folder.fill")
            }

            HStack(alignment: .top, spacing: Theme.Space.m) {
                // Mini stage preview
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader("Stage Layout Preview", systemImage: "square.grid.3x3.topleft.filled")
                    GeometryReader { geo in
                        let w = max(geo.size.width, 1)
                        let h = max(geo.size.height, 1)
                        let stageW = max(result.project.stage.width, 1)
                        let stageH = max(result.project.stage.height, 1)
                        ZStack {
                            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                                .fill(Theme.canvas)
                            ForEach(resolved) { rf in
                                let nx = clamp(rf.fixture.transform.x / stageW, 0.08, 0.92)
                                let ny = clamp(rf.fixture.transform.y / stageH, 0.08, 0.92)
                                VStack(spacing: 2) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Theme.accent)
                                        .frame(width: rf.definition.category == .tube ? 28 : 14, height: rf.definition.category == .tube ? 7 : 14)
                                        .rotationEffect(.degrees(rf.fixture.transform.rotation))
                                    Text(rf.fixture.stageLabel)
                                        .font(.system(size: 9, weight: .bold, design: .rounded))
                                        .foregroundStyle(Theme.textPrimary)
                                }
                                .position(x: nx * w, y: ny * h)
                            }
                        }
                    }
                    .frame(height: 190)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.stroke))
                }
                .frame(width: 260)
                .prismPanel()

                // Fixtures & Looks lists
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionHeader("Patched Lights (\(resolved.count))", systemImage: "cable.connector")
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(resolved) { rf in
                                HStack(spacing: 8) {
                                    Text(rf.fixture.stageLabel)
                                        .font(Theme.Font.mono(11))
                                        .foregroundStyle(Theme.accent)
                                        .frame(width: 34, alignment: .leading)
                                    Text(rf.fixture.name)
                                        .font(Theme.Font.captionStrong)
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    Text("\(rf.definition.displayName) · \(rf.mode.name)")
                                        .font(Theme.Font.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                    Text(rf.addressRange.map { "U\(rf.fixture.universe) · \($0.lowerBound)–\($0.upperBound)" } ?? "Unpatched")
                                        .font(Theme.Font.number(11))
                                        .foregroundStyle(Theme.textTertiary)
                                        .frame(width: 86, alignment: .trailing)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panelRaised))
                            }
                        }
                    }
                    .frame(maxHeight: 125)

                    SectionHeader("Saved Looks (\(result.project.looks.count))", systemImage: "paintpalette")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(result.project.looks) { look in
                                let colors = look.states.storage.values.prefix(6).map { Color($0.color.displayRGB) }
                                VStack(alignment: .leading, spacing: 4) {
                                    SwatchStrip(colors: colors.isEmpty ? [.black] : colors, height: 10)
                                        .frame(width: 110)
                                    Text(look.name)
                                        .font(Theme.Font.captionStrong)
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                }
                                .padding(7)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panelRaised))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .prismPanel()
            }

            if !result.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(result.warnings, id: \.self) { warning in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.warning)
                            Text(warning)
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Theme.warning.opacity(0.10)))
            }
        }
    }

    private func summaryStatCard(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased())
                    .font(Theme.Font.sectionLabel)
                    .foregroundStyle(Theme.textTertiary)
                Text(value)
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.stroke))
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Lightkey Project"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let utType = UTType(filenameExtension: "lightkeyproj") {
            panel.allowedContentTypes = [utType, .propertyList, .package]
        }
        if panel.runModal() == .OK, let url = panel.url {
            importFromURL(url)
        }
    }

    private func importFromURL(_ url: URL) {
        do {
            let res = try LightkeyImporter.importProject(at: url, library: app.library.lookup)
            self.importResult = res
            self.sourceLabel = url.lastPathComponent
            self.errorMessage = nil
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    private func loadSampleLondonStudio() {
        do {
            let data = try LightkeyArchiveBuilder.londonStudioArchiveData()
            let res = try LightkeyImporter.importProject(from: data, projectName: "London Studio (Lightkey)", library: app.library.lookup)
            self.importResult = res
            self.sourceLabel = "London Studio.lightkeyproj"
            self.errorMessage = nil
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
}
