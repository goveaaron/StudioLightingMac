import SwiftUI
import ScreenCaptureKit
import AppKit
import PrismCore

/// CI screenshot harness: `Prism --screenshot-tour <dir>` drives the UI through every registered
/// scene, renders the window to PNG and quits. Lets developers (and agents) *see* the UI on
/// headless CI runners. Each workstream registers scenes in its own `<Feature>Tour.swift`.
@MainActor
enum ScreenshotTour {
    struct Scene {
        let name: String
        /// Puts the app into the state to capture. Runs on the main actor.
        let setup: @MainActor (AppModel) async -> Void
        /// Extra settle time (animations, camera, async loads).
        var settle: Double = 1.0
    }

    static var allScenes: [Scene] {
        coreScenes
            + StageTour.scenes + InspectorTour.scenes + LooksTour.scenes + PatchTour.scenes
            + MusicTour.scenes + CameraTour.scenes + RemoteTour.scenes + AssistantTour.scenes
            + OutputTour.scenes + OnboardingTour.scenes + EffectsTour.scenes
    }

    static var coreScenes: [Scene] {
        [
            Scene(name: "stage") { app in
                app.ui.selectedTab = .stage
                recall(app, "Chill Vibes 4")
            },
            Scene(name: "stage-selected-tube") { app in
                app.ui.selectedTab = .stage
                app.show.selection = [DemoRig.IDs.tube(1)]
            },
            Scene(name: "stage-teal-blue-pink") { app in
                app.ui.selectedTab = .stage
                app.show.selection = [DemoRig.IDs.pn1]
                recall(app, "Teal Left, Blue Right, Pink Above")
            },
            Scene(name: "live") { app in app.ui.selectedTab = .live },
            Scene(name: "patch") { app in app.ui.selectedTab = .patch },
            Scene(name: "music") { app in app.ui.selectedTab = .music },
            Scene(name: "camera") { app in app.ui.selectedTab = .camera },
            Scene(name: "remote") { app in app.ui.selectedTab = .remote },
            Scene(name: "assistant") { app in
                app.ui.selectedTab = .stage
                app.ui.isAssistantPresented = true
            },
            Scene(name: "add-light-sheet") { app in app.ui.activeSheet = .addFixture },
            Scene(name: "welcome-sheet") { app in app.ui.activeSheet = .welcome },
        ]
    }

    /// Recalls a demo look instantly by name.
    static func recall(_ app: AppModel, _ name: String) {
        if let look = app.show.looks.first(where: { $0.name == name }) {
            app.show.recallLook(look.id, fade: 0)
        }
    }

    static func run(app: AppModel, outputDirectory: URL) async {
        let fm = FileManager.default
        try? fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var log: [String] = ["Prism screenshot tour — \(AppResources.appVersion) — macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        await sleep(2.5)
        prepareWindow()
        await sleep(1.0)

        for (index, scene) in allScenes.enumerated() {
            await resetUI(app)
            await sleep(0.3)
            await scene.setup(app)
            await sleep(scene.settle)
            let base = String(format: "%02d-%@", index, scene.name)
            let method = await capture(to: outputDirectory.appendingPathComponent("\(base).png"))
            log.append("\(method != nil ? "ok    " : "FAILED") \(base)\(method.map { "  [\($0)]" } ?? "")")
        }
        await resetUI(app)
        try? log.joined(separator: "\n").write(to: outputDirectory.appendingPathComponent("tour.log"), atomically: true, encoding: .utf8)
        print(log.joined(separator: "\n"))
        fflush(stdout)
        NSApp.terminate(nil)
    }

    private static func resetUI(_ app: AppModel) async {
        if app.ui.activeSheet != nil {
            app.ui.activeSheet = nil
            await sleep(0.6)
        }
        app.ui.isAssistantPresented = false
        app.ui.showInspector = true
        app.show.selection = []
    }

    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) && $0.frame.width > 600 }
    }

    private static func prepareWindow() {
        guard let w = mainWindow else { return }
        let size = NSSize(width: 1440, height: 900)
        var frame = w.frame
        frame.size = w.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        if let screen = w.screen ?? NSScreen.main {
            // Centered horizontally: on small CI displays (1024 pt wide) the window overhangs both
            // edges, but centered sheets and popovers stay fully on-screen.
            frame.origin = NSPoint(x: screen.visibleFrame.midX - frame.width / 2,
                                   y: screen.visibleFrame.maxY - frame.height)
        }
        w.setFrame(frame, display: true)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Captures the main window (plus any attached sheet, composited in place) to a PNG.
    /// Returns the method used ("window-server" or "cache") or nil on failure.
    @discardableResult
    static func capture(to url: URL) async -> String? {
        guard let w = mainWindow else { return nil }
        if let image = await windowServerImage(of: w) {
            var composed = image
            if let sheet = w.attachedSheet, let sheetImage = await windowServerImage(of: sheet) {
                composed = composite(base: image, baseFrame: w.frame, overlay: sheetImage, overlayFrame: sheet.frame) ?? image
            }
            if writePNG(composed, to: url) { return "window-server" }
        }
        // Fallback: AppKit rendering (no permission needed, but glass/vibrancy render blank).
        guard cacheCapture(window: w, to: url) else { return nil }
        if let sheet = w.attachedSheet {
            let sheetURL = url.deletingPathExtension().appendingPathExtension("sheet.png")
            _ = cacheCapture(window: sheet, to: sheetURL)
        }
        return "cache"
    }

    /// Real on-screen appearance via ScreenCaptureKit (works even where the window extends past
    /// the display). Needs screen-recording permission, which CI grants to processes started
    /// from the runner shell. Times out after a few seconds instead of hanging.
    static func windowServerImage(of window: NSWindow) async -> CGImage? {
        let windowID = CGWindowID(window.windowNumber)
        return await withTaskGroup(of: CGImage?.self) { group in
            group.addTask { @MainActor in
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
                    let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                    let config = SCStreamConfiguration()
                    let scale = CGFloat(filter.pointPixelScale)
                    config.width = max(Int(filter.contentRect.width * scale), 1)
                    config.height = max(Int(filter.contentRect.height * scale), 1)
                    config.showsCursor = false
                    config.ignoreShadowsSingleWindow = true
                    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                } catch {
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Draws `overlay` (e.g. a sheet) on top of `base` at its on-screen position.
    static func composite(base: CGImage, baseFrame: NSRect, overlay: CGImage, overlayFrame: NSRect) -> CGImage? {
        let scale = CGFloat(base.width) / max(baseFrame.width, 1)
        guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        // Core Graphics origin is bottom-left, like screen coordinates.
        let rect = CGRect(x: (overlayFrame.minX - baseFrame.minX) * scale,
                          y: (overlayFrame.minY - baseFrame.minY) * scale,
                          width: overlayFrame.width * scale, height: overlayFrame.height * scale)
        ctx.draw(overlay, in: rect)
        return ctx.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// Renders the whole window (including toolbar) into a PNG without screen-recording permission.
    static func cacheCapture(window: NSWindow, to url: URL) -> Bool {
        guard let view = window.contentView?.superview ?? window.contentView else { return false }
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
