import Foundation

public enum FixtureImportError: Error, LocalizedError, Sendable {
    case unreadableFile(String)
    case unsupportedFormat(String)
    case noValidModes(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let msg): return "Could not read fixture file: \(msg)"
        case .unsupportedFormat(let msg): return "Unsupported fixture format: \(msg)"
        case .noValidModes(let msg): return "Fixture has no valid DMX modes (1–512 channels): \(msg)"
        }
    }
}

/// Imports and exports fixture profiles in Prism native (`.prismfixture` / `.json`),
/// Open Fixture Library (`.json`), and QLC+ (`.qxf` XML) formats.
public struct FixtureImporter: Sendable {

    /// Exports a single `FixtureDefinition` as pretty-printed `.prismfixture` JSON data.
    public static func exportPrismFixture(_ definition: FixtureDefinition) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(definition)
    }

    /// Imports one or more fixture definitions from a file URL (`.prismfixture`, `.json`, or `.qxf`).
    public static func importFile(at url: URL) throws -> [FixtureDefinition] {
        guard let data = try? Data(contentsOf: url) else {
            throw FixtureImportError.unreadableFile(url.lastPathComponent)
        }
        return try importData(data, filename: url.lastPathComponent)
    }

    /// Imports one or more fixture definitions from raw data.
    public static func importData(_ data: Data, filename: String = "") throws -> [FixtureDefinition] {
        let lowerName = filename.lowercased()
        if lowerName.hasSuffix(".qxf") || looksLikeXML(data) {
            let def = try parseQLCPlusXML(data, filename: filename)
            return try validateDefinitions([def], context: filename)
        }

        // Check if this is a raw Open Fixture Library (OFL) fixture JSON before trying Prism native
        if let rawObj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let schema = (rawObj["$schema"] as? String) ?? ""
            if schema.contains("open-fixture-library") || rawObj["availableChannels"] != nil {
                let def = try parseOFLJSON(rawObj, filename: filename)
                return try validateDefinitions([def], context: filename)
            }
        }

        let decoder = JSONDecoder()
        if let file = try? decoder.decode(FixtureDefinitionFile.self, from: data), !file.fixtures.isEmpty {
            return try validateDefinitions(file.fixtures, context: filename)
        }
        if let single = try? decoder.decode(FixtureDefinition.self, from: data), !single.modes.isEmpty {
            return try validateDefinitions([single], context: filename)
        }
        if let list = try? decoder.decode([FixtureDefinition].self, from: data), !list.isEmpty {
            return try validateDefinitions(list, context: filename)
        }

        throw FixtureImportError.unsupportedFormat(filename.isEmpty ? "Unknown data" : filename)
    }

    private static func validateDefinitions(_ defs: [FixtureDefinition], context: String) throws -> [FixtureDefinition] {
        var out: [FixtureDefinition] = []
        for var d in defs {
            d.modes = d.modes.filter { !$0.channels.isEmpty && $0.channels.count <= 512 }
            if d.modes.isEmpty { continue }
            if d.modes.allSatisfy({ !$0.recommended }) {
                d.modes[0].recommended = true
            }
            out.append(d)
        }
        guard !out.isEmpty else {
            throw FixtureImportError.noValidModes(context)
        }
        return out
    }

    private static func looksLikeXML(_ data: Data) -> Bool {
        guard let prefix = String(data: data.prefix(256), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return prefix.hasPrefix("<?xml") || prefix.hasPrefix("<FixtureDefinition") || prefix.hasPrefix("<!DOCTYPE")
    }

    // MARK: - Raw Open Fixture Library (OFL) JSON Converter

    private static func parseOFLJSON(_ obj: [String: Any], filename: String) throws -> FixtureDefinition {
        let model = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Imported Fixture"
        let stem = (filename as NSString).deletingPathExtension
        let manufacturer = (obj["manufacturer"] as? String)
            ?? (obj["manufacturerKey"] as? String)?.capitalized
            ?? "Custom"
        let id = FixtureDefinition.makeID(manufacturer: manufacturer, model: model.isEmpty ? stem : model)

        var aliases: [String] = []
        if let shortName = obj["shortName"] as? String, !shortName.isEmpty, shortName != model {
            aliases.append(shortName)
        }

        // Parse matrix pixel count if present
        var pixelKeys: [String] = []
        if let matrix = obj["matrix"] as? [String: Any] {
            if let counts = matrix["pixelCount"] as? [Int], counts.count == 3 {
                let total = max(1, counts[0]) * max(1, counts[1]) * max(1, counts[2])
                pixelKeys = (1...min(total, 512)).map(String.init)
            } else if let pks = matrix["pixelKeys"] as? [[[String?]]] {
                for z in pks {
                    for y in z {
                        for x in y {
                            if let k = x { pixelKeys.append(k) }
                        }
                    }
                }
            }
        }

        // Build channel registry from availableChannels + templateChannels
        var channelMap: [String: (ChannelDefinition, Int?)] = [:]
        let avail = (obj["availableChannels"] as? [String: [String: Any]]) ?? [:]
        for (key, cj) in avail {
            let def = parseOFLChannel(key: key, json: cj, cell: nil)
            channelMap[key] = (def, nil)
            if let fines = cj["fineChannelAliases"] as? [String], let firstFine = fines.first {
                var fineDef = def
                fineDef.label = "\(def.label ?? def.kind.defaultLabel) Fine"
                fineDef.fine = true
                channelMap[firstFine] = (fineDef, nil)
            }
        }

        let templates = (obj["templateChannels"] as? [String: [String: Any]]) ?? [:]
        for (tkey, tj) in templates {
            for (idx, pk) in pixelKeys.enumerated() {
                let resolvedKey = tkey.replacingOccurrences(of: "$pixelKey", with: pk)
                var def = parseOFLChannel(key: resolvedKey, json: tj, cell: idx)
                def.label = def.label?.replacingOccurrences(of: "$pixelKey", with: pk)
                channelMap[resolvedKey] = (def, idx)
                if let fines = tj["fineChannelAliases"] as? [String], let firstFine = fines.first {
                    let fineKey = firstFine.replacingOccurrences(of: "$pixelKey", with: pk)
                    var fineDef = def
                    fineDef.label = "\(def.label ?? def.kind.defaultLabel) Fine"
                    fineDef.fine = true
                    channelMap[fineKey] = (fineDef, idx)
                }
            }
        }

        // Parse modes
        guard let rawModes = obj["modes"] as? [[String: Any]], !rawModes.isEmpty else {
            throw FixtureImportError.unsupportedFormat("OFL JSON missing modes")
        }

        var modes: [FixtureMode] = []
        for rm in rawModes {
            let mName = (rm["name"] as? String) ?? "Default"
            let mShort = rm["shortName"] as? String
            guard let rawChans = rm["channels"] as? [Any] else { continue }
            var chans: [ChannelDefinition] = []
            for item in rawChans {
                if let chKey = item as? String {
                    if let (def, _) = channelMap[chKey] {
                        chans.append(def)
                    } else {
                        chans.append(ChannelDefinition(kind: inferKindFromName(chKey), label: chKey))
                    }
                } else if item is NSNull {
                    chans.append(ChannelDefinition(kind: .nothing, label: "Unused"))
                } else if let matrixInsert = item as? [String: Any],
                          (matrixInsert["insert"] as? String) == "matrixChannels",
                          let tList = matrixInsert["templateChannels"] as? [Any] {
                    let order = (matrixInsert["channelOrder"] as? String) ?? "perPixel"
                    let pks = pixelKeys.isEmpty ? ["1"] : pixelKeys
                    if order == "perPixel" {
                        for (idx, pk) in pks.enumerated() {
                            for tItem in tList {
                                guard let tKey = tItem as? String else {
                                    chans.append(ChannelDefinition(kind: .nothing, label: "Unused"))
                                    continue
                                }
                                let rKey = tKey.replacingOccurrences(of: "$pixelKey", with: pk)
                                if let (def, _) = channelMap[rKey] {
                                    chans.append(def)
                                } else {
                                    chans.append(ChannelDefinition(kind: inferKindFromName(rKey), cell: idx, label: rKey))
                                }
                            }
                        }
                    } else {
                        for tItem in tList {
                            for (idx, pk) in pks.enumerated() {
                                guard let tKey = tItem as? String else {
                                    chans.append(ChannelDefinition(kind: .nothing, label: "Unused"))
                                    continue
                                }
                                let rKey = tKey.replacingOccurrences(of: "$pixelKey", with: pk)
                                if let (def, _) = channelMap[rKey] {
                                    chans.append(def)
                                } else {
                                    chans.append(ChannelDefinition(kind: inferKindFromName(rKey), cell: idx, label: rKey))
                                }
                            }
                        }
                    }
                }
            }
            if !chans.isEmpty && chans.count <= 512 {
                modes.append(FixtureMode(name: mName, shortName: mShort, channels: chans))
            }
        }

        let cats = (obj["categories"] as? [String]) ?? []
        let allKinds = Set(modes.flatMap { $0.channels.map(\.kind) })
        let cat = inferCategory(model: model, categories: cats, kinds: allKinds)

        var authors: [String]?
        if let meta = obj["meta"] as? [String: Any], let a = meta["authors"] as? [String] {
            authors = a
        }

        return FixtureDefinition(
            id: id,
            manufacturer: manufacturer,
            model: model,
            category: cat,
            aliases: aliases,
            modes: modes,
            source: "ofl",
            verification: .community,
            sourceInfo: FixtureSource(kind: "ofl", license: "MIT", authors: authors)
        )
    }

    private static func parseOFLChannel(key: String, json: [String: Any], cell: Int?) -> ChannelDefinition {
        let name = (json["name"] as? String) ?? key
        var caps: [[String: Any]] = []
        if let single = json["capability"] as? [String: Any] {
            caps = [single]
        } else if let list = json["capabilities"] as? [[String: Any]] {
            caps = list
        }

        var kind: ChannelKind = .generic
        var physRange: PhysicalRange?
        var outCaps: [ChannelCapability] = []

        for c in caps {
            let ctype = (c["type"] as? String) ?? "Generic"
            let mapped = mapOFLCapabilityType(ctype, color: c["color"] as? String, shutterEffect: c["shutterEffect"] as? String)
            if kind == .generic && mapped != .nothing {
                kind = mapped
            }
            if let rng = c["dmxRange"] as? [Int], rng.count == 2 {
                let label = (c["comment"] as? String) ?? (c["effectName"] as? String) ?? ctype
                outCaps.append(ChannelCapability(from: clampByte(rng[0]), to: clampByte(rng[1]), label: label))
            }
            if mapped == .cct, physRange == nil {
                if let s = c["colorTemperatureStart"] as? String, let e = c["colorTemperatureEnd"] as? String,
                   let sv = Double(s.replacingOccurrences(of: "K", with: "")),
                   let ev = Double(e.replacingOccurrences(of: "K", with: "")) {
                    physRange = PhysicalRange(from: sv, to: ev, unit: "K")
                }
            }
        }

        if kind == .generic || kind == .intensity || kind == .control {
            let inferred = inferKindFromName(name)
            if inferred != .generic {
                if kind != .intensity || [.cct, .tint, .hue, .saturation, .crossfade].contains(inferred) {
                    kind = inferred
                }
            }
        }

        var defVal: UInt8 = 0
        if let dv = json["defaultValue"] as? Int {
            defVal = UInt8(clamping: dv)
        } else if kind == .pan || kind == .tilt || kind == .tint {
            defVal = 128
        }

        let isAdv = Self.advancedKinds.contains(kind)
        return ChannelDefinition(
            kind: kind,
            fine: false,
            cell: cell,
            label: name,
            defaultValue: defVal,
            physical: physRange,
            capabilities: outCaps.isEmpty ? nil : outCaps,
            advanced: isAdv
        )
    }

    private static func mapOFLCapabilityType(_ type: String, color: String?, shutterEffect: String?) -> ChannelKind {
        switch type {
        case "NoFunction": return .nothing
        case "Intensity": return .intensity
        case "ColorIntensity":
            switch color {
            case "Red": return .red
            case "Green": return .green
            case "Blue": return .blue
            case "White": return .white
            case "Warm White": return .warmWhite
            case "Cold White": return .coolWhite
            case "Amber": return .amber
            case "Lime": return .lime
            case "Cyan": return .cyan
            case "Magenta": return .magenta
            case "Yellow": return .yellow
            case "UV": return .uv
            case "Indigo": return .indigo
            default: return .generic
            }
        case "ColorTemperature": return .cct
        case "ColorPreset", "WheelSlot", "WheelShake": return .colorMacro
        case "ShutterStrobe":
            if shutterEffect == "Open" || shutterEffect == "Closed" { return .shutter }
            return .strobe
        case "StrobeSpeed", "StrobeDuration": return .strobe
        case "Pan", "PanContinuous": return .pan
        case "Tilt", "TiltContinuous": return .tilt
        case "PanTiltSpeed": return .effectSpeed
        case "Effect", "EffectParameter", "SoundSensitivity": return .effect
        case "EffectSpeed", "EffectDuration": return .effectSpeed
        case "BeamAngle", "Zoom": return .zoom
        case "Focus": return .focus
        case "Iris", "IrisEffect": return .iris
        case "Frost", "FrostEffect": return .generic
        case "Prism": return .prism
        case "PrismRotation": return .prism
        case "Fog", "FogOutput", "FogType": return .generic
        case "Speed", "Time": return .effectSpeed
        case "Rotation": return .effectSpeed
        case "Maintenance": return .control
        default: return .generic
        }
    }

    // MARK: - QLC+ (.qxf) XML Parser (Portable Pure-Swift Scanner)

    private static func parseQLCPlusXML(_ data: Data, filename: String) throws -> FixtureDefinition {
        guard let xml = String(data: data, encoding: .utf8) else {
            throw FixtureImportError.unreadableFile(filename)
        }
        guard xml.contains("<FixtureDefinition") else {
            throw FixtureImportError.unsupportedFormat("Not a QLC+ FixtureDefinition XML file")
        }

        let manufacturer = extractTagText(xml, tag: "Manufacturer") ?? "Unknown"
        let model = extractTagText(xml, tag: "Model") ?? ((filename as NSString).deletingPathExtension)
        let qtype = extractTagText(xml, tag: "Type") ?? "Other"
        let author = extractTagText(xml, tag: "Author")

        // Parse <Channel ...> blocks
        var channelByName: [String: ChannelDefinition] = [:]
        for chBlock in extractBlocks(xml, tag: "Channel", topLevelOnly: true) {
            guard let name = extractAttribute(chBlock.openTag, attr: "Name") else { continue }
            let preset = extractAttribute(chBlock.openTag, attr: "Preset") ?? ""
            let defAttr = extractAttribute(chBlock.openTag, attr: "Default").flatMap(Int.init)
            let groupText = extractTagText(chBlock.inner, tag: "Group") ?? ""
            let groupOpen = extractFirstOpenTag(chBlock.inner, tag: "Group") ?? ""
            let byte = extractAttribute(groupOpen, attr: "Byte").flatMap(Int.init) ?? 0
            let colour = extractTagText(chBlock.inner, tag: "Colour") ?? ""

            var (kind, isFine) = mapQLCPreset(preset: preset, group: groupText, colour: colour, byte: byte)
            if [.generic, .intensity, .colorMacro, .effect, .white].contains(kind) {
                let inferred = inferKindFromName(name)
                if inferred != .generic {
                    if kind != .intensity || [.warmWhite, .coolWhite, .cct, .tint, .hue, .saturation, .crossfade].contains(inferred) {
                        kind = inferred
                    }
                }
            }

            var caps: [ChannelCapability] = []
            for capBlock in extractBlocks(chBlock.inner, tag: "Capability", topLevelOnly: false) {
                let cmin = extractAttribute(capBlock.openTag, attr: "Min").flatMap(Int.init) ?? 0
                let cmax = extractAttribute(capBlock.openTag, attr: "Max").flatMap(Int.init) ?? 255
                let label = unescapeXML(capBlock.inner.trimmingCharacters(in: .whitespacesAndNewlines))
                caps.append(ChannelCapability(from: clampByte(cmin), to: clampByte(cmax), label: label.isEmpty ? name : label))
            }

            let defaultVal: UInt8
            if let d = defAttr {
                defaultVal = UInt8(clamping: d)
            } else if (kind == .pan || kind == .tilt || kind == .tint) && !isFine {
                defaultVal = 128
            } else {
                defaultVal = 0
            }

            let isAdv = Self.advancedKinds.contains(kind)
            channelByName[unescapeXML(name)] = ChannelDefinition(
                kind: kind,
                fine: isFine,
                label: unescapeXML(name),
                defaultValue: defaultVal,
                capabilities: caps.isEmpty ? nil : caps,
                advanced: isAdv
            )
        }

        // Parse <Mode ...> blocks
        var modes: [FixtureMode] = []
        for modeBlock in extractBlocks(xml, tag: "Mode", topLevelOnly: false) {
            let modeName = unescapeXML(extractAttribute(modeBlock.openTag, attr: "Name") ?? "Default")
            let headBlocks = extractBlocks(modeBlock.inner, tag: "Head", topLevelOnly: false)
            var slotToCell: [Int: Int] = [:]
            if headBlocks.count > 1 {
                for (cellIdx, hb) in headBlocks.enumerated() {
                    for hc in extractBlocks(hb.inner, tag: "Channel", topLevelOnly: false) {
                        if let slot = Int(hc.inner.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            slotToCell[slot] = cellIdx
                        }
                    }
                }
            }

            // Extract mode channels (excluding <Channel> inside <Head>)
            let innerWithoutHeads = removeBlocks(modeBlock.inner, tag: "Head")
            let chBlocks = extractBlocks(innerWithoutHeads, tag: "Channel", topLevelOnly: false)
            var chans: [ChannelDefinition] = []
            for (idx, cb) in chBlocks.enumerated() {
                let chName = unescapeXML(cb.inner.trimmingCharacters(in: .whitespacesAndNewlines))
                var ch = channelByName[chName] ?? ChannelDefinition(kind: inferKindFromName(chName), label: chName.isEmpty ? "Ch \(idx + 1)" : chName)
                if let cell = slotToCell[idx] {
                    ch.cell = cell
                }
                chans.append(ch)
            }
            if !chans.isEmpty && chans.count <= 512 {
                modes.append(FixtureMode(name: modeName, channels: chans))
            }
        }

        let allKinds = Set(modes.flatMap { $0.channels.map(\.kind) })
        let cat = inferCategory(model: model, categories: [qtype], kinds: allKinds)
        let id = FixtureDefinition.makeID(manufacturer: manufacturer, model: model)
        let authors = author.map { [$0] }

        return FixtureDefinition(
            id: id,
            manufacturer: unescapeXML(manufacturer),
            model: unescapeXML(model),
            category: cat,
            modes: modes,
            source: "qlcplus",
            verification: .community,
            sourceInfo: FixtureSource(kind: "qlcplus", license: "Apache-2.0", authors: authors)
        )
    }

    private static func mapQLCPreset(preset: String, group: String, colour: String, byte: Int) -> (ChannelKind, Bool) {
        let fineFromByte = (byte > 0)
        let isFinePreset = preset.hasSuffix("Fine")
        let fine = fineFromByte || isFinePreset
        let basePreset = isFinePreset ? String(preset.dropLast(4)) : preset
        switch basePreset {
        case "IntensityMasterDimmer", "IntensityDimmer", "IntensityLightness", "IntensityValue":
            return (.intensity, fine)
        case "IntensityRed": return (.red, fine)
        case "IntensityGreen": return (.green, fine)
        case "IntensityBlue": return (.blue, fine)
        case "IntensityCyan": return (.cyan, fine)
        case "IntensityMagenta": return (.magenta, fine)
        case "IntensityYellow": return (.yellow, fine)
        case "IntensityAmber": return (.amber, fine)
        case "IntensityWhite": return (.white, fine)
        case "IntensityUV": return (.uv, fine)
        case "IntensityIndigo": return (.indigo, fine)
        case "IntensityLime": return (.lime, fine)
        case "IntensityHue", "ColorRGBMixer": return (.hue, fine)
        case "IntensitySaturation": return (.saturation, fine)
        case "PositionPan", "PositionXAxis": return (.pan, fine)
        case "PositionTilt", "PositionYAxis": return (.tilt, fine)
        case "ColorMacro", "ColorDoubleMacro", "ColorWheel": return (.colorMacro, fine)
        case "ColorCTOMixer", "ColorCTCMixer", "ColorCTBMixer": return (.cct, fine)
        case "GoboWheel": return (.gobo, fine)
        case "GoboIndex": return (.gobo, fine)
        case "ShutterStrobeSlowFast", "ShutterStrobeFastSlow": return (.strobe, fine)
        case "ShutterIrisMinToMax", "ShutterIrisMaxToMin": return (.iris, fine)
        case "BeamFocusNearFar", "BeamFocusFarNear": return (.focus, fine)
        case "BeamZoomSmallBig", "BeamZoomBigSmall": return (.zoom, fine)
        case "PrismRotationSlowFast", "PrismRotationFastSlow": return (.prism, fine)
        case "NoFunction": return (.nothing, false)
        default: break
        }
        if group == "Intensity" {
            switch colour {
            case "Red": return (.red, fine)
            case "Green": return (.green, fine)
            case "Blue": return (.blue, fine)
            case "Cyan": return (.cyan, fine)
            case "Magenta": return (.magenta, fine)
            case "Yellow": return (.yellow, fine)
            case "Amber": return (.amber, fine)
            case "White": return (.white, fine)
            case "Warm White": return (.warmWhite, fine)
            case "Cold White": return (.coolWhite, fine)
            case "UV": return (.uv, fine)
            case "Lime": return (.lime, fine)
            case "Indigo": return (.indigo, fine)
            default: return (.intensity, fine)
            }
        }
        switch group {
        case "Colour": return (.colorMacro, fine)
        case "Gobo": return (.gobo, fine)
        case "Prism": return (.prism, fine)
        case "Beam": return (.zoom, fine)
        case "Shutter": return (.strobe, fine)
        case "Speed": return (.effectSpeed, fine)
        case "Effect": return (.effect, fine)
        case "Maintenance": return (.control, fine)
        case "Pan": return (.pan, fine)
        case "Tilt": return (.tilt, fine)
        case "Nothing": return (.nothing, false)
        default: return (.generic, fine)
        }
    }

    // MARK: - Shared Heuristics & Lightweight XML Helpers

    private static func inferKindFromName(_ name: String) -> ChannelKind {
        let low = name.lowercased()
        if low.contains("warm white") || low == "ww" { return .warmWhite }
        if low.contains("cool white") || low.contains("cold white") || low == "cw" { return .coolWhite }
        if low.contains("tint") || low.contains("green/magenta") || low.contains("g/m") || low.contains("minus green") { return .tint }
        if low.contains("crossfade") || low.contains("cross fade") || low.contains("x-fade") { return .crossfade }
        if low.contains("hue") { return .hue }
        if low.contains("saturation") || low == "sat" { return .saturation }
        if low.contains("cie x") || low == "x" { return .cieX }
        if low.contains("cie y") || low == "y" { return .cieY }
        if low.contains("cct") || low.contains("kelvin") || low.contains("color temp") || low.contains("colour temp") { return .cct }
        if low.contains("strobe") || low.contains("flash") { return .strobe }
        if low.contains("shutter") { return .shutter }
        if low.contains("dimmer") || low.contains("intensity") || low.contains("master") { return .intensity }
        if low.contains("red") || low == "r" { return .red }
        if low.contains("green") || low == "g" { return .green }
        if low.contains("blue") || low == "b" { return .blue }
        if low.contains("white") || low == "w" { return .white }
        if low.contains("amber") { return .amber }
        if low.contains("lime") { return .lime }
        if low.contains("uv") || low.contains("ultraviolet") { return .uv }
        if low.contains("fan") { return .fan }
        // Fog/haze output stays generic so "all lights up" never fires the machine.
        if low.contains("fog") || low.contains("haze") || low.contains("smoke") { return .generic }
        if low.contains("zoom") { return .zoom }
        if low.contains("focus") { return .focus }
        if low.contains("effect") || low.contains("fx") || low.contains("macro") { return .effect }
        return .generic
    }

    private static let advancedKinds: Set<ChannelKind> = [.control, .effect, .effectSpeed, .effectParameter, .fan, .dimmerCurve]

    private static func inferCategory(model: String, categories: [String], kinds: Set<ChannelKind>) -> FixtureCategory {
        if kinds.contains(.pan) || kinds.contains(.tilt) || categories.contains("Moving Head") || categories.contains("Scanner") {
            return .movingHead
        }
        let lowModel = model.lowercased()
        if categories.contains("Smoke") || categories.contains("Hazer") || categories.contains("Fog")
            || lowModel.contains("fog") || lowModel.contains("hazer") || lowModel.contains("haze") {
            return .effect
        }
        let low = model.lowercased()
        if low.contains("tube") || low.contains("pavotube") || low.contains("titan") || low.contains("helios") || low.contains("pt4c") {
            return .tube
        }
        if low.contains("fresnel") || low.contains("orbiter") { return .fresnel }
        if low.contains("panel") || low.contains("skypanel") || low.contains("nova") || low.contains("gemini") || low.contains("celeb") {
            return .panel
        }
        if low.contains("par") || low.contains("slimpar") { return .par }
        if low.contains("strip") || low.contains("flex") { return .strip }
        if low.contains("bar") || low.contains("batten") || categories.contains("Pixel Bar") || categories.contains("LED Bar (Pixels)") {
            return .bar
        }
        if categories.contains("Dimmer") && kinds.isSubset(of: [.intensity, .nothing]) { return .dimmer }
        if categories.contains("Color Changer") { return .wash }
        return .spot
    }

    private static func clampByte(_ v: Int) -> Int { max(0, min(255, v)) }

    private struct XMLBlock {
        var openTag: String
        var inner: String
    }

    private static func extractBlocks(_ xml: String, tag: String, topLevelOnly: Bool) -> [XMLBlock] {
        var results: [XMLBlock] = []
        let openPrefix = "<\(tag)"
        let closeTag = "</\(tag)>"
        var searchStart = xml.startIndex
        while let openRange = xml.range(of: openPrefix, range: searchStart..<xml.endIndex) {
            let afterPrefix = openRange.upperBound
            if afterPrefix < xml.endIndex {
                let nextCh = xml[afterPrefix]
                if nextCh != " " && nextCh != ">" && nextCh != "/" && nextCh != "\t" && nextCh != "\n" && nextCh != "\r" {
                    searchStart = afterPrefix
                    continue
                }
            }
            guard let tagEnd = xml.range(of: ">", range: afterPrefix..<xml.endIndex) else { break }
            let openTagStr = String(xml[openRange.lowerBound..<tagEnd.upperBound])
            if openTagStr.hasSuffix("/>") {
                results.append(XMLBlock(openTag: openTagStr, inner: ""))
                searchStart = tagEnd.upperBound
            } else if let closeRange = xml.range(of: closeTag, range: tagEnd.upperBound..<xml.endIndex) {
                let innerStr = String(xml[tagEnd.upperBound..<closeRange.lowerBound])
                results.append(XMLBlock(openTag: openTagStr, inner: innerStr))
                searchStart = closeRange.upperBound
            } else {
                break
            }
        }
        return results
    }

    private static func removeBlocks(_ xml: String, tag: String) -> String {
        var out = xml
        let closeTag = "</\(tag)>"
        while let start = out.range(of: "<\(tag)"),
              let end = out.range(of: closeTag, range: start.upperBound..<out.endIndex) {
            out.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return out
    }

    private static func extractFirstOpenTag(_ xml: String, tag: String) -> String? {
        extractBlocks(xml, tag: tag, topLevelOnly: false).first?.openTag
    }

    private static func extractTagText(_ xml: String, tag: String) -> String? {
        guard let b = extractBlocks(xml, tag: tag, topLevelOnly: false).first else { return nil }
        let trimmed = unescapeXML(b.inner.trimmingCharacters(in: .whitespacesAndNewlines))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func extractAttribute(_ openTag: String, attr: String) -> String? {
        let pattern = "\(attr)=\""
        guard let r = openTag.range(of: pattern) else { return nil }
        let rest = openTag[r.upperBound...]
        guard let endQuote = rest.firstIndex(of: "\"") else { return nil }
        return unescapeXML(String(rest[..<endQuote]))
    }

    private static func unescapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&apos;", with: "'")
    }
}
