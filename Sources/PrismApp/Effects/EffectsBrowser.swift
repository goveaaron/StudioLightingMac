import SwiftUI
import PrismCore

/// Effect picker + parameter editor (animated previews of every effect), embedded by the
/// Inspector's effects section and the Live page.
///
/// OWNER: Effects workstream. Placeholder; the Inspector embeds it as
/// `EffectsBrowser(fixtureIDs: app.show.selection)`.
struct EffectsBrowser: View {
    let fixtureIDs: Set<UUID>

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Effects").font(Theme.Font.headline)
            Text(fixtureIDs.isEmpty ? "Select lights to add an effect." : "Effects for \(fixtureIDs.count) light(s).")
                .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
