import SwiftUI
import PrismCore

/// Three-column layout: Looks sidebar · workspace (Stage/Live/Patch/Music/Camera/Remote) ·
/// Inspector, with a unified toolbar and a bottom master bar.
struct MainWindow: View {
    @Environment(AppModel.self) private var app
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var ui = app.ui
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LooksSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            WorkspaceView()
                .safeAreaInset(edge: .bottom, spacing: 0) { BottomBar() }
        }
        .inspector(isPresented: $ui.showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .toolbar { toolbarContent }
        .navigationTitle(app.show.project.name)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ProjectTitleView()
        }
        ToolbarItem(placement: .principal) {
            WorkspacePicker()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            OutputStatusButton()
            MusicToggleButton()
            AssistantButton()
            BlackoutButton()
            Button {
                app.ui.showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show/hide the inspector (⌥⌘I)")
        }
    }
}

/// Center area for the selected workspace tab.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            switch app.ui.selectedTab {
            case .stage: StageWorkspace()
            case .live: LiveWorkspace()
            case .patch: PatchWorkspace()
            case .music: MusicWorkspace()
            case .camera: CameraWorkspace()
            case .remote: RemoteWorkspace()
            }
        }
    }
}

// MARK: - Toolbar pieces

struct ProjectTitleView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        HStack(spacing: 8) {
            PrismLogo(size: 18)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(app.show.project.name)
                        .font(Theme.Font.headline)
                        .foregroundStyle(Theme.textPrimary)
                    if app.show.isDirty {
                        Circle().fill(Theme.textTertiary).frame(width: 5, height: 5)
                            .help("Unsaved changes (your session is autosaved)")
                    }
                }
                Text(app.outputs.summary.title)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 4)
    }
}

struct WorkspacePicker: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        @Bindable var ui = app.ui
        Picker("Workspace", selection: $ui.selectedTab) {
            ForEach(WorkspaceTab.allCases) { tab in
                Label(tab.title, systemImage: tab.systemImage).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.titleAndIcon)
        .frame(minWidth: 520)
        .help("Switch workspace (⌘1–⌘6)")
    }
}

struct OutputStatusButton: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let s = app.outputs.summary
        Button {
            app.ui.selectedTab = .patch
        } label: {
            StatusPill(text: s.title, color: color(for: s.level), pulsing: s.level == .connected)
        }
        .buttonStyle(.plain)
        .help(s.detail)
    }

    private func color(for level: OutputSummary.Level) -> Color {
        switch level {
        case .connected: return Theme.success
        case .simulated: return Theme.accent
        case .warning: return Theme.warning
        case .error: return Theme.danger
        }
    }
}

struct MusicToggleButton: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let on = app.show.live.music.enabled
        Button {
            app.music.setEnabled(!on)
        } label: {
            Label("Music", systemImage: on ? "waveform.circle.fill" : "waveform.circle")
                .foregroundStyle(on ? Theme.music : Theme.textSecondary)
        }
        .help(on ? "Music mode is on — lights follow the music" : "Turn on music mode")
    }
}

struct AssistantButton: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Button {
            app.ui.isAssistantPresented = true
        } label: {
            Label("Ask Prism", systemImage: "sparkles")
        }
        .help("Ask Prism to change the lights (⌘K)")
    }
}

struct BlackoutButton: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let on = app.show.live.blackout
        Button {
            app.show.toggleBlackout()
        } label: {
            Label("Blackout", systemImage: on ? "lightbulb.slash.fill" : "lightbulb.slash")
                .foregroundStyle(on ? Theme.live : Theme.textSecondary)
        }
        .help(on ? "Blackout is ON — click to bring the lights back (⇧⌘B)" : "Blackout all lights (⇧⌘B)")
    }
}

/// The Prism mark: a small spectrum triangle.
struct PrismLogo: View {
    var size: CGFloat = 20
    var body: some View {
        Canvas { ctx, sz in
            var p = Path()
            p.move(to: CGPoint(x: sz.width / 2, y: sz.height * 0.08))
            p.addLine(to: CGPoint(x: sz.width * 0.95, y: sz.height * 0.9))
            p.addLine(to: CGPoint(x: sz.width * 0.05, y: sz.height * 0.9))
            p.closeSubpath()
            ctx.fill(p, with: .linearGradient(Gradient(colors: Theme.spectrumColors),
                                              startPoint: .zero, endPoint: CGPoint(x: sz.width, y: sz.height)))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
