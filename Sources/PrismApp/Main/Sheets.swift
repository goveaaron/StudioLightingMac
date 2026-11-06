import SwiftUI
import PrismCore

/// Share/export a project. OWNER: Shell (polish by Docs/QA workstream).
struct ShareProjectSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Share Project").font(Theme.Font.title)
            Text("A .prismlights file contains your lights, stage layout, looks and every fixture profile it uses, so it opens on any Mac running Prism. It never contains your devices, remote links or API keys.")
                .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save a Copy…") {
                    dismiss()
                    DispatchQueue.main.async { FileActions.saveAs(app) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 520)
    }
}

/// Keyboard shortcut reference.
struct KeyboardShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let rows: [(String, String)] = [
        ("⌘K", "Ask Prism (assistant)"), ("⇧⌘K", "Talk to Prism"), ("⌘N", "Save current lights as a look"),
        ("⌘1–⌘6", "Switch workspace"), ("⇧⌘B", "Blackout"), ("⇧⌘L", "Add light"), ("⇧⌘I", "Identify selected"),
        ("⌥⌘A", "Select all lights"), ("⌘Z / ⇧⌘Z", "Undo / Redo"), ("⌥-drag slider", "Fine adjustment"),
        ("Double-click value", "Type an exact value"), ("Esc", "Close / clear"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Keyboard Shortcuts").font(Theme.Font.title)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                ForEach(rows, id: \.0) { r in
                    GridRow {
                        KeyCap(keys: r.0)
                        Text(r.1).font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(Theme.Space.xl)
        .frame(width: 460)
    }
}
