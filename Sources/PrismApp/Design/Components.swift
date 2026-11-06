import SwiftUI
import AppKit
import PrismCore

// MARK: - Panels & surfaces

struct PrismPanelModifier: ViewModifier {
    var radius: CGFloat = Theme.Radius.large
    var padding: CGFloat? = Theme.Space.m
    var raised = false

    func body(content: Content) -> some View {
        content
            .padding(padding ?? 0)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(raised ? Theme.panelRaised : Theme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )
    }
}

/// Liquid Glass on macOS 26+, translucent material on older systems.
struct GlassBackgroundModifier: ViewModifier {
    var radius: CGFloat = Theme.Radius.large

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.stroke))
        }
    }
}

extension View {
    func prismPanel(radius: CGFloat = Theme.Radius.large, padding: CGFloat? = Theme.Space.m, raised: Bool = false) -> some View {
        modifier(PrismPanelModifier(radius: radius, padding: padding, raised: raised))
    }

    func glassBackground(radius: CGFloat = Theme.Radius.large) -> some View {
        modifier(GlassBackgroundModifier(radius: radius))
    }

    /// Standard hover highlight for custom buttons/rows.
    func hoverHighlight(_ hovering: Bool, radius: CGFloat = Theme.Radius.small) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(hovering ? Color.white.opacity(0.06) : .clear))
    }
}

// MARK: - Section header

struct SectionHeader<Trailing: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, systemImage: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(title.uppercased())
                .font(Theme.Font.sectionLabel)
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
            trailing()
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, systemImage: String? = nil) {
        self.init(title, systemImage: systemImage) { EmptyView() }
    }
}

// MARK: - Precise slider

