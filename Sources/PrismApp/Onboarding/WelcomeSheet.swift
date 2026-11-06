import SwiftUI
import PrismCore

/// First-run welcome. OWNER: Shell workstream (moved from Main/Sheets.swift).
struct WelcomeSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            PrismLogo(size: 56)
            Text("Welcome to Prism").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Beautiful, simple control for your studio lights.")
                .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
            HStack(spacing: Theme.Space.m) {
                Button("Explore the demo studio") {
                    app.show.loadDemo()
                    finish()
                }
                .buttonStyle(.pill)
                Button("Set up my lights") {
                    app.ui.selectedTab = .patch
                    finish()
                }
                .buttonStyle(.pill(prominent: true))
            }
        }
        .padding(40)
        .frame(width: 560)
    }

    private func finish() {
        app.preferences.hasCompletedOnboarding = true
        dismiss()
    }
}

/// Studio templates (Podcast, Talking head, Product table, Gaming room, YouTube set).
/// OWNER: Shell workstream. Placeholder pre-wired into `SheetRouter`.
struct TemplatesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            EmptyStateView(systemImage: "square.grid.2x2", title: "Start from a template",
                           message: "Ready-made studios with lights, positions and looks.")
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(width: 640, height: 440)
    }
}
