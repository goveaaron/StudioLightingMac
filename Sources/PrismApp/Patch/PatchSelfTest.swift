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
            SelfTest.Check(name: "patch.addLightWizard") { app in
                let wizard = AddLightWizardModel.shared
                let before = app.show.fixtures.count
                wizard.reset()
                wizard.select(DemoRig.pixelTubeID, app: app)
                wizard.quantity = 2
                guard let plan = wizard.plan(app: app) else {
                    return "No plan for 2 × \(DemoRig.pixelTubeID) (definition missing?)"
                }
                guard plan.assignments.count == 2 else {
                    return "Plan placed \(plan.assignments.count) of 2 lights"
                }
                guard wizard.commit(app: app) else { return "Adding the planned lights failed" }

                var failure: String?
                let ids = wizard.added.map(\.id)
                if ids.count != 2 || app.show.fixtures.count != before + 2 {
                    failure = "Expected 2 new lights, got \(ids.count) (show has \(app.show.fixtures.count), was \(before))"
                } else if !PatchMath.conflicts(app.show.resolvedFixtures).isEmpty {
                    failure = "The wizard created an address conflict"
                } else {
                    for (id, planned) in zip(ids, plan.assignments) {
                        guard let rf = app.show.resolved(id) else { failure = "New light \(id) not found"; break }
                        if rf.fixture.address != planned.address || rf.fixture.universe != planned.universe {
                            failure = "Light landed at \(rf.fixture.universe).\(rf.fixture.address ?? 0); the plan said \(planned.universe).\(planned.address)"
                            break
                        }
                        if rf.mode.name != plan.modeName {
                            failure = "Light got mode \(rf.mode.name); the plan said \(plan.modeName)"
                            break
                        }
                        let steps = SetupWalkthrough.make(for: rf)?.steps.count ?? 0
                        if steps < 3 {
                            failure = "Setup walkthrough has only \(steps) steps"
                            break
                        }
                    }
                }
                // One undo step must remove everything the wizard added.
                app.show.undo()
                wizard.reset()
                if failure == nil && app.show.fixtures.count != before {
                    failure = "One undo didn't remove the wizard's lights (\(app.show.fixtures.count) vs \(before))"
                }
                return failure
            },
        ]
    }
}
