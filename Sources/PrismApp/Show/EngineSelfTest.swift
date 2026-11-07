import Foundation
import PrismCore

/// Show-engine self-test checks (see App/SelfTest.swift): crossfade continuity, every command kind
/// through the executor, limits/protection for every origin, and crash-safe persistence. They run in
/// the real app on CI with the demo rig, work on private document copies, and only write to a
/// temporary directory, never to the user's session or backups.
@MainActor
enum EngineSelfTest {
    static var checks: [SelfTest.Check] {
        [
            SelfTest.Check(name: "engine.crossfade") { app in EngineSelfTest.crossfade(app) },
            SelfTest.Check(name: "engine.commands") { app in EngineSelfTest.commands(app) },
            SelfTest.Check(name: "engine.limitsAndProtection") { app in EngineSelfTest.limitsAndProtection(app) },
            SelfTest.Check(name: "engine.persistenceAndMigration") { app in EngineSelfTest.persistence(app) },
        ]
    }

    /// Perceptual crossfade midpoint, mid-fade interruption without a jump, and the fade's end value.
    private static func crossfade(_ app: AppModel) -> String? {
        let lookup = app.library.lookup
        let id = DemoRig.IDs.p1
        var doc = ShowDocument(project: DemoRig.londonStudio())
        _ = CommandExecutor(library: lookup, now: { 99 }).apply([.fadeTime(0), .setIntensity(.id(id), 0)], to: &doc)
        _ = CommandExecutor(library: lookup, now: { 100 }).apply([.fadeTime(2), .setIntensity(.id(id), 1)], to: &doc)

        let mid = EngineCore.renderFrame(ShowSnapshot(document: doc, library: lookup), time: 101)
        let midValue = mid.states[id]?.intensity ?? -1
        let expected = FixtureState.mixIntensity(0, 1, 0.5)
        guard abs(midValue - expected) < 0.02 else {
            return "Mid-fade intensity \(midValue), expected \(expected)"
        }

        _ = CommandExecutor(library: lookup, now: { 101 })
            .apply([.fadeTime(2), .setIntensity(.id(id), 0.2)], to: &doc, currentRendered: mid.preMasterStates)
        let after = EngineCore.renderFrame(ShowSnapshot(document: doc, library: lookup), time: 101)
        let afterValue = after.states[id]?.intensity ?? -1
        guard abs(afterValue - midValue) < 1e-4 else {
            return "Interrupted fade jumped from \(midValue) to \(afterValue)"
        }

        let end = EngineCore.renderFrame(ShowSnapshot(document: doc, library: lookup), time: 103.5)
        let endValue = end.states[id]?.intensity ?? -1
        return abs(endValue - 0.2) < 1e-3 ? nil : "Fade ended at \(endValue), expected 0.2"
    }

    /// Random realistic batches covering every command kind and origin: each command survives a JSON
    /// round trip, and rendered frames and the document stay finite and in range.
    private static func commands(_ app: AppModel) -> String? {
        let lookup = app.library.lookup
        var doc = ShowDocument(project: DemoRig.londonStudio())
        var fuzzer = CommandFuzzer(seed: 0x5EED_CAFE, mode: .realistic)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var rendered: [UUID: FixtureState] = [:]
        for step in 0..<240 {
            let time = 1000 + Double(step) * 0.1
            let batch = fuzzer.nextBatch(in: doc, maxCount: 3)
            for command in batch {
                // Decoding may normalize once (RGB colors are stored as 8-bit hex); the kind must
                // survive and a second round trip must be stable.
                guard let data = try? encoder.encode(command),
                      let decoded = try? decoder.decode(LightingCommand.self, from: data),
                      kind(of: decoded) == kind(of: command),
                      let again = try? encoder.encode(decoded),
                      let redecoded = try? decoder.decode(LightingCommand.self, from: again),
                      redecoded == decoded else {
                    return "JSON round trip failed for \(command)"
                }
            }
            let origin = fuzzer.nextOrigin()
            _ = CommandExecutor(library: lookup, now: { time })
                .apply(batch, to: &doc, currentRendered: rendered, origin: origin)
            if step % 8 == 0 {
                let frame = EngineCore.renderFrame(ShowSnapshot(document: doc, library: lookup),
                                                   time: time + 0.05, frameNumber: UInt64(step))
                if let problem = EngineInvariants.violation(in: frame) { return "Step \(step): \(problem)" }
                rendered = frame.preMasterStates
            }
        }
        return EngineInvariants.violation(in: doc)
    }

    /// The command's case name, e.g. "shiftColor".
    private static func kind(of command: LightingCommand) -> String {
        String(String(describing: command).prefix { $0 != "(" })
    }