/// The workhorse control: absolute drag, ⌥-drag for 10× finer control, arrow keys (⇧ = ×10),
/// double-click (or click the value) to type an exact number, NaN-safe, accessible.
struct PrismSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    /// Keyboard step in value units.
    var step: Double = 0.01
    var label: String?
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
    /// Parses typed text into a value (default: number, "%" aware for 0…1 ranges).
    var parse: ((String) -> Double?)?
    var tint: Color = Theme.accent
    /// Optional custom track (e.g. Kelvin or hue gradient). When set, no fill is drawn.
    var track: AnyView?
    var height: CGFloat = 26
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var isDragging = false
    @State private var fineAnchor: (x: CGFloat, value: Double)?
    @State private var isEditingText = false
    @State private var text = ""
    @State private var hovering = false
    @FocusState private var focused: Bool
    @FocusState private var textFocused: Bool

    private var span: Double { max(range.upperBound - range.lowerBound, .ulpOfOne) }
    private var safeValue: Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }
    private var fraction: Double { (safeValue - range.lowerBound) / span }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                trackView(width: width)
                thumb(width: width)
                labels
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(width: width))
            .simultaneousGesture(TapGesture(count: 2).onEnded { beginTextEdit() })
        }
        .frame(height: height)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .overlay(
            RoundedRectangle(cornerRadius: height / 2.6, style: .continuous)
                .strokeBorder(focused ? tint.opacity(0.9) : .clear, lineWidth: 1.5)
        )
        .onKeyPress(.leftArrow) { nudge(-1); return .handled }
        .onKeyPress(.rightArrow) { nudge(1); return .handled }
        .onKeyPress(.downArrow) { nudge(-1); return .handled }
        .onKeyPress(.upArrow) { nudge(1); return .handled }
        .onKeyPress(.return) { beginTextEdit(); return .handled }
        .onHover { hovering = $0 }
        .overlay { if isEditingText { editor } }
        .accessibilityElement()
        .accessibilityLabel(label ?? "Value")
        .accessibilityValue(format(safeValue))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(1)
            case .decrement: nudge(-1)
            @unknown default: break
            }
        }
        .help("Drag to adjust · ⌥-drag for fine control · double-click to type an exact value")
    }

    @ViewBuilder
    private func trackView(width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: height / 2.6, style: .continuous)
        ZStack(alignment: .leading) {
            if let track {
                track.clipShape(shape)
            } else {
                shape.fill(Theme.control)
                shape.fill(
                    LinearGradient(colors: [tint.opacity(0.55), tint], startPoint: .leading, endPoint: .trailing)
                )
                .frame(width: max(CGFloat(fraction) * width, 0))
                .clipShape(shape)
            }
        }
        .overlay(shape.strokeBorder(hovering || isDragging ? Theme.strokeStrong : Theme.stroke))
    }

    private func thumb(width: CGFloat) -> some View {
        let x = CGFloat(fraction) * width
        return Capsule()
            .fill(Color.white)
            .frame(width: 3, height: height - 8)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .offset(x: min(max(x - 1.5, 2), width - 5))
            .opacity(track != nil || hovering || isDragging ? 1 : 0.0)
    }

    private var labels: some View {
        HStack {
            if let label {
                Text(label)
                    .font(Theme.Font.captionStrong)
                    .foregroundStyle(Theme.textPrimary.opacity(0.9))
                    .shadow(color: .black.opacity(0.6), radius: 1)
            }
            Spacer(minLength: 4)
            Text(format(safeValue))
                .font(Theme.Font.number(12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .shadow(color: .black.opacity(0.6), radius: 1)
                .onTapGesture { beginTextEdit() }
        }
        .padding(.horizontal, 10)
        .allowsHitTesting(!isDragging)
    }

    private var editor: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(Theme.Font.number(12, weight: .semibold))
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: height / 2.6, style: .continuous).fill(Theme.panelRaised))
            .overlay(RoundedRectangle(cornerRadius: height / 2.6, style: .continuous).strokeBorder(tint, lineWidth: 1.5))
            .focused($textFocused)
            .onSubmit { commitText() }
            .onExitCommand { isEditingText = false }
            .onChange(of: textFocused) { _, isFocused in
                if !isFocused && isEditingText { commitText() }
            }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if !isDragging {
                    isDragging = true
                    focused = true
                    onEditingChanged(true)
                }
                let fine = NSEvent.modifierFlags.contains(.option)
                if fine {
                    if fineAnchor == nil { fineAnchor = (g.location.x, safeValue) }
                    let anchor = fineAnchor!
                    let delta = Double((g.location.x - anchor.x) / width) * span * 0.1
                    set(anchor.value + delta)
                } else {
                    fineAnchor = nil
                    set(range.lowerBound + Double(min(max(g.location.x / width, 0), 1)) * span)
                }
            }
            .onEnded { _ in
                isDragging = false
                fineAnchor = nil
                onEditingChanged(false)
            }
    }

    private func set(_ v: Double) {
        guard v.isFinite else { return }
        value = min(max(v, range.lowerBound), range.upperBound)
    }

    private func nudge(_ direction: Double) {
        let mult = NSEvent.modifierFlags.contains(.shift) ? 10.0 : (NSEvent.modifierFlags.contains(.option) ? 0.1 : 1.0)
        onEditingChanged(true)
        set(safeValue + direction * step * mult)
        onEditingChanged(false)
    }

    private func beginTextEdit() {
        text = format(safeValue)
        isEditingText = true
        DispatchQueue.main.async { textFocused = true }
    }

    private func commitText() {
        defer { isEditingText = false }
        let parsed = parse?(text) ?? PrismSlider.defaultParse(text, range: range)
        guard let v = parsed else { NSSound.beep(); return }
        onEditingChanged(true)
        set(v)
        onEditingChanged(false)
    }

    /// "72", "72%", "0.72" → value; percentages map onto 0…1 ranges.
    static func defaultParse(_ raw: String, range: ClosedRange<Double>) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isPercent = s.hasSuffix("%")
        s = s.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "k", with: "")
            .replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let n = Double(s), n.isFinite else { return nil }
        if range == 0...1 && (isPercent || n > 1) { return n / 100 }
        return n
    }
}

// MARK: - Numeric / hex fields

/// Exact-entry numeric field with unit, clamping and validation (commits on ⏎ or blur).
struct NumericField: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var unit: String = ""
    var decimals: Int = 0
    var width: CGFloat = 64
    var onCommit: () -> Void = {}

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 2) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Font.number(12))
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit(commit)
            if !unit.isEmpty {
                Text(unit).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 7)
        .frame(width: width, height: 24)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Theme.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small)
            .strokeBorder(focused ? Theme.accent : Theme.stroke, lineWidth: focused ? 1.5 : 1))
        .onAppear { text = formatted }
        .onChange(of: value) { _, _ in if !focused { text = formatted } }
        .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private var formatted: String {
        guard value.isFinite else { return "–" }
        return String(format: "%.\(decimals)f", value)
    }

    private func commit() {
        let cleaned = text.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: CharacterSet(charactersIn: " %K°k"))
        if let v = Double(cleaned), v.isFinite {
            value = min(max(v, range.lowerBound), range.upperBound)
            onCommit()
        } else {
            NSSound.beep()
        }
        text = formatted
    }
}

