import SwiftUI
import PrismCore

// Placeholder sheets pre-wired into `SheetRouter`. OWNER: Patch workstream (replace freely).

/// Step-by-step cards: "Set this light to address 17, mode 8 Pixels" with the exact menu path.
struct SetupCardsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        PatchPlaceholderSheet(systemImage: "list.bullet.rectangle.portrait", title: "Setup Cards",
                              message: "Exactly what to set on each light, step by step.") { dismiss() }
    }
}

/// Finds lights you're unsure of by flashing addresses one at a time (no camera needed).
struct AddressScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        PatchPlaceholderSheet(systemImage: "dot.radiowaves.left.and.right", title: "Find My Lights",
                              message: "Flashes each address so you can tell which light is which.") { dismiss() }
    }
}

/// "A light isn't responding" guided troubleshooter.
struct TroubleshooterSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        PatchPlaceholderSheet(systemImage: "stethoscope", title: "Light Troubleshooter",
                              message: "Walks through cables, addresses and modes until it works.") { dismiss() }
    }
}

/// Build or edit a fixture profile.
struct ProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        PatchPlaceholderSheet(systemImage: "slider.horizontal.below.rectangle", title: "Fixture Profile",
                              message: "Describe what each channel of a light does.") { dismiss() }
    }
}

struct PatchPlaceholderSheet: View {
    let systemImage: String
    let title: String
    let message: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            EmptyStateView(systemImage: systemImage, title: title, message: message)
            Button("Close", action: close).keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(width: 560, height: 380)
    }
}
