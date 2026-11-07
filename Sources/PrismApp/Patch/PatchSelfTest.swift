import Foundation
import PrismCore

/// In-app self-test checks for the Patch & Lightkey Importer workstream.
@MainActor
enum PatchSelfTest {
    static var checks: [SelfTest.Check] {
        [
            SelfTest.Check(name: "patch.lightkeyImport") { app in
                do {
                    let data = try LightkeyArchiveBuilder.londonStudioArchiveData()
                    let result = try LightkeyImporter.importProject(
                        from: data,
                        projectName: "London Studio",
                        library: app.library.lookup
                    )
                    guard result.importedFixtureCount == 10 else {
                        return "Expected 10 imported Lightkey fixtures, got \(result.importedFixtureCount)"
                    }
                    guard result.importedLookCount >= 3 else {
                        return "Expected >= 3 imported Lightkey looks, got \(result.importedLookCount)"
                    }
                    let resolved = result.project.resolvedFixtures(library: app.library.lookup)
                    guard PatchMath.conflicts(resolved).isEmpty else {
                        return "Imported Lightkey rig had address conflicts"
                    }
                    return nil
                } catch {
                    return "Lightkey import failed: \(error.localizedDescription)"
                }
            },
            SelfTest.Check(name: "patch.conflictAutoFix") { app in
                let originalFixtures = app.show.fixtures
                guard originalFixtures.count >= 2 else { return "Need at least 2 fixtures in demo rig" }
                let firstAddr = originalFixtures[0].address ?? 1
                let secondID = originalFixtures[1].id
                app.show.setAddress(secondID, universe: originalFixtures[0].universe, address: firstAddr)
                let detected = PatchMath.conflicts(app.show.resolvedFixtures)
                guard !detected.isEmpty else {
                    app.show.undo()
                    return "Conflict was not detected when two fixtures shared address \(firstAddr)"
                }
                let changes = app.show.fixPatchConflicts(style: .packed)
                let afterConflicts = PatchMath.conflicts(app.show.resolvedFixtures)
                // Restore original demo rig via undo twice
                app.show.undo()
                app.show.undo()
                guard !changes.isEmpty && afterConflicts.isEmpty else {
                    return "fixPatchConflicts did not clear all conflicts"
                }
                return nil
            },
            SelfTest.Check(name: "patch.setupCardsAndTester") { app in
                let resolved = app.show.resolvedFixtures
                let cards = SetupCardGenerator.cards(for: resolved)
                guard cards.count == resolved.count, let firstCard = cards.first else {
                    return "Expected \(resolved.count) setup cards, got \(cards.count)"
                }
                guard !firstCard.headline.isEmpty, firstCard.dipSwitches.count == 9 else {
                    return "Invalid setup card fields"
                }
                if let firstRF = resolved.first {
                    let walk = AddressScanPlanner.pixelWalkOverrides(for: firstRF, activePixel: 0)
                    app.show.setRawOverrides(walk)
                    app.engine.tick()
                    app.show.clearRawOverrides()
                    app.engine.tick()
                }
                return nil
            },
        ]
    }
}
