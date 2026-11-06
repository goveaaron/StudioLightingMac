import SwiftUI
import PrismCore

/// Live workspace: big look tiles for performance / quick recall.
/// OWNER: Looks/Live workstream.
struct LiveWorkspace: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 14)], spacing: 14) {
                ForEach(app.show.looks.sorted { $0.sortIndex < $1.sortIndex }) { look in
                    LookTile(look: look, isActive: app.show.live.activeLookID == look.id) {
                        app.show.recallLook(look.id)
                    }
                }
            }
            .padding(Theme.Space.xl)
        }
    }
}

struct LookTile: View {
    let look: Look
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                let colors = look.swatchColors(max: 6).map { Color($0) }
                LinearGradient(colors: colors.isEmpty ? [.black, .black] : (colors.count == 1 ? [colors[0], colors[0]] : colors),
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(height: 86)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
                HStack {
                    Text(look.name).font(Theme.Font.headline).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer()
                    if look.isFavorite { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Theme.warning) }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hovering ? Theme.panelRaised : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isActive ? Theme.accent : Theme.stroke, lineWidth: isActive ? 2 : 1))
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(Theme.Motion.quick, value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
