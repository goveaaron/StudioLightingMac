import Foundation
import PrismCore

/// Inspector edits, built on ShowController's undoable `updateStates` / `apply`.
///
/// Every helper takes the target fixture IDs explicitly (the inspector edits exactly what it
/// shows), clamps values to each light's own limits, and uses a coalesce key for continuous
/// drags so one gesture is one undo step.
extension ShowController {
    /// Resolved fixtures for `ids`, keyed by ID.
    func inspectorResolved<C: Collection>(_ ids: C) -> [UUID: ResolvedFixture] where C.Element == UUID {
        let wanted = Set(ids)
        var out: [UUID: ResolvedFixture] = [:]
        for rf in resolvedFixtures where wanted.contains(rf.id) { out[rf.id] = rf }
        return out
    }

    /// Clamps a Kelvin white to what a fixture can actually play.
    private func clampWhite(_ color: LightColor, for rf: ResolvedFixture?) -> LightColor {
        guard case .kelvin(let k, let t) = color, let rf else { return color }
        let range = rf.inspectorKelvinRange
        return .kelvin(clamp(k, range.lowerBound, range.upperBound), tint: t)
    }

    // MARK: Color

    /// Gives every light one color (replacing pixel patterns). Lights that are off come up to
    /// the default level so the change is visible.
    func inspectorSetColor(_ ids: [UUID], _ color: LightColor, undoName: String = "Change Color",
                           coalesceKey: String? = nil) {
        let resolved = inspectorResolved(ids)
        let color = color.sanitized
        updateStates(ids, undoName: undoName, coalesceKey: coalesceKey) { id, state in
            state.color = clampWhite(color, for: resolved[id])
            state.cells = nil
            if state.intensity <= 0.0005 { state.intensity = FixtureState.defaultOn.intensity }
        }
    }

    /// Sets per-light colors (e.g. a palette spread across the stage).
    func inspectorSetColors(_ colors: [UUID: LightColor], undoName: String = "Change Color") {
        let resolved = inspectorResolved(colors.keys)
        updateStates(Array(colors.keys), undoName: undoName) { id, state in
            guard let c = colors[id] else { return }
            state.color = clampWhite(c.sanitized, for: resolved[id])
            state.cells = nil
            if state.intensity <= 0.0005 { state.intensity = FixtureState.defaultOn.intensity }
        }
    }

    /// Sets Kelvin and/or tint, switching lights to white. A `nil` component keeps the light's
    /// current value when it's already white (or the derived/remembered value otherwise).
    func inspectorSetWhite(_ ids: [UUID], kelvin: Double?, tint: Double?, fallbackKelvin: Double = 5600,
                           undoName: String = "Change White Balance", coalesceKey: String? = nil) {
        let resolved = inspectorResolved(ids)
        updateStates(ids, undoName: undoName, coalesceKey: coalesceKey) { id, state in
            let current = ColorFieldValues(state.color)
            let k = kelvin ?? current.kelvin ?? fallbackKelvin
            let t = tint ?? current.tint ?? 0
            state.color = clampWhite(.kelvin(k, tint: clamp(t, -1, 1)), for: resolved[id])
            state.cells = nil
            if state.intensity <= 0.0005 { state.intensity = FixtureState.defaultOn.intensity }
        }
    }

    /// Copies another light's color (and pixel pattern) onto `ids`.
    func inspectorMatch(_ ids: [UUID], to source: UUID) {
        let src = state(of: source)
        let resolved = inspectorResolved(ids + [source])
        let srcCells = resolved[source]?.cellCount ?? 0
        updateStates(ids, undoName: "Match Light") { id, state in
            state.color = clampWhite(src.color, for: resolved[id])
            let count = resolved[id]?.cellCount ?? 0
            if let cells = src.cells, !cells.isEmpty, count > 1, srcCells > 1 {
                // Resample the source pattern onto this light's cell count.
                state.cells = (0..<min(count, PixelOps.maxCells)).map { i in
                    let pos = count == 1 ? 0 : Double(i) / Double(count - 1)
                    let j = Int((pos * Double(srcCells - 1)).rounded())
                    return src.cell(clamp(j, 0, srcCells - 1))
                }
            } else {
                state.cells = nil
            }
            if state.intensity <= 0.0005 { state.intensity = FixtureState.defaultOn.intensity }
        }
    }

