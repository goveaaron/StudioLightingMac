import SwiftUI
import PrismCore

/// Patch workspace: every light, its DMX address and status, with plain-language help.
/// OWNER: Patch workstream (Add Light wizard, universe map, conflicts, setup cards, channel
/// tester, Light Finder entry, replace fixture type, profile editor, Lightkey import).
struct PatchWorkspace: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Patch").font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
                    Text("Each light listens on a DMX address. Prism keeps them from overlapping.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button { app.ui.activeSheet = .addFixture } label: { Label("Add Light", systemImage: "plus") }
                    .buttonStyle(.pill(prominent: true))
            }
            .padding(Theme.Space.l)

            Table(app.show.resolvedFixtures, selection: Binding(get: { app.show.selection }, set: { app.show.selection = $0 })) {
                TableColumn("Name") { rf in Text(rf.fixture.name) }
                TableColumn("Label") { rf in Text(rf.fixture.stageLabel) }
                TableColumn("Type") { rf in Text(rf.definition.displayName) }
                TableColumn("Mode") { rf in Text("\(rf.mode.name) (\(rf.channelCount) ch)") }
                TableColumn("Universe") { rf in Text("\(rf.fixture.universe)") }
                TableColumn("Address") { rf in
                    Text(rf.addressRange.map { "\($0.lowerBound)–\($0.upperBound)" } ?? "—")
                        .font(Theme.Font.number(12))
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}
