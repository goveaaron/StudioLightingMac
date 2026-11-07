import SwiftUI
import PrismCore

// MARK: - Light screen readout

/// The light's own display, drawn as a glowing LCD, showing exactly what it should read once set up.
struct LightScreenReadout: View {
    let walkthrough: SetupWalkthrough
    var compact = false

    private let lcd = Color(hex: 0x8CF5D8)

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            Text(walkthrough.usesDipSwitches ? "ADDRESS SWITCHES" : "DMX ADDRESS")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(lcd.opacity(0.6))
            if walkthrough.usesDipSwitches {
                DipSwitchStrip(switches: walkthrough.dipSwitches)
            } else {
                Text(walkthrough.addressReadout)
                    .font(.system(size: compact ? 28 : 44, weight: .semibold, design: .monospaced))
                    .foregroundStyle(lcd)
                    .shadow(color: lcd.opacity(0.55), radius: 8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Rectangle().fill(lcd.opacity(0.15)).frame(height: 1)
            Text("MODE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(lcd.opacity(0.6))
            Text(walkthrough.modeReadout)
                .font(.system(size: compact ? 12 : 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(lcd)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(compact ? 10 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x0C1814), Color(hex: 0x08100D)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(lcd.opacity(0.22))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The light should show address \(walkthrough.addressReadout), mode \(walkthrough.modeReadout)")
    }
}

// MARK: - DIP switches

/// Nine DIP switches (1 → 9, left to right) with the ON ones highlighted.
struct DipSwitchStrip: View {
    let switches: [Bool]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<9, id: \.self) { i in
                let on = i < switches.count && switches[i]
                VStack(spacing: 3) {
                    ZStack(alignment: on ? .top : .bottom) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.5))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(on ? Theme.accent : Color.white.opacity(0.35))
                            .frame(height: 9)
                            .padding(2)
                    }
                    .frame(width: 15, height: 26)
                    Text("\(i + 1)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(on ? Theme.accent : Theme.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Switches on: \(switches.enumerated().filter { $0.element }.map { "\($0.offset + 1)" }.joined(separator: ", "))")
    }
}

// MARK: - Button presses

/// "MENU › DMX Settings › DMX Address" drawn as hardware buttons and menu items.
struct PressChain: View {
    let presses: [String]
    var value: String?

    var body: some View {
        PatchWrapLayout(spacing: 4, lineSpacing: 5) {
            ForEach(Array(presses.enumerated()), id: \.offset) { i, press in
                HStack(spacing: 4) {
                    if i > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    PressKey(text: press)
                }
            }
            if let value {
                HStack(spacing: 4) {
                    if !presses.isEmpty {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Text(value)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.accentSoft))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.accent.opacity(0.45)))
                }
            }
        }
    }
}

/// One physical button (MENU, OK, ▲) or menu item (DMX Settings).
struct PressKey: View {
    let text: String

    private var isButton: Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return (t == t.uppercased() && t.count <= 8) || t.lowercased().hasPrefix("hold")
    }

    var body: some View {
        Text(text)
            .font(isButton ? Font.system(size: 10.5, weight: .bold, design: .rounded) : Font.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, isButton ? 8 : 7)
            .padding(.vertical, isButton ? 3.5 : 3)
            .background(
                RoundedRectangle(cornerRadius: isButton ? 6 : 5, style: .continuous)
                    .fill(isButton
                          ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x3A4152), Color(hex: 0x262B37)], startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Color.white.opacity(0.06)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: isButton ? 6 : 5, style: .continuous)
                    .strokeBorder(isButton ? Color.white.opacity(0.22) : Theme.stroke)
            )
            .shadow(color: isButton ? Color.black.opacity(0.4) : .clear, radius: 0, y: isButton ? 1.5 : 0)
    }
}

// MARK: - Step row

/// One numbered walkthrough step: title, presses, value and a plain-English sentence.
struct WalkthroughStepRow: View {
    let number: Int
    let step: SetupWalkthrough.Step

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(step.kind == .test ? Theme.success.opacity(0.18) : Theme.accentSoft)
                if step.kind == .test {
                    Image(systemName: "light.max")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.success)
                } else {
                    Text("\(number)")
                        .font(Theme.Font.number(11, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 5) {
                Text(step.title)
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.textPrimary)
                if !step.presses.isEmpty || step.value != nil {
                    PressChain(presses: step.presses, value: step.value)
                }
                Text(step.detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Wrap layout

/// Lays children out left to right, wrapping onto new lines when they don't fit.
struct PatchWrapLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
