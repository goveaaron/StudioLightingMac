import Foundation

// MARK: - Plain-language mode names

/// Plain-English names for fixture modes, shared by the Add Light wizard, setup cards and tests.
public enum ModeNaming {
    /// A friendly title such as `"Full color + white balance · 8 zones"`. Prefers the library's
    /// `friendlyName`, then its `summary`, then a description built from the mode's channels.
    public static func friendlyTitle(for mode: FixtureMode) -> String {
        if let friendly = mode.friendlyName?.trimmingCharacters(in: .whitespacesAndNewlines), !friendly.isEmpty {
            return friendly
        }
        if let summary = mode.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return summary
        }
        return generatedTitle(for: mode)
    }

    /// A description built only from the mode's channels (ignores library-provided names).
    public static func generatedTitle(for mode: FixtureMode) -> String {
        let caps = mode.capabilities
        let zones = mode.cellCount > 1 ? " · \(mode.cellCount) zones" : ""
        if caps.hasRGB && (caps.hasCCT || caps.emitters.contains(.white) || caps.emitters.contains(.warmWhite)
                           || caps.emitters.contains(.coolWhite)) {
            return "Full color + white balance" + zones
        }
        if caps.hasRGB { return "Full color" + zones }
        if caps.hasHSI || caps.hasXY { return "Color by hue & saturation" + zones }
        if caps.canDoColor { return "Color" + zones }
        if caps.hasCCT && caps.hasTint { return "White balance + green/magenta tint" + zones }
        if caps.canDoWhiteBalance { return "White balance (warm ↔ cool)" + zones }
        if caps.hasIntensity || mode.channelCount == 1 { return "Brightness only" + zones }
        if isEffectMode(mode) { return "Built-in effects" }
        return mode.name
    }

    /// True for modes that only trigger the fixture's built-in effects (e.g. amaran "System FX").
    public static func isEffectMode(_ mode: FixtureMode) -> Bool {
        let n = mode.name.lowercased()
        let caps = mode.capabilities
        let looksLikeFX = n.contains(" fx") || n.hasPrefix("fx") || n.contains("effect") || n.contains("system fx")
        return looksLikeFX && !caps.hasRGB && !caps.hasCCT
    }

    /// How "rich" a mode is for everyday use: 4 = color + white, 3 = color, 2 = white balance,
    /// 1 = brightness only, 0 = effects-only modes (never picked automatically).
    public static func richness(of mode: FixtureMode) -> Int {
        if isEffectMode(mode) { return 0 }
        let caps = mode.capabilities
        if caps.canDoColor && (caps.hasCCT || caps.emitters.contains(.white) || caps.emitters.contains(.warmWhite)
                               || caps.emitters.contains(.coolWhite)) {
            return 4
        }
        if caps.canDoColor { return 3 }
        if caps.canDoWhiteBalance { return 2 }
        return 1
    }
}

// MARK: - New light planning

/// What Prism decided for lights the user is adding: which mode, which addresses, and why.
public struct NewLightPlan: Hashable, Sendable {
    public var definitionID: String
    public var modeName: String
    public var channelCount: Int
    public var quantity: Int
    public var style: AddressingStyle
    public var assignments: [PatchMath.AddressAssignment]
    /// Prism picked a smaller mode than the recommended one so every light fits on the existing DMX output(s).
    public var usedSmallerMode: Bool
    /// The recommended mode Prism would have liked to use (set when `usedSmallerMode` is true).
    public var recommendedModeName: String?
    /// At least one light landed in a universe the rig doesn't use yet (needs another DMX output).
    public var needsAnotherUniverse: Bool
    /// One friendly sentence about the addresses, e.g. "Prism picked address 401 — it's free and easy to dial in."
    public var summary: String
    /// Extra plain-English notes (smaller mode, extra universe).
    public var notes: [String]

