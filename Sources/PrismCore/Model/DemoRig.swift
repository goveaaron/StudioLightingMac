import Foundation

/// Built-in demo / template projects.
///
/// `londonStudio()` mirrors the layout of the studio Prism was designed for (from the owner's
/// Lightkey screenshot): a round dimmer (P1), eight 16-pixel tubes (B1–B8) around the subject and
/// a square RGBWW panel (PN1). It uses generic profiles so it works without the curated library;
/// once the real models are known the fixtures can be swapped with "Replace fixture type".
public enum DemoRig {
    public static let pixelTubeID = "amaran.pt4c"
    public static let pixelTubeMode = "Light Engine CCT & RGB 8 Pixels"
    public static let panelID = "amaran.f22c"
    public static let panelMode = "CCT & RGB 8-bit"
    public static let dimmerID = "generic.dimmer"
    public static let dimmerMode = "8-bit"

    /// Stable IDs so screenshots/tests can refer to fixtures.
    public enum IDs {
        public static let p1 = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
        public static let pn1 = UUID(uuidString: "00000000-0000-4000-8000-0000000000B1")!
        public static func tube(_ n: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-4000-8000-0000000000C%X", max(0, min(n, 15))))!
        }
    }

    public static func londonStudio() -> Project {
        var fixtures: [PatchedFixture] = []
        var address = 1

        func add(_ id: UUID, name: String, short: String, def: String, mode: String, channels: Int,
                 role: FixtureRole, x: Double, y: Double, rotation: Double = 0, depth: Double? = nil) {
            fixtures.append(PatchedFixture(
                id: id, name: name, shortName: short, definitionID: def, modeName: mode,
                universe: 1, address: address, role: role,
                transform: StageTransform(x: x, y: y, rotation: rotation, scale: 1, depth: depth)))
            address += channels
        }

        // Stage is portrait like the owner's Lightkey canvas: 5.2 m wide × 9.2 m deep.
        // Total footprint: 1 (P1) + 8 × 56 (PT4c 8-px) + 10 (F22c) = 459 channels in Universe 1.
        add(IDs.p1, name: "Round Light", short: "P1", def: dimmerID, mode: dimmerMode, channels: 1,
            role: .practical, x: 1.43, y: 1.33, depth: 0.95)
        add(IDs.tube(1), name: "Tube Left", short: "B1", def: pixelTubeID, mode: pixelTubeMode, channels: 56,
            role: .background, x: 1.01, y: 6.04, rotation: 270, depth: 0.6)
        add(IDs.tube(2), name: "Tube Back Left", short: "B2", def: pixelTubeID, mode: pixelTubeMode, channels: 56,
            role: .background, x: 1.34, y: 3.92, depth: 0.9)
        add(IDs.tube(3), name: "Tube Back Right", short: "B3", def: pixelTubeID, mode: pixelTubeMode, channels: 56,
            role: .background, x: 3.35, y: 3.92, depth: 0.9)
        add(IDs.tube(4), name: "Tube Back Center", short: "B4", def: pixelTubeID, mode: pixelTubeMode, channels: 56,
            role: .background, x: 2.52, y: 4.73, depth: 0.8)
        add(IDs.tube(5), name: "Tube Right", short: "B5", def: pixelTubeID, mode: pixelTubeMode, channels: 56,
            role: .background, x: 3.94, y: 6.06, rotation: 90, depth: 0.6)
        add(IDs.tube(6), name: "Floor Tube 2", short: "B6", def: pixelTubeID, mode: pixelTubeMode, channels: 56,
            role: .accent, x: 3.42, y: 7.61, rotation: 305, depth: 0.25)
        add(IDs.tube(7), name: "Floor Tube 1", short: "B7", def: pixelTubeID, mode: pixelTubeMode, channels: 56,
            role: .accent, x: 3.13, y: 7.59, rotation: 305, depth: 0.25)
        add(IDs.tube(8), name: "Floor Tube 3", short: "B8", def: pixelTubeID, mode: pixelTubeMode, channels: 56,
            role: .accent, x: 3.73, y: 7.66, rotation: 305, depth: 0.25)
        add(IDs.pn1, name: "Key Panel", short: "PN1", def: panelID, mode: panelMode, channels: 10,
            role: .key, x: 1.19, y: 8.2, depth: 0.05)

        let tubes = (1...8).map { IDs.tube($0) }
        let groups = [
            FixtureGroup(name: "All Tubes", fixtureIDs: tubes, colorHex: "#FF4FD8"),
            FixtureGroup(name: "Back Tubes", fixtureIDs: [IDs.tube(2), IDs.tube(3), IDs.tube(4)], colorHex: "#B36BFF"),
            FixtureGroup(name: "Side Tubes", fixtureIDs: [IDs.tube(1), IDs.tube(5)], colorHex: "#22D3EE"),
            FixtureGroup(name: "Floor Tubes", fixtureIDs: [IDs.tube(6), IDs.tube(7), IDs.tube(8)], colorHex: "#F472B6"),
        ]

        let pink = LightColor.hex("#FF2FB4")!
        let cyan = LightColor.hex("#14D8F0")!
        let teal = LightColor.hex("#00C2A8")!
        let blue = LightColor.hex("#1F4BFF")!
        let deepBlue = LightColor.hex("#0A2AFF")!
        let orange = LightColor.hex("#FF7A1A")!
        let salmon = LightColor.hex("#FF8C7A")!
        let green = LightColor.hex("#00FF3C")!

        func states(_ pairs: [(UUID, FixtureState)]) -> FixtureStateMap {
            var m = FixtureStateMap()
            for (id, s) in pairs { m[id] = s }
            return m
        }
        func on(_ c: LightColor, _ i: Double = 1) -> FixtureState { FixtureState(intensity: i, color: c) }
        func gradient(_ a: LightColor, _ b: LightColor, cells: Int = 8, _ i: Double = 1) -> FixtureState {
            let cs = (0..<cells).map { idx -> CellState in
                CellState(intensity: 1, color: LightColor.mix(a, b, Double(idx) / Double(max(cells - 1, 1))))
            }
            return FixtureState(intensity: i, color: LightColor.mix(a, b, 0.5), cells: cs)
        }

        let randomFolder = LookFolder(name: "Random", sortIndex: 0)
        let coolFolder = LookFolder(name: "Cool Setups", sortIndex: 1)

        var looks: [Look] = []
        func look(_ name: String, folder: UUID? = nil, favorite: Bool = false, fade: Double = 1.5,
                  _ pairs: [(UUID, FixtureState)]) {
            looks.append(Look(name: name, folderID: folder, states: states(pairs), fadeTime: fade,
                              isFavorite: favorite, sortIndex: looks.count))
        }

        look("Chill Vibes 4", favorite: true, [
            (IDs.p1, on(.white, 1)),
            (IDs.tube(1), on(cyan)), (IDs.tube(5), on(cyan)), (IDs.tube(8), on(cyan)),
            (IDs.tube(2), on(pink)), (IDs.tube(3), on(pink)), (IDs.tube(4), on(pink)),
            (IDs.tube(6), on(pink)), (IDs.tube(7), on(pink)),
            (IDs.pn1, FixtureState(intensity: 0, color: .kelvin(5600, tint: 0))),
        ])
        look("New Studio Vibes", favorite: true, [
            (IDs.p1, on(.white, 0.6)),
            (IDs.tube(1), gradient(pink, blue)), (IDs.tube(5), gradient(blue, pink)),
            (IDs.tube(2), on(LightColor.hex("#7A2BFF")!)), (IDs.tube(3), on(LightColor.hex("#7A2BFF")!)),
            (IDs.tube(4), gradient(pink, cyan)),
            (IDs.tube(6), on(pink, 0.7)), (IDs.tube(7), on(pink, 0.7)), (IDs.tube(8), on(cyan, 0.7)),
            (IDs.pn1, FixtureState(intensity: 0.55, color: .kelvin(4300, tint: 0))),
        ])
        look("Teal Left, Blue Right, Pink Above", folder: coolFolder.id, [
            (IDs.tube(1), on(teal)), (IDs.tube(7), on(teal)),
            (IDs.tube(5), on(blue)), (IDs.tube(8), on(blue)), (IDs.tube(6), on(blue)),
            (IDs.tube(2), on(pink)), (IDs.tube(3), on(pink)), (IDs.tube(4), on(pink)),
            (IDs.p1, on(.white, 0.3)),
            (IDs.pn1, FixtureState(intensity: 0.7, color: .kelvin(5600, tint: 0))),
        ])
        look("Blackout", fade: 0.8, [])
        look("Deep Blue", [
            (IDs.tube(1), on(deepBlue)), (IDs.tube(2), on(deepBlue)), (IDs.tube(3), on(deepBlue)),
            (IDs.tube(4), on(deepBlue)), (IDs.tube(5), on(deepBlue)), (IDs.tube(6), on(deepBlue, 0.6)),
            (IDs.tube(7), on(deepBlue, 0.6)), (IDs.tube(8), on(deepBlue, 0.6)),
            (IDs.pn1, FixtureState(intensity: 0.5, color: .kelvin(6500, tint: 0))),
        ])
        look("White Background", (1...8).map { (IDs.tube($0), FixtureState(intensity: 1, color: .kelvin(5600, tint: 0))) }
             + [(IDs.pn1, FixtureState(intensity: 0.8, color: .kelvin(5600, tint: 0))), (IDs.p1, on(.white, 1))])
        look("Gray Background", (1...8).map { (IDs.tube($0), FixtureState(intensity: 0.35, color: .kelvin(5000, tint: 0))) }
             + [(IDs.pn1, FixtureState(intensity: 0.8, color: .kelvin(5600, tint: 0)))])
        look("Orange to Pink Gradient", folder: randomFolder.id, (1...8).map { (IDs.tube($0), gradient(orange, pink)) }
             + [(IDs.pn1, FixtureState(intensity: 0.6, color: .kelvin(3800, tint: 0)))])
        look("Blue Gradient", folder: randomFolder.id, (1...8).map { (IDs.tube($0), gradient(cyan, deepBlue)) })
        look("Salmon Background", folder: randomFolder.id, (1...8).map { (IDs.tube($0), on(salmon, 0.9)) }
             + [(IDs.pn1, FixtureState(intensity: 0.7, color: .kelvin(4500, tint: 0)))])
        look("Greenscreen", folder: randomFolder.id, (1...8).map { (IDs.tube($0), on(green, 1)) }
             + [(IDs.pn1, FixtureState(intensity: 0.9, color: .kelvin(5600, tint: 0)))])

        var stage = StageSettings(
            width: 5.2, height: 9.2,
            props: [StageProp(kind: .person, label: "Subject", transform: StageTransform(x: 2.55, y: 6.5))])
        stage.showLabels = true

        var project = Project(name: "London Studio", fixtures: fixtures, groups: groups, looks: looks,
                              folders: [randomFolder, coolFolder], stage: stage)
        project.notes = "Demo rig modelled on the owner's studio (generic profiles)."
        if let chill = looks.first {
            project.lastLive = LiveSnapshot(base: chill.states, activeLookID: chill.id)
        }
        return project
    }
}
