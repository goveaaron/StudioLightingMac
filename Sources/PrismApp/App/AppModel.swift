import Foundation
import AppKit
import PrismCore

/// Lifecycle for app-wide services (outputs, music, voice, remote, MIDI…).
@MainActor
protocol AppService: AnyObject {
    /// Called once after every service exists and the show is loaded.
    func start(app: AppModel)
    /// Called on quit. Must return quickly (< 200 ms) and never block on hardware.
    func shutdown()
}

/// Root object: owns the engine, the show and every service. One per app.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()
    static let mainWindowID = "main"

    let launch: LaunchOptions
    let preferences: AppPreferences
    let library: LibraryStore
    let engine: EngineCore
    let show: ShowController
    let ui = UIState()

    // Services (each lives in its own feature folder).
    let outputs: OutputManager
    let music: MusicController
    let assistant: AssistantController
    let voice: VoiceController
    let camera: CameraController
    let remote: RemoteController
    let integrations: IntegrationsController

    private(set) var isStarted = false

    private var services: [AppService] {
        [outputs, music, assistant, voice, camera, remote, integrations]
    }

    private init() {
        let launch = LaunchOptions.current
        if launch.reset { AppPreferences.resetAll() }
        self.launch = launch
        let preferences = AppPreferences()
        self.preferences = preferences
        let library = LibraryStore()
        self.library = library
        let engine = EngineCore(frameRate: preferences.frameRate)
        self.engine = engine
        self.show = ShowController(engine: engine, library: library, preferences: preferences)
        self.outputs = OutputManager(engine: engine)
        self.music = MusicController()
        self.assistant = AssistantController()
        self.voice = VoiceController()
        self.camera = CameraController()
        self.remote = RemoteController()
        self.integrations = IntegrationsController()
    }

    /// Boots everything (idempotent). Order matters: library → show → engine → services.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        CrashGuard.markLaunch()
        library.load()
        show.restoreOnLaunch(options: launch)
        show.start()
        engine.start()
        for service in services { service.start(app: self) }
        if !preferences.hasCompletedOnboarding && !launch.isAutomated {
            ui.activeSheet = .welcome
        }
        if CrashGuard.previousLaunchCrashed && !launch.isAutomated {
            ui.toast("Prism restored your last session after an unexpected quit.", style: .warning,
                     systemImage: "lifepreserver", duration: 6)
        }
        if let dir = launch.screenshotTourDirectory {
            ui.isRunningTour = true
            Task { @MainActor in await ScreenshotTour.run(app: self, outputDirectory: dir) }
        } else if launch.selfTest {
            Task { @MainActor in await SelfTest.runAndExit(app: self) }
        }
    }

    /// Called from applicationWillTerminate. Fast and non-blocking.
    func shutdown() {
        guard isStarted else { return }
        if preferences.blackoutOnQuit {
            show.setBlackout(true)
            engine.tick()
        }
        show.shutdown()
        for service in services { service.shutdown() }
        engine.stop()
        CrashGuard.markCleanExit()
    }

    // MARK: Document actions shared by menus, toolbar and drag & drop

    func openDocument(_ url: URL) {
        do {
            try show.open(url: url)
            ui.toast("Opened \(show.project.name)", style: .success, systemImage: "folder")
            if !show.openReport.isEmpty {
                ui.toast("Repaired \(show.openReport.count) issue(s) in the file.", style: .warning,
                         systemImage: "wrench.and.screwdriver")
            }
        } catch {
            presentError("Couldn't open “\(url.lastPathComponent)”", error)
        }
    }

    func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if launch.isAutomated {
            NSLog("Prism error: \(title): \(error.localizedDescription)")
        } else {
            alert.runModal()
        }
    }
}

/// Detects launches that didn't end cleanly so we can offer safe mode / reassure the user.
enum CrashGuard {
    private static let key = "prism.cleanExit"
    private(set) static var previousLaunchCrashed = false

    static func markLaunch() {
        let d = UserDefaults.standard
        previousLaunchCrashed = d.object(forKey: key) != nil && !d.bool(forKey: key)
        d.set(false, forKey: key)
    }

    static func markCleanExit() {
        UserDefaults.standard.set(true, forKey: key)
    }
}
