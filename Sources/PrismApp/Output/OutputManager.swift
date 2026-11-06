import Foundation
import PrismCore

/// Summary shown in the toolbar status pill.
struct OutputSummary: Equatable {
    enum Level: Equatable { case connected, simulated, warning, error }
    var level: Level
    var title: String
    var detail: String
}

/// Manages DMX interfaces (Enttec DMX USB Pro, Art-Net, sACN…) and connects them to the engine.
///
/// OWNER: Output workstream. This placeholder registers a virtual output so the app runs
/// without hardware; the real implementation adds device discovery, hot-plug, reconnect,
/// per-universe routing, the hardware test and sleep prevention.
@MainActor
@Observable
final class OutputManager: AppService {
    @ObservationIgnored let engine: EngineCore
    private(set) var summary = OutputSummary(level: .simulated, title: "Simulation", detail: "No DMX interface connected")
    @ObservationIgnored private let virtualOutput = VirtualDMXOutput(id: "virtual", name: "Virtual Output", universe: 1)

    init(engine: EngineCore) {
        self.engine = engine
    }

    func start(app: AppModel) {
        engine.addOutput(virtualOutput)
    }

    func shutdown() {}
}
