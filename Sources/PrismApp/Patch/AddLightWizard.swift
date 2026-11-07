import SwiftUI
import AppKit
import PrismCore

// MARK: - Wizard state

/// State for the "Add a light" wizard: pick the model → Prism plans mode + address → button-by-button
/// setup on the light → "Blink it" to confirm. A shared instance so the screenshot tour and self-tests
/// can drive every step; it resets whenever the sheet opens normally.
@MainActor
@Observable
final class AddLightWizardModel {
    static let shared = AddLightWizardModel()

    enum Step: Int, CaseIterable, Identifiable {
        case pick, configure, setup, done
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .pick: return "Pick it"
            case .configure: return "Where it goes"
            case .setup: return "Set it up"
            case .done: return "Done"
            }
        }
    }

    enum BrandFilter: String, CaseIterable, Identifiable {
        case popular = "Popular"
        case amaran = "amaran"
        case aputure = "Aputure"
        case nanlite = "Nanlite"
        case godox = "Godox"
        case astera = "Astera"
        case generic = "Generic"
        case all = "All brands"

        var id: String { rawValue }

        func matches(_ manufacturer: String) -> Bool {
            let m = manufacturer.lowercased()
            switch self {
            case .popular:
                return ["amaran", "aputure", "nanlite", "nanlux", "godox", "astera", "quasar", "elgato", "generic"]
                    .contains { m.contains($0) }
            case .amaran: return m.contains("amaran")
            case .aputure: return m.contains("aputure")
            case .nanlite: return m.contains("nanlite") || m.contains("nanlux")
            case .godox: return m.contains("godox")
            case .astera: return m.contains("astera")
            case .generic: return m.contains("generic")
            case .all: return true
            }
        }
    }

    /// A light this wizard added (kept so the summary still renders if the light is removed later).
    struct AddedLight: Identifiable, Hashable {
        let id: UUID
        let name: String
        let label: String
        let addressText: String
    }

    var step: Step = .pick
    var query = ""
    var brand: BrandFilter = .popular
    var category: FixtureCategory?
    var selectedEntryID: String?
    var quantity = 1
    var role: FixtureRole = .background
    var baseName = ""
    /// The user's explicit mode (nil = Prism picks).
    var chosenModeName: String?
    /// The user's explicit addressing style (nil = Prism picks).
    var chosenStyle: AddressingStyle?
    var showModeChoices = false
    var showAddressChoices = false
    var added: [AddedLight] = []
    var setupIndex = 0
    /// The light we just blinked and are asking "did it blink?" about.
    var askingAbout: UUID?
    var confirmed: Set<UUID> = []
    var notResponding: Set<UUID> = []
    /// Set by the screenshot tour so the next appearance keeps the prepared state.
    var keepStateOnNextAppear = false

    func reset() {
        step = .pick
        query = ""
        brand = .popular
        category = nil
        selectedEntryID = nil
        quantity = 1
        role = .background
        baseName = ""
        chosenModeName = nil
        chosenStyle = nil
        showModeChoices = false
        showAddressChoices = false
        added = []
        setupIndex = 0
        askingAbout = nil
        confirmed = []
        notResponding = []
    }

    // MARK: Picking

    func definition(app: AppModel) -> FixtureDefinition? {
        guard let id = selectedEntryID else { return nil }
        return app.library.definition(id) ?? app.show.project.definition(id)
    }

    /// Selects a model and applies friendly defaults (role, name) for it.
    func select(_ entryID: String, app: AppModel) {
        guard selectedEntryID != entryID else { return }
        selectedEntryID = entryID
        chosenModeName = nil
        chosenStyle = nil
        showModeChoices = false
        showAddressChoices = false
        if let def = definition(app: app) {
            baseName = def.model
            role = Self.defaultRole(for: def.category)
        }
    }

    static func defaultRole(for category: FixtureCategory) -> FixtureRole {
        switch category {
        case .tube, .bar, .strip: return .background
        case .panel, .wash, .spot, .fresnel: return .key
        case .bulb, .dimmer: return .practical
        case .par, .movingHead, .effect, .other: return .accent
        }
    }

    func entries(app: AppModel) -> [FixtureLibraryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            return app.library.search(q, category: category, limit: 120)
        }
        let priority = ["amaran", "aputure", "nanlite", "godox", "astera", "quasar", "elgato", "generic"]
        return app.library.entries
            .filter { (category == nil || $0.category == category) && brand.matches($0.manufacturer) }
            .sorted { a, b in
                let pa = priority.firstIndex { a.manufacturer.lowercased().contains($0) } ?? 99
                let pb = priority.firstIndex { b.manufacturer.lowercased().contains($0) } ?? 99
                if pa != pb { return pa < pb }
                if (a.source == "curated") != (b.source == "curated") { return a.source == "curated" }
                return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }
    }

    /// A light model already in the show, with the setting most of those lights use.
    struct ShowModel: Identifiable, Hashable {
        /// The fixture definition ID.
        let id: String
        let model: String
        let category: FixtureCategory
        let modeName: String
        let modeTitle: String
        let cells: Int
        let count: Int
    }

    /// Models already in the show, most-used first: "add another one of these" is the most common case.
    func modelsInShow(app: AppModel) -> [ShowModel] {
        var groups: [String: [ResolvedFixture]] = [:]
        for rf in app.show.resolvedFixtures {
            groups[rf.definition.id, default: []].append(rf)
        }
        let models = groups.compactMap { entry -> ShowModel? in
            let list = entry.value
            guard let first = list.first else { return nil }
            var modeCounts: [String: Int] = [:]
            for rf in list { modeCounts[rf.mode.name, default: 0] += 1 }
            let topMode = modeCounts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
            let mode = list.first { $0.mode.name == topMode }?.mode ?? first.mode
            return ShowModel(id: entry.key, model: first.definition.model, category: first.definition.category,
                             modeName: mode.name, modeTitle: ModeNaming.friendlyTitle(for: mode),
                             cells: mode.cellCount, count: list.count)
        }
        return models.sorted { a, b in a.count != b.count ? a.count > b.count : a.model < b.model }
    }

    /// Picks a model that's already in the show and keeps the same setting as the others.
    func pickFromShow(_ model: ShowModel, app: AppModel) {
        select(model.id, app: app)
        chosenModeName = model.modeName
    }

    // MARK: Planning

    func plan(app: AppModel) -> NewLightPlan? {
        guard let def = definition(app: app) else { return nil }
        return NewLightPlanner.plan(definition: def, quantity: quantity, preferredModeName: chosenModeName,
                                    style: chosenStyle, existing: app.show.resolvedFixtures)
    }

    /// Adds the planned lights (one undo step) and moves on to the setup step.
    @discardableResult
    func commit(app: AppModel) -> Bool {
        guard let plan = plan(app: app) else { return false }
        let ids = app.show.addPlannedFixtures(plan, baseName: baseName, role: role)
        guard !ids.isEmpty else {
            app.ui.toast("Couldn't add that light — try another mode.", style: .error, systemImage: "exclamationmark.triangle.fill")
            return false
        }
        added = ids.compactMap { id in
            guard let rf = app.show.resolved(id) else { return nil }
            let text = rf.fixture.address.map { SetupWalkthrough.make(for: rf, address: $0).addressReadout } ?? "—"
            return AddedLight(id: id, name: rf.fixture.name, label: rf.fixture.stageLabel, addressText: text)
        }
        setupIndex = 0
        askingAbout = nil
        confirmed = []
        notResponding = []
        step = .setup
        return true
    }

    // MARK: Setup & confirm

    /// Lights from this run that still exist in the show.
    func liveAdded(app: AppModel) -> [AddedLight] {
        added.filter { app.show.resolved($0.id) != nil }
    }

    func blink(_ id: UUID, app: AppModel) {
        app.show.identify([id])
        askingAbout = id
    }

    func answer(_ id: UUID, blinked: Bool, app: AppModel) {
        if blinked {
            confirmed.insert(id)
            notResponding.remove(id)
            askingAbout = nil
            advance(app: app)
        } else {
            notResponding.insert(id)
            confirmed.remove(id)
        }
    }

    /// Next light that isn't confirmed yet, or the summary.
    func advance(app: AppModel) {
        let lights = liveAdded(app: app)
        if let next = lights.indices.first(where: { $0 > setupIndex && !confirmed.contains(lights[$0].id) })
            ?? lights.indices.first(where: { !confirmed.contains(lights[$0].id) }), next != setupIndex {
            setupIndex = next
            askingAbout = nil
        } else {
            step = .done
        }
    }
}

