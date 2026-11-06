import SwiftUI
import PrismCore

/// Remote workspace (QR pairing, share links, guest permissions). OWNER: Remote workstream.
struct RemoteWorkspace: View {
    var body: some View {
        EmptyStateView(systemImage: "qrcode", title: "Phone Remote",
                       message: "Scan a QR code to control the lights from any phone — with limits so guests can't break anything.")
    }
}
