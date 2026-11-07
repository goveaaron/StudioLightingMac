import AppKit
import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from idle-sleeping (and disables App Nap) while DMX is being sent, so a
/// show never freezes because nobody touched the keyboard. Lid-close and Apple menu › Sleep
/// still work; Prism reconnects after wake.
@MainActor
final class KeepAwake {
    private var activity: NSObjectProtocol?
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private(set) var isActive = false
    private(set) var keepsDisplayOn = false

    /// Turns sleep prevention on or off (idempotent).
    func update(active: Bool, keepDisplayOn: Bool) {
        if active && !isActive {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "Prism is sending DMX to your lights")
            systemAssertion = Self.createAssertion(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                   "Prism is sending DMX to your lights")
            isActive = true
        } else if !active && isActive {
            Self.releaseAssertion(&systemAssertion)
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
            isActive = false
        }
        let wantDisplay = active && keepDisplayOn
        if wantDisplay && displayAssertion == 0 {
            displayAssertion = Self.createAssertion(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                    "Prism show running")
        } else if !wantDisplay && displayAssertion != 0 {
            Self.releaseAssertion(&displayAssertion)
        }
        keepsDisplayOn = displayAssertion != 0
    }

    private static func createAssertion(_ type: CFString, _ reason: String) -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        return result == kIOReturnSuccess ? id : 0
    }

    private static func releaseAssertion(_ id: inout IOPMAssertionID) {
        if id != 0 { IOPMAssertionRelease(id); id = 0 }
    }
}

/// Tells the output manager when the Mac goes to sleep and wakes up again.
@MainActor
final class SleepWakeObserver {
    private var tokens: [NSObjectProtocol] = []

    init(onSleep: @escaping @MainActor () -> Void, onWake: @escaping @MainActor () -> Void) {
        let center = NSWorkspace.shared.notificationCenter // not NotificationCenter.default
        tokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { onSleep() }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { onWake() }
        })
    }

    func invalidate() {
        let center = NSWorkspace.shared.notificationCenter
        for t in tokens { center.removeObserver(t) }
        tokens.removeAll()
    }
}