    public init(definitionID: String, modeName: String, channelCount: Int, quantity: Int, style: AddressingStyle,
                assignments: [PatchMath.AddressAssignment], usedSmallerMode: Bool = false,
                recommendedModeName: String? = nil, needsAnotherUniverse: Bool = false,
                summary: String, notes: [String] = []) {
        self.definitionID = definitionID
        self.modeName = modeName
        self.channelCount = channelCount
        self.quantity = quantity
        self.style = style
        self.assignments = assignments
        self.usedSmallerMode = usedSmallerMode
        self.recommendedModeName = recommendedModeName
        self.needsAnotherUniverse = needsAnotherUniverse
        self.summary = summary
        self.notes = notes
    }

    /// The first address, formatted the way most fixtures show it (e.g. `"401"`).
    public var firstAddressText: String { assignments.first?.displayAddress ?? "—" }
}

/// Plans "I plugged in a new light" for someone who doesn't know DMX: picks the recommended mode
/// (or the richest mode that still fits), free addresses (easy round numbers when possible), and
/// explains the choice in plain English. Never throws; always returns a usable plan.
public enum NewLightPlanner {

    /// - Parameters:
    ///   - definition: the light model being added.
    ///   - quantity: how many identical lights (clamped to 1…64).
    ///   - preferredModeName: the user's explicit mode choice. When set, Prism keeps it even if it spills over.
    ///   - style: the user's explicit addressing style; `nil` lets Prism pick (easy numbers when they fit).
    ///   - universe: the universe to start in.
    ///   - existing: the current patch.
    ///   - availableUniverses: how many universes the user can drive (defaults to the universes already used, min 1).
    public static func plan(
        definition: FixtureDefinition,
        quantity: Int,
        preferredModeName: String? = nil,
        style: AddressingStyle? = nil,
        universe: Int = 1,
        existing: [ResolvedFixture],
        availableUniverses: Int? = nil
    ) -> NewLightPlan {
        let n = clamp(quantity, 1, 64)
        let startUniverse = clamp(universe, 1, 64)
        let usedUniverses = existing.compactMap { $0.fixture.address != nil ? $0.fixture.universe : nil }
        let maxUniverse = max(startUniverse + max(1, availableUniverses ?? 1) - 1, usedUniverses.max() ?? startUniverse)

        guard let recommended = definition.recommendedMode ?? definition.modes.first else {
            return NewLightPlan(definitionID: definition.id, modeName: "", channelCount: 0, quantity: n,
                                style: style ?? .easyNumbers, assignments: [],
                                summary: "This light has no DMX modes yet — add one in the profile editor.")
        }

        func allocate(_ mode: FixtureMode, _ s: AddressingStyle) -> PatchMath.AddressAllocationResult {
            PatchMath.allocateAddresses(channelCount: mode.channelCount, count: n, style: s,
                                        startingUniverse: startUniverse, startingAt: 1, existing: existing)
        }
        func fits(_ r: PatchMath.AddressAllocationResult) -> Bool {
            r.assignments.count == n && r.assignments.allSatisfy { $0.universe <= maxUniverse }
        }
        func spillCount(_ r: PatchMath.AddressAllocationResult) -> Int {
            r.assignments.filter { $0.universe > maxUniverse }.count
        }
        /// Easy numbers first (when the user didn't pick), then packed.
        let styles: [AddressingStyle] = style.map { [$0] } ?? [.easyNumbers, .packed]

        // 1. The user's explicit mode: keep it, whatever happens.
        if let preferredModeName, let chosen = definition.mode(named: preferredModeName) {
            var best: (AddressingStyle, PatchMath.AddressAllocationResult)?
            for s in styles {
                let r = allocate(chosen, s)
                if fits(r) { best = (s, r); break }
                if let b = best, spillCount(b.1) <= spillCount(r) { continue }
                best = (s, r)
            }
            let (s, r) = best ?? (styles[0], allocate(chosen, styles[0]))
            return finish(definition: definition, mode: chosen, quantity: n, style: s, result: r,
                          maxUniverse: maxUniverse, smallerThan: nil)
        }

        // 2. The recommended mode, if it fits.
        for s in styles {
            let r = allocate(recommended, s)
            if fits(r) {
                return finish(definition: definition, mode: recommended, quantity: n, style: s, result: r,
                              maxUniverse: maxUniverse, smallerThan: nil)
            }
        }

        // 3. The richest smaller mode that fits.
        let fallbacks = definition.modes
            .filter { $0.name != recommended.name && $0.channelCount < recommended.channelCount }
            .filter { ModeNaming.richness(of: $0) > 0 }
            .sorted { a, b in
                let ra = ModeNaming.richness(of: a), rb = ModeNaming.richness(of: b)
                if ra != rb { return ra > rb }
                if a.cellCount != b.cellCount { return a.cellCount > b.cellCount }
                return a.channelCount < b.channelCount
            }
        for mode in fallbacks {
            for s in styles {
                let r = allocate(mode, s)
                if fits(r) {
                    return finish(definition: definition, mode: mode, quantity: n, style: s, result: r,
                                  maxUniverse: maxUniverse, smallerThan: recommended)
                }
            }
        }

        // 4. Nothing fits: keep the recommended mode, packed, and say it needs another universe.
        let s = style ?? .packed
        return finish(definition: definition, mode: recommended, quantity: n, style: s,
                      result: allocate(recommended, s), maxUniverse: maxUniverse, smallerThan: nil)
    }

