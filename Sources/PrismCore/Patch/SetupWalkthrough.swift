import Foundation

// MARK: - Button-by-button setup walkthrough

/// Step-by-step instructions for setting a light's DMX address and mode **on the light itself**,
/// written as the buttons to press and the exact text the light shows. Built from the library's
/// `FixtureSetupGuide` when available, with careful generic wording otherwise.
public struct SetupWalkthrough: Hashable, Sendable, Identifiable {

    /// One thing to do on the light.
    public struct Step: Hashable, Sendable, Identifiable {
        public enum Kind: String, Hashable, Sendable {
            case connect, address, dipSwitches, mode, signalLoss, lock, test
        }

        public var id: Int
        public var kind: Kind
        /// Short title, e.g. "Set the address".
        public var title: String
        /// Buttons or menu items to press in order, e.g. `["MENU", "DMX Settings", "DMX Address"]`.
        public var presses: [String]
        /// The value to dial in, exactly as the light shows it (e.g. `"113"`, `"9: LE CCT&RGB 8PX"`).
        public var value: String?
        /// One or two plain-English sentences.
        public var detail: String

        public init(id: Int, kind: Kind, title: String, presses: [String] = [], value: String? = nil, detail: String) {
            self.id = id
            self.kind = kind
            self.title = title
            self.presses = presses
            self.value = value
            self.detail = detail
        }
    }

    public var id: UUID { fixtureID }
    public var fixtureID: UUID
    public var lightName: String
    public var stageLabel: String
    public var modelName: String
    public var universe: Int
    public var address: Int
    /// What the light's address screen should read once set (e.g. `"113"`, `"A113"`, `"d113"`).
    public var addressReadout: String
    /// The mode exactly as it appears in the light's own menu.
    public var modeReadout: String
    /// Friendly description of the mode, e.g. "Full color + white balance · 8 zones".
    public var modeFriendlyName: String
    public var channelCount: Int
    public var steps: [Step]
    /// Model-specific tips (e.g. the amaran PT "keep the DMX Address screen open" rule).
    public var tips: [String]
    public var usesDipSwitches: Bool
    /// Nine DIP switch states (switch 1 first) for `address`.
    public var dipSwitches: [Bool]
    /// True when the steps come from this model's own manual (library setup guide or built-in
    /// knowledge), false when Prism had to use generic wording.
    public var isModelSpecific: Bool

    /// Numbers of the DIP switches that must be ON (1-based), e.g. `[1, 5, 7]`.
    public var dipSwitchesOn: [Int] {
        dipSwitches.enumerated().compactMap { $0.element ? $0.offset + 1 : nil }
    }

    /// Builds the walkthrough for a patched fixture, or `nil` if it has no address yet.
    public static func make(for rf: ResolvedFixture) -> SetupWalkthrough? {
        guard let address = rf.fixture.address else { return nil }
        return make(for: rf, address: address)
    }