    /// A protected light ignores broad selectors from every non-UI origin; explicit UI edits are clamped
    /// to the light's intensity and white-balance limits.
    private static func limitsAndProtection(_ app: AppModel) -> String? {
        let lookup = app.library.lookup
        let exec = CommandExecutor(library: lookup, now: { 10 })
        var doc = ShowDocument(project: DemoRig.londonStudio())
        let id = DemoRig.IDs.pn1
        guard let index = doc.project.fixtures.firstIndex(where: { $0.id == id }) else {
            return "Demo rig has no panel"
        }
        doc.project.fixtures[index].limits = FixtureLimits(
            maxIntensity: 0.75, minIntensity: 0.1, allowEffects: false, protected: true,
            minKelvin: 3200, maxKelvin: 5200)

        _ = exec.apply([.setIntensity(.id(id), 0.5)], to: &doc, origin: .ui)
        let start = doc.live.base[id]?.intensity ?? -1
        guard abs(start - 0.5) < 1e-6 else { return "Explicit UI edit of a protected light gave \(start)" }

        let origins: [CommandOrigin] = [.assistant, .voice, .midi, .osc, .http, .shortcuts, .system,
                                        .remote(clientID: "selftest", linkID: UUID())]
        for origin in origins {
            _ = exec.apply([.setIntensity(.all, 1.0)], to: &doc, origin: origin)
            let value = doc.live.base[id]?.intensity ?? -1
            guard abs(value - 0.5) < 1e-6 else { return "\(origin.displayName) changed a protected light (\(value))" }
        }

        _ = exec.apply([.setIntensity(.id(id), 1.0), .setKelvin(.id(id), 6500)], to: &doc, origin: .ui)
        let intensity = doc.live.base[id]?.intensity ?? -1
        guard abs(intensity - 0.75) < 1e-6 else { return "Max intensity limit not enforced (\(intensity))" }
        let kelvin = doc.live.base[id]?.color.approximateKelvin.kelvin ?? -1
        guard abs(kelvin - 5200) < 25 else { return "White balance limit not enforced (\(Int(kelvin)) K)" }

        let frame = EngineCore.renderFrame(ShowSnapshot(document: doc, library: lookup), time: 20)
        let output = frame.states[id]?.intensity ?? -1
        return output <= 0.75 + 1e-6 ? nil : "Rendered output \(output) exceeds the light's limit"
    }

    /// v1 → v2 migration, atomic save with a kept previous version, rolling backups, `.prismlook`
    /// sharing, and hostile input that must never crash the decoders.
    private static func persistence(_ app: AppModel) -> String? {
        let lookup = app.library.lookup
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("prism-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)

            var legacy = DemoRig.londonStudio()
            legacy.formatVersion = 1
            let report = try ProjectIO.decodeWithReport(try ProjectIO.encoder().encode(legacy))
            guard report.project.formatVersion == Project.currentFormatVersion,
                  report.fixes.contains(where: { $0.contains("Migrated project") }) else {
                return "v1 → v2 migration did not run (fixes: \(report.fixes))"
            }
            let project = report.project

            let url = dir.appendingPathComponent("Show.prismlights")
            let previous = dir.appendingPathComponent("Show.prismlights.prev")
            let data = try ProjectIO.data(for: project, library: lookup)
            try ProjectIO.writeAtomic(data, to: url, keepingPreviousAt: previous)
            try ProjectIO.writeAtomic(data, to: url, keepingPreviousAt: previous)
            guard fm.fileExists(atPath: previous.path) else { return "Atomic save did not keep the previous version" }
            let leftovers = try fm.contentsOfDirectory(atPath: dir.path)
                .filter { $0 != url.lastPathComponent && $0 != previous.lastPathComponent }
            guard leftovers.isEmpty else { return "Atomic save left files behind: \(leftovers)" }
            let reopened = try ProjectIO.read(from: url)
            guard reopened.fixtures.count == project.fixtures.count, reopened.looks.count == project.looks.count else {
                return "Saved project did not round-trip"
            }

            let backups = dir.appendingPathComponent("Backups", isDirectory: true)
            let base = Date()
            for i in 0..<12 {
                _ = try ProjectIO.recordBackup(for: project, data: data, backupsRoot: backups,
                                               now: base.addingTimeInterval(Double(i) * 61))
            }
            let saves = ProjectIO.backupEntries(for: project.id, backupsRoot: backups).filter { $0.kind == .save }
            guard saves.count == 10 else { return "Expected 10 rolling backups, found \(saves.count)" }

            guard let look = project.looks.first(where: { !$0.states.isEmpty }) else { return "Demo rig has no look to share" }
            let lookURL = dir.appendingPathComponent("Look.\(SharedLook.fileExtension)")
            try ProjectIO.writeLook(look, from: project, to: lookURL, library: lookup)
            let shared = try ProjectIO.readLook(from: lookURL)
            var target = project
            let imported = ProjectIO.importLook(shared, into: &target)
            let patched = Set(project.fixtures.map(\.id))
            let expectedStates = look.states.keys.filter { patched.contains($0) }.count
            guard target.looks.count == project.looks.count + 1, imported.states.count == expectedStates else {
                return "Look import mapped \(imported.states.count) of \(expectedStates) states"
            }

            for junk in ["", "{", "null", "[]", "{\"fixtures\":42}", "{\"formatVersion\":1e308}", "{\"looks\":[{\"states\":7}]}"] {
                _ = try? ProjectIO.decodeWithReport(Data(junk.utf8))
                _ = try? ProjectIO.decodeLook(Data(junk.utf8))
            }
            return nil
        } catch {
            return "Persistence failed: \(error.localizedDescription)"
        }
    }
}
