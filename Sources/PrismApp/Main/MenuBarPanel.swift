import SwiftUI
import AppKit
import PrismCore

/// Menu bar control: looks, master, blackout, music — usable with the main window closed.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                PrismLogo(size: 16)
                Text(app.show.project.name).font(Theme.Font.headline)
                Spacer()
                Button("Open Prism") {
                    openWindow(id: AppModel.mainWindowID)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.pill(compact: true))
            }
            PrismSlider(value: Binding(get: { app.show.live.grandMaster }, set: { app.show.setGrandMaster($0) }),
                        label: "Master", height: 24)
            HStack(spacing: 8) {
                Button(app.show.live.blackout ? "Lights On" : "Blackout") { app.show.toggleBlackout() }
                    .buttonStyle(.pill(tint: Theme.live, prominent: app.show.live.blackout, compact: true))
                Button(app.show.live.music.enabled ? "Music Off" : "Music On") {
                    app.music.setEnabled(!app.show.live.music.enabled)
                }
                .buttonStyle(.pill(tint: Theme.music, prominent: app.show.live.music.enabled, compact: true))
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(app.show.looks.sorted { ($0.isFavorite ? 0 : 1, $0.sortIndex) < ($1.isFavorite ? 0 : 1, $1.sortIndex) }) { look in
                        Button {
                            app.show.recallLook(look.id)
                        } label: {
                            HStack {
                                LookDot(colors: look.swatchColors(max: 4).map { Color($0) }, size: 12)
                                Text(look.name).lineLimit(1)
                                Spacer()
                                if app.show.live.activeLookID == look.id {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                }
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(Theme.Space.m)
        .frame(width: 300)
    }
}
