import SwiftUI
import AppKit
import PrismCore

/// Prism design tokens. Dark, calm, studio-friendly (no light spill), with a prism-spectrum
/// accent. Every view should use these instead of ad-hoc colors/sizes.
enum Theme {
    // MARK: Surfaces
    static let window = Color(hex: 0x0B0D12)
    static let canvas = Color(hex: 0x07080B)
    static let panel = Color(hex: 0x12151C)
    static let panelRaised = Color(hex: 0x191D26)
    static let control = Color(hex: 0x222733)
    static let controlHover = Color(hex: 0x2A3040)
    static let stroke = Color.white.opacity(0.08)
    static let strokeStrong = Color.white.opacity(0.16)

    // MARK: Text
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.40)

    // MARK: Accent & semantic
    static let accent = Color(hex: 0x7C8CFF)
    static let accentSoft = Color(hex: 0x7C8CFF).opacity(0.18)
    static let success = Color(hex: 0x34D399)
    static let warning = Color(hex: 0xFBBF24)
    static let danger = Color(hex: 0xF87171)
    static let live = Color(hex: 0xFF453A)
    static let music = Color(hex: 0xC084FC)
    static let remote = Color(hex: 0x38BDF8)

    /// Signature prism spectrum (logo, highlights, active states).
    static let spectrum = LinearGradient(
        colors: [Color(hex: 0xFF4FD8), Color(hex: 0x8B5CF6), Color(hex: 0x38BDF8), Color(hex: 0x34F5C5)],
        startPoint: .leading, endPoint: .trailing)

    static let spectrumColors: [Color] = [Color(hex: 0xFF4FD8), Color(hex: 0x8B5CF6), Color(hex: 0x38BDF8), Color(hex: 0x34F5C5)]

    // MARK: Metrics
    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
        static let xlarge: CGFloat = 20
    }

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Typography
    enum Font {
        static let title = SwiftUI.Font.system(size: 20, weight: .semibold, design: .rounded)
        static let headline = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let caption = SwiftUI.Font.system(size: 11)
        static let captionStrong = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let sectionLabel = SwiftUI.Font.system(size: 10, weight: .bold)
        /// Numbers: rounded + tabular so values don't jitter while dragging.
        static func number(_ size: CGFloat = 13, weight: SwiftUI.Font.Weight = .medium) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .rounded).monospacedDigit()
        }
        static func mono(_ size: CGFloat = 12) -> SwiftUI.Font { .system(size: size, design: .monospaced) }
    }

    // MARK: Motion
    enum Motion {
        static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.86)
        static let smooth = Animation.spring(response: 0.42, dampingFraction: 0.9)
        static let quick = Animation.easeOut(duration: 0.15)
    }
}

// MARK: - Color helpers

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    /// Display color for a Prism color value.
    init(_ rgb: RGBColor, opacity: Double = 1) {
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: opacity)
    }

    init(_ light: LightColor, opacity: Double = 1) {
        self.init(light.displayRGB, opacity: opacity)
    }

    /// Hex parsing for user-entered strings; nil when invalid.
    init?(hexString: String) {
        guard let rgb = RGBColor(hex: hexString) else { return nil }
        self.init(rgb)
    }

    /// sRGB components (for eyedropper / NSColor interop).
    var rgbColor: RGBColor? {
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return RGBColor(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
    }
}

extension FixtureState {
    /// What the light looks like on screen (color scaled by intensity, for glows/swatches).
    var displayColor: Color {
        Color(color.displayRGB, opacity: 1)
    }
}
