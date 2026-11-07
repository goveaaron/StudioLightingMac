import Foundation
import PrismCore

/// Screenshot-tour scenes for the Patch & Lightkey Importer workstream.
///
/// Scenes that change the show (adding lights, creating a conflict) count their edits in
/// `pendingUndos`; the next patch scene undoes them first, so later scenes and other teams'
/// scenes always see the untouched demo rig.
@MainActor
enum PatchTour {
    /// Show edits made by the previous patch scene that still need undoing.
    static var pendingUndos = 0

    static func undoTourEdits(_ app: AppModel) {
        guard pendingUndos > 0 else { return }
        while pendingUndos > 0 {
            app.show.undo()
            pendingUndos -= 1
        }
        // Undo announces itself with a toast; keep it out of the next screenshot.
        app.ui.toasts.removeAll()
    }

    /// Opens the Add Light wizard keeping whatever state the scene prepared.
    static func presentWizard(_ app: AppModel) {
        AddLightWizardModel.shared.keepStateOnNextAppear = true
        app.ui.selectedTab = .patch
        app.ui.activeSheet = .addFixture
    }

    static var scenes: [ScreenshotTour.Scene] {
        [
            ScreenshotTour.Scene(name: "patch-add-light-1-pick") { app in
                PatchTour.undoTourEdits(app)
                let w = AddLightWizardModel.shared
                w.reset()
                w.select(DemoRig.pixelTubeID, app: app)
                PatchTour.presentWizard(app)
            },
            ScreenshotTour.Scene(name: "patch-add-light-2-plan") { app in
                PatchTour.undoTourEdits(app)
                let w = AddLightWizardModel.shared
                w.reset()
                w.select(DemoRig.pixelTubeID, app: app)
                w.quantity = 2
                w.showModeChoices = true
                w.step = .configure
                PatchTour.presentWizard(app)
            },
            ScreenshotTour.Scene(name: "patch-add-light-3-setup") { app in
                PatchTour.undoTourEdits(app)
                let w = AddLightWizardModel.shared
                w.reset()
                w.select(DemoRig.pixelTubeID, app: app)
                w.quantity = 2
                if w.commit(app: app) {
                    PatchTour.pendingUndos += 1
                    // The "Did it blink?" question, as right after pressing Blink it.
                    w.askingAbout = w.added.first?.id
                }
                PatchTour.presentWizard(app)
            },
            ScreenshotTour.Scene(name: "patch-add-light-4-done") { app in
                let w = AddLightWizardModel.shared
                if let first = w.added.first { w.confirmed.insert(first.id) }
                if let second = w.added.dropFirst().first { w.notResponding.insert(second.id) }
                w.step = .done
                // The summary renders from the wizard's own record, so the demo rig can be restored now.
                PatchTour.undoTourEdits(app)
                PatchTour.presentWizard(app)
            },
            ScreenshotTour.Scene(name: "patch-universe-conflict") { app in
                PatchTour.undoTourEdits(app)
                app.ui.selectedTab = .patch
                let fixtures = app.show.fixtures
                if let first = fixtures.first, let second = fixtures.dropFirst().first, let address = first.address {
                    // Two lights sharing channels: the map and the list both flag it.
                    app.show.setAddress(second.id, universe: first.universe, address: address)
                    PatchTour.pendingUndos += 1
                    PatchWorkspaceState.shared.selectedUniverse = first.universe
                }
                PatchWorkspaceState.shared.show512CellGrid = true
                PatchWorkspaceState.shared.showChannelTester = false
            },
            ScreenshotTour.Scene(name: "patch-channel-tester") { app in
                PatchTour.undoTourEdits(app)
                app.ui.selectedTab = .patch
                app.show.selection = [DemoRig.IDs.tube(1)]
                PatchWorkspaceState.shared.showChannelTester = true
                PatchWorkspaceState.shared.activeTestPattern = .pixelWalk
                PatchWorkspaceState.shared.activeWalkPixel = 2
            },
            ScreenshotTour.Scene(name: "patch-setup-cards") { app in
                PatchTour.undoTourEdits(app)
                PatchWorkspaceState.shared.showChannelTester = false
                app.show.clearRawOverrides()
                app.ui.selectedTab = .patch
                app.ui.activeSheet = .setupCards
            },
            ScreenshotTour.Scene(name: "patch-troubleshooter") { app in
                PatchTour.undoTourEdits(app)
                app.ui.selectedTab = .patch
                app.ui.activeSheet = .troubleshooter
            },
            ScreenshotTour.Scene(name: "patch-address-scan") { app in
                PatchTour.undoTourEdits(app)
                app.ui.selectedTab = .patch
                app.ui.activeSheet = .addressScan
            },
            ScreenshotTour.Scene(name: "patch-profile-editor") { app in
                PatchTour.undoTourEdits(app)
                app.show.clearRawOverrides()
                app.ui.selectedTab = .patch
                app.ui.activeSheet = .profileEditor
            },
            ScreenshotTour.Scene(name: "patch-lightkey-import") { app in
                PatchTour.undoTourEdits(app)
                app.ui.selectedTab = .patch
                app.ui.activeSheet = .importLightkey
            },
        ]
    }
}
