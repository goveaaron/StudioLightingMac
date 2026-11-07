import Foundation

/// Most-recently-used colours for the inspector's "Recent" row (newest first, no duplicates).
public struct ColorHistory: Codable, Sendable, Hashable {
    /// Default number of colours kept.
    public static let defaultLimit = 14

    /// Colours, newest first.
    public private(set) var colors: [LightColor]
    /// Maximum colours kept (1…64).
    public private(set) var limit: Int

    public init(colors: [LightColor] = [], limit: Int = ColorHistory.defaultLimit) {
        self.limit = clamp(limit, 1, 64)
        self.colors = []
        for c in colors.reversed() { push(c) }
    }

    /// Identity used for de-duplication: exact hex for RGB, the label otherwise.
    static func key(_ color: LightColor) -> String {
        if case .rgb(let c) = color { return c.hex }
        return color.label
    }

    /// Moves `color` to the front (adding it if new), trimming to `limit`.
    public mutating func push(_ color: LightColor) {
        let c = color.sanitized
        let k = Self.key(c)
        colors.removeAll { Self.key($0) == k }
        colors.insert(c, at: 0)
        if colors.count > limit { colors.removeLast(colors.count - limit) }
    }

    /// Removes `color` if present.
    public mutating func remove(_ color: LightColor) {
        let k = Self.key(color.sanitized)
        colors.removeAll { Self.key($0) == k }
    }

    /// Forgets everything.
    public mutating func clear() {
        colors.removeAll()
    }

    /// JSON for persistence.
    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Restores from persisted JSON, tolerating missing or damaged data (returns an empty history).
    public static func decode(_ data: Data?) -> ColorHistory {
        guard let data, let decoded = try? JSONDecoder().decode(ColorHistory.self, from: data) else {
            return ColorHistory()
        }
        // Re-run through `init` so limits, sanitising and de-duplication always hold.
        return ColorHistory(colors: decoded.colors, limit: decoded.limit)
    }
}
