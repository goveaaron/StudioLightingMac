import Foundation

/// Webcam: live view, Light Finder (flash each light and locate it), unknown-light scan,
/// color verification for assistant requests.
///
/// OWNER: Camera workstream. Placeholder.
@MainActor
@Observable
final class CameraController: AppService {
    private(set) var isRunning = false

    func start(app: AppModel) {}
    func shutdown() {}
}
