import Foundation

/// How a requested color is turned into emitter levels.
///
/// Set project-wide with `Project.colorMixingMode`. Each fixture can override it with
/// `ColorCalibration.mixingMode` (`nil` means "use the project default").
public enum ColorMixingMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Match the chromaticity you asked for, preferring the white/warm-white/amber/lime emitters
    /// for whites and pastels because they give higher-quality light.
    case accurate
    /// Send the hex code straight to the R/G/B channels (exactly `#FF00AA` → R 255, G 0, B 170);
    /// other emitters stay off. Kelvin/HSB/xy colors go out as their sRGB equivalent.
    case direct

    /// Short label for settings UI.
    public var displayName: String {
        switch self {
        case .accurate: return "Accurate"
        case .direct: return "Direct"
        }
    }

    /// One-line plain-language explanation for settings UI.
    public var explanation: String {
        switch self {
        case .accurate:
            return "Matches the color you picked and uses the light's white LEDs for whites and pastels."
        case .direct:
            return "Sends hex codes straight to the red, green and blue LEDs, like most lighting consoles."
        }
    }
}
