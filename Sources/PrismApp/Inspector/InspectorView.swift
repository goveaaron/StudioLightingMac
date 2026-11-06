import SwiftUI
import PrismCore

/// Inspector for the selected lights: brightness, exact color (hex / RGB), white balance
/// (Kelvin + green/magenta tint), quick swatches, identify, patch info.
///
/// OWNER: Inspector workstream (adds color wheel, HSB, gels, eyedropper, per-pixel editor,
/// effects section, multi-selection relative edits, color history, favorites).
struct InspectorView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let ids = app.show.selectedIDs()
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if ids.isEmpty {
                    EmptyStateView(systemImage: "cursorarrow.click.2", title: "No Selection",
                                   message: "Click a light on the stage to adjust it. Shift-click to select several.")
                        .frame(minHeight: 320)
                } else {
                    InspectorHeader(ids: ids)
                    IntensitySection(ids: ids)
                    ColorSection(ids: ids)
                    WhiteBalanceSection(ids: ids)
                    if ids.count == 1, let rf = app.show.resolved(ids[0]) {
                        FixtureInfoSection(rf: rf)
                    }
                }
            }
            .padding(Theme.Space.l)
        }
        .background(Theme.panel)
    }
}

private struct InspectorHeader: View {
    @Environment(AppModel.self) private var app
    let ids: [UUID]

    var body: some View {
        let names = ids.compactMap { app.show.project.fixture($0)?.name }
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ids.count == 1 ? (names.first ?? "Light") : "\(ids.count) lights")
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if ids.count > 1 {
                    Text(names.prefix(4).joined(separator: ", ") + (names.count > 4 ? "…" : ""))
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                } else if let f = app.show.project.fixture(ids[0]) {
                    Text(f.role.displayName).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            Button {
                app.show.identify(ids)
            } label: {
                Label("Identify", systemImage: "light.beacon.max")
            }
            .buttonStyle(.pill(compact: true))
            .help("Flash these lights so you can spot them in the room")
        }
    }
}

private struct IntensitySection: View {
    @Environment(AppModel.self) private var app
    let ids: [UUID]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Brightness", systemImage: "sun.max")
            let current = ids.map { app.show.state(of: $0).intensity }.reduce(0, +) / Double(max(ids.count, 1))
            PrismSlider(
                value: Binding(get: { current }, set: { v in
                    app.show.updateStates(ids, undoName: "Brightness", coalesceKey: "intensity") { _, s in s.intensity = v }
                }),
                label: "Intensity", tint: Color(hex: 0xF5F5F5), height: 30)
            HStack(spacing: 6) {
                ForEach([0, 25, 50, 75, 100], id: \.self) { pct in
                    Button("\(pct)%") {
                        app.show.updateStates(ids, undoName: "Brightness") { _, s in s.intensity = Double(pct) / 100 }
                    }
                    .buttonStyle(.pill(compact: true))
                }
            }
        }
    }
}

private struct ColorSection: View {
    @Environment(AppModel.self) private var app
    let ids: [UUID]

    static let swatches = ["#FF2FB4", "#FF4FD8", "#B36BFF", "#7A2BFF", "#1F4BFF", "#14D8F0",
                           "#00C2A8", "#00FF3C", "#FFE14D", "#FF7A1A", "#FF3B30", "#FFFFFF"]

