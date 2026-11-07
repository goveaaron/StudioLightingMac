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
        NSApp.windows.first {
            $0.isVisible && $0.contentView != nil && !($0 is NSPanel) && $0.sheetParent == nil && $0.frame.width > 600
        }
    }

    private static func prepareWindow() {
        guard let w = mainWindow else { return }
        let size = NSSize(width: 1440, height: 900)
        var frame = w.frame
        frame.size = w.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        if let screen = w.screen ?? NSScreen.main {
            // Centered horizontally: on small CI displays (1024 pt wide) the window overhangs both
            // edges, but centered sheets and popovers stay fully on-screen. `capture` stitches
            // display-wide tiles so the whole window still ends up in the screenshot.
            frame.origin = NSPoint(x: screen.visibleFrame.midX - frame.width / 2,
                                   y: screen.visibleFrame.maxY - frame.height)
        }
        w.setFrame(frame, display: true)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Captures the main window to a PNG. The window-server capture already includes any
    /// attached sheet (it is part of the window's group), so nothing is composited on top.
    /// Returns the method used ("window-server" or "cache") or nil on failure.
    @discardableResult
    static func capture(to url: URL) async -> String? {
        guard let w = mainWindow else { return nil }
        if let image = await fullWindowImage(of: w), writePNG(image, to: url) {
            return "window-server"
        }
        // Fallback: AppKit rendering (no permission needed, but glass/vibrancy render blank).
        guard cacheCapture(window: w, to: url) else { return nil }
        if let sheet = w.attachedSheet {
            let sheetURL = url.deletingPathExtension().appendingPathExtension("sheet.png")
            _ = cacheCapture(window: sheet, to: sheetURL)
        }
        return "cache"
    }

    /// The window server leaves the parts of a window that hang off the display blank, and CI
    /// displays (1024 pt) are narrower than the tour window (1440 pt). So when the window is
    /// wider than the display, capture it in display-wide tiles — sliding the window so each
    /// strip is on-screen in turn — and stitch the strips back together.
    static func fullWindowImage(of w: NSWindow) async -> CGImage? {
        guard let screen = w.screen ?? NSScreen.main else { return await windowServerImage(of: w) }
        let visible = screen.visibleFrame
        let windowWidth = w.frame.width
        guard windowWidth > visible.width + 1, visible.width > 100 else { return await windowServerImage(of: w) }

        // Tile offsets (in window points): 0, V, 2V, … and finally flush right.
        var offsets: [CGFloat] = []
        var next: CGFloat = 0
        while next + visible.width < windowWidth {
            offsets.append(next)
            next += visible.width
        }
        offsets.append(windowWidth - visible.width)

        let originalOrigin = w.frame.origin
        defer { w.setFrameOrigin(originalOrigin) }
        var tiles: [(image: CGImage, from: CGFloat, to: CGFloat)] = []
        var covered: CGFloat = 0
        for offset in offsets {
            w.setFrameOrigin(NSPoint(x: visible.minX - offset, y: originalOrigin.y))
            await sleep(0.35)
            guard let image = await windowServerImage(of: w) else { return nil }
            let end = min(offset + visible.width, windowWidth)
            tiles.append((image: image, from: covered, to: end))
            covered = end
        }
        return stitch(tiles, windowWidth: windowWidth)
    }

    /// Joins horizontal strips; each tile contributes window points `from..<to`.
    static func stitch(_ tiles: [(image: CGImage, from: CGFloat, to: CGFloat)], windowWidth: CGFloat) -> CGImage? {
        guard let first = tiles.first?.image else { return nil }
        let width = tiles.map { $0.image.width }.min() ?? first.width
        let height = tiles.map { $0.image.height }.min() ?? first.height
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = CGFloat(width) / max(windowWidth, 1)
        for tile in tiles {
            let strip = CGRect(x: (tile.from * scale).rounded(.down), y: 0,
                               width: ((tile.to - tile.from) * scale).rounded(.up), height: CGFloat(height))
            ctx.saveGState()
            ctx.clip(to: strip)
            // Align tops (Core Graphics origin is bottom-left).
            ctx.draw(tile.image, in: CGRect(x: 0, y: CGFloat(height - tile.image.height),
                                            width: CGFloat(tile.image.width), height: CGFloat(tile.image.height)))
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    /// Real on-screen appearance via ScreenCaptureKit (glass and vibrancy render correctly; parts
    /// of the window that hang off the display come back blank — see `fullWindowImage`). Needs
    /// screen-recording permission, which CI grants to processes started from the runner shell.
    /// Times out after a few seconds instead of hanging.
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