    /// Rotates hues from captured start states (so a drag is reversible and never accumulates error).
    func inspectorHueShift(from start: [UUID: FixtureState], degrees: Double) {
        updateStates(Array(start.keys), undoName: "Shift Hue", coalesceKey: "inspector.hueShift") { id, state in
            guard let s = start[id] else { return }
            let rotated = ColorEdit.hueRotated(s, by: degrees)
            state.color = rotated.color
            state.cells = rotated.cells
        }
    }

    // MARK: Intensity

    /// Sets every light to one brightness.
    func inspectorSetIntensity(_ ids: [UUID], _ value: Double, coalesceKey: String? = nil) {
        let v = clamp01(value.finiteOr(0))
        updateStates(ids, undoName: "Change Brightness", coalesceKey: coalesceKey) { _, state in
            state.intensity = v
        }
    }

    /// Sets each light's brightness individually (relative drags on a mixed selection).
    func inspectorSetIntensities(_ values: [UUID: Double], coalesceKey: String? = nil) {
        updateStates(Array(values.keys), undoName: "Change Brightness", coalesceKey: coalesceKey) { id, state in
            if let v = values[id] { state.intensity = clamp01(v.finiteOr(state.intensity)) }
        }
    }

    /// Adds `delta` (e.g. +0.1 = 10 points brighter) to every light, keeping their differences.
    func inspectorAdjustIntensity(_ ids: [UUID], by delta: Double) {
        updateStates(ids, undoName: delta >= 0 ? "Brighter" : "Dimmer") { _, state in
            state.intensity = clamp01(state.intensity + delta.finiteOr(0))
        }
    }

    /// Changes every light by photographic stops (±⅓ = one click), keeping their ratios.
    func inspectorNudgeStops(_ ids: [UUID], by stops: Double) {
        updateStates(ids, undoName: stops >= 0 ? "Brighter" : "Dimmer", coalesceKey: "inspector.stops") { _, state in
            state.intensity = InspectorFormat.nudge(state.intensity, stops: stops)
        }
    }

    // MARK: Pixels

    /// Applies a pure pixel edit to each light that has pixels.
    func inspectorEditPixels(_ ids: [UUID], undoName: String, coalesceKey: String? = nil,
                             _ edit: (FixtureState, Int) -> FixtureState) {
        let resolved = inspectorResolved(ids)
        let pixelIDs = ids.filter { (resolved[$0]?.cellCount ?? 0) > 1 }
        guard !pixelIDs.isEmpty else { return }
        updateStates(pixelIDs, undoName: undoName, coalesceKey: coalesceKey) { id, state in
            let count = resolved[id]?.cellCount ?? 0
            let edited = edit(state, count)
            state.cells = edited.cells
            state.color = edited.color
            if state.intensity <= 0.0005 { state.intensity = FixtureState.defaultOn.intensity }
        }
    }

    /// Paints a gradient across several lights by stage position (pixels follow their position).
    func inspectorSpreadGradient(_ ids: [UUID], colors: [LightColor]) {
        guard !ids.isEmpty, colors.count >= 2 else { return }
        apply(.gradient(.fixtures(ids), colors: colors, axis: .horizontal), undoName: "Spread Gradient")
    }

    // MARK: Fixture setup

    /// Protects (or releases) lights from effects, music and remote changes.
    func inspectorSetProtected(_ ids: [UUID], _ on: Bool) {
        apply(.setFixtureProtection(.fixtures(ids), on), undoName: on ? "Protect Light" : "Unprotect Light")
    }

    /// Adds or removes lights from a group.
    func inspectorSetGroup(_ groupID: UUID, contains ids: [UUID], _ member: Bool) {
        editProject(member ? "Add to Group" : "Remove from Group", change: [.patch]) { project in
            guard let gi = project.groups.firstIndex(where: { $0.id == groupID }) else { return }
            var list = project.groups[gi].fixtureIDs
            if member {
                for id in ids where !list.contains(id) { list.append(id) }
            } else {
                list.removeAll { ids.contains($0) }
            }
            project.groups[gi].fixtureIDs = list
        }
    }
}
