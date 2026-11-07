import Foundation
import AppKit
import PrismCore

/// What changed (for observers like the remote server, menu bar, MIDI feedback).
struct ShowChange: OptionSet {
    let rawValue: Int
    /// Fixture states / masters / effects / music changed.
    static let live = ShowChange(rawValue: 1 << 0)
    /// Fixtures, patch, groups, stage layout changed.
    static let patch = ShowChange(rawValue: 1 << 1)
    /// Looks or folders changed.
    static let looks = ShowChange(rawValue: 1 << 2)
    /// A different project was loaded.
    static let project = ShowChange(rawValue: 1 << 3)
    static let all: ShowChange = [.live, .patch, .looks, .project]
}

/// The single source of truth for the open show. MainActor-isolated; every mutation goes
/// through here so undo, autosave, the engine and observers (remote, MIDI…) stay in sync.
///
/// Mutation APIs (all undoable unless noted):
///   - `apply(_:origin:)`        — LightingCommands (UI, assistant, voice, remote, MIDI, OSC)
///   - `updateStates(_:...)`     — direct per-fixture edits from the inspector/stage
///   - `editProject(_:...)`      — structural edits (patch, layout, looks, groups)
///   - `editLive(...)`           — live-only edits (masters, music); undo optional
///   - `applyPlan(_:origin:undoName:)` — a multi-step plan (assistant) as a single undo step
///   - `beginInteractiveChange(coalesceKey:)` / `endInteractiveChange()` — wrap a slider, knob or
///     drag gesture so the whole gesture becomes one undo step
///
/// Keep this type lean: feature teams add their convenience helpers as `extension ShowController`
/// in their own folders, built on the APIs above (never by bypassing them).
@MainActor
@Observable
final class ShowController {
    // MARK: Observable state

    private(set) var document: ShowDocument
    /// Increments on every change; cheap change detection for views.
    private(set) var revision = 0
    /// Selected fixtures (stage/inspector).
    var selection: Set<UUID> = []
    /// Selected pixels per fixture (empty/missing = whole fixture).
    var cellSelection: [UUID: Set<Int>] = [:]
    private(set) var fileURL: URL?
    private(set) var isDirty = false
    private(set) var lastResult: CommandResult?
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var undoActionName: String?
    private(set) var redoActionName: String?
    /// Chronological attributed history timeline (most recent first) for the History popover.
    private(set) var historyTimeline: [UndoHistory.Entry] = []
    var historyEntries: [UndoHistory.Entry] { historyTimeline }
    /// Problems found when the last project was opened (shown once in the UI).
    var openReport: [String] = []

    // MARK: Dependencies

    @ObservationIgnored let engine: EngineCore
    @ObservationIgnored let library: LibraryStore
    @ObservationIgnored let preferences: AppPreferences
    @ObservationIgnored private var history = UndoHistory()
    @ObservationIgnored private var observers: [UUID: (ShowChange) -> Void] = [:]
    @ObservationIgnored private var autosaveWork: DispatchWorkItem?
    @ObservationIgnored private var firstUnsavedChangeAt: Double?
    /// Serial queue for all background persistence so writes never overlap or land out of order.
    @ObservationIgnored private let persistenceQueue = DispatchQueue(label: "studio.prism.persistence", qos: .utility)
    @ObservationIgnored private var maintenanceTimer: Timer?
    @ObservationIgnored private var resolvedCache: (revision: Int, fixtures: [ResolvedFixture])?

    init(engine: EngineCore, library: LibraryStore, preferences: AppPreferences) {
        self.engine = engine
        self.library = library
        self.preferences = preferences
        self.document = ShowDocument(project: Project(name: "Untitled Studio"))
    }

    // MARK: Convenience accessors

    var project: Project { document.project }
    var live: LiveState { document.live }
    var fixtures: [PatchedFixture] { document.project.fixtures }
    var looks: [Look] { document.project.looks }
    var activeLook: Look? { document.live.activeLookID.flatMap { document.project.look($0) } }
    var fadeProgress: Double? { engine.latestFrame.fadeProgress ?? document.live.fadeProgress(at: PrismClock.now()) }
    var isFading: Bool { fadeProgress != nil }

