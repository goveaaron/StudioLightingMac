import SwiftUI
import PrismCore

/// Camera workspace. OWNER: Camera workstream.
struct CameraWorkspace: View {
    var body: some View {
        EmptyStateView(systemImage: "camera.viewfinder", title: "Camera",
                       message: "Use the Mac's camera to find your lights, check colors and verify what the assistant did.")
    }
}

/// Light Finder sheet. OWNER: Camera workstream.
struct LightFinderSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: Theme.Space.m) {
            EmptyStateView(systemImage: "scope", title: "Find My Lights",
                           message: "Prism flashes each light and watches through the camera to place it on the stage.")
            Button("Close") { dismiss() }
        }
        .padding()
        .frame(width: 560, height: 380)
    }
}
