import SwiftUI
import PrismCore

/// Live view of all 512 channels of one universe (Hardware Test, step 3): each cell shows the
/// value Prism is sending right now, tinted by the light that owns the channel, with overlapping
/// patches outlined in red. Point at a cell to see the light and channel; click to pin it.
struct ChannelMonitorView: View {
    @Environment(AppModel.self) private var app
    let model: HardwareTestModel

    var body: some View {
        let universes = app.outputs.usedUniverses
        let universe = universes.contains(model.monitorUniverse) ? model.monitorUniverse : (universes.first ?? 1)
        let fixtures = app.show.resolvedFixtures
        let map = ChannelMap(universe: universe, fixtures: fixtures)

        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                StepIntro(title: "Channel monitor",
                          text: "Exactly what Prism is sending right now. Colors show which light uses each channel.")
                Spacer(minLength: 0)
                if universes.count > 1 {
                    Picker("Universe", selection: Binding(get: { universe }, set: { model.monitorUniverse = $0 })) {
                        ForEach(universes, id: \.self) { u in Text("Universe \(u)").tag(u) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
            }

            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let frame = app.outputs.latestFrame(universe: universe)
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ChannelGrid(frame: frame, map: map, selected: model.selectedAddress, hovered: model.hoveredAddress,
                                onHover: { address in
                                    if model.hoveredAddress != address { model.hoveredAddress = address }
                                },
                                onSelect: { address in
                                    model.selectedAddress = model.selectedAddress == address ? nil : address
                                })
                    detailLine(frame: frame, map: map)
                }
            }

            legend(map: map, fixtures: fixtures)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private func detailLine(frame: [UInt8], map: ChannelMap) -> some View {
        let address = model.hoveredAddress ?? model.selectedAddress
        HStack(spacing: Theme.Space.s) {
            if let address {
                let value = address >= 1 && address <= frame.count ? frame[address - 1] : 0
                Text("Address \(address)")
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
                if let owner = map.owner(at: address) {
                    Circle().fill(ChannelGrid.tint(owner.colorIndex)).frame(width: 8, height: 8)
                    Text("\(owner.fixtureName) · \(owner.channelName)")
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                } else {
                    Text("Not used by any light")
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: Theme.Space.s)
                if map.conflicts.contains(address) {
                    Label("Two lights use this address", systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Font.captionStrong)
                        .foregroundStyle(Theme.danger)
                }
                Text("\(value)")
                    .font(Theme.Font.number(15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(Int((Double(value) / 255 * 100).rounded()))%")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            } else {
                Image(systemName: "cursorarrow.rays")
                    .foregroundStyle(Theme.textTertiary)
                Text("Point at a channel to see which light uses it.")
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: Theme.Space.s)
                Text("\(map.usedChannelCount) of 512 channels in use")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .font(Theme.Font.body)
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Theme.panelRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).strokeBorder(Theme.stroke))
    }

    // MARK: - Legend

    @ViewBuilder
    private func legend(map: ChannelMap, fixtures: [ResolvedFixture]) -> some View {
        let byID = Dictionary(fixtures.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        HStack(spacing: Theme.Space.s) {
            if !map.conflicts.isEmpty {
                Label("\(map.conflicts.count) channels are used by two lights — check addresses in Patch",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Font.captionStrong)
                    .foregroundStyle(Theme.danger)
                    .lineLimit(1)
            } else if map.fixtureIDs.isEmpty {
                Text("No lights are patched in this universe.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(map.fixtureIDs.enumerated()), id: \.element) { index, id in
                            if let rf = byID[id] {
                                Button {
                                    model.selectedAddress = rf.fixture.address
                                } label: {
                                    HStack(spacing: 5) {
                                        Circle().fill(ChannelGrid.tint(index)).frame(width: 7, height: 7)
                                        Text(rf.fixture.stageLabel)
                                            .font(Theme.Font.captionStrong)
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Theme.control))
                                }
                                .buttonStyle(.plain)
                                .help("\(rf.fixture.name) · address \(rf.fixture.address ?? 0)")
                            }
                        }
                    }
                }
            }
        }
        .frame(height: 22)
    }
}

/// The 32 × 16 grid, drawn with Canvas (cheap at 10 Hz).
private struct ChannelGrid: View {
    let frame: [UInt8]
    let map: ChannelMap
    let selected: Int?
    let hovered: Int?
    let onHover: (Int?) -> Void
    let onSelect: (Int) -> Void

    static let columns = 32
    static let rows = 16
    static let labelWidth: CGFloat = 30
    static let headerHeight: CGFloat = 14
    static let gap: CGFloat = 2
    static let cellHeight: CGFloat = 21
    static var height: CGFloat { headerHeight + CGFloat(rows) * cellHeight + CGFloat(rows - 1) * gap }

