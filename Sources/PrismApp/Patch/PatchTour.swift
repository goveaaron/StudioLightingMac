import Foundation
import PrismCore

/// Screenshot-tour scenes for the Patch & Lightkey Importer workstream.
@MainActor
enum PatchTour {
    static var scenes: [ScreenshotTour.Scene] {
        [
            ScreenshotTour.Scene(name: "patch-channel-tester") { app in
                app.ui.selectedTab = .patch
                app.show.selection = [DemoRig.IDs.tube(1)]
                PatchWorkspaceState.shared.showChannelTester = true
                PatchWorkspaceState.shared.activeTestPattern = .pixelWalk
                PatchWorkspaceState.shared.activeWalkPixel = 2
            },
            ScreenshotTour.Scene(name: "patch-setup-cards") { app in
                PatchWorkspaceState.shared.showChannelTester = false
                app.show.clearRawOverrides()
                app.ui.selectedTab = .patch
                app.ui.activeSheet = .setupCards
            },
            ScreenshotTour.Scene(name: "patch-troubleshooter") { app in
                app.ui.selectedTab = .patch
                app.ui.activeSheet = .troubleshooter
            },
            ScreenshotTour.Scene(name: "patch-address-scan") { app in
                app.ui.selectedTab = .patch
                app.ui.activeSheet = .addressScan
            },
            ScreenshotTour.Scene(name: "patch-profile-editor") { app in
                app.show.clearRawOverrides()
                app.ui.selectedTab = .patch
                app.ui.activeSheet = .profileEditor
            },
            ScreenshotTour.Scene(name: "patch-lightkey-import") { app in
                app.ui.selectedTab = .patch
                app.ui.activeSheet = .importLightkey
            },
        ]
    }
}