    private static func finish(
        definition: FixtureDefinition,
        mode: FixtureMode,
        quantity n: Int,
        style: AddressingStyle,
        result: PatchMath.AddressAllocationResult,
        maxUniverse: Int,
        smallerThan recommended: FixtureMode?
    ) -> NewLightPlan {
        let assignments = result.assignments
        let spills = assignments.filter { $0.universe > maxUniverse }
        var notes: [String] = []
        if let recommended {
            notes.append("There isn't room for “\(ModeNaming.friendlyTitle(for: recommended))” (\(recommended.channelCount) channels each), so Prism picked “\(ModeNaming.friendlyTitle(for: mode))” (\(mode.channelCount) each) to keep everything on your DMX box. You can change it.")
        }
        if !spills.isEmpty {
            let universes = Array(Set(spills.map(\.universe))).sorted().map(String.init).joined(separator: ", ")
            notes.append("\(spills.count == 1 ? "1 light doesn't" : "\(spills.count) lights don't") fit in the 512 channels you're using, so \(spills.count == 1 ? "it goes" : "they go") to universe \(universes). That needs another DMX output — or pick a smaller mode.")
        }
        return NewLightPlan(
            definitionID: definition.id,
            modeName: mode.name,
            channelCount: mode.channelCount,
            quantity: n,
            style: style,
            assignments: assignments,
            usedSmallerMode: recommended != nil,
            recommendedModeName: recommended?.name,
            needsAnotherUniverse: !spills.isEmpty,
            summary: summary(for: assignments, style: style),
            notes: notes
        )
    }

    /// "Prism picked address 401 — it's free and easy to dial in." / "Prism picked addresses 1, 101 and 201."
    public static func summary(for assignments: [PatchMath.AddressAssignment], style: AddressingStyle) -> String {
        guard let first = assignments.first else { return "No free addresses found." }
        let multiUniverse = Set(assignments.map(\.universe)).count > 1
        func label(_ a: PatchMath.AddressAssignment) -> String {
            multiUniverse ? "\(a.address) (universe \(a.universe))" : "\(a.address)"
        }
        if assignments.count == 1 {
            let isRound = first.address == 1 || (first.address - 1) % 10 == 0
            if style == .easyNumbers && isRound {
                return "Prism picked address \(label(first)) — it's free and easy to dial in."
            }
            return "Prism picked address \(label(first)), the next free spot."
        }
        let labels = assignments.map(label)
        let shown = labels.count > 6 ? Array(labels.prefix(5)) + ["…"] : labels
        let list: String
        if shown.count >= 2, shown.last != "…" {
            list = shown.dropLast().joined(separator: ", ") + " and " + (shown.last ?? "")
        } else {
            list = shown.joined(separator: ", ")
        }
        return "Prism picked free addresses \(list)."
    }
}