    /// Fixtures with their definitions resolved (cached per revision).
    var resolvedFixtures: [ResolvedFixture] {
        if let c = resolvedCache, c.revision == revision { return c.fixtures }
        let r = document.project.resolvedFixtures(library: library.lookup)
        resolvedCache = (revision, r)
        return r
    }

    func resolved(_ id: UUID) -> ResolvedFixture? { resolvedFixtures.first { $0.id == id } }

    func state(of id: UUID) -> FixtureState { document.live.base[id] ?? .off }

    /// Selected fixtures in stage order (left → right), or all when nothing is selected
    /// and `fallbackToAll` is true.
    func selectedIDs(fallbackToAll: Bool = false) -> [UUID] {
        let ids = fixtures.filter { selection.contains($0.id) }.map(\.id)
        if ids.isEmpty && fallbackToAll { return fixtures.map(\.id) }
        return ids
    }

    // MARK: Observers

    @discardableResult
    func addObserver(_ handler: @escaping (ShowChange) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    // MARK: Lifecycle

    func start() {
        pushToEngine()
        maintenanceTimer?.invalidate()
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.maintenance() }
        }
    }

    func shutdown() {
        maintenanceTimer?.invalidate()
        flushAutosave(timeout: 1.0)
        UserDefaults.standard.removeObject(forKey: Self.restoringAutosaveKey)
    }

    private func maintenance() {
        let now = PrismClock.now()
        let hasExpired = document.live.fades.values.contains { $0.isFinished(at: now) }
            || document.live.effectFades.values.contains { $0.isFinished(at: now) }
            || (document.live.musicFade?.isFinished(at: now) ?? false)
            || document.live.identify.values.contains { now - $0 > 2.5 }
        guard hasExpired else { return }
        document.live.pruneExpired(at: now)
        pushToEngine()
    }

    // MARK: Commands

    @discardableResult
    func apply(_ command: LightingCommand, origin: CommandOrigin = .ui, undoName: String? = nil,
               coalesceKey: String? = nil) -> CommandResult {
        apply([command], origin: origin, undoName: undoName, coalesceKey: coalesceKey)
    }

    @discardableResult
    func apply(_ commands: [LightingCommand], origin: CommandOrigin = .ui, undoName: String? = nil,
               coalesceKey: String? = nil) -> CommandResult {
        guard !commands.isEmpty else { return CommandResult() }
        let before = document
        var doc = document
        let executor = CommandExecutor(library: library.lookup, defaultFade: 0)
        let latest = engine.latestFrame
        let currentRendered = latest.preMasterStates.isEmpty ? latest.states : latest.preMasterStates
        let result = executor.apply(commands, to: &doc, selection: selectedIDs(),
                                    currentRendered: currentRendered, origin: origin)
        lastResult = result
        guard doc != before else { return result }
        var change: ShowChange = [.live]
        if doc.project.looks != before.project.looks { change.insert(.looks) }
        if doc.project.fixtures != before.project.fixtures { change.insert(.patch) }
        let actionName = undoName ?? CommandNaming.name(for: commands)
        let summary = result.summary.isEmpty ? actionName : result.summary
        commit(doc, before: before, undoName: actionName, summary: summary, origin: origin,
               coalesceKey: coalesceKey, change: change,
               marksDirty: change.contains(.looks) || change.contains(.patch))
        return result
    }

    /// Applies a multi-step plan (assistant, Shortcuts…) step by step as a single undo step.
    @discardableResult
    func applyPlan(_ steps: [[LightingCommand]], origin: CommandOrigin, undoName: String) -> [CommandResult] {
        let key = "plan-\(UUID().uuidString)"
        beginInteractiveChange(coalesceKey: key)
        defer { endInteractiveChange() }
        return steps.map { apply($0, origin: origin, undoName: undoName, coalesceKey: key) }
    }

    // MARK: Direct edits

    /// Edits base states of fixtures (inspector, stage painting). Turning a light's color on
    /// while it's at 0% brings it up so the change is visible.
    func updateStates<C: Collection>(_ ids: C, undoName: String, coalesceKey: String? = nil, fade: Double = 0,
                                     _ body: (UUID, inout FixtureState) -> Void) where C.Element == UUID {
        guard !ids.isEmpty else { return }
        let before = document
        var doc = document
        let now = PrismClock.now()
        let latest = engine.latestFrame
        let rendered = latest.preMasterStates.isEmpty ? latest.states : latest.preMasterStates
        for id in ids {
            let old = doc.live.base[id] ?? .off
            var new = old
            body(id, &new)
            new.intensity = clamp01(new.intensity.finiteOr(0))
            new.color = new.color.sanitized
            if let rf = doc.project.fixture(id) {
                let lim = rf.limits.sanitized
                if new.intensity > 0 {
                    new.intensity = clamp(new.intensity, lim.minIntensity, lim.maxIntensity)
                } else if lim.minIntensity > 0 {
                    new.intensity = lim.minIntensity
                }
            }
            guard new != old else { continue }
            if fade > 0 {
                let startState = doc.live.effectiveBaseState(of: id, at: now, currentRendered: rendered)
                doc.live.fades[id] = FixtureFade(from: startState, startTime: now, duration: fade)
            } else {
                doc.live.fades[id] = nil
            }
            doc.live.base[id] = new
        }
        guard doc != before else { return }
        commit(doc, before: before, undoName: undoName, coalesceKey: coalesceKey, change: .live, marksDirty: false)
    }

    /// Structural edit of the project (patch, layout, looks, groups, stage). Undoable.
    func editProject(_ undoName: String, coalesceKey: String? = nil, change: ShowChange = [.patch],
                     _ body: (inout Project) -> Void) {
        let before = document
        var doc = document
        body(&doc.project)
        guard doc.project != before.project else { return }
        doc.project.modifiedAt = Date()
        // Drop states for fixtures that no longer exist.
        let ids = Set(doc.project.fixtures.map(\.id))
        if doc.live.base.storage.keys.contains(where: { !ids.contains($0) }) {
            doc.live.base.storage = doc.live.base.storage.filter { ids.contains($0.key) }
        }
        selection = selection.intersection(ids)
        commit(doc, before: before, undoName: undoName, coalesceKey: coalesceKey, change: change, marksDirty: true)
    }

    /// Live-only edit (masters, effects, music). Pass `undoName` to make it undoable.
    func editLive(undoName: String? = nil, coalesceKey: String? = nil, _ body: (inout LiveState) -> Void) {
        let before = document
        var doc = document
        body(&doc.live)
        guard doc != before else { return }
        if let undoName {
            commit(doc, before: before, undoName: undoName, coalesceKey: coalesceKey, change: .live, marksDirty: false)
        } else {
            document = doc
            didChange(.live, marksDirty: false)
        }
    }

    /// Call when a continuous gesture (slider, knob, drag) begins: every change recorded with
    /// `coalesceKey` until `endInteractiveChange()` becomes one undo step, even across pauses.
    func beginInteractiveChange(coalesceKey: String) {
        history.beginInteraction(key: coalesceKey)
    }

    /// Call when the gesture ends; the next change starts a new undo step.
    func endInteractiveChange() {
        history.endInteraction()
        syncUndoState()
    }

    private func commit(_ doc: ShowDocument, before: ShowDocument, undoName: String,
                        summary: String? = nil, origin: CommandOrigin = .ui,
                        coalesceKey: String?, change: ShowChange, marksDirty: Bool) {
        history.record(
            before: before,
            after: doc,
            name: undoName,
            summary: summary ?? undoName,
            origin: origin,
            coalesceKey: coalesceKey,
            now: PrismClock.now()
        )
        document = doc
        didChange(change, marksDirty: marksDirty)
    }

    private func didChange(_ change: ShowChange, marksDirty: Bool) {
        revision &+= 1
        if marksDirty { isDirty = true }
        syncUndoState()
        pushToEngine()
        scheduleAutosave()
        for handler in observers.values { handler(change) }
    }

    private func syncUndoState() {
        canUndo = history.canUndo
        canRedo = history.canRedo
        undoActionName = history.undoName
        redoActionName = history.redoName
        historyTimeline = history.timeline
    }

    /// Sends the current document to the real-time engine (cheap; call after every change).
    func pushToEngine() {
        let snapshot = ShowSnapshot(document: document, library: library.lookup,
                                    safety: preferences.safety, revision: revision)
        engine.update(snapshot)
    }

    // MARK: Undo & History Timeline

    func undo() {
        guard let r = history.undo(current: document) else { return }
        restore(r.document)
        AppModel.shared.ui.toast("Undid \(r.name)", systemImage: "arrow.uturn.backward")
    }

    func redo() {
        guard let r = history.redo(current: document) else { return }
        restore(r.document)
        AppModel.shared.ui.toast("Redid \(r.name)", systemImage: "arrow.uturn.forward")
    }

    /// Reverts the show to the state right before a specific history timeline entry.
    func revertToHistoryEntry(_ entryID: UUID) {
        guard let r = history.revertTo(entryID: entryID, current: document) else { return }
        restore(r.document)
        AppModel.shared.ui.toast("Reverted to before \(r.name)", systemImage: "clock.arrow.circlepath")
    }

    private func restore(_ doc: ShowDocument) {
        var d = doc
        // Keep masters where the operator left them; undo is about the look, not safety controls.
        d.live.grandMaster = document.live.grandMaster
        d.live.blackout = document.live.blackout
        let projectChanged = d.project != document.project
        document = d
        selection = selection.intersection(Set(d.project.fixtures.map(\.id)))
        didChange(projectChanged ? [.live, .patch, .looks] : [.live], marksDirty: projectChanged || isDirty)
    }

    // MARK: Looks

    /// Recalls a look with a crossfade (look's own fade time unless overridden).
    func recallLook(_ id: UUID, fade: Double? = nil, origin: CommandOrigin = .ui) {
        guard let look = project.look(id) else { return }
        apply(.recallLook(.id(id), fade: fade ?? look.fadeTime), origin: origin, undoName: "Recall \(look.name)")
    }

    /// Saves the current state of all fixtures as a new look and returns its id.
    @discardableResult
    func saveLook(name: String, folderID: UUID? = nil, fadeTime: Double? = nil) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var look = Look(name: trimmed.isEmpty ? uniqueLookName("New Look") : trimmed, folderID: folderID,
                        states: document.live.base, effects: document.live.effects,
                        music: document.live.music.enabled ? document.live.music : nil,
                        fadeTime: fadeTime ?? preferences.defaultFadeTime)
        look.sortIndex = (project.looks.map(\.sortIndex).max() ?? -1) + 1
        let id = look.id
        editProject("Save Look", change: [.looks]) { $0.looks.append(look) }
        editLive { $0.activeLookID = id }
        return id
    }

    /// Overwrites a look with the current state.
    func updateLook(_ id: UUID) {
        let states = document.live.base
        let effects = document.live.effects
        editProject("Update Look", change: [.looks]) { p in
            guard let i = p.looks.firstIndex(where: { $0.id == id }) else { return }
            p.looks[i].states = states
            p.looks[i].effects = effects
            p.looks[i].modifiedAt = Date()
        }
    }

    func uniqueLookName(_ base: String) -> String {
        let names = Set(project.looks.map { $0.name.lowercased() })
        if !names.contains(base.lowercased()) { return base }
        var n = 2
        while names.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Patch helpers

    /// Adds fixtures of a type, auto-addressing them after existing ones. Returns new ids.
    @discardableResult
    func addFixtures(definitionID: String, modeName: String, count: Int = 1, baseName: String? = nil,
                     role: FixtureRole = .other, universe: Int = 1, startAddress: Int? = nil,
                     at position: (x: Double, y: Double)? = nil) -> [UUID] {
        guard let def = library.definition(definitionID) ?? project.definition(definitionID),
              let mode = def.modes.first(where: { $0.name == modeName }) ?? def.recommendedMode else { return [] }
        let n = max(1, min(count, 64))
        var newFixtures: [PatchedFixture] = []
        var resolved = resolvedFixtures
        let stage = project.stage
        let name = baseName ?? def.model
        var next = startAddress
        for i in 0..<n {
            let address = next ?? PatchMath.nextFreeAddress(channelCount: mode.channelCount, universe: universe,
                                                            fixtures: resolved)
            let px = position?.x ?? (stage.width * (Double(i) + 1) / Double(n + 1))
            let py = position?.y ?? stage.height * 0.25
            let f = PatchedFixture(name: n > 1 ? "\(name) \(i + 1)" : name, definitionID: def.id, modeName: mode.name,
                                   universe: universe, address: address, role: role,
                                   transform: StageTransform(x: px + (position == nil ? 0 : Double(i) * 0.4), y: py))
            newFixtures.append(f)
            resolved.append(ResolvedFixture(fixture: f, definition: def, mode: mode))
            if let a = address { next = a + mode.channelCount } else { next = nil }
        }
        let ids = newFixtures.map(\.id)
        let embed = library.definition(definitionID) == nil ? [] : [def]
        editProject(n > 1 ? "Add \(n) Lights" : "Add Light") { p in
            p.fixtures.append(contentsOf: newFixtures)
            for d in embed where !p.definitions.contains(where: { $0.id == d.id }) { p.definitions.append(d) }
        }
        selection = Set(ids)
        return ids
    }

    func removeFixtures(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        editProject(ids.count > 1 ? "Delete \(ids.count) Lights" : "Delete Light") { p in
            p.fixtures.removeAll { ids.contains($0.id) }
            for i in p.groups.indices { p.groups[i].fixtureIDs.removeAll { ids.contains($0) } }
            for i in p.looks.indices { p.looks[i].states.storage = p.looks[i].states.storage.filter { !ids.contains($0.key) } }
        }
    }

    func setAddress(_ id: UUID, universe: Int, address: Int?) {
        editProject("Change Address") { p in
            guard let i = p.fixtures.firstIndex(where: { $0.id == id }) else { return }
            p.fixtures[i].universe = max(1, universe)
            p.fixtures[i].address = address.map { min(max($0, 1), 512) }
        }
    }

    func updateFixture(_ id: UUID, undoName: String, coalesceKey: String? = nil, _ body: (inout PatchedFixture) -> Void) {
        editProject(undoName, coalesceKey: coalesceKey) { p in
            guard let i = p.fixtures.firstIndex(where: { $0.id == id }) else { return }
            body(&p.fixtures[i])
        }
    }

    // MARK: Masters

    func setGrandMaster(_ value: Double) {
        editLive { $0.grandMaster = clamp01(value) }
    }

    func setBlackout(_ on: Bool) {
        editLive { $0.blackout = on }
    }

    func toggleBlackout() { setBlackout(!live.blackout) }

    /// Flashes fixtures so you can find them in the room (2 s).
    func identify<C: Collection>(_ ids: C) where C.Element == UUID {
        let now = PrismClock.now()
        editLive { live in for id in ids { live.identify[id] = now } }
    }

    // MARK: Project loading / saving

    /// Replaces the current project (no undo across projects).
    func load(_ project: Project, fileURL: URL?, restoreLive: Bool = true, additionalFixes: [String] = []) {
        let report = ProjectIO.validate(project)
        var p = report.project
        library.registerEmbedded(p.definitions)
        var live = LiveState()
        if restoreLive, let snap = p.lastLive {
            live = LiveState(snapshot: snap)
        }
        p.lastLive = nil
        history.clear()
        selection = []
        cellSelection = [:]
        self.fileURL = fileURL
        var fixes = additionalFixes
        for fix in report.fixes where !fixes.contains(fix) { fixes.append(fix) }
        openReport = fixes
        document = ShowDocument(project: p, live: live)
        isDirty = false
        didChange(.all, marksDirty: false)
    }

    func newProject(name: String = "Untitled Studio") {
        load(Project(name: name), fileURL: nil, restoreLive: false)
    }

    func loadDemo() {
        load(DemoRig.londonStudio(), fileURL: nil, restoreLive: true)
    }

    func open(url: URL) throws {
        let report = try ProjectIO.readWithReport(from: url)
        load(report.project, fileURL: url, additionalFixes: report.fixes)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    /// The project as it should be written to disk (with live state & embedded definitions).
    func projectForSaving() -> Project {
        var p = document.project
        p.lastLive = document.live.snapshot
        p.modifiedAt = Date()
        p.appVersion = AppResources.appVersion
        return p
    }

    func save(to url: URL) throws {
        let project = projectForSaving()
        let data = try ProjectIO.data(for: project, library: library.lookup, appVersion: AppResources.appVersion)
        try ProjectIO.writeAtomic(data, to: url)
        fileURL = url
        isDirty = false
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        let backupsRoot = AppResources.backups
        persistenceQueue.async {
            do {
                try ProjectIO.recordBackup(for: project, data: data, backupsRoot: backupsRoot)
            } catch {
                NSLog("Prism backup failed: %@", error.localizedDescription)
            }
        }
        autosaveNow()
    }

    /// Backup files of the current project (last 10 saves + hourly snapshots), newest first.
    func backups() -> [URL] {
        ProjectIO.listBackups(for: project.id, backupsRoot: AppResources.backups)
    }

    /// Backups of the current project with their dates and kinds, newest first.
    func backupEntries() -> [ProjectIO.BackupEntry] {
        ProjectIO.backupEntries(for: project.id, backupsRoot: AppResources.backups)
    }

    /// Exports a single look to a `.prismlook` file.
    func exportLook(_ lookID: UUID, to url: URL) throws {
        guard let look = project.look(lookID) else { return }
        try ProjectIO.writeLook(look, from: project, to: url, library: library.lookup)
    }

    /// Imports a `.prismlook` file into the current project.
    @discardableResult
    func importLook(from url: URL, overwriteExistingByName: Bool = false) throws -> Look {
        let shared = try ProjectIO.readLook(from: url)
        library.registerEmbedded(shared.definitions)
        var importedLook = shared.look
        editProject("Import Look “\(shared.look.name)”", change: [.looks]) { p in
            importedLook = ProjectIO.importLook(shared, into: &p, overwriteExistingByName: overwriteExistingByName)
        }
        return importedLook
    }

    /// Imports/merges looks from another `.prismlights` project file into the current project.
    @discardableResult
    func importLooks(fromProjectURL url: URL, lookIDs: Set<UUID>? = nil, overwriteExistingByName: Bool = false) throws -> [Look] {
        let source = try ProjectIO.read(from: url)
        library.registerEmbedded(source.definitions)
        var imported: [Look] = []
        editProject("Import Looks", change: [.looks]) { p in
            imported = ProjectIO.mergeLooks(
                from: source,
                into: &p,
                lookIDs: lookIDs,
                overwriteExistingByName: overwriteExistingByName
            )
        }
        return imported
    }

    func renameProject(_ name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        editProject("Rename Project", change: [.project]) { $0.name = t }
    }

    // MARK: Autosave (crash safety)

    private static let autosaveDebounce = 1.5
    /// Continuous editing never postpones the autosave longer than this.
    private static let autosaveMaxDelay = 10.0
    private static let lastProjectPathKey = "prism.lastProjectPath"
    /// Whether the latest autosave holds changes that were not saved to the project file.
    private static let autosaveDirtyKey = "prism.autosaveHasUnsavedChanges"
    /// Set while a restored autosave is opened and for the first seconds after. If it is still set at the
    /// next launch, reopening that autosave crashed Prism, so it is set aside instead of reopened.
    static let restoringAutosaveKey = "prism.restoringAutosave"
    private static let restoreGuardSeconds = 15.0

    /// The autosave before the latest one (second line of defense if the latest is damaged).
    static var previousAutosaveURL: URL {
        let auto = AppResources.autosaveURL
        return auto.deletingLastPathComponent().appendingPathComponent(auto.lastPathComponent + ".prev")
    }

    /// Automated runs (self-test, screenshot tour, soak) never touch the user's session files.
    private var autosaveDisabled: Bool { LaunchOptions.current.isAutomated }

    private func scheduleAutosave() {
        guard !autosaveDisabled else { return }
        let now = PrismClock.now()
        let first = firstUnsavedChangeAt ?? now
        firstUnsavedChangeAt = first
        if now - first >= Self.autosaveMaxDelay {
            autosaveNow()
            return
        }
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.autosaveNow() }
        }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autosaveDebounce, execute: work)
    }

    /// Writes the session to Application Support on the serial persistence queue: atomic write that keeps
    /// the previous autosave, plus an hourly backup snapshot. Never blocks the UI and never throws.
    func autosaveNow() {
        guard !autosaveDisabled else { return }
        autosaveWork?.cancel()
        autosaveWork = nil
        firstUnsavedChangeAt = nil
        let job = makeAutosaveJob()
        persistenceQueue.async { job() }
    }

    /// Writes the autosave and waits for it (bounded), so the last edits survive quitting.
    func flushAutosave(timeout: Double) {
        guard !autosaveDisabled else { return }
        autosaveWork?.cancel()
        autosaveWork = nil
        firstUnsavedChangeAt = nil
        let job = makeAutosaveJob()
        let done = DispatchSemaphore(value: 0)
        persistenceQueue.async {
            job()
            done.signal()
        }
        _ = done.wait(timeout: .now() + max(0.05, timeout))
    }

    /// Captures the session on the main actor; the returned job runs on the persistence queue.
    private func makeAutosaveJob() -> @Sendable () -> Void {
        let project = projectForSaving()
        let url = AppResources.autosaveURL
        let previousURL = Self.previousAutosaveURL
        let backupsRoot = AppResources.backups
        let lookup = library.lookup
        let appVersion = AppResources.appVersion
        let lastPath = fileURL?.path
        let lastPathKey = Self.lastProjectPathKey
        let hasUnsavedChanges = isDirty
        let dirtyKey = Self.autosaveDirtyKey
        return {
            do {
                let data = try ProjectIO.data(for: project, library: lookup, appVersion: appVersion)
                try ProjectIO.writeAtomic(data, to: url, keepingPreviousAt: previousURL)
                _ = try? ProjectIO.recordHourlySnapshot(for: project, data: data, backupsRoot: backupsRoot)
                UserDefaults.standard.set(lastPath, forKey: lastPathKey)
                UserDefaults.standard.set(hasUnsavedChanges, forKey: dirtyKey)
            } catch {
                NSLog("Prism autosave failed: %@", error.localizedDescription)
            }
        }
    }

    /// Restores the previous session on launch: autosave (or the one before it) → last file → demo.
    /// If the autosave is newer than the last saved file, it wins so no work is lost. After a crash the
    /// session is restored even when "restore last session" is off. If reopening the autosave crashed
    /// Prism last time, it is set aside (moved next to the backups, never deleted) instead of reopened.
    func restoreOnLaunch(options: LaunchOptions) {
        if let path = options.projectPath, (try? open(url: path)) != nil { return }
        if options.demo {
            loadDemo()
            return
        }
        let fm = FileManager.default
        let defaults = UserDefaults.standard
        let auto = AppResources.autosaveURL
        let previous = Self.previousAutosaveURL
        let lastURL = defaults.string(forKey: Self.lastProjectPathKey).map { URL(fileURLWithPath: $0) }
        var notes: [String] = []

        if defaults.bool(forKey: Self.restoringAutosaveKey) {
            defaults.removeObject(forKey: Self.restoringAutosaveKey)
            if CrashGuard.previousLaunchCrashed {
                setAsideAutosaves([auto, previous])
                notes.append("Prism closed unexpectedly while reopening your last session, so it was set aside in the Backups folder.")
            }
        }

        if !options.safeMode, preferences.restoreLastSession || CrashGuard.previousLaunchCrashed {
            let fileMTime = lastURL.flatMap { modificationDate(of: $0) } ?? .distantPast
            var latestWasDamaged = false
            for candidate in [auto, previous] {
                guard let autoMTime = modificationDate(of: candidate), autoMTime >= fileMTime else { continue }
                defaults.set(true, forKey: Self.restoringAutosaveKey)
                guard let report = try? ProjectIO.readWithReport(from: candidate) else {
                    defaults.removeObject(forKey: Self.restoringAutosaveKey)
                    if candidate == auto { latestWasDamaged = true }
                    continue
                }
                var fixes = notes
                if candidate == previous, latestWasDamaged {
                    fixes.append("The latest autosave was damaged, so the one before it was restored.")
                }
                load(report.project, fileURL: lastURL, restoreLive: preferences.restoreLastLook,
                     additionalFixes: fixes + report.fixes)
                if defaults.bool(forKey: Self.autosaveDirtyKey) { isDirty = true }
                let guardKey = Self.restoringAutosaveKey
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreGuardSeconds) {
                    UserDefaults.standard.removeObject(forKey: guardKey)
                }
                return
            }
            if let lastURL, fm.fileExists(atPath: lastURL.path), (try? open(url: lastURL)) != nil {
                openReport = notes + openReport
                return
            }
        }
        loadDemo()
        openReport = notes + openReport
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Moves autosave files that crashed Prism into `Backups/Crashed Sessions` (renamed in place as a fallback).
    private func setAsideAutosaves(_ urls: [URL]) {
        let fm = FileManager.default
        let dir = AppResources.backups.appendingPathComponent("Crashed Sessions", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        for url in urls where fm.fileExists(atPath: url.path) {
            let destination = dir.appendingPathComponent("\(stamp)-\(url.lastPathComponent)")
            if (try? fm.moveItem(at: url, to: destination)) != nil { continue }
            if (try? fm.moveItem(at: url, to: url.appendingPathExtension("crashed-\(stamp)"))) != nil { continue }
            try? fm.removeItem(at: url)
        }
    }
}

