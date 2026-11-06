import SwiftUI
import PrismCore

/// Looks (presets) sidebar: favorites, folders, search, one-click recall with crossfade.
///
/// OWNER: Looks/Live workstream (polish: drag reordering, thumbnails, shortcuts, folders CRUD).
struct LooksSidebar: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var renamingID: UUID?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
                let favorites = filtered.filter(\.isFavorite)
                if !favorites.isEmpty && query.isEmpty {
                    Section("Favorites") {
                        ForEach(favorites) { look in row(look) }
                    }
                }
                Section("Looks") {
                    ForEach(filtered.filter { $0.folderID == nil }) { look in row(look) }
                }
                ForEach(app.show.project.folders.sorted { $0.sortIndex < $1.sortIndex }) { folder in
                    let items = filtered.filter { $0.folderID == folder.id }
                    if !items.isEmpty || query.isEmpty {
                        Section {
                            ForEach(items) { look in row(look) }
                        } header: {
                            Label(folder.name, systemImage: "folder")
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Theme.panel)
    }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                TextField("Search looks", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.control))
            IconButton(systemImage: "plus", help: "Save the current lights as a new look (⌘N)") {
                let id = app.show.saveLook(name: app.show.uniqueLookName("New Look"))
                renameText = app.show.project.look(id)?.name ?? ""
                renamingID = id
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
    }

    private var filtered: [Look] {
        let all = app.show.looks.sorted { $0.sortIndex < $1.sortIndex }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.lowercased().contains(q) }
    }

    @ViewBuilder
    private func row(_ look: Look) -> some View {
        let active = app.show.live.activeLookID == look.id
        HStack(spacing: 8) {
            LookDot(colors: look.swatchColors(max: 4).map { Color($0) })
            if renamingID == look.id {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.plain)
                    .onSubmit { commitRename(look.id) }
                    .onExitCommand { renamingID = nil }
            } else {
                Text(look.name)
                    .font(Theme.Font.body)
                    .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if active {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { renameText = look.name; renamingID = look.id }
        .onTapGesture { app.show.recallLook(look.id) }
        .listRowBackground(active ? Theme.accentSoft : Color.clear)
        .contextMenu {
            Button("Recall") { app.show.recallLook(look.id) }
            Button("Recall Instantly") { app.show.recallLook(look.id, fade: 0) }
            Divider()
            Button("Update with Current Lights") { app.show.updateLook(look.id) }
            Button("Rename") { renameText = look.name; renamingID = look.id }
            Button(look.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                app.show.editProject("Favorite", change: [.looks]) { p in
                    if let i = p.looks.firstIndex(where: { $0.id == look.id }) { p.looks[i].isFavorite.toggle() }
                }
            }
            Button("Duplicate") {
                app.show.editProject("Duplicate Look", change: [.looks]) { p in
                    guard let l = p.look(look.id) else { return }
                    var copy = l
                    copy.id = UUID()
                    copy.name = app.show.uniqueLookName(l.name)
                    copy.sortIndex = l.sortIndex
                    p.looks.append(copy)
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                app.show.editProject("Delete Look", change: [.looks]) { p in p.looks.removeAll { $0.id == look.id } }
            }
        }
    }

    private func commitRename(_ id: UUID) {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingID = nil
        guard !name.isEmpty else { return }
        app.show.editProject("Rename Look", change: [.looks]) { p in
            if let i = p.looks.firstIndex(where: { $0.id == id }) { p.looks[i].name = name }
        }
    }
}

/// Four-quadrant color dot summarizing a look (like Lightkey's preset icons, but true colors).
struct LookDot: View {
    let colors: [Color]
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            if colors.isEmpty {
                Circle().fill(Color.black).overlay(Circle().strokeBorder(Color.white.opacity(0.3)))
            } else {
                ForEach(Array(colors.prefix(4).enumerated()), id: \.offset) { i, c in
                    Circle()
                        .trim(from: CGFloat(i) / CGFloat(min(colors.count, 4)),
                              to: CGFloat(i + 1) / CGFloat(min(colors.count, 4)))
                        .stroke(c, lineWidth: size / 2)
                        .frame(width: size / 2, height: size / 2)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.18)))
        .shadow(color: (colors.first ?? .clear).opacity(0.5), radius: 3)
    }
}
