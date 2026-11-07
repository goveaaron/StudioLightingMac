import Foundation

/// Text normalization for the assistant: lowercasing, accent folding, contractions, British
/// spellings, number words, punctuation tokens and typo correction. Pure and deterministic.
public enum AssistantText {
    /// Punctuation kept as clause-separating tokens.
    public static let clausePunctuation: Set<String> = [".", ",", ";", "!", "?", ":"]

    /// Pure noise words dropped during tokenization.
    static let noise: Set<String> = ["um", "umm", "ummm", "uh", "uhh", "uhm", "er", "erm", "ehm", "hmm", "hm", "mm", "ah", "ahh"]

    /// Splits raw text into normalized tokens ("Bit more blue to the left-hand side!" →
    /// ["bit", "more", "blue", "to", "the", "left", "hand", "side", "!"]).
    public static func tokenize(_ raw: String) -> [String] {
        let folded = raw.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var s = folded
        let replacements: [(String, String)] = [
            ("\u{2019}", "'"), ("\u{2018}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\""),
            ("\u{2014}", " , "), ("\u{2013}", " , "), ("\u{2026}", " . "), ("&", " and "),
            ("%", " percent "), ("\u{00B0}", " "), ("\u{00BD}", " half "), ("\u{00BC}", " quarter ")
        ]
        for (a, b) in replacements { s = s.replacingOccurrences(of: a, with: b) }

        let chars = Array(s)
        var out = ""
        out.reserveCapacity(chars.count + 16)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let prev: Character = i > 0 ? chars[i - 1] : " "
            let next: Character = i + 1 < chars.count ? chars[i + 1] : " "
            switch c {
            case ".":
                if prev.isNumber && next.isNumber { out.append(c) } else { out += " . " }
            case ",":
                // Thousands separator: "3,200k".
                if prev.isNumber && i + 3 < chars.count && chars[i + 1].isNumber && chars[i + 2].isNumber && chars[i + 3].isNumber
                    && (i + 4 >= chars.count || !chars[i + 4].isNumber) {
                    // drop it
                } else {
                    out += " , "
                }
            case ";", "!", "?", ":":
                out += " \(c) "
            case "/":
                if prev.isNumber && next.isNumber { out.append(c) } else { out += " " }
            case "#", "'":
                out.append(c)
            default:
                if c.isLetter || c.isNumber { out.append(c) } else { out += " " }
            }
            i += 1
        }

