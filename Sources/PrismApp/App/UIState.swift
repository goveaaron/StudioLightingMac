import SwiftUI
import PrismCore

/// Top-level workspaces (center area tabs).
enum WorkspaceTab: String, CaseIterable, Identifiable, Codable {
    case stage, live, patch, music, camera, remote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stage: return "Stage"
        case .live: return "Live"
        case .patch: return "Patch"
        case .music: return "Music"
        case .camera: return "Camera"
        case .remote: return "Remote"
        }
    }

    var systemImage: String {
        switch self {
        case .stage: return "square.grid.3x3.topleft.filled"
        case .live: return "rectangle.grid.2x2.fill"
        case .patch: return "cable.connector"
        case .music: return "waveform"
        case .camera: return "camera.viewfinder"
        case .remote: return "iphone.radiowaves.left.and.right"
        }
    }

    /// ⌘1…⌘6
    var shortcut: KeyEquivalent {
        KeyEquivalent(Character(String((WorkspaceTab.allCases.firstIndex(of: self) ?? 0) + 1)))
    }
}

/// Modal sheets presented over the main window. Each case's view lives in its owner's folder.
enum AppSheet: String, Identifiable {
    case addFixture         // Patch
    case exportProject      // Shell
    case importLightkey     // Patch
    case keyboardShortcuts  // Shell
    case hardwareTest       // Hardware (Output/)
    case outputSettings     // Hardware (Output/) — Settings › Outputs as a sheet
    case lightFinder        // Camera
    case welcome            // Shell (Onboarding/)
    case templates          // Shell (Onboarding/)
    case setupCards         // Patch — step-by-step "set your light to…" cards
    case addressScan        // Patch — find lights you're unsure of (no camera)
    case troubleshooter     // Patch — "a light isn't responding"
    case profileEditor      // Patch — build/edit a fixture profile
    case shareRemote        // Remote — QR code + share link

    var id: String { rawValue }
}

/// Short feedback messages ("Set Back Tubes to Teal").
struct Toast: Identifiable, Equatable {
    enum Style: Equatable { case info, success, warning, error }
    let id = UUID()
    var message: String
    var style: Style = .info
    var systemImage: String = "sparkles"
    var duration: Double = 2.6
}

/// Transient UI state (not saved in the project).
@MainActor
@Observable
final class UIState {
    var selectedTab: WorkspaceTab = .stage
    var showSidebar = true
    var showInspector = true
    var activeSheet: AppSheet?
    var isAssistantPresented = false
    var toasts: [Toast] = []
    /// Set while the screenshot tour drives the UI (disables onboarding, animations that never settle).
    var isRunningTour = false

    func toast(_ message: String, style: Toast.Style = .info, systemImage: String = "sparkles", duration: Double = 2.6) {
        let t = Toast(message: message, style: style, systemImage: systemImage, duration: duration)
        toasts.append(t)
        if toasts.count > 3 { toasts.removeFirst(toasts.count - 3) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            self?.toasts.removeAll { $0.id == t.id }
        }
    }
}
