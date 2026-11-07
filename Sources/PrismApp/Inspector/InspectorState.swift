import SwiftUI
import AppKit
import PrismCore

/// The inspector's pages for a selection.
enum InspectorPage: String, CaseIterable, Identifiable {
    case color, pixels, effects, setup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .color: return "Color"
        case .pixels: return "Pixels"
        case .effects: return "Effects"
        case .setup: return "Setup"
        }
    }

    var systemImage: String {
        switch self {
        case .color: return "paintpalette.fill"
        case .pixels: return "rectangle.split.3x1.fill"
        case .effects: return "sparkles"
        case .setup: return "slider.horizontal.3"
        }
    }
}

/// How a color is picked on the Color page.
enum InspectorColorTab: String, CaseIterable, Identifiable {
    case color, white, gel, source

    var id: String { rawValue }

    var title: String {
        switch self {
        case .color: return "Color"
        case .white: return "White"
        case .gel: return "Gel"
        case .source: return "Source"
        }
    }
}

/// Brightness readout unit.
enum InspectorIntensityUnit: String, CaseIterable {
    case percent, stops
}

/// UI state of the inspector that outlives a single selection (tabs, searches, recent colors).
///
/// Lives as a singleton so the stage, the screenshot tour and self-tests can drive it, and so the
/// open page survives clicking from light to light.
@MainActor
@Observable
final class InspectorState {
    static let shared = InspectorState()

    private enum Keys {
        static let unit = "prism.inspector.intensityUnit"
        static let history = "prism.inspector.recentColors"
    }

    // MARK: Navigation
    var page: InspectorPage = .color
    var colorTab: InspectorColorTab = .color
    private(set) var intensityUnit: InspectorIntensityUnit
    var showXY = false
    var showAllLights = false
    var showLiveDMX = false

    // MARK: Searches & pickers
    var gelQuery = ""
    var gelBrand: GelManufacturer?
    var gelCategory: GelCategory?
    var gelBaseKelvin: Double = 5600
    var colorQuery = ""

    // MARK: Remembered values
    private(set) var history: ColorHistory
    /// Hue the wheel keeps for greys (so dragging saturation up from grey has a direction).
    var lastHue: Double = 186
    /// Kelvin shown on the White tab while the light is showing a color.
    var lastKelvin: Double = 5600
    /// Gradient stops used by the pixel editor and the multi-selection "spread" tool.
    var gradientStops: [LightColor] = [
        .rgb(RGB(r255: 0, g255: 194, b255: 168)),
        .rgb(RGB(r255: 255, g255: 47, b255: 180)),
    ]
    /// Pixel editor paint color.
    var paintColor: LightColor = .rgb(RGB(r255: 20, g255: 216, b255: 240))
    /// Colors extracted from a dropped photo.
    var imagePalette: [RGB] = []
    var imageName: String?
    /// Friendly echo of the last smart-field entry ("Read as LEE 201 Full C.T. Blue").
    var lastMatchNote: String?
    /// Hue-shift slider position while dragging (snaps back to 0 afterwards).
    var hueShift: Double = 0

    // MARK: Transient interaction state (not observed)
    @ObservationIgnored var intensityDragStart: [UUID: Double]?
    @ObservationIgnored var intensityDragAnchor: Double = 0
    @ObservationIgnored var typedIntensity = false
    @ObservationIgnored var hueShiftStart: [UUID: FixtureState]?
    @ObservationIgnored var sampler: NSColorSampler?
    @ObservationIgnored var cellAnchor: Int?
    @ObservationIgnored var lastSelection: [UUID] = []

    private init() {
        let defaults = UserDefaults.standard
        intensityUnit = InspectorIntensityUnit(rawValue: defaults.string(forKey: Keys.unit) ?? "") ?? .percent
        history = ColorHistory.decode(defaults.data(forKey: Keys.history))
    }

    func setIntensityUnit(_ unit: InspectorIntensityUnit) {
        intensityUnit = unit
        UserDefaults.standard.set(unit.rawValue, forKey: Keys.unit)
    }

    /// Adds a color to the Recent row (newest first) and persists it.
    func remember(_ color: LightColor) {
        var h = history
        h.push(color)
        guard h != history else { return }
        history = h
        UserDefaults.standard.set(h.encoded(), forKey: Keys.history)
    }

    func forget(_ color: LightColor) {
        var h = history
        h.remove(color)
        history = h
        UserDefaults.standard.set(h.encoded(), forKey: Keys.history)
    }

    func clearHistory() {
        history = ColorHistory()
        UserDefaults.standard.removeObject(forKey: Keys.history)
    }

    /// Back to first-launch navigation (used by the tour and when a project loads).
    func resetNavigation() {
        page = .color
        colorTab = .color
        showXY = false
        gelQuery = ""
        gelBrand = nil
        gelCategory = nil
        colorQuery = ""
        lastMatchNote = nil
        hueShift = 0
        imagePalette = []
        imageName = nil
        showAllLights = false
        showLiveDMX = false
    }

    /// Keeps the Color/White tab in step with what the selected lights are doing when the
    /// selection changes (Gel and Source stay open if the user chose them).
    func syncTabs(to ids: [UUID], states: [FixtureState]) {
        guard ids != lastSelection else { return }
        lastSelection = ids
        lastMatchNote = nil
        hueShift = 0
        guard colorTab == .color || colorTab == .white, let first = states.first else { return }
        let allWhite = states.allSatisfy { if case .kelvin = $0.color { return true } else { return false } }
        if allWhite {
            colorTab = .white
        } else if case .kelvin = first.color {
            colorTab = .white
        } else {
            colorTab = .color
        }
    }
}