        var tokens: [String] = []
        for piece in out.split(separator: " ") {
            for t in expand(String(piece)) where !t.isEmpty && !noise.contains(t) {
                tokens.append(t)
            }
        }
        return tokens
    }

    static let contractions: [String: [String]] = [
        "it's": ["it", "is"], "that's": ["that", "is"], "what's": ["what", "is"], "where's": ["where", "is"],
        "there's": ["there", "is"], "here's": ["here", "is"], "who's": ["who", "is"], "how's": ["how", "is"],
        "let's": ["let", "us"], "i'm": ["i", "am"], "can't": ["can", "not"], "cannot": ["can", "not"],
        "won't": ["will", "not"], "'em": ["them"], "em": ["them"], "gimme": ["give", "me"], "lemme": ["let", "me"],
        "wanna": ["want", "to"], "gonna": ["going", "to"], "gotta": ["got", "to"], "kinda": ["kind", "of"],
        "sorta": ["sort", "of"], "alright": ["all", "right"], "allright": ["all", "right"], "ok": ["okay"],
        "okey": ["okay"], "okie": ["okay"], "pls": ["please"], "plz": ["please"], "thx": ["thanks"],
        "colour": ["color"], "colours": ["colors"], "coloured": ["colored"], "centre": ["center"],
        "grey": ["gray"], "favourite": ["favorite"], "lightapp": ["light", "app"], "tv's": ["tv"],
        "backlight": ["backlight"], "brightness": ["brightness"]
    ]

    /// Expands one raw token (contractions, possessives, glued words).
    static func expand(_ token: String) -> [String] {
        var t = token
        while t.hasPrefix("'") && t != "'em" { t.removeFirst() }
        while t.hasSuffix("'") { t.removeLast() }
        guard !t.isEmpty else { return [] }
        if let mapped = contractions[t] { return mapped }
        if t.hasSuffix("n't"), t.count > 3 { return [String(t.dropLast(3)), "not"] }
        if t.hasSuffix("'s") { return [String(t.dropLast(2))] }
        for (suffix, word) in [("'re", "are"), ("'ll", "will"), ("'ve", "have"), ("'d", "would")] where t.hasSuffix(suffix) {
            return [String(t.dropLast(suffix.count)), word]
        }
        return [t.replacingOccurrences(of: "'", with: "")]
    }

    // MARK: Numbers

    static let unitWords: [String: Double] = [
        "zero": 0, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19
    ]
    static let tensWords: [String: Double] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]

    /// Parses a number at `index` — digits ("50", "0.5", "1/2", "3200k" without the unit) or
    /// number words ("fifty", "thirty two hundred", "five thousand six hundred"). "one" only
    /// counts when followed by a number word or `allowOne` (so "the left one" stays a noun).
    /// Returns the value and the number of tokens consumed.
    static func number(in tokens: [String], at index: Int, allowOne: Bool = false) -> (value: Double, consumed: Int)? {
        guard index < tokens.count else { return nil }
        let t = tokens[index]
        if let v = digitValue(t) { return (v, 1) }
        var total = 0.0
        var current = 0.0
        var consumed = 0
        var sawWord = false
        var j = index
        while j < tokens.count {
            let w = tokens[j]
            if let u = unitWords[w] {
                current += u; sawWord = true
            } else if w == "one" || w == "a" {
                let nextWord = j + 1 < tokens.count ? tokens[j + 1] : ""
                let isMultiplier = nextWord == "hundred" || nextWord == "thousand"
                let afterTens = sawWord && current >= 20 && current < 100 && current.truncatingRemainder(dividingBy: 10) == 0
                let accepted = w == "a" ? (isMultiplier && !sawWord) : (isMultiplier || afterTens || (allowOne && !sawWord))
                guard accepted else { break }
                current += 1; sawWord = true
            } else if let tv = tensWords[w] {
                current += tv; sawWord = true
            } else if w == "hundred" && sawWord {
                current = max(current, 1) * 100
            } else if w == "thousand" && sawWord {
                total += max(current, 1) * 1000; current = 0
            } else if w == "and" && sawWord && j + 1 < tokens.count && (unitWords[tokens[j + 1]] != nil || tensWords[tokens[j + 1]] != nil) {
                // "two hundred and fifty"
            } else {
                break
            }
            j += 1
            consumed = j - index
        }
        guard sawWord, consumed > 0 else { return nil }
        return (total + current, consumed)
    }

    /// Parses digit strings: "50", "0.5", "1/2", ".5".
    static func digitValue(_ t: String) -> Double? {
        guard let first = t.first, first.isNumber || (first == "." && t.count > 1) else { return nil }
        if t.contains("/") {
            let parts = t.split(separator: "/")
            guard parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b != 0 else { return nil }
            return a / b
        }
        guard t.allSatisfy({ $0.isNumber || $0 == "." }), let v = Double(t), v.isFinite else { return nil }
        return v
    }

    // MARK: Typos

    /// Optimal-string-alignment edit distance (adjacent transpositions count as one edit),
    /// returning `limit + 1` as soon as the distance must exceed `limit`.
    public static func editDistance(_ a: String, _ b: String, limit: Int = 2) -> Int {
        editDistance(Array(a), Array(b), limit: limit)
    }

    static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev2 = [Int](repeating: 0, count: b.count + 1)
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { v = min(v, prev2[j - 2] + 1) }
                cur[j] = v
                rowMin = min(rowMin, v)
            }
            if rowMin > limit { return limit + 1 }
            prev2 = prev
            prev = cur
        }
        return prev[b.count]
    }

    /// Replaces unknown words (4+ letters) with the closest vocabulary word when the match is
    /// unambiguous: one edit for short words, two for words of 7+ letters.
    public static func correctTypos(_ tokens: [String], vocabulary: Set<String>) -> [String] {
        let candidates = vocabulary.filter { $0.count >= 3 }.map { ($0, Array($0)) }
        return tokens.map { t in
            guard t.count >= 4, t.allSatisfy({ $0.isLetter }), !vocabulary.contains(t),
                  !vocabulary.contains(SelectorResolver.singular(t)) else { return t }
            let limit = t.count >= 7 ? 2 : 1
            let tc = Array(t)
            var best: [String] = []
            var bestD = limit + 1
            for (word, chars) in candidates where abs(chars.count - tc.count) <= limit {
                let d = editDistance(tc, chars, limit: limit)
                if d < bestD { bestD = d; best = [word] } else if d == bestD && d <= limit { best.append(word) }
            }
            guard bestD <= limit, !best.isEmpty else { return t }
            if best.count == 1 { return best[0] }
            // Ties: keep those sharing the first letter; accept when they are forms of one word.
            let sameStart = best.filter { $0.first == t.first }
            let pool = sameStart.isEmpty ? best : sameStart
            let stems = Set(pool.map { SelectorResolver.singular($0) })
            if stems.count == 1 { return pool.sorted { abs($0.count - t.count) < abs($1.count - t.count) }[0] }
            return t
        }
    }
}
