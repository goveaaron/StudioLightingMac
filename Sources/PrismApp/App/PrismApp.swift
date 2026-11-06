import SwiftUI
import AppKit
import PrismCore

@main
struct PrismApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Prism", id: AppModel.mainWindowID) {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1100, minHeight: 680)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { PrismCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
        }

        MenuBarExtra(isInserted: Binding(
            get: { model.preferences.showMenuBarExtra },
            set: { model.preferences.showMenuBarExtra = $0 })) {
            MenuBarPanel()
                .environment(model)
                .preferredColorScheme(.dark)
        } label: {
            Image(systemName: "light.recessed.3.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lighting must not stall: opt out of App Nap / timer coalescing and idle system sleep
        // while Prism runs (DMX output and music mode are time-critical).
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Prism is driving DMX lighting")
        MainActor.assumeIsolated {
            AppModel.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.shutdown()
        }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    /// Keep running (and driving the lights) when the window is closed; the menu bar control
    /// and Dock icon bring it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == Project.fileExtension }) ?? urls.first else { return }
            if AppModel.shared.isStarted {
                AppModel.shared.openDocument(url)
            } else {
                // Launch-by-double-click: open after boot.
                DispatchQueue.main.async { AppModel.shared.openDocument(url) }
            }
        }
    }
}
