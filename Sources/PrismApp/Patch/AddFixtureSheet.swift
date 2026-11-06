import SwiftUI
import PrismCore

/// Add Light flow. OWNER: Patch workstream (library browser, friendly modes, auto-address,
/// "set this on your light" instructions, identify/test).
struct AddFixtureSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: FixtureLibraryEntry?
    @State private var count = 1

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Add Light").font(Theme.Font.title)
            TextField("Search 2,000+ lights (e.g. “amaran PT4c”, “RGB par”)", text: $query)
                .textFieldStyle(.roundedBorder)
            List(app.library.search(query, limit: 200), selection: Binding(get: { selected?.id }, set: { id in
                selected = app.library.entries.first { $0.id == id }
            })) { entry in
                HStack {
                    Text(entry.displayName)
                    Spacer()
                    Text(entry.badge).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
                .tag(entry.id)
            }
            .frame(minHeight: 280)
            HStack {
                Stepper("How many: \(count)", value: $count, in: 1...32)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    if let e = selected, let def = app.library.definition(e.id), let mode = def.recommendedMode ?? def.modes.first {
                        app.show.addFixtures(definitionID: def.id, modeName: mode.name, count: count, baseName: def.model)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 620, height: 520)
    }
}

/// Lightkey import. OWNER: Patch workstream.
struct ImportLightkeySheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: Theme.Space.m) {
            EmptyStateView(systemImage: "square.and.arrow.down", title: "Import from Lightkey",
                           message: "Coming soon: bring your Lightkey patch, layout and presets into Prism.")
            Button("Close") { dismiss() }
        }
        .padding()
        .frame(width: 520, height: 360)
    }
}
