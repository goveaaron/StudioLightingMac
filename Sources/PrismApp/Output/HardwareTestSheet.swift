import SwiftUI
import PrismCore

/// Hardware test: checks the DMX interface and walks through each light.
///
/// OWNER: Hardware workstream. Placeholder (moved from Main/Sheets.swift).
struct HardwareTestSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: Theme.Space.m) {
            EmptyStateView(systemImage: "cable.connector.horizontal", title: "Hardware Test",
                           message: "Checks your DMX interface and walks through each light.")
            Button("Close") { dismiss() }
        }
        .padding()
        .frame(width: 560, height: 380)
    }
}
