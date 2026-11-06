import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PrismCore

extension UTType {
    /// Prism project document (declared in Info.plist by scripts/build_app.sh).
    static let prismProject = UTType(exportedAs: "com.goveaaron.prism.project", conformingTo: .json)
}

/// Menu bar commands. Keyboard shortcuts are designed so the most common live actions are
/// one keystroke away (see Help ▸ Keyboard Shortcuts).
struct PrismCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") { model.show.newProject() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Open…") { FileActions.open(model) }
                .keyboardShortcut("o")
            Menu("Open Template") {
                Button("London Studio (demo rig)") { model.show.loadDemo() }
            }
            Divider()
            Button("Import from Lightkey…") { model.ui.activeSheet = .importLightkey }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { FileActions.save(model) }
                .keyboardShortcut("s")
            Button("Save As…") { FileActions.saveAs(model) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Share Project…") { model.ui.activeSheet = .exportProject }
        }
        CommandGroup(replacing: .undoRedo) {
            Button(model.show.undoActionName.map { "Undo \($0)" } ?? "Undo") { model.show.undo() }
                .keyboardShortcut("z")
                .disabled(!model.show.canUndo)
            Button(model.show.redoActionName.map { "Redo \($0)" } ?? "Redo") { model.show.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.show.canRedo)
        }
        CommandMenu("Lights") {
            Button("Add Light…") { model.ui.activeSheet = .addFixture }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Select All Lights") { model.show.selection = Set(model.show.fixtures.map(\.id)) }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button("Identify Selected") { model.show.identify(model.show.selectedIDs()) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button(model.show.live.blackout ? "Release Blackout" : "Blackout") { model.show.toggleBlackout() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Save Look") { _ = model.show.saveLook(name: model.show.uniqueLookName("New Look")) }
                .keyboardShortcut("n", modifiers: [.command])
            Divider()
            Button("Hardware Test…") { model.ui.activeSheet = .hardwareTest }
            Button("Find My Lights with Camera…") { model.ui.activeSheet = .lightFinder }
        }
        CommandMenu("Assistant") {
            Button("Ask Prism…") { model.ui.isAssistantPresented = true }
                .keyboardShortcut("k")
            Button(model.voice.isListening ? "Stop Listening" : "Start Listening") { model.voice.toggleListening() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            ForEach(WorkspaceTab.allCases) { tab in
                Button(tab.title) { model.ui.selectedTab = tab }
                    .keyboardShortcut(tab.shortcut)
            }
            Divider()
            Button(model.ui.showInspector ? "Hide Inspector" : "Show Inspector") { model.ui.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { model.ui.activeSheet = .keyboardShortcuts }
                .keyboardShortcut("/", modifiers: [.command])
            Button("Welcome to Prism") { model.ui.activeSheet = .welcome }
        }
    }
}

/// Open/Save panels.
@MainActor
enum FileActions {
    static func open(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.prismProject, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a Prism project (.prismlights)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.openDocument(url)
    }

    static func save(_ model: AppModel) {
        if let url = model.show.fileURL {
            write(model, to: url)
        } else {
            saveAs(model)
        }
    }

    static func saveAs(_ model: AppModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.prismProject]
        panel.nameFieldStringValue = "\(model.show.project.name).\(Project.fileExtension)"
        panel.message = "Project files include your lights, layout, looks and fixture profiles — send them to anyone using Prism."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(model, to: url)
    }

    private static func write(_ model: AppModel, to url: URL) {
        do {
            try model.show.save(to: url)
            model.ui.toast("Saved \(url.lastPathComponent)", style: .success, systemImage: "checkmark.circle")
        } catch {
            model.presentError("Couldn't save the project", error)
        }
    }
}
