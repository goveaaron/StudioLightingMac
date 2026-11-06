import Foundation
import PrismCore

/// Namespace + version info for the embedded remote-control server.
///
/// The full implementation (SwiftNIO HTTP + WebSocket server, share-link auth,
/// guardrails, static web-remote hosting) lives in this module. See
/// `docs/ARCHITECTURE.md` → "Remote".
public enum PrismServerInfo {
    public static let protocolVersion = 1
    public static let defaultPort = 8742
}