/// Hex color entry (#RRGGBB or RRGGBB or #RGB). Invalid input reverts with a beep.
struct HexField: View {
    let hex: String
    var onCommit: (RGBColor) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text("#").font(Theme.Font.mono(12)).foregroundStyle(Theme.textTertiary)
            TextField("RRGGBB", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Font.mono(12))
                .focused($focused)
                .onSubmit(commit)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Theme.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small)
            .strokeBorder(focused ? Theme.accent : Theme.stroke, lineWidth: focused ? 1.5 : 1))
        .onAppear { text = stripped(hex) }
        .onChange(of: hex) { _, h in if !focused { text = stripped(h) } }
        .onChange(of: focused) { _, f in if !f { commit() } }
        .help("Type an exact hex color, e.g. 00C2A8")
    }

    private func stripped(_ h: String) -> String { h.replacingOccurrences(of: "#", with: "").uppercased() }

    private func commit() {
        if let rgb = RGBColor(hex: text) {
            onCommit(rgb)
            text = stripped(rgb.hex)
        } else if stripped(hex) != stripped(text) {
            NSSound.beep()
            text = stripped(hex)
        }
    }
}

// MARK: - Buttons, pills, chips

struct PillButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    var prominent = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? Theme.Font.captionStrong : Theme.Font.headline)
            .padding(.horizontal, compact ? 9 : 13)
            .padding(.vertical, compact ? 4 : 7)
            .foregroundStyle(prominent ? Color.white : Theme.textPrimary)
            .background(
                Capsule().fill(prominent ? tint : Theme.control)
                    .opacity(configuration.isPressed ? 0.75 : 1)
            )
            .overlay(Capsule().strokeBorder(prominent ? Color.white.opacity(0.15) : Theme.stroke))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static func pill(tint: Color = Theme.accent, prominent: Bool = false, compact: Bool = false) -> PillButtonStyle {
        PillButtonStyle(tint: tint, prominent: prominent, compact: compact)
    }
}

/// Square-ish icon button used in floating toolbars.
struct IconButton: View {
    let systemImage: String
    var help: String = ""
    var isActive = false
    var tint: Color = Theme.accent
    var size: CGFloat = 28
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.46, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(isActive ? tint : Theme.textSecondary)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill(isActive ? tint.opacity(0.18) : (hovering ? Color.white.opacity(0.07) : .clear))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help.isEmpty ? systemImage : help)
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = Theme.success
    var systemImage: String?
    var pulsing = false

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
                    .shadow(color: color.opacity(0.8), radius: pulse ? 4 : 1)
            }
            Text(text).font(Theme.Font.captionStrong).foregroundStyle(Theme.textPrimary).lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.14)))
        .overlay(Capsule().strokeBorder(color.opacity(0.35)))
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

struct KeyCap: View {
    let keys: String
    var body: some View {
        Text(keys)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.stroke))
    }
}

/// Round color swatch with optional selection ring.
struct ColorSwatch: View {
    let color: Color
    var size: CGFloat = 22
    var isSelected = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            .padding(2)
            .overlay(Circle().strokeBorder(isSelected ? Color.white : .clear, lineWidth: 2))
            .shadow(color: color.opacity(0.5), radius: isSelected ? 6 : 0)
    }
}

/// Multi-color mini swatch strip used for look thumbnails.
struct SwatchStrip: View {
    let colors: [Color]
    var height: CGFloat = 14
    var body: some View {
        HStack(spacing: 0) {
            if colors.isEmpty {
                Rectangle().fill(Color.black)
            } else {
                ForEach(Array(colors.enumerated()), id: \.offset) { _, c in Rectangle().fill(c) }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
    }
}

/// Friendly empty state with an optional action.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.spectrum)
            Text(title).font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.pill(prominent: true))
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Toasts

struct ToastView: View {
    let toast: Toast
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.systemImage)
                .foregroundStyle(toast.style.color)
            Text(toast.message)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassBackground(radius: 12)
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}

extension Toast.Style {
    var color: Color {
        switch self {
        case .info: return Theme.accent
        case .success: return Theme.success
        case .warning: return Theme.warning
        case .error: return Theme.danger
        }
    }
}
