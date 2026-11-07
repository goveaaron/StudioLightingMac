import XCTest
import Foundation
@testable import PrismCore

/// History (attributed timeline, coalescing, revert) and persistence (migration, tolerant decoding,
/// atomic writes, rolling backups, look sharing/merging, validation repairs).
final class HistoryAndPersistenceTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - History

    func testUndoHistoryAttributedTimelineCoalescingAndRevert() throws {
        let lib = TestResources.library()
        let exec = CommandExecutor(library: lib.definition, now: { 10 })
        let original = ShowDocument(project: DemoRig.londonStudio())
        var doc = original
        var history = UndoHistory()

        // A UI slider drag: five changes, one undo step.
        for i in 0..<5 {
            let before = doc
            exec.apply(.setIntensity(.all, 0.2 + Double(i) * 0.1), to: &doc)
            history.record(before: before, after: doc, name: "Brightness", origin: .ui,
                           coalesceKey: "intensity", now: 100 + Double(i) * 0.2)
        }
        XCTAssertEqual(history.undoStack.count, 1)

        // An assistant plan with several commands is one step.
        let beforePlan = doc
        exec.apply([
            .setKelvin(.role(.key), 4000),
            .setColor(.role(.background), .rgb(RGB(r: 1, g: 0.4, b: 0.1))),
            .setIntensity(.role(.background), 0.4),
        ], to: &doc, origin: .assistant)
        history.record(before: beforePlan, after: doc, name: "Warm interview", origin: .assistant,
                       coalesceKey: nil, now: 101.2)

        // The same key from another origin never merges into the UI step.
        let remote = CommandOrigin.remote(clientID: "iPad", linkID: UUID())
        let beforeRemote = doc
        exec.apply(.setIntensity(.role(.background), 0.9), to: &doc, origin: remote)
        history.record(before: beforeRemote, after: doc, name: "Brightness", origin: remote,
                       coalesceKey: "intensity", now: 101.3)

        XCTAssertEqual(history.undoStack.count, 3)
        XCTAssertEqual(history.timeline.map(\.attributedTitle),
                       ["Remote (iPad): Brightness", "Assistant: Warm interview", "UI: Brightness"])
        XCTAssertEqual(history.undoName, "Brightness")

        // An active drag merges despite long pauses; ending it starts a new step.
        history.beginInteraction(key: "kelvin")
        for i in 0..<3 {
            let before = doc
            exec.apply(.setKelvin(.all, 3000 + Double(i) * 500), to: &doc)
            history.record(before: before, after: doc, name: "White Balance", coalesceKey: "kelvin",
                           now: 200 + Double(i) * 5)
        }
        XCTAssertEqual(history.undoStack.count, 4)
        history.endInteraction()
        let beforeNextDrag = doc
        exec.apply(.setKelvin(.all, 5600), to: &doc)
        history.record(before: beforeNextDrag, after: doc, name: "White Balance", coalesceKey: "kelvin", now: 210.1)
        XCTAssertEqual(history.undoStack.count, 5, "a new drag after endInteraction is its own step")

        // breakCoalescing splits even inside the time window.
        history.breakCoalescing()
        let beforeNudge = doc
        exec.apply(.setKelvin(.all, 5000), to: &doc)
        history.record(before: beforeNudge, after: doc, name: "White Balance", coalesceKey: "kelvin", now: 210.2)
        XCTAssertEqual(history.undoStack.count, 6)

        // Reverting to the oldest entry restores the document from before the first drag…
        let first = try XCTUnwrap(history.timeline.last)
        let reverted = try XCTUnwrap(history.revertTo(entryID: first.id, current: doc))
        XCTAssertEqual(reverted.document.live.base, UndoHistory.stripTransient(original).live.base)
        XCTAssertFalse(history.canUndo)
        XCTAssertEqual(history.redoStack.count, 6)

        // …and reverting "forward" redoes everything.
        let newest = try XCTUnwrap(history.redoStack.first)
        let forward = try XCTUnwrap(history.revertTo(entryID: newest.id, current: reverted.document))
        XCTAssertEqual(forward.document.live.base, UndoHistory.stripTransient(doc).live.base)
        XCTAssertEqual(history.undoStack.count, 6)
        XCTAssertNil(history.revertTo(entryID: UUID(), current: doc))
    }

    // MARK: - Migration & tolerant decoding

    func testV1ToV2MigrationDisablesEffectsOnKeyAndFill() throws {
        var v1 = DemoRig.londonStudio()
        v1.formatVersion = 1
        for i in v1.fixtures.indices { v1.fixtures[i].limits.allowEffects = true }
        let data = try ProjectIO.encoder().encode(v1)

        let report = try ProjectIO.decodeWithReport(data)
        XCTAssertEqual(report.project.formatVersion, Project.currentFormatVersion)
        XCTAssertTrue(report.fixes.contains("Migrated project from format v1 to v2."), "\(report.fixes)")
        let keyFill = report.project.fixtures.filter { $0.role == .key || $0.role == .fill }
        XCTAssertFalse(keyFill.isEmpty)
        XCTAssertTrue(keyFill.allSatisfy { !$0.limits.allowEffects })
        let others = report.project.fixtures.filter { $0.role != .key && $0.role != .fill }
        XCTAssertTrue(others.allSatisfy { $0.limits.allowEffects })

        // Current-version files are not "migrated" again.
        let current = try ProjectIO.decodeWithReport(ProjectIO.data(for: report.project))
        XCTAssertFalse(current.fixes.contains { $0.hasPrefix("Migrated") })
    }

    func testTolerantDecodingRepairsCorruptEntriesAndReportsThem() throws {
        let lib = TestResources.library()
        let good = DemoRig.londonStudio()
        let data = try ProjectIO.data(for: good, library: lib.definition)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        var fixtures = try XCTUnwrap(json["fixtures"] as? [[String: Any]])
        fixtures[0]["universe"] = "seven"
        fixtures[1]["name"] = 42
        fixtures.append(["corrupt": true, "id": "not-a-uuid"])
        json["fixtures"] = fixtures
        var looks = try XCTUnwrap(json["looks"] as? [[String: Any]])
        XCTAssertFalse(looks.isEmpty)
        looks[0]["fadeTime"] = "slow"
        looks.append(["garbage": 1])
        json["looks"] = looks
        json["groups"] = "not an array"
        json["stage"] = ["photoData": 12, "props": [["kind": "unicorn"]]]

        let report = try ProjectIO.decodeWithReport(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(report.project.fixtures.count, good.fixtures.count)
        XCTAssertEqual(report.project.fixtures[0].universe, 1)
        XCTAssertEqual(report.project.looks.count, good.looks.count)
        XCTAssertEqual(report.project.looks.first?.fadeTime, 1)
        XCTAssertTrue(report.project.groups.isEmpty)
        XCTAssertTrue(report.fixes.contains("Repaired 1 corrupt entry in fixtures."), "\(report.fixes)")
        XCTAssertTrue(report.fixes.contains("Repaired 1 corrupt entry in looks."), "\(report.fixes)")
        XCTAssertTrue(report.fixes.contains("Repaired corrupt groups section."), "\(report.fixes)")

        // Not a project at all.
        XCTAssertThrowsError(try ProjectIO.decodeWithReport(Data("[1,2,3]".utf8)))
        XCTAssertThrowsError(try ProjectIO.decodeWithReport(Data("{\"hello\": \"world\"}".utf8)))
        XCTAssertThrowsError(try ProjectIO.decodeWithReport(Data()))
        XCTAssertThrowsError(try ProjectIO.decodeWithReport(Data("{\"fixtures\": [".utf8)))

        // Far-future files are refused; slightly newer files open with a notice.
        json["formatVersion"] = Project.currentFormatVersion + 50
        XCTAssertThrowsError(try ProjectIO.decodeWithReport(JSONSerialization.data(withJSONObject: json))) { error in
            guard case ProjectIOError.tooNew = error else { return XCTFail("Unexpected error \(error)") }
        }
        json["formatVersion"] = Project.currentFormatVersion + 1
        let newer = try ProjectIO.decodeWithReport(JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(newer.fixes.contains { $0.contains("newer version") }, "\(newer.fixes)")
        XCTAssertEqual(newer.project.formatVersion, Project.currentFormatVersion)
    }

    func testValidationRepairsDuplicateIDsDanglingReferencesAndFolderCycles() throws {
        var p = DemoRig.londonStudio()
        let dupFixture = try XCTUnwrap(p.fixtures.first)
        p.fixtures.append(dupFixture)

        var a = LookFolder(name: "A")
        let b = LookFolder(name: "B", parentID: a.id)
        a.parentID = b.id // A ↔ B cycle
        let selfID = UUID()
        let selfParent = LookFolder(id: selfID, name: "Self", parentID: selfID)
        let orphan = LookFolder(name: "Orphan", parentID: UUID())
        p.folders = [a, b, b, selfParent, orphan]

        let group = FixtureGroup(name: "Tubes", fixtureIDs: [dupFixture.id, UUID()])
        p.groups = [group, group]

        var dangling = Look(name: "Dangling", folderID: UUID())
        dangling.states[UUID()] = FixtureState(intensity: 1)
        p.looks.append(dangling)
        if let firstLook = p.looks.first { p.looks.append(firstLook) }

        let report = ProjectIO.validate(p)
        let fixed = report.project
        XCTAssertEqual(Set(fixed.fixtures.map(\.id)).count, fixed.fixtures.count)
        XCTAssertEqual(Set(fixed.groups.map(\.id)).count, fixed.groups.count)
        XCTAssertEqual(Set(fixed.folders.map(\.id)).count, fixed.folders.count)
        XCTAssertEqual(Set(fixed.looks.map(\.id)).count, fixed.looks.count)

        let fixtureIDs = Set(fixed.fixtures.map(\.id))
        XCTAssertTrue(fixed.groups.allSatisfy { $0.fixtureIDs.allSatisfy(fixtureIDs.contains) })
        let folderIDs = Set(fixed.folders.map(\.id))
        XCTAssertTrue(fixed.looks.allSatisfy { $0.folderID.map(folderIDs.contains) ?? true })
        XCTAssertTrue(fixed.looks.allSatisfy { $0.states.storage.keys.allSatisfy(fixtureIDs.contains) })

        // No folder is its own ancestor.
        let parentOf = Dictionary(fixed.folders.compactMap { f in f.parentID.map { (f.id, $0) } }, uniquingKeysWith: { x, _ in x })
        for folder in fixed.folders {
            var cursor = parentOf[folder.id]
            var steps = 0
            while let c = cursor, steps <= fixed.folders.count {
                XCTAssertNotEqual(c, folder.id, "Folder \(folder.name) is its own ancestor")
                cursor = parentOf[c]
                steps += 1
            }
            XCTAssertLessThanOrEqual(steps, fixed.folders.count)
        }
        XCTAssertNil(fixed.folders.first { $0.id == selfID }?.parentID)
        XCTAssertNil(fixed.folders.first { $0.name == "Orphan" }?.parentID)
        XCTAssertFalse(report.fixes.isEmpty)
        XCTAssertLessThanOrEqual(report.fixes.count, ProjectIO.maxReportedFixes + 1)
    }

    // MARK: - Atomic writes & backups

    func testAtomicWriteKeepsPreviousVersionAndLeavesNoTempFiles() throws {
        let lib = TestResources.library()
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("Show.prismlights")
        let prev = dir.appendingPathComponent("Show.prismlights.prev")

        var p = DemoRig.londonStudio()
        p.name = "First"
        try ProjectIO.write(p, to: url, library: lib.definition, keepingPreviousAt: prev)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prev.path), "nothing to keep on the first write")
        p.name = "Second"
        try ProjectIO.write(p, to: url, library: lib.definition, keepingPreviousAt: prev)
        p.name = "Third"
        try ProjectIO.write(p, to: url, library: lib.definition, keepingPreviousAt: prev)

        XCTAssertEqual(try ProjectIO.read(from: url).name, "Third")
        XCTAssertEqual(try ProjectIO.read(from: prev).name, "Second")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".tmp-") }
        XCTAssertEqual(leftovers, [])

        // A crash between writing the temp file and renaming it leaves a torn temp file behind: the real
        // file is untouched, and the next save sweeps stale temp files but never a fresh (in-flight) one.
        let stale = dir.appendingPathComponent(".Show.prismlights.tmp-crashed")
        let fresh = dir.appendingPathComponent(".Show.prismlights.tmp-inflight")
        try Data("{\"name\": \"Torn".utf8).write(to: stale)
        try Data("{".utf8).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: stale.path)
        XCTAssertEqual(try ProjectIO.read(from: url).name, "Third")
        p.name = "Fourth"
        try ProjectIO.write(p, to: url, library: lib.definition, keepingPreviousAt: prev)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "stale temp file from a crash is removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "a recent temp file may belong to an in-flight save")
        XCTAssertEqual(try ProjectIO.read(from: url).name, "Fourth")
        XCTAssertEqual(try ProjectIO.read(from: prev).name, "Third")
        try FileManager.default.removeItem(at: fresh)

        // Missing parent folders are created.
        let nested = dir.appendingPathComponent("a/b/c/Show.prismlights")
        try ProjectIO.write(p, to: nested, library: lib.definition)
        XCTAssertEqual(try ProjectIO.read(from: nested).name, "Fourth")

        // Impossible destinations fail with a readable error instead of crashing.
        let blocker = dir.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: blocker)
        XCTAssertThrowsError(try ProjectIO.write(p, to: blocker.appendingPathComponent("Show.prismlights"))) { error in
            XCTAssertTrue(error is ProjectIOError, "\(error)")
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertThrowsError(try ProjectIO.read(from: dir.appendingPathComponent("missing.prismlights")))
    }

    func testBackupRotationKeepsTenSavesAndHourlySnapshots() throws {
        let root = try makeTempDir()
        var project = DemoRig.londonStudio()
        let base = Date(timeIntervalSince1970: 1_800_000_000) // exactly on an hour boundary

        for i in 0..<15 { // every 10 minutes for 2h20m → 3 distinct hours
            project.name = "Save \(i)"
            try ProjectIO.recordBackup(for: project, backupsRoot: root, now: base.addingTimeInterval(Double(i) * 600))
        }
        var entries = ProjectIO.backupEntries(for: project.id, backupsRoot: root)
        let saves = entries.filter { $0.kind == .save }
        XCTAssertEqual(saves.count, 10)
        XCTAssertEqual(entries.filter { $0.kind == .hourly }.count, 3)
        XCTAssertEqual(try ProjectIO.read(from: saves[0].url).name, "Save 14", "newest first")
        XCTAssertEqual(try ProjectIO.read(from: saves[9].url).name, "Save 5")
        XCTAssertEqual(entries.map(\.date), entries.map(\.date).sorted(by: >))
        XCTAssertEqual(ProjectIO.listBackups(for: project.id, backupsRoot: root), entries.map(\.url))

        // The hourly snapshot keeps the first save of its hour.
        let firstHourly = try XCTUnwrap(entries.last { $0.kind == .hourly })
        XCTAssertEqual(try ProjectIO.read(from: firstHourly.url).name, "Save 0")

        // Autosave-only hourly snapshots: one per hour, at most 24, saves untouched.
        for i in 0..<30 {
            project.name = "Hour \(i)"
            try ProjectIO.recordHourlySnapshot(for: project, backupsRoot: root,
                                               now: base.addingTimeInterval(Double(i + 3) * 3600 + 120))
        }
        try ProjectIO.recordHourlySnapshot(for: project, backupsRoot: root, now: base.addingTimeInterval(32 * 3600 + 900))
        entries = ProjectIO.backupEntries(for: project.id, backupsRoot: root)
        let hourlies = entries.filter { $0.kind == .hourly }
        XCTAssertEqual(hourlies.count, 24)
        XCTAssertEqual(try ProjectIO.read(from: hourlies[0].url).name, "Hour 29", "same hour isn't overwritten")
        XCTAssertEqual(entries.filter { $0.kind == .save }.count, 10)

        // A save written while the clock is wrong (in the past) is never pruned immediately.
        project.name = "Skewed"
        let skewed = try ProjectIO.recordBackup(for: project, backupsRoot: root, now: base.addingTimeInterval(-86_400))
        XCTAssertTrue(FileManager.default.fileExists(atPath: skewed.path))
        XCTAssertEqual(ProjectIO.backupEntries(for: project.id, backupsRoot: root).filter { $0.kind == .save }.count, 10)

        // Unknown projects have no backups.
        XCTAssertEqual(ProjectIO.backupEntries(for: UUID(), backupsRoot: root), [])
    }

    // MARK: - Look sharing & merging

    func testSingleLookShareRoundTripAndImportRemapsByRoleLabelAndName() throws {
        let lib = TestResources.library()
        let source = DemoRig.londonStudio()
        let look = try XCTUnwrap(source.looks.first { !$0.states.isEmpty })
        let data = try ProjectIO.data(forLook: look, in: source, library: lib.definition)
        let shared = try ProjectIO.decodeLook(data)
        XCTAssertEqual(SharedLook.fileExtension, "prismlook")
        XCTAssertEqual(shared.look.id, look.id)
        XCTAssertEqual(shared.look.name, look.name)
        XCTAssertEqual(shared.look.states, look.states)
        XCTAssertEqual(shared.fixtures.count, source.fixtures.count)

        // Another studio: same rig, different fixture ids.
        var target = source
        target.fixtures = source.fixtures.map { f in var copy = f; copy.id = UUID(); return copy }
        target.looks = []
        target.groups = []
        let imported = ProjectIO.importLook(shared, into: &target)
        var expectedMatches = 0
        for tf in target.fixtures {
            guard let sf = source.fixtures.first(where: { $0.name == tf.name && $0.role == tf.role }),
                  let expected = look.states[sf.id] else { continue }
            expectedMatches += 1
            XCTAssertEqual(imported.states[tf.id], expected, "\(tf.name) should receive \(sf.name)'s state")
        }
        XCTAssertGreaterThan(expectedMatches, 0)
        XCTAssertEqual(target.looks.count, 1)

        let again = ProjectIO.importLook(shared, into: &target)
        XCTAssertEqual(again.name, "\(look.name) 2")
        XCTAssertNotEqual(again.id, imported.id)
        let overwritten = ProjectIO.importLook(shared, into: &target, overwriteExistingByName: true)
        XCTAssertEqual(overwritten.id, imported.id)
        XCTAssertEqual(target.looks.count, 2)

        // Bare Look JSON is accepted; other JSON is rejected with a look-specific error.
        XCTAssertEqual(try ProjectIO.decodeLook(ProjectIO.encoder().encode(look)).look.name, look.name)
        XCTAssertThrowsError(try ProjectIO.decodeLook(Data("{\"hello\": 1}".utf8))) { error in
            guard case ProjectIOError.invalidLook = error else { return XCTFail("Unexpected error \(error)") }
        }
        XCTAssertThrowsError(try ProjectIO.decodeLook(Data()))

        // Hints with corrupt entries still import.
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var hints = try XCTUnwrap(json["fixtures"] as? [[String: Any]])
        hints.append(["id": "nope"])
        hints[0]["role"] = "dragon"
        json["fixtures"] = hints
        json["definitions"] = "missing"
        let repaired = try ProjectIO.decodeLook(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(repaired.fixtures.count, source.fixtures.count)
        XCTAssertEqual(repaired.fixtures[0].role, .other)
        XCTAssertTrue(repaired.definitions.isEmpty)

        // Merging every look from another project.
        var empty = target
        empty.looks = []
        let merged = ProjectIO.mergeLooks(from: source, into: &empty)
        XCTAssertEqual(merged.count, source.looks.count)
        XCTAssertEqual(empty.looks.count, source.looks.count)
        let subset = ProjectIO.mergeLooks(from: source, into: &empty, lookIDs: [look.id])
        XCTAssertEqual(subset.count, 1)
    }

    func testFileWriteRoundTripPreservesProject() throws {
        let lib = TestResources.library()
        let dir = try makeTempDir()
        var project = DemoRig.londonStudio()
        project.folders = [LookFolder(name: "Interviews")]
        project.lastLive = ShowDocument(project: project).live.snapshot
        let url = dir.appendingPathComponent("RoundTrip.prismlights")
        try ProjectIO.write(project, to: url, library: lib.definition, appVersion: "9.9")
        let report = try ProjectIO.readWithReport(from: url)
        XCTAssertEqual(report.fixes, [])
        XCTAssertEqual(report.project.id, project.id)
        XCTAssertEqual(report.project.fixtures, project.fixtures)
        XCTAssertEqual(report.project.looks.map(\.id), project.looks.map(\.id))
        XCTAssertEqual(report.project.folders, project.folders)
        XCTAssertEqual(report.project.appVersion, "9.9")
        XCTAssertFalse(report.project.definitions.isEmpty, "definitions are embedded")
    }
}