    /// Builds the walkthrough for a fixture at a specific address (used for previews before patching).
    public static func make(for rf: ResolvedFixture, address rawAddress: Int) -> SetupWalkthrough {
        let def = rf.definition
        let mode = rf.mode
        let address = clamp(rawAddress, 1, 512)
        let guide = def.setupGuide
        let readout = guide?.formatAddress(address) ?? String(format: "%03d", address)
        let modeReadout = SetupCardGenerator.fixtureMenuName(for: def, mode: mode)
        let dips = PatchMath.dipSwitches(for: address)
        let mfg = def.manufacturer.lowercased()
        let model = def.model.lowercased()
        let isAputureFamily = mfg.contains("amaran") || mfg.contains("aputure")
        let isPTTube = isAputureFamily && (model.contains("pt") || model.contains("pixel tube"))

        var steps: [Step] = []
        var tips: [String] = []
        var usesDips = false
        var modelSpecific = false

        func add(_ kind: Step.Kind, _ title: String, _ presses: [String] = [], _ value: String? = nil, _ detail: String) {
            steps.append(Step(id: steps.count, kind: kind, title: title, presses: presses, value: value, detail: detail))
        }

        if let guide, !guide.addressMenuPath.isEmpty || !guide.modeMenuPath.isEmpty || guide.usesDipSwitches {
            // The library knows this model's menus.
            modelSpecific = true
            usesDips = guide.usesDipSwitches
            let connector = guide.connector?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            add(.connect, "Plug in the DMX cable", [], nil, connector.isEmpty
                ? "Run a DMX cable from your DMX box (or the previous light's DMX OUT) into this light's DMX IN."
                : "Connect DMX using the \(connector). The cable from your DMX box goes into IN.")
            if guide.usesDipSwitches {
                add(.dipSwitches, "Set the address switches", [], onList(dips),
                    "Flip these switches ON and all the others OFF. Together they add up to \(address).")
            } else {
                add(.address, "Set the address", guide.addressMenuPath, readout,
                    "Use the arrow buttons or knob until the screen shows \(readout), then confirm.")
            }
            if !guide.modeMenuPath.isEmpty || def.modes.count > 1 {
                add(.mode, "Choose the mode", guide.modeMenuPath, modeReadout,
                    "Pick \(modeReadout) — it uses \(mode.channelCount) \(mode.channelCount == 1 ? "channel" : "channels").")
            }
            if let loss = guide.signalLossBehavior, !loss.isEmpty {
                add(.signalLoss, "If the signal drops", [], loss,
                    "Choose this if the light offers it, so the lights stay steady if the Mac sleeps.")
            }
            tips.append(contentsOf: guide.notes.filter { !$0.isEmpty })
        } else if isPTTube {
            // Built-in knowledge from the amaran PT manual (docs/research/aputure_profiles.md §2.2).
            modelSpecific = true
            add(.connect, "Plug in the DMX adapter", [], nil,
                "Plug the amaran USB-C → DMX adapter into the tube. The cable from your DMX box goes into the adapter's IN; its OUT goes on to the next tube.")
            add(.address, "Set the address", ["MENU", "DMX Settings", "DMX Address"], readout,
                "Press ▲ / ▼ until the screen shows \(readout), then press OK.")
            add(.mode, "Choose the mode", ["MENU", "DMX Settings", "DMX Profiles"], modeReadout,
                "Press ▲ / ▼ to pick \(modeReadout) (\(mode.channelCount) channels), then press OK.")
            add(.signalLoss, "If the signal drops", ["MENU", "DMX Settings", "DMX Loss Behavior"], "Hold Last Setting",
                "Keeps the tube steady if the Mac sleeps or the cable wiggles.")
            add(.lock, "Lock the address screen", ["DMX Address", "Hold OK for 2 s"], readout,
                "Go back to the DMX Address screen and hold OK for 2 seconds. The tube only listens to DMX while this screen is showing.")
            tips.append("amaran PT tubes only follow DMX while the DMX Address screen is showing — lock it with a 2-second press of OK.")
        } else if isAputureFamily {
            modelSpecific = true
            add(.connect, "Plug in the DMX cable", [], nil,
                "Connect the DMX cable to the light's DMX IN (some models need the amaran/Aputure USB-C → DMX adapter).")
            add(.address, "Set the address", ["MENU", "DMX Settings", "DMX Address"], readout,
                "Turn the knob or use ▲ / ▼ until the screen shows \(readout), then press it to confirm.")
            add(.mode, "Choose the mode", ["MENU", "DMX Settings", "DMX Profile"], modeReadout,
                "Pick \(modeReadout) (\(mode.channelCount) channels).")
            add(.signalLoss, "If the signal drops", ["MENU", "DMX Settings", "DMX Loss Behavior"], "Hold Last Setting",
                "Keeps the light steady if the Mac sleeps.")
        } else {
            add(.connect, "Plug in the DMX cable", [], nil,
                "Run a DMX cable from your DMX box (or the previous light's DMX OUT) into this light's DMX IN.")
            if let help = def.addressHelp?.trimmingCharacters(in: .whitespacesAndNewlines), !help.isEmpty {
                modelSpecific = true
                add(.address, "Set the address", [], readout, help + " Set it to \(readout).")
            } else {
                add(.address, "Set the address", ["MENU"], readout,
                    "Find the DMX address setting — it often shows as “Addr”, “A001” or “d001” — and set it to \(address). Some lights show it as A\(readout) or d\(readout).")
            }
            if def.modes.count > 1 {
                add(.mode, "Choose the mode", ["MENU"], modeReadout,
                    "Find the DMX mode (sometimes called “Personality” or “Ch”) and pick \(modeReadout) — \(mode.channelCount) \(mode.channelCount == 1 ? "channel" : "channels").")
            }
        }
        if let notes = def.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty, !tips.contains(notes) {
            tips.append(notes)
        }
        add(.test, "Blink it", [], nil, "Click “Blink it” in Prism. The light should flash for two seconds.")

        return SetupWalkthrough(
            fixtureID: rf.id,
            lightName: rf.fixture.name,
            stageLabel: rf.fixture.stageLabel,
            modelName: def.displayName,
            universe: rf.fixture.universe,
            address: address,
            addressReadout: readout,
            modeReadout: modeReadout,
            modeFriendlyName: ModeNaming.friendlyTitle(for: mode),
            channelCount: mode.channelCount,
            steps: steps,
            tips: tips,
            usesDipSwitches: usesDips,
            dipSwitches: dips,
            isModelSpecific: modelSpecific
        )
    }

    private static func onList(_ dips: [Bool]) -> String {
        let on = dips.enumerated().compactMap { $0.element ? "\($0.offset + 1)" : nil }
        return on.isEmpty ? "All OFF" : "ON: " + on.joined(separator: ", ")
    }
}
