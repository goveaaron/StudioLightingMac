import Foundation

/// Phone / web remote: embedded server, QR pairing, share links with guardrails, tunnel.
///
/// OWNER: Remote workstream. Placeholder.
@MainActor
@Observable
final class RemoteController: AppService {
    private(set) var isServing = false
    private(set) var connectedClients = 0

    func start(app: AppModel) {}
    func shutdown() {}
}