    /// Alternating tints so neighbouring lights stand apart.
    static let palette: [Color] = [Theme.accent, Theme.remote, Theme.music, Theme.success, Theme.warning, Color(hex: 0xF472B6)]
    static func tint(_ index: Int) -> Color { palette[((index % palette.count) + palette.count) % palette.count] }

    struct Layout {
        let width: CGFloat

        var cellWidth: CGFloat {
            max(8, (width - ChannelGrid.labelWidth - ChannelGrid.gap * CGFloat(ChannelGrid.columns - 1)) / CGFloat(ChannelGrid.columns))
        }

        /// Cell rectangle for a 0-based channel index.
        func rect(_ index: Int) -> CGRect {
            let col = index % ChannelGrid.columns, row = index / ChannelGrid.columns
            return CGRect(x: ChannelGrid.labelWidth + CGFloat(col) * (cellWidth + ChannelGrid.gap),
                          y: ChannelGrid.headerHeight + CGFloat(row) * (ChannelGrid.cellHeight + ChannelGrid.gap),
                          width: cellWidth, height: ChannelGrid.cellHeight)
        }

        /// 1-based address under a point, if any.
        func address(at p: CGPoint) -> Int? {
            let x = p.x - ChannelGrid.labelWidth, y = p.y - ChannelGrid.headerHeight
            guard x >= 0, y >= 0 else { return nil }
            let col = Int(x / (cellWidth + ChannelGrid.gap)), row = Int(y / (ChannelGrid.cellHeight + ChannelGrid.gap))
            guard col < ChannelGrid.columns, row < ChannelGrid.rows else { return nil }
            return row * ChannelGrid.columns + col + 1
        }
    }

    var body: some View {
        GeometryReader { geo in
            let layout = Layout(width: geo.size.width)
            Canvas { context, _ in draw(&context, layout: layout) }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): onHover(layout.address(at: point))
                    case .ended: onHover(nil)
                    }
                }
                .onTapGesture { location in
                    if let address = layout.address(at: location) { onSelect(address) }
                }
        }
        .frame(height: Self.height)
    }

    private func draw(_ context: inout GraphicsContext, layout: Layout) {
        let labelFont = Font.system(size: 9, weight: .medium).monospacedDigit()
        // Column numbers.
        for col in 0..<Self.columns where col == 0 || (col + 1) % 4 == 0 {
            let r = layout.rect(col)
            context.draw(Text("\(col + 1)").font(labelFont).foregroundStyle(Theme.textTertiary),
                         at: CGPoint(x: r.midX, y: Self.headerHeight / 2 - 1), anchor: .center)
        }
        // Row start addresses.
        for row in 0..<Self.rows {
            let r = layout.rect(row * Self.columns)
            context.draw(Text("\(row * Self.columns + 1)").font(labelFont).foregroundStyle(Theme.textTertiary),
                         at: CGPoint(x: Self.labelWidth - 6, y: r.midY), anchor: .trailing)
        }

        let focus = (hovered ?? selected).flatMap { map.owner(at: $0)?.fixtureID }
        let valueFont = Font.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit()
        var texts: [UInt8: GraphicsContext.ResolvedText] = [:]
        for index in 0..<(Self.columns * Self.rows) {
            let address = index + 1
            let value: UInt8 = index < frame.count ? frame[index] : 0
            let owner = index < map.owners.count ? map.owners[index] : nil
            let tint = owner.map { Self.tint($0.colorIndex) }
            let r = layout.rect(index)
            let cell = Path(roundedRect: r, cornerRadius: 3, style: .continuous)

            context.fill(cell, with: .color(tint?.opacity(0.14) ?? Color.white.opacity(0.035)))
            if value > 0 {
                let h = r.height * CGFloat(value) / 255
                let bar = CGRect(x: r.minX, y: r.maxY - h, width: r.width, height: h)
                context.fill(Path(roundedRect: bar, cornerRadius: 3, style: .continuous),
                             with: .color((tint ?? Theme.textSecondary).opacity(0.5)))
            }
            if owner != nil || value > 0 {
                let text: GraphicsContext.ResolvedText
                if let cached = texts[value] {
                    text = cached
                } else {
                    text = context.resolve(Text("\(value)").font(valueFont)
                        .foregroundStyle(value > 0 ? Theme.textPrimary : Theme.textTertiary))
                    texts[value] = text
                }
                context.draw(text, at: CGPoint(x: r.midX, y: r.midY), anchor: .center)
            }
            if let owner, owner.fixtureID == focus {
                context.stroke(cell, with: .color(Self.tint(owner.colorIndex).opacity(0.9)), lineWidth: 1)
            }
            if map.conflicts.contains(address) {
                context.stroke(cell, with: .color(Theme.danger), lineWidth: 1.5)
            }
            if address == selected {
                context.stroke(cell, with: .color(.white), lineWidth: 1.5)
            } else if address == hovered {
                context.stroke(cell, with: .color(.white.opacity(0.55)), lineWidth: 1)
            }
        }
    }
}