/// Human-readable undo names for commands.
enum CommandNaming {
    static func name(for commands: [LightingCommand]) -> String {
        guard let first = commands.first(where: { if case .fadeTime = $0 { return false }; return true }) else { return "Change" }
        switch first {
        case .setIntensity, .adjustIntensity: return "Brightness"
        case .setColor, .shiftColor, .adjustSaturation, .gradient, .swapColors: return "Color"
        case .setCells, .paintCells: return "Paint Pixels"
        case .setKelvin, .adjustKelvin, .setTint, .adjustTint: return "White Balance"
        case .turnOn: return "Turn On"
        case .turnOff: return "Turn Off"
        case .recallLook: return "Recall Look"
        case .saveLook: return "Save Look"
        case .copyLook: return "Copy Look"
        case .startEffect: return "Start Effect"
        case .setEffectParameters: return "Effect Settings"
        case .stopEffects, .stopAllEffects: return "Stop Effects"
        case .setMusicMode: return "Music Mode"
        case .setGrandMaster: return "Master"
        case .setBlackout: return "Blackout"
        case .setFixtureProtection: return "Fixture Protection"
        case .setRecordingMode: return "Recording Mode"
        case .freeze: return "Freeze Output"
        case .identify: return "Identify"
        case .fadeTime: return "Change"
        }
    }
}
