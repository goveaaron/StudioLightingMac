import Foundation
import PrismCore

/// In-app self-test checks for this feature (see App/SelfTest.swift). Runs on CI inside the
/// real app process with the demo rig and no hardware.
@MainActor
enum StageSelfTest {
    static var checks: [SelfTest.Check] { [] }
}
