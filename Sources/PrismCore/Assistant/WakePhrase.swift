import Foundation

/// Detects and strips wake phrases ("Hey Prism", "All right, light app", or a user-defined
/// phrase) at the start of an utterance, with a confidence score so background music or
/// conversation never triggers the assistant by accident.
public struct WakePhraseMatcher: Hashable, Sendable {
    /// Assistant names (token sequences) that may follow an optional greeting.
    public private(set) var names: [[String]]

    /// Greetings that may precede a name ("hey", "all right", "okay").
    public static let greetings: [[String]] = [
        ["all", "right"], ["hey", "there"], ["hey"], ["hi"], ["hello"], ["okay"], ["right"], ["yo"], ["oi"], ["so"]
    ]

    /// Built-in names: "Prism" and the owner's nickname for the app, "light app".
    public static let builtInNames = ["prism", "light app", "lights app", "prism lights", "the light app"]

    /// Confidence for a greeting followed by an exact name (or an exact custom phrase).
    public static let fullConfidence = 1.0
    /// Confidence for an exact name without a greeting ("Prism, dim the tubes").
    public static let nameOnlyConfidence = 0.85
    /// Confidence for a near-miss name ("prizm").
    public static let fuzzyConfidence = 0.6

    public init(customPhrases: [String] = [], includeBuiltIns: Bool = true) {
        var all: [[String]] = []
        let phrases = (includeBuiltIns ? WakePhraseMatcher.builtInNames : []) + customPhrases
        for p in phrases {
            let tokens = AssistantText.tokenize(p).filter { !AssistantText.clausePunctuation.contains($0) }
            if !tokens.isEmpty && !all.contains(tokens) { all.append(tokens) }
        }
        names = all.sorted { $0.count > $1.count }
    }

    /// Default matcher (built-in names only).
    public static let standard = WakePhraseMatcher()

    /// A detected wake phrase.
    public struct Match: Hashable, Sendable {
        /// The words that matched ("all right light app").
        public var phrase: String
        /// 1 = greeting + exact name, 0.85 = exact name alone, 0.6 = near miss.
        public var confidence: Double
        /// Tokens consumed from the start, including punctuation after the phrase.
        public var consumed: Int
        public var hadGreeting: Bool
    }

    /// Matches a wake phrase at the start of `tokens` (one leading filler like "so" is allowed).
    public func match(_ tokens: [String]) -> Match? {
        var i = 0
        func skipPunct() { while i < tokens.count && AssistantText.clausePunctuation.contains(tokens[i]) { i += 1 } }
        func startsWith(_ seq: [String], at k: Int) -> Bool {
            guard k + seq.count <= tokens.count else { return false }
            for (o, w) in seq.enumerated() where tokens[k + o] != w { return false }
            return true
        }
        skipPunct()
        var words: [String] = []
        var hadGreeting = false
        // Full custom phrases that start with a greeting are matched as names first.
        if let name = names.first(where: { startsWith($0, at: i) }) {
            words = name
            i += name.count
            skipPunct()
            return Match(phrase: words.joined(separator: " "), confidence: name.count > 1 || isDistinctive(name) ? Self.fullConfidence : Self.nameOnlyConfidence,
                         consumed: i, hadGreeting: false)
        }
        for g in Self.greetings where startsWith(g, at: i) {
            words += g
            i += g.count
            hadGreeting = true
            break
        }
        skipPunct()
        if let name = names.first(where: { startsWith($0, at: i) }) {
            words += name
            i += name.count
            skipPunct()
            return Match(phrase: words.joined(separator: " "), confidence: hadGreeting ? Self.fullConfidence : Self.nameOnlyConfidence,
                         consumed: i, hadGreeting: hadGreeting)
        }
        // Near misses ("prizm", "prisim") only count after a greeting.
        if hadGreeting, i < tokens.count {
            let word = tokens[i]
            for name in names where name.count == 1 && name[0].count >= 5 {
                if AssistantText.editDistance(word, name[0], limit: 1) <= 1 {
                    i += 1
                    skipPunct()
                    return Match(phrase: (words + [word]).joined(separator: " "), confidence: Self.fuzzyConfidence, consumed: i, hadGreeting: true)
                }
            }
        }
        return nil
    }

    /// Single words that are unlikely in normal speech count as a full-confidence name.
    func isDistinctive(_ name: [String]) -> Bool {
        name.count == 1 && name[0] != "prism" && name[0].count >= 6
    }

    /// Removes a wake phrase — or a bare leading greeting followed by a pause ("All right, …") —
    /// from the start of the tokens.
    public func strip(_ tokens: [String]) -> (tokens: [String], match: Match?) {
        if let m = match(tokens) {
            return (Array(tokens.dropFirst(m.consumed)), m)
        }
        // "All right, warm up…" / "Okay. Dim the tubes" — a greeting followed by punctuation.
        for g in Self.greetings {
            guard g.count < tokens.count, Array(tokens.prefix(g.count)) == g else { continue }
            if AssistantText.clausePunctuation.contains(tokens[g.count]) || g != ["right"] {
                var rest = Array(tokens.dropFirst(g.count))
                while let f = rest.first, AssistantText.clausePunctuation.contains(f) { rest.removeFirst() }
                return (rest, nil)
            }
        }
        return (tokens, nil)
    }

    /// Minimum confidence to wake from hands-free listening. With music playing only a greeting
    /// plus the exact name counts.
    public static func minimumConfidence(musicPlaying: Bool) -> Double {
        musicPlaying ? fullConfidence : 0.8
    }

    /// Checks a live transcript for a wake phrase at its start. Returns the command after the
    /// phrase (possibly empty: the user paused after the name) when confident enough.
    public func wake(in transcript: String, musicPlaying: Bool) -> (command: String, match: Match)? {
        let tokens = AssistantText.tokenize(transcript)
        guard let m = match(tokens), m.confidence >= Self.minimumConfidence(musicPlaying: musicPlaying) else { return nil }
        let rest = tokens.dropFirst(m.consumed)
        let command = rest.joined(separator: " ")
            .replacingOccurrences(of: " ,", with: ",").replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " ?", with: "?").replacingOccurrences(of: " !", with: "!")
        return (command, m)
    }
}