    var body: some View {
        let first = app.show.state(of: ids[0])
        let rgb = first.color.displayRGB
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Color", systemImage: "paintpalette")
            HStack(spacing: Theme.Space.s) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(rgb))
                    .frame(width: 44, height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.2)))
                    .shadow(color: Color(rgb).opacity(0.6), radius: 8)
                VStack(alignment: .leading, spacing: 6) {
                    HexField(hex: rgb.hex) { new in
                        app.show.updateStates(ids, undoName: "Color") { _, s in
                            s.color = .rgb(new); s.cells = nil
                            if s.intensity < 0.01 { s.intensity = 0.8 }
                        }
                    }
                    Text(first.color.label).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            channelSlider("R", value: rgb.r, tint: .red) { v in RGBColor(r: v, g: rgb.g, b: rgb.b) }
            channelSlider("G", value: rgb.g, tint: .green) { v in RGBColor(r: rgb.r, g: v, b: rgb.b) }
            channelSlider("B", value: rgb.b, tint: .blue) { v in RGBColor(r: rgb.r, g: rgb.g, b: v) }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 8), count: 6), spacing: 8) {
                ForEach(Self.swatches, id: \.self) { hex in
                    let c = RGBColor(hex: hex)!
                    ColorSwatch(color: Color(c), size: 20, isSelected: rgb.hex == c.hex)
                        .onTapGesture {
                            app.show.updateStates(ids, undoName: "Color") { _, s in
                                s.color = .rgb(c); s.cells = nil
                                if s.intensity < 0.01 { s.intensity = 0.8 }
                            }
                        }
                        .help(hex)
                }
            }
        }
    }

    private func channelSlider(_ name: String, value: Double, tint: Color, make: @escaping (Double) -> RGBColor) -> some View {
        PrismSlider(
            value: Binding(get: { value }, set: { v in
                let c = make(v)
                app.show.updateStates(ids, undoName: "Color", coalesceKey: "rgb-\(name)") { _, s in
                    s.color = .rgb(c); s.cells = nil
                }
            }),
            step: 1.0 / 255.0,
            label: name,
            format: { "\(Int(($0 * 255).rounded()))" },
            parse: { Double($0.trimmingCharacters(in: .whitespaces)).map { $0 / 255 } },
            tint: tint, height: 22)
    }
}

private struct WhiteBalanceSection: View {
    @Environment(AppModel.self) private var app
    let ids: [UUID]

    static func whiteValues(_ color: LightColor) -> (Double, Double) {
        if case .kelvin(let k, let t) = color { return (k, t) }
        let a = color.approximateKelvin
        return (a.kelvin, a.tint)
    }

    var body: some View {
        let (kelvin, tint) = Self.whiteValues(app.show.state(of: ids[0]).color)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("White Balance", systemImage: "thermometer.sun")
            PrismSlider(
                value: Binding(get: { kelvin }, set: { k in
                    app.show.updateStates(ids, undoName: "White Balance", coalesceKey: "kelvin") { _, s in
                        var t = 0.0
                        if case .kelvin(_, let old) = s.color { t = old }
                        s.color = .kelvin(k, tint: t); s.cells = nil
                        if s.intensity < 0.01 { s.intensity = 0.8 }
                    }
                }),
                range: 1700...12000, step: 50, label: "Kelvin",
                format: { "\(Int($0.rounded()))K" },
                track: AnyView(LinearGradient(colors: stride(from: 1700.0, through: 12000, by: 1300).map { Color(LightColor.kelvin($0, tint: 0)) },
                                              startPoint: .leading, endPoint: .trailing)),
                height: 26)
            PrismSlider(
                value: Binding(get: { tint }, set: { t in
                    app.show.updateStates(ids, undoName: "Tint", coalesceKey: "tint") { _, s in
                        var k = 5600.0
                        if case .kelvin(let old, _) = s.color { k = old } else { k = s.color.approximateKelvin.kelvin }
                        s.color = .kelvin(k, tint: t); s.cells = nil
                    }
                }),
                range: -1...1, step: 0.01, label: "Tint",
                format: { v in v == 0 ? "0" : (v < 0 ? "\(Int((-v * 100).rounded())) G" : "\(Int((v * 100).rounded())) M") },
                track: AnyView(LinearGradient(colors: [Color(hex: 0x6BFF7A), Color(hex: 0xF4F1EA), Color(hex: 0xFF7AE0)],
                                              startPoint: .leading, endPoint: .trailing)),
                height: 26)
            HStack(spacing: 6) {
                ForEach([2700, 3200, 4300, 5600, 6500], id: \.self) { k in
                    Button("\(k)K") {
                        app.show.updateStates(ids, undoName: "White Balance") { _, s in
                            s.color = .kelvin(Double(k), tint: 0); s.cells = nil
                            if s.intensity < 0.01 { s.intensity = 0.8 }
                        }
                    }
                    .buttonStyle(.pill(compact: true))
                }
            }
        }
    }
}

private struct FixtureInfoSection: View {
    let rf: ResolvedFixture

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Fixture", systemImage: "info.circle")
            row("Type", rf.definition.displayName)
            row("Mode", "\(rf.mode.name) · \(rf.channelCount) ch")
            if let range = rf.addressRange {
                row("DMX", "Universe \(rf.fixture.universe) · \(range.lowerBound)–\(range.upperBound)")
            } else {
                row("DMX", "Not patched")
            }
            if rf.cellCount > 0 { row("Pixels", "\(rf.cellCount)") }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            Spacer()
            Text(v).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
    }
}
