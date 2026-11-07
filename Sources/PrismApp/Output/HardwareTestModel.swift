import Foundation
import Observation
import PrismCore

/// State and actions behind the guided Hardware Test (Help ▸ Hardware Test…).
///
/// The test signal uses raw DMX overrides: the light under test at 30 % white, every other
/// patched light held dark. Whatever overrides were active before are put back as soon as the
/// user leaves that step or closes the sheet, so the test never leaves anything behind.
@MainActor
@Observable
final class HardwareTestModel {
    enum Step: Int, CaseIterable, Identifiable {
        case connection, testLights, channels, blink, tips

        var id: Int { rawValue }
        var number: Int { rawValue + 1 }

        var title: String {
            switch self {
            case .connection: return "DMX box"
            case .testLights: return "Test each light"
            case .channels: return "Channel monitor"
            case .blink: return "Blink a light"
            case .tips: return "Tips"
            }
        }

        var subtitle: String {
            switch self {
            case .connection: return "Is it plugged in?"
            case .testLights: return "One at a time, 30% white"
            case .channels: return "All 512 channels, live"
            case .blink: return "Find a light in the room"
            case .tips: return "If a light stays dark"
            }
        }

        var systemImage: String {
            switch self {
            case .connection: return "cable.connector.horizontal"
            case .testLights: return "lightbulb.fill"
            case .channels: return "square.grid.3x3.fill"
            case .blink: return "sparkles"
            case .tips: return "wrench.and.screwdriver"
            }
        }
    }

    /// The step on screen.
    private(set) var step: Step = .connection
    /// Index into `fixtures` of the light under test.
    private(set) var testIndex = 0
    /// Answers to "Did it light up?", by fixture.
    private(set) var answers: [UUID: Bool] = [:]
    /// The light that is blinking right now (step 4), if any.
    private(set) var blinking: UUID?
    /// True while the sheet is on screen.
    private(set) var isOpen = false
    /// Universe shown by the channel monitor.
    var monitorUniverse = 1
    /// Channel clicked in the monitor (1-based).
    var selectedAddress: Int?
    /// Channel under the pointer (1-based).
    var hoveredAddress: Int?

    @ObservationIgnored private weak var app: AppModel?
    /// Overrides that were active before the test signal started (restored afterwards).
    @ObservationIgnored private var savedOverrides: [RawOverride]?
    @ObservationIgnored private var pending: (step: Step, lightIndex: Int, answers: [UUID: Bool])?
    @ObservationIgnored private var blinkTask: Task<Void, Never>?

    func attach(_ app: AppModel) { self.app = app }

    // MARK: - Lights

    /// Patched lights in test order (universe, then address).
    var fixtures: [ResolvedFixture] {
        guard let app else { return [] }
        return HardwareTestPlan.order(app.show.resolvedFixtures)
    }

    /// The light under test (step 2).
    var currentFixture: ResolvedFixture? {
        let list = fixtures
        guard !list.isEmpty else { return nil }
        return list[min(max(testIndex, 0), list.count - 1)]
    }

    /// Lights the user said stayed dark.
    var darkFixtures: [ResolvedFixture] { fixtures.filter { answers[$0.id] == false } }

    /// True once every patched light has an answer.
    var allAnswered: Bool {
        let list = fixtures
        return !list.isEmpty && list.allSatisfy { answers[$0.id] != nil }
    }

    // MARK: - Navigation

    /// Sets what the sheet shows when it next opens (screenshot tour, deep links).
    func prepare(step: Step, lightIndex: Int = 0, answers: [UUID: Bool] = [:]) {
        pending = (step, lightIndex, answers)
    }

    /// The sheet appeared.
    func open() {
        isOpen = true
        let start = pending ?? (step: Step.connection, lightIndex: 0, answers: [UUID: Bool]())
        pending = nil
        answers = start.answers
        testIndex = start.lightIndex
        go(to: start.step)
    }

    func go(to newStep: Step) {
        step = newStep
        if newStep == .testLights { applyTestSignal() } else { restoreOverrides() }
    }

    func next() {
        if let s = Step(rawValue: step.rawValue + 1) { go(to: s) }
    }

    func back() {
        if let s = Step(rawValue: step.rawValue - 1) { go(to: s) }
    }

    /// The sheet closed (or Prism quits): stop the test signal and reset.
    func end() {
        restoreOverrides()
        blinkTask?.cancel()
        blinkTask = nil
        blinking = nil
        isOpen = false
        step = .connection
        testIndex = 0
        selectedAddress = nil
        hoveredAddress = nil
    }

    // MARK: - Test signal

    func showLight(at index: Int) {
        let count = fixtures.count
        guard count > 0 else { return }
        testIndex = min(max(index, 0), count - 1)
        if step == .testLights { applyTestSignal() }
    }

    func nextLight() { showLight(at: testIndex + 1) }
    func previousLight() { showLight(at: testIndex - 1) }

    /// Records the answer to "Did it light up?". A yes moves on to the next light.
    func answer(_ litUp: Bool) {
        guard let rf = currentFixture else { return }
        answers[rf.id] = litUp
        if litUp, testIndex < fixtures.count - 1 { nextLight() }
    }

    /// Starts over with the first light that stayed dark.
    func retestDarkLights() {
        let list = fixtures
        guard let first = list.firstIndex(where: { answers[$0.id] == false }) else { return }
        for rf in list where answers[rf.id] == false { answers[rf.id] = nil }
        showLight(at: first)
    }

    /// Keeps the test signal in place: re-applies it after an undo or a patch change.
    /// Called twice a second while the sheet is open.
    func maintain() {
        guard isOpen, step == .testLights, let app else { return }
        let wanted = HardwareTestPlan.soloOverrides(target: currentFixture?.id, fixtures: app.show.resolvedFixtures)
        if app.show.live.rawOverrides != wanted { app.show.setRawOverrides(wanted) }
    }

    private func applyTestSignal() {
        guard let app else { return }
        if savedOverrides == nil { savedOverrides = app.show.live.rawOverrides }
        let overrides = HardwareTestPlan.soloOverrides(target: currentFixture?.id, fixtures: app.show.resolvedFixtures)
        if app.show.live.rawOverrides != overrides { app.show.setRawOverrides(overrides) }
    }

    private func restoreOverrides() {
        guard let saved = savedOverrides else { return }
        savedOverrides = nil
        guard let app else { return }
        if saved.isEmpty { app.show.clearRawOverrides() } else { app.show.setRawOverrides(saved) }
    }

    // MARK: - Blink

    /// Flashes one light for two seconds (visible even in blackout).
    func blink(_ id: UUID) {
        app?.show.identify([id])
        blinking = id
        blinkTask?.cancel()
        blinkTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.blinking = nil
        }
    }
}
