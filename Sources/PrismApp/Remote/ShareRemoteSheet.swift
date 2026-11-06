import SwiftUI
import PrismCore

/// QR code + share link for the phone/web remote, with guest permissions.
///
/// OWNER: Remote workstream. Placeholder pre-wired into `SheetRouter`.
struct ShareRemoteSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            EmptyStateView(systemImage: "qrcode", title: "Control from your phone",
                           message: "Scan the code with your phone's camera to control the lights.")
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(width: 560, height: 420)
    }
}
