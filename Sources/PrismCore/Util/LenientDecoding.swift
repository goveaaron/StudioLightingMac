import Foundation

/// Helpers for decoding untrusted files defensively (ARCHITECTURE §7): a corrupt value repairs
/// to a default instead of making the whole document unreadable.

/// Wraps one element of an array (or dictionary value) so a corrupt element decodes to `nil`
/// instead of failing the whole collection.
struct TolerantElement<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// Decodes a value leniently: a missing, `null` or corrupt value yields `nil` instead of throwing.
    func decodeLenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        guard contains(key) else { return nil }
        return (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// Decodes an array leniently, dropping corrupt elements.
    /// - Returns: `nil` when the key is missing or isn't an array at all; otherwise the valid
    ///   elements (at most `limit`) and how many were dropped.
    func decodeTolerantArray<T: Decodable>(_ type: T.Type, forKey key: Key,
                                           limit: Int = .max) -> (values: [T], dropped: Int)? {
        guard contains(key) else { return nil }
        if let direct = try? decodeIfPresent([T].self, forKey: key) {
            let capped = direct.count > limit ? Array(direct.prefix(max(0, limit))) : direct
            return (capped, direct.count - capped.count)
        }
        guard let tolerant = try? decode([TolerantElement<T>].self, forKey: key) else { return nil }
        var valid = tolerant.compactMap(\.value)
        var dropped = tolerant.count - valid.count
        if valid.count > limit {
            dropped += valid.count - max(0, limit)
            valid = Array(valid.prefix(max(0, limit)))
        }
        return (valid, dropped)
    }
}