// MARK: - Sheet

/// "Add a light": a four-step wizard for people who don't know DMX.
struct AddFixtureSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Bindable private var wizard = AddLightWizardModel.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.stroke)
            Group {
                switch wizard.step {
                case .pick: pickStep
                case .configure: configureStep
                case .setup: setupStep
                case .done: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(width: 880, height: 640)
        .background(Theme.window)
        .onAppear {
            if wizard.keepStateOnNextAppear {
                wizard.keepStateOnNextAppear = false
            } else {
                wizard.reset()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.m)
            WizardStepIndicator(current: wizard.step)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.l)
    }

    private var headerTitle: String {
        switch wizard.step {
        case .pick: return "Add a light"
        case .configure: return wizard.definition(app: app).map { "Add \($0.model)" } ?? "Add a light"
        case .setup: return currentSetupLight.map { "Set up \($0.fixture.name)" } ?? "Set up your light"
        case .done: return wizard.confirmed.count == wizard.added.count && !wizard.added.isEmpty ? "All set!" : "Lights added"
        }
    }

    private var headerSubtitle: String {
        switch wizard.step {
        case .pick: return "What did you plug in? Search by name, or pick it by its picture."
        case .configure: return "Prism picks the address and settings for you. Just say how many and where they are."
        case .setup: return "Do this on the light itself — these are its own buttons and menu names."
        case .done: return "Prism remembers these settings. You can print a setup card for each light any time."
        }
    }

    // MARK: Step 1 — pick

    private var pickStep: some View {
        let items = wizard.entries(app: app)
        let siblings = wizard.modelsInShow(app: app)
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search, e.g. PT4c, Nova, tube, dimmer…", text: $wizard.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                if !wizard.query.isEmpty {
                    Button {
                        wizard.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Theme.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).strokeBorder(Theme.stroke))

            HStack(spacing: 6) {
                ForEach(AddLightWizardModel.BrandFilter.allCases) { brand in
                    chip(brand.rawValue, active: wizard.brand == brand && wizard.query.isEmpty) {
                        wizard.query = ""
                        wizard.brand = brand
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                chip("All types", active: wizard.category == nil, subtle: true) { wizard.category = nil }
                ForEach([FixtureCategory.tube, .panel, .par, .spot, .bar, .dimmer], id: \.self) { cat in
                    chip(cat.displayName, active: wizard.category == cat, subtle: true) { wizard.category = cat }
                }
                Spacer(minLength: 0)
                Text("\(items.count) \(items.count == 1 ? "light" : "lights")")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            if wizard.query.isEmpty && !siblings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ANOTHER ONE OF THESE?")
                        .font(Theme.Font.sectionLabel)
                        .foregroundStyle(Theme.textTertiary)
                    HStack(spacing: 8) {
                        ForEach(Array(siblings.prefix(4))) { model in
                            siblingCard(model)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            if items.isEmpty {
                EmptyStateView(
                    systemImage: "sparkle.magnifyingglass",
                    title: "No lights match",
                    message: "Try the brand or a simpler word (\"tube\", \"panel\"). Not listed? Pick a Generic light with the same colors, or make a custom profile.",
                    actionTitle: "Show generic lights"
                ) {
                    wizard.query = ""
                    wizard.category = nil
                    wizard.brand = .generic
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 10)], spacing: 10) {
                        ForEach(items) { entry in
                            entryCard(entry)
                        }
                    }
                    .padding(2)
                }
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.m)
    }

    private func chip(_ title: String, active: Bool, subtle: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(subtle ? Font.system(size: 11, weight: .semibold) : Theme.Font.captionStrong)
                .foregroundStyle(active ? (subtle ? Theme.accent : Color.white) : Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(active ? (subtle ? Theme.accentSoft : Theme.accent) : Theme.control))
        }
        .buttonStyle(.plain)
    }

    private func siblingCard(_ model: AddLightWizardModel.ShowModel) -> some View {
        let selected = wizard.selectedEntryID == model.id && wizard.chosenModeName == model.modeName
        return Button {
            wizard.pickFromShow(model, app: app)
        } label: {
            HStack(spacing: 9) {
                FixturePicture(category: model.category, cells: model.cells)
                    .frame(width: 46, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.model)
                        .font(Theme.Font.captionStrong)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text("\(model.count) in your show")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.14) : Theme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Adds another \(model.model), set up like the others (\(model.modeTitle))")
    }

    private func entryCard(_ entry: FixtureLibraryEntry) -> some View {
        let selected = wizard.selectedEntryID == entry.id
        return VStack(alignment: .leading, spacing: 8) {
            FixturePicture(category: entry.category, cells: FixturePicture.cells(fromBadge: entry.badge))
                .frame(height: 46)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Color.black.opacity(0.28)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.model)
                        .font(Theme.Font.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if entry.source == "curated" {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.success)
                            .help("Checked against the manufacturer's DMX chart")
                    }
                }
                Text("\(entry.manufacturer) · \(entry.category.displayName)")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Text(entry.badge)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(selected ? Theme.accent.opacity(0.3) : Theme.control))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.14) : Theme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            wizard.select(entry.id, app: app)
            wizard.step = .configure
        }
        .onTapGesture {
            wizard.select(entry.id, app: app)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? AccessibilityTraits([.isButton, .isSelected]) : AccessibilityTraits.isButton)
    }

    // MARK: Step 2 — where it goes + Prism's plan

    @ViewBuilder
    private var configureStep: some View {
        if let def = wizard.definition(app: app), let plan = wizard.plan(app: app) {
            let mode = def.mode(named: plan.modeName) ?? def.recommendedMode
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    FixturePicture(category: def.category, cells: mode?.cellCount ?? 0)
                        .frame(height: 96)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous).fill(Color.black.opacity(0.3)))
                    Text(def.model)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Text("\(def.manufacturer) · \(def.category.displayName)")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Button("Pick a different light") { wizard.step = .pick }
                        .buttonStyle(.pill(compact: true))
                        .padding(.top, 4)
                }
                .frame(width: 220)

                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        questions(def)
                        planPanel(def: def, plan: plan)
                    }
                    .padding(.bottom, Theme.Space.m)
                }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.l)
        } else {
            EmptyStateView(systemImage: "lightbulb.led", title: "Pick a light first",
                           message: "Go back and choose the light you plugged in.",
                           actionTitle: "Back") { wizard.step = .pick }
        }
    }

    private func questions(_ def: FixtureDefinition) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 6) {
                Text("How many?")
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 8) {
                    Stepper(value: $wizard.quantity, in: 1...32) {
                        Text("\(wizard.quantity) \(wizard.quantity == 1 ? "light" : "lights")")
                            .font(Theme.Font.number(14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(minWidth: 64, alignment: .leading)
                    }
                    .fixedSize()
                    ForEach([1, 2, 4, 8], id: \.self) { n in
                        chip("\(n)", active: wizard.quantity == n, subtle: true) { wizard.quantity = n }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Where is it?")
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 6) {
                    ForEach([FixtureRole.key, .fill, .back, .background, .accent, .practical], id: \.self) { role in
                        chip(role.displayName, active: wizard.role == role) { wizard.role = role }
                    }
                }
                Text(wizard.role.explanation + " Prism places it on the stage for you.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            HStack(spacing: 10) {
                Text("Name")
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.textPrimary)
                TextField(def.model, text: $wizard.baseName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                if wizard.quantity > 1 {
                    Text("→ “\(effectiveBaseName(def)) 1”, “\(effectiveBaseName(def)) 2”…")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func effectiveBaseName(_ def: FixtureDefinition) -> String {
        let t = wizard.baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? def.model : t
    }

    private func planPanel(def: FixtureDefinition, plan: NewLightPlan) -> some View {
        let mode = def.mode(named: plan.modeName)
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Prism's plan", systemImage: "wand.and.stars")

            // Mode
            planRow(icon: "dial.medium", caption: "Setting on the light",
                    title: mode.map(ModeNaming.friendlyTitle(for:)) ?? plan.modeName,
                    expanded: $wizard.showModeChoices) {
                HStack(spacing: 6) {
                    if plan.usedSmallerMode {
                        tag("Smaller, so it fits", color: Theme.warning)
                    } else if wizard.chosenModeName == nil {
                        tag("Recommended", color: Theme.success)
                    } else if wizard.modelsInShow(app: app).contains(where: { $0.id == def.id && $0.modeName == plan.modeName }) {
                        tag("Same as your others", color: Theme.success)
                    } else {
                        tag("Your choice", color: Theme.accent)
                    }
                    Text("\(plan.channelCount) DMX \(plan.channelCount == 1 ? "channel" : "channels")\(plan.quantity > 1 ? " each" : "")")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            if wizard.showModeChoices {
                modeChoices(def: def, plan: plan)
            }

            Divider().overlay(Theme.stroke)

            // Address
            planRow(icon: "number", caption: plan.quantity == 1 ? "Address" : "Addresses",
                    title: addressTitle(plan), expanded: $wizard.showAddressChoices) {
                Text(plan.summary)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if wizard.showAddressChoices {
                Picker("Addresses", selection: $wizard.chosenStyle) {
                    Text("Let Prism choose").tag(AddressingStyle?.none)
                    Text("Easy numbers (1, 101, 201…)").tag(AddressingStyle?.some(.easyNumbers))
                    Text("Back to back").tag(AddressingStyle?.some(.packed))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            BudgetBar(plan: plan, existing: app.show.resolvedFixtures)

            ForEach(plan.notes, id: \.self) { note in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Theme.warning)
                    Text(note)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.warning.opacity(0.12)))
            }
        }
        .prismPanel()
    }

    private func addressTitle(_ plan: NewLightPlan) -> String {
        let multiUniverse = Set(plan.assignments.map(\.universe)).count > 1 || plan.assignments.contains { $0.universe != 1 }
        let parts = plan.assignments.prefix(6).map { a in multiUniverse ? "\(a.address) (U\(a.universe))" : "\(a.address)" }
        return parts.joined(separator: ", ") + (plan.assignments.count > 6 ? ", …" : "")
    }

    private func planRow<Detail: View>(icon: String, caption: String, title: String, expanded: Binding<Bool>,
                                       @ViewBuilder detail: () -> Detail) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accentSoft))
            VStack(alignment: .leading, spacing: 3) {
                Text(caption.uppercased())
                    .font(Theme.Font.sectionLabel)
                    .foregroundStyle(Theme.textTertiary)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                detail()
            }
            Spacer(minLength: 8)
            Button(expanded.wrappedValue ? "Done" : "Change") {
                withAnimation(Theme.Motion.snappy) { expanded.wrappedValue.toggle() }
            }
            .buttonStyle(.pill(compact: true))
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
    }

    private func modeChoices(def: FixtureDefinition, plan: NewLightPlan) -> some View {
        VStack(spacing: 5) {
            if wizard.chosenModeName != nil {
                Button {
                    wizard.chosenModeName = nil
                } label: {
                    HStack {
                        Image(systemName: "wand.and.stars")
                        Text("Let Prism choose")
                            .font(Theme.Font.captionStrong)
                        Spacer()
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            ForEach(def.modes.filter { !ModeNaming.isEffectMode($0) || def.modes.count == 1 }) { mode in
                let isOn = mode.name == plan.modeName
                Button {
                    wizard.chosenModeName = mode.name
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isOn ? Theme.accent : Theme.textTertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(ModeNaming.friendlyTitle(for: mode))
                                    .font(Theme.Font.captionStrong)
                                    .foregroundStyle(Theme.textPrimary)
                                if mode.recommended {
                                    tag("Recommended", color: Theme.success)
                                }
                            }
                            Text("On the light: \(SetupCardGenerator.fixtureMenuName(for: def, mode: mode))")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("\(mode.channelCount) ch")
                            .font(Theme.Font.number(10, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill(isOn ? Theme.accent.opacity(0.14) : Theme.panelRaised))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .strokeBorder(isOn ? Theme.accent.opacity(0.7) : Theme.stroke))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Step 3 — set it up on the light

    private var currentSetupLight: ResolvedFixture? {
        let lights = wizard.liveAdded(app: app)
        guard !lights.isEmpty else { return nil }
        let idx = clamp(wizard.setupIndex, 0, lights.count - 1)
        return app.show.resolved(lights[idx].id)
    }

    @ViewBuilder
    private var setupStep: some View {
        if let rf = currentSetupLight, let walk = SetupWalkthrough.make(for: rf) {
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    let lights = wizard.liveAdded(app: app)
                    if lights.count > 1 {
                        lightPager(lights)
                    }
                    LightScreenReadout(walkthrough: walk)
                    blinkPanel(rf, walk: walk)
                    Spacer(minLength: 0)
                }
                .frame(width: 280)

                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        HStack(spacing: 8) {
                            Text(rf.fixture.stageLabel)
                                .font(Theme.Font.mono(11).weight(.bold))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.accentSoft))
                            Text("On the \(walk.modelName):")
                                .font(Theme.Font.headline)
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                        }
                        ForEach(Array(walk.steps.enumerated()), id: \.element.id) { index, step in
                            WalkthroughStepRow(number: index + 1, step: step)
                        }
                        if !walk.tips.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(walk.tips, id: \.self) { tip in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "lightbulb.fill")
                                            .foregroundStyle(Theme.warning)
                                        Text(tip)
                                            .font(Theme.Font.caption)
                                            .foregroundStyle(Theme.textPrimary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.warning.opacity(0.1)))
                        }
                        if !walk.isModelSpecific {
                            Text("These are general steps — every brand words its menus a little differently. Look for “DMX”, “Address” or “Addr”.")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.bottom, Theme.Space.m)
                }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.l)
        } else {
            EmptyStateView(systemImage: "checkmark.circle", title: "Nothing left to set up",
                           message: "The lights from this step were removed or are already set.",
                           actionTitle: "Finish") { wizard.step = .done }
        }
    }

    private func lightPager(_ lights: [AddLightWizardModel.AddedLight]) -> some View {
        let idx = clamp(wizard.setupIndex, 0, max(0, lights.count - 1))
        return HStack(spacing: 8) {
            Text("Light \(idx + 1) of \(lights.count)")
                .font(Theme.Font.captionStrong)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            HStack(spacing: 5) {
                ForEach(Array(lights.enumerated()), id: \.element.id) { i, light in
                    Circle()
                        .fill(wizard.confirmed.contains(light.id) ? Theme.success
                              : wizard.notResponding.contains(light.id) ? Theme.danger
                              : (i == idx ? Theme.accent : Theme.control))
                        .frame(width: 8, height: 8)
                        .onTapGesture {
                            wizard.setupIndex = i
                            wizard.askingAbout = nil
                        }
                }
            }
        }
    }

    private func blinkPanel(_ rf: ResolvedFixture, walk: SetupWalkthrough) -> some View {
        let id = rf.id
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                wizard.blink(id, app: app)
            } label: {
                Label("Blink it", systemImage: "light.max")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.pill(prominent: true))
            .help("Flashes this light for two seconds")

            if wizard.confirmed.contains(id) {
                StatusPill(text: "Working — it blinked", color: Theme.success, systemImage: "checkmark")
            } else if wizard.askingAbout == id || wizard.notResponding.contains(id) {
                Text("Did \(rf.fixture.stageLabel) blink?")
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 8) {
                    Button {
                        wizard.answer(id, blinked: true, app: app)
                    } label: {
                        Label("Yes", systemImage: "checkmark")
                    }
                    .buttonStyle(.pill(tint: Theme.success, prominent: true, compact: true))
                    Button {
                        wizard.answer(id, blinked: false, app: app)
                    } label: {
                        Label("No", systemImage: "xmark")
                    }
                    .buttonStyle(.pill(compact: true))
                }
            } else {
                Text("When the screen shows \(walk.addressReadout), press Blink it.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if wizard.notResponding.contains(id) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Check the screen says \(walk.addressReadout) and the mode is \(walk.modeReadout), that the DMX cable goes into IN, then blink again.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Troubleshoot…") {
                            app.show.selection = [id]
                            app.ui.activeSheet = .troubleshooter
                        }
                        .buttonStyle(.pill(compact: true))
                        Button("Find it…") {
                            app.show.selection = [id]
                            app.ui.activeSheet = .addressScan
                        }
                        .buttonStyle(.pill(compact: true))
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.danger.opacity(0.1)))
            }
        }
        .prismPanel()
    }

    // MARK: Step 4 — done

    private var doneStep: some View {
        let total = wizard.added.count
        let ok = wizard.added.filter { wizard.confirmed.contains($0.id) }.count
        return VStack(spacing: Theme.Space.l) {
            Image(systemName: ok == total && total > 0 ? "checkmark.circle.fill" : "lightbulb.led.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(ok == total && total > 0 ? AnyShapeStyle(Theme.success) : AnyShapeStyle(Theme.spectrum))
                .padding(.top, Theme.Space.l)
            Text(total == 0 ? "No lights were added" : ok == total
                 ? "\(total == 1 ? "Your light is" : "All \(total) lights are") ready"
                 : "\(ok) of \(total) \(total == 1 ? "light" : "lights") confirmed")
                .font(Theme.Font.title)
                .foregroundStyle(Theme.textPrimary)
            Text(ok == total ? "They're on the stage and in your patch. Undo removes them if you change your mind."
                 : "Lights you haven't confirmed are still added. Use Setup Cards or Find My Lights whenever you're ready.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            VStack(spacing: 0) {
                ForEach(wizard.added) { light in
                    HStack(spacing: 10) {
                        let isOK = wizard.confirmed.contains(light.id)
                        let isBad = wizard.notResponding.contains(light.id)
                        Image(systemName: isOK ? "checkmark.circle.fill" : isBad ? "exclamationmark.triangle.fill" : "circle.dashed")
                            .foregroundStyle(isOK ? Theme.success : isBad ? Theme.warning : Theme.textTertiary)
                        Text(light.label)
                            .font(Theme.Font.mono(11).weight(.bold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 44, alignment: .leading)
                        Text(light.name)
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text("Address \(light.addressText)")
                            .font(Theme.Font.number(12, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        Text(isOK ? "Working" : isBad ? "Not responding" : "Not tested")
                            .font(Theme.Font.caption)
                            .foregroundStyle(isOK ? Theme.success : isBad ? Theme.warning : Theme.textTertiary)
                            .frame(width: 96, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    if light.id != wizard.added.last?.id {
                        Divider().overlay(Theme.stroke)
                    }
                }
            }
            .frame(maxWidth: 560)
            .prismPanel(padding: 4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.xl)
    }

    // MARK: Footer

    private var footer: some View {
        let lights = wizard.liveAdded(app: app)
        return HStack(spacing: Theme.Space.m) {
            switch wizard.step {
            case .pick:
                Button {
                    app.ui.activeSheet = .profileEditor
                } label: {
                    Label("Not listed? Make a custom profile", systemImage: "slider.horizontal.below.rectangle")
                }
                .buttonStyle(.plain)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.accent)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.pill)
                    .keyboardShortcut(.cancelAction)
                Button {
                    wizard.step = .configure
                } label: {
                    Label("Next", systemImage: "arrow.right")
                }
                .buttonStyle(.pill(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(wizard.selectedEntryID == nil)
            case .configure:
                Button {
                    wizard.step = .pick
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.pill)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.pill)
                    .keyboardShortcut(.cancelAction)
                Button {
                    wizard.commit(app: app)
                } label: {
                    Label(wizard.quantity > 1 ? "Add \(wizard.quantity) lights & set up" : "Add light & set it up",
                          systemImage: "plus")
                }
                .buttonStyle(.pill(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(wizard.definition(app: app) == nil)
            case .setup:
                Button("Finish later") { wizard.step = .done }
                    .buttonStyle(.pill)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if lights.count > 1 {
                    Button {
                        wizard.setupIndex = max(0, wizard.setupIndex - 1)
                        wizard.askingAbout = nil
                    } label: {
                        Label("Previous", systemImage: "chevron.left")
                    }
                    .buttonStyle(.pill)
                    .disabled(wizard.setupIndex == 0)
                }
                Button {
                    if wizard.setupIndex + 1 < lights.count {
                        wizard.setupIndex += 1
                        wizard.askingAbout = nil
                    } else {
                        wizard.step = .done
                    }
                } label: {
                    Label(wizard.setupIndex + 1 < lights.count ? "Next light" : "Finish", systemImage: "arrow.right")
                }
                .buttonStyle(.pill(prominent: true))
                .keyboardShortcut(.defaultAction)
            case .done:
                Button {
                    app.ui.activeSheet = .setupCards
                } label: {
                    Label("Setup cards", systemImage: "printer")
                }
                .buttonStyle(.pill)
                Spacer()
                Button {
                    wizard.reset()
                } label: {
                    Label("Add another light", systemImage: "plus")
                }
                .buttonStyle(.pill)
                Button("Done") { dismiss() }
                    .buttonStyle(.pill(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.m)
    }
}

// MARK: - Step indicator

/// ① Pick it — ② Where it goes — ③ Set it up — ④ Done
struct WizardStepIndicator: View {
    let current: AddLightWizardModel.Step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AddLightWizardModel.Step.allCases) { step in
                if step.rawValue > 0 {
                    Capsule()
                        .fill(step.rawValue <= current.rawValue ? Theme.accent.opacity(0.7) : Theme.control)
                        .frame(width: 18, height: 2)
                }
                HStack(spacing: 5) {
                    ZStack {
                        Circle()
                            .fill(step.rawValue < current.rawValue ? Theme.accent
                                  : step == current ? Theme.accent.opacity(0.22) : Theme.control)
                        if step.rawValue < current.rawValue {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(Color.white)
                        } else {
                            Text("\(step.rawValue + 1)")
                                .font(Theme.Font.number(10, weight: .bold))
                                .foregroundStyle(step == current ? Theme.accent : Theme.textTertiary)
                        }
                    }
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(step == current ? Theme.accent : .clear, lineWidth: 1))
                    Text(step.title)
                        .font(Theme.Font.captionStrong)
                        .foregroundStyle(step == current ? Theme.textPrimary : Theme.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current.rawValue + 1) of \(AddLightWizardModel.Step.allCases.count): \(current.title)")
    }
}

// MARK: - Budget bar

/// How much of the 512-channel universe is used, with the new lights highlighted.
private struct BudgetBar: View {
    let plan: NewLightPlan
    let existing: [ResolvedFixture]

    var body: some View {
        let universe = plan.assignments.first?.universe ?? 1
        let summary = PatchMath.universeSummary(universe: universe, fixtures: existing)
        let mine = plan.assignments.filter { $0.universe == universe }
        let addedChannels = mine.count * max(1, plan.channelCount)
        let after = min(512, summary.usedChannelCount + addedChannels)
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                let w = max(geo.size.width, 1)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.control)
                    ForEach(summary.blocks) { block in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.26))
                            .frame(width: max(2, CGFloat(block.channelCount) / 512 * w - 1))
                            .offset(x: CGFloat(block.startAddress - 1) / 512 * w)
                    }
                    ForEach(Array(mine.enumerated()), id: \.offset) { _, a in
                        let x = CGFloat(a.address - 1) / 512 * w
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.accent)
                            .frame(width: max(3, min(CGFloat(plan.channelCount) / 512 * w, w - x)))
                            .offset(x: x)
                            .shadow(color: Theme.accent.opacity(0.6), radius: 4)
                    }
                }
            }
            .frame(height: 12)
            HStack(spacing: 10) {
                legend(Color.white.opacity(0.3), "Lights you have")
                legend(Theme.accent, "New")
                Spacer()
                Text("Universe \(universe): \(after) of 512 channels used")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Universe \(universe): \(after) of 512 channels used after adding")
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 6)
            Text(text).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
        }
    }
}
