import Foundation
import PrismCore

/// Screenshot-tour scenes for this feature (see App/ScreenshotTour.swift). Add scenes that put
/// the UI into interesting states; CI renders each one to a PNG artifact.
@MainActor
enum OnboardingTour {
    static var scenes: [ScreenshotTour.Scene] { [] }
}
