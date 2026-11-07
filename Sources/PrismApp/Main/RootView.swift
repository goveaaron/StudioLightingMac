import SwiftUI
import UniformTypeIdentifiers
import PrismCore

/// Window root: main layout + sheets, toasts, assistant overlay, file drops.
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var ui = app.ui
        MainWindow()
            .background(Theme.window)
            .sheet(item: $ui.activeSheet) { sheet in
                SheetRouter(sheet: sheet)
                    .environment(app)
                    .preferredColorScheme(.dark)
            }
            .overlay(alignment: .top) { ToastStack().padding(.top, 8) }
            .overlay {
                if app.ui.isAssistantPresented {
                    AssistantOverlay()
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .animation(Theme.Motion.snappy, value: app.ui.isAssistantPresented)
            .onOpenURL { app.openDocument($0) }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { $0.pathExtension.lowercased() == Project.fileExtension }) else { return false }
                app.openDocument(url)
                return true
            }
    }
}

/// Routes `AppSheet` values to their views. Feature workstreams replace the placeholders.
struct SheetRouter: View {
    let sheet: AppSheet
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch sheet {
            case .addFixture: AddFixtureSheet()
            case .exportProject: ShareProjectSheet()
            case .importLightkey: ImportLightkeySheet()
            case .keyboardShortcuts: KeyboardShortcutsSheet()
            case .hardwareTest: HardwareTestSheet()
            case .outputSettings: OutputSettingsSheet()
            case .lightFinder: LightFinderSheet()
            case .welcome: WelcomeSheet()
            case .templates: TemplatesSheet()
            case .setupCards: SetupCardsSheet()
            case .addressScan: AddressScanSheet()
            case .troubleshooter: TroubleshooterSheet()
            case .profileEditor: ProfileEditorSheet()
            case .shareRemote: ShareRemoteSheet()
            }
        }
        .background(Theme.panel)
    }
}

struct ToastStack: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 6) {
            ForEach(app.ui.toasts) { toast in
                ToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Theme.Motion.snappy, value: app.ui.toasts)
        .allowsHitTesting(false)
    }
}
