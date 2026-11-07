import Foundation

/// Immutable search structures over the library's index entries, built off the main thread once
/// per library generation (`FixtureLibrary.searchIndex()`) and shared by every query.
///
/// Each entry is tokenized once:
/// - words from the manufacturer, model, aliases, badge and category ("SkyPanel S60-C" → skypanel, s60, c);
/// - sub-word parts at camelCase and letter↔digit boundaries (sky, panel, s, 60, c);
/// - adjacent-word joins ("LS 600c" → ls600c, "Pavo Tube" → pavotube, "amaran" + "PT4c" → amaranpt4c);
/// - brand and category synonyms ("nanlight", "adj", "batten", "monolight"...).
///
/// Tokens are interned into a sorted vocabulary with postings lists, so a query word only touches
/// the entries that contain a matching token. Substring matches use a 2/3-gram index over the
/// vocabulary, and typo tolerance (bounded edit distance) runs against the vocabulary, never
/// against every entry.
struct FixtureSearchIndex: Sendable {
    struct Doc: Sendable {
        let entry: FixtureLibraryEntry
        let modelCompact: String
        let displayCompact: String
        let idCompact: String
        let aliasCompacts: [String]
        let baseBoost: Int
    }

    // Per-word match tiers (best tier per word counts).
    static let exactScore: UInt8 = 35
    static let prefixScore: UInt8 = 28
    static let substringScore: UInt8 = 20
    static let gluedScore = 18
    static let fuzzy1Score: UInt8 = 12
    static let fuzzy2Score: UInt8 = 6

    let generation: Int
    /// Entries in browse order: manufacturer, then model (case- and accent-insensitive).
    let docs: [Doc]
    private let vocab: [String]
    private let vocabBytes: [[UInt8]]
    private let postings: [[Int32]]
    private let grams: [UInt32: [Int32]]
    private let byLength: [[Int32]]
    private let browseOrder: [Int32]
    private let docIndex: [String: Int32]

    /// Words that carry no meaning in a fixture search; dropped when other words remain.
    private static let stopWords: Set<String> = [
        "the", "a", "an", "my", "light", "lights", "fixture", "fixtures", "profile", "dmx", "lamp", "by", "for",
    ]

    private static let filmBrands: Set<String> = [
        "aputure", "amaran", "nanlite", "nanguang", "godox", "astera", "arri",
        "litepanels", "kino flo", "kinoflo", "quasar science", "quasar",
        "creamsource", "rotolight", "dedolight", "litegear", "fiilex", "lupo", "dmg lumiere",
    ]

    private static let stageBrands: Set<String> = [
        "chauvet", "chauvet dj", "chauvet professional", "american dj", "adj",
        "etc", "elation", "martin", "robe", "clay paky", "cameo", "stairville",
        "eurolite", "showtec", "glp", "ayrton", "prolights", "briteq", "varytec", "chroma q",
    ]

    /// Extra searchable words per manufacturer (keyed by the compact manufacturer name).
    private static let brandSynonyms: [String: [String]] = [
        "nanlite": ["nanlight nanguang"],
        "nanguang": ["nanlite nanlight"],
        "amaran": ["aputure"],
        "americandj": ["adj"],
        "adj": ["american dj"],
        "chauvetdj": ["chauvet"],
        "chauvetprofessional": ["chauvet"],
        "litepanels": ["lite panels"],
        "kinoflo": ["kino flo"],
        "quasarscience": ["quasar"],
        "arri": ["arriflex"],
        "claypaky": ["clay paky"],
    ]

    /// Plain words people use for each kind of light.
    private static let categorySynonyms: [FixtureCategory: [String]] = [
        .tube: ["tube tubes wand pixel tube"],
        .panel: ["panel soft mat flex"],
        .spot: ["spot cob monolight bowens point source"],
        .fresnel: ["fresnel"],
        .par: ["par led par can slimpar"],
        .bulb: ["bulb practical"],
        .strip: ["strip tape ribbon"],
        .bar: ["bar batten linear pixelbar"],
        .wash: ["wash flood"],
        .movingHead: ["moving head mover"],
        .dimmer: ["dimmer pack channel"],
        .effect: ["effect fx"],
    ]

    // MARK: - Building

    init(entries: [FixtureLibraryEntry], generation: Int) {
        self.generation = generation

        // Browse order: manufacturer, then model, then id (keys computed once, not per comparison).
        var keyed: [(mfr: String, model: String, entry: FixtureLibraryEntry)] = []
        keyed.reserveCapacity(entries.count)
        for e in entries {
            keyed.append((Self.tokenize(e.manufacturer).words.joined(separator: " "),
                          Self.tokenize(e.model).words.joined(separator: " "), e))
        }
        keyed.sort { a, b in
            if a.mfr != b.mfr { return a.mfr < b.mfr }
            if a.model != b.model { return a.model < b.model }
            return a.entry.id < b.entry.id
        }

        var tokenIDs: [String: Int32] = [:]
        var tokens: [String] = []
        var docTokens: [[Int32]] = []
        var docs: [Doc] = []
        docs.reserveCapacity(keyed.count)
        docTokens.reserveCapacity(keyed.count)

        for item in keyed {
            let e = item.entry
            var bag = Set<String>()
            func addField(_ text: String) -> [String] {
                let t = Self.tokenize(text)
                for w in t.words { bag.insert(w) }
                for p in t.parts { bag.insert(p) }
                if t.words.count > 1 {
                    for i in 0..<(t.words.count - 1) { bag.insert(t.words[i] + t.words[i + 1]) }
                    if t.words.count <= 5 { bag.insert(t.words.joined()) }
                }
                return t.words
            }
            let mfrWords = addField(e.manufacturer)
            let modelWords = addField(e.model)
            var aliasCompacts: [String] = []
            aliasCompacts.reserveCapacity(e.aliases.count)
            for alias in e.aliases {
                let words = addField(alias)
                if !words.isEmpty { aliasCompacts.append(words.joined()) }
            }
            _ = addField(e.badge)
            _ = addField(e.category.displayName)
            _ = addField(e.category.rawValue)
            if let last = mfrWords.last, let first = modelWords.first { bag.insert(last + first) }
            let mfrCompact = mfrWords.joined()
            for synonym in Self.brandSynonyms[mfrCompact] ?? [] { _ = addField(synonym) }
            for synonym in Self.categorySynonyms[e.category] ?? [] { _ = addField(synonym) }

            var ids: [Int32] = []
            ids.reserveCapacity(bag.count)
            for token in bag {
                if let id = tokenIDs[token] {
                    ids.append(id)
                } else {
                    let id = Int32(tokens.count)
                    tokenIDs[token] = id
                    tokens.append(token)
                    ids.append(id)
                }
            }
            docTokens.append(ids)

            let modelCompact = modelWords.joined()
            docs.append(Doc(
                entry: e,
                modelCompact: modelCompact,
                displayCompact: mfrCompact + modelCompact,
                idCompact: Self.tokenize(e.id).words.joined(),
                aliasCompacts: aliasCompacts,
                baseBoost: Self.baseBoost(source: e.source, manufacturer: mfrWords.joined(separator: " "))
            ))
        }

        // Sorted vocabulary + postings (doc indices ascending because docs are visited in order).
        let order = tokens.indices.sorted { tokens[$0] < tokens[$1] }
        var remap = [Int32](repeating: 0, count: tokens.count)
        for (newIndex, old) in order.enumerated() { remap[old] = Int32(newIndex) }
        let vocab = order.map { tokens[$0] }
        var postings = [[Int32]](repeating: [], count: vocab.count)
        for (di, list) in docTokens.enumerated() {
            for old in list { postings[Int(remap[Int(old)])].append(Int32(di)) }
        }

        // 2/3-gram index (substring lookups) and length buckets (typo tolerance).
        let vocabBytes = vocab.map { Array($0.utf8) }
        var grams: [UInt32: [Int32]] = [:]
        var byLength: [[Int32]] = []
        for (t, bytes) in vocabBytes.enumerated() {
            let n = bytes.count
            let t32 = Int32(t)
            while byLength.count <= n { byLength.append([]) }
            byLength[n].append(t32)
            guard n >= 2 else { continue }
            for i in 0..<(n - 1) {
                let k2 = Self.gramKey(bytes[i], bytes[i + 1])
                if grams[k2]?.last != t32 { grams[k2, default: []].append(t32) }
                if i + 2 < n {
                    let k3 = Self.gramKey(bytes[i], bytes[i + 1], bytes[i + 2])
                    if grams[k3]?.last != t32 { grams[k3, default: []].append(t32) }
                }
            }
        }

        var docIndex: [String: Int32] = [:]
        docIndex.reserveCapacity(docs.count)
        for (i, d) in docs.enumerated() where docIndex[d.entry.id] == nil { docIndex[d.entry.id] = Int32(i) }

        let browse = docs.indices.sorted { a, b in
            docs[a].baseBoost != docs[b].baseBoost ? docs[a].baseBoost > docs[b].baseBoost : a < b
        }

        self.docs = docs
        self.vocab = vocab
        self.vocabBytes = vocabBytes
        self.postings = postings
        self.grams = grams
        self.byLength = byLength
        self.browseOrder = browse.map { Int32($0) }
        self.docIndex = docIndex
    }

    private static func baseBoost(source: String?, manufacturer: String) -> Int {
        var boost = 0
        switch source {
        case "curated": boost += 50
        case "user": boost += 40
        case "generic": boost += 35
        case "ofl": boost += 10
        default: break
        }
        if filmBrands.contains(manufacturer) {
            boost += 25
        } else if stageBrands.contains(manufacturer) {
            boost += 15
        }
        return boost
    }

    // MARK: - Query

    /// Ranked, typo-tolerant search. Every meaningful query word must match (exactly, as a prefix,
    /// inside a word, or within a small edit distance); words that match nothing anywhere
    /// ("light", typos beyond repair) are ignored. Ties keep browse order.
    func search(_ query: String, category: FixtureCategory?, limit: Int, recent: [String]) -> [FixtureLibraryEntry] {
        guard limit > 0, !docs.isEmpty else { return [] }
        var words: [String] = []
        for w in Self.tokenize(query).words where !words.contains(w) { words.append(w) }
        let meaningful = words.filter { !Self.stopWords.contains($0) }
        if !meaningful.isEmpty { words = meaningful }
        if words.isEmpty { return browse(category: category, limit: limit, recent: recent) }

        let n = docs.count
        var total = [Int32](repeating: 0, count: n)
        var hits = [UInt8](repeating: 0, count: n)
        var best = [UInt8](repeating: 0, count: n)
        var touched: [Int32] = []
        var required = 0
        var expansions: [(token: Int32, score: UInt8)] = []

        for w in words.prefix(12) {
            expansions.removeAll(keepingCapacity: true)
            collectMatches(w, fuzzy: true, into: &expansions)
            if expansions.isEmpty { continue }
            let round = UInt8(required)
            required += 1
            for (token, score) in expansions {
                for d in postings[Int(token)] {
                    let di = Int(d)
                    if hits[di] == round {
                        hits[di] = round &+ 1
                        best[di] = score
                        touched.append(d)
                    } else if hits[di] == round &+ 1, score > best[di] {
                        best[di] = score
                    }
                }
            }
            for d in touched { total[Int(d)] += Int32(best[Int(d)]) }
            touched.removeAll(keepingCapacity: true)
        }
        guard required > 0 else { return [] }

        // The words glued together ("pavo tube" → pavotube, "amaran pt 4" → amaranpt4) also count.
        let glued = words.joined()
        if words.count > 1 {
            expansions.removeAll(keepingCapacity: true)
            collectMatches(glued, fuzzy: false, into: &expansions)
            let full = UInt8(required)
            let floor = Int32(Self.gluedScore * required)
            for (token, _) in expansions {
                for d in postings[Int(token)] {
                    let di = Int(d)
                    if hits[di] != full { hits[di] = full }
                    if total[di] < floor { total[di] = floor }
                }
            }
        }

        let recentDocs = Set(recent.compactMap { docIndex[$0] })
        let full = UInt8(required)
        var candidates: [(score: Int, doc: Int32)] = []
        for i in 0..<n where hits[i] == full {
            let doc = docs[i]
            if let category, doc.entry.category != category { continue }
            var score = Int(total[i]) + doc.baseBoost
            if recentDocs.contains(Int32(i)) { score += 15 }
            if doc.modelCompact == glued {
                score += 180
            } else if doc.modelCompact.hasPrefix(glued) {
                score += 95
            } else if doc.modelCompact.contains(glued) {
                score += 55
            }
            if doc.displayCompact == glued || doc.idCompact == glued {
                score += 200
            } else if doc.displayCompact.hasPrefix(glued) {
                score += 85
            }
            if doc.aliasCompacts.contains(glued) {
                score += 160
            } else if doc.aliasCompacts.contains(where: { $0.hasPrefix(glued) }) {
                score += 75
            }
            candidates.append((score, Int32(i)))
        }
        return Self.top(candidates, limit: limit).map { docs[Int($0)].entry }
    }

    /// Empty query: recently used first (most recent first), then curated/generic/brand-ranked.
    private func browse(category: FixtureCategory?, limit: Int, recent: [String]) -> [FixtureLibraryEntry] {
        var out: [FixtureLibraryEntry] = []
        out.reserveCapacity(min(limit, docs.count))
        var used = Set<Int32>()
        for id in recent {
            guard out.count < limit, let i = docIndex[id], !used.contains(i) else { continue }
            let entry = docs[Int(i)].entry
            if let category, entry.category != category { continue }
            used.insert(i)
            out.append(entry)
        }
        for i in browseOrder where out.count < limit && !used.contains(i) {
            let entry = docs[Int(i)].entry
            if let category, entry.category != category { continue }
            out.append(entry)
        }
        return out
    }

    /// Highest scores first; ties keep browse order. Uses a score histogram to avoid sorting
    /// thousands of candidates when only the first `limit` are needed.
    private static func top(_ candidates: [(score: Int, doc: Int32)], limit: Int) -> [Int32] {
        var pool = candidates
        if pool.count > limit * 2 {
            let maxBucket = 4095
            var histogram = [Int](repeating: 0, count: maxBucket + 1)
            for c in pool { histogram[min(max(c.score, 0), maxBucket)] += 1 }
            var threshold = 0
            var running = 0
            var bucket = maxBucket
            while bucket >= 0 {
                running += histogram[bucket]
                if running >= limit { threshold = bucket; break }
                bucket -= 1
            }
            pool = pool.filter { min(max($0.score, 0), maxBucket) >= threshold }
        }
        pool.sort { a, b in a.score != b.score ? a.score > b.score : a.doc < b.doc }
        return pool.prefix(limit).map(\.doc)
    }

    /// Vocabulary tokens matching `word`: exact (35), prefix (28), inside a token (20, words of
    /// 3+ characters or 2 with a digit, e.g. "4c"), and, when `fuzzy`, within edit distance 1–2
    /// of the word or of a token's beginning (12 / 6, words of 4+ characters).
    private func collectMatches(_ word: String, fuzzy: Bool, into out: inout [(token: Int32, score: UInt8)]) {
        let wBytes = Array(word.utf8)
        guard !wBytes.isEmpty else { return }

        // Exact + prefix: a contiguous range of the sorted vocabulary.
        var lo = 0, hi = vocab.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if vocab[mid] < word { lo = mid + 1 } else { hi = mid }
        }
        var i = lo
        while i < vocab.count, vocab[i].hasPrefix(word) {
            out.append((Int32(i), vocab[i] == word ? Self.exactScore : Self.prefixScore))
            i += 1
        }

        // Inside a token, via the rarest n-gram of the word.
        let hasDigit = wBytes.contains { $0 >= 48 && $0 <= 57 }
        if wBytes.count >= 3 || (wBytes.count == 2 && hasDigit) {
            var candidates: [Int32]?
            if wBytes.count == 2 {
                candidates = grams[Self.gramKey(wBytes[0], wBytes[1])]
            } else {
                for j in 0...(wBytes.count - 3) {
                    guard let list = grams[Self.gramKey(wBytes[j], wBytes[j + 1], wBytes[j + 2])] else {
                        candidates = nil
                        break
                    }
                    if let current = candidates, current.count <= list.count { continue }
                    candidates = list
                }
            }
            for t in candidates ?? [] {
                let tok = vocabBytes[Int(t)]
                guard tok.count > wBytes.count, !Self.hasPrefix(tok, wBytes), Self.contains(tok, wBytes) else { continue }
                out.append((t, Self.substringScore))
            }
        }

        // Typos: bounded edit distance against tokens (or their beginnings) of similar length.
        guard fuzzy, wBytes.count >= 4 else { return }
        let qLen = wBytes.count
        let maxDistance = qLen >= 7 ? 2 : 1
        let minLen = max(3, qLen - maxDistance)
        guard minLen < byLength.count else { return }
        let first = wBytes[0], last = wBytes[qLen - 1]
        var scratch = [Int](repeating: 0, count: 3 * (qLen + maxDistance + 1))
        for len in minLen..<byLength.count {
            let compareLen = min(len, qLen + maxDistance)
            for t in byLength[len] {
                let tok = vocabBytes[Int(t)]
                if tok[0] != first && tok[compareLen - 1] != last { continue }
                guard let d = Self.editDistance(wBytes, tok, compareLen: compareLen, maxDistance: maxDistance,
                                                scratch: &scratch), d > 0 else { continue }
                out.append((t, d == 1 ? Self.fuzzy1Score : Self.fuzzy2Score))
            }
        }
    }

    // MARK: - Text helpers

    /// Splits text into lowercase, accent-free words ("SkyPanel S60-C" → skypanel, s60, c) and
    /// sub-word parts at camelCase and letter↔digit boundaries (sky, panel, s, 60, c).
    static func tokenize(_ text: String) -> (words: [String], parts: [String]) {
        var words: [String] = []
        var parts: [String] = []
        var word: [UInt8] = []
        var part: [UInt8] = []
        // 0 = start of word, 1 = lowercase, 2 = uppercase, 3 = digit, 4 = other letter
        var previous = 0

        func flushPart() {
            if !part.isEmpty {
                parts.append(String(decoding: part, as: UTF8.self))
                part.removeAll(keepingCapacity: true)
            }
        }
        func flushWord() {
            flushPart()
            if !word.isEmpty {
                words.append(String(decoding: word, as: UTF8.self))
                word.removeAll(keepingCapacity: true)
            }
            previous = 0
        }
        func boundary(_ current: Int) {
            let prevLetter = previous == 1 || previous == 2 || previous == 4
            let curLetter = current == 1 || current == 2 || current == 4
            if (previous == 1 && current == 2) || (prevLetter && current == 3) || (previous == 3 && curLetter) {
                flushPart()
            }
            previous = current
        }

        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v < 128 {
                let b = UInt8(v)
                switch b {
                case 97...122: boundary(1); word.append(b); part.append(b)
                case 65...90: boundary(2); word.append(b + 32); part.append(b + 32)
                case 48...57: boundary(3); word.append(b); part.append(b)
                default: flushWord()
                }
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                let folded = String(scalar).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
                var appended = false
                for fs in folded.unicodeScalars where fs.properties.isAlphabetic || fs.properties.numericType != nil {
                    if !appended { boundary(fs.properties.numericType != nil ? 3 : 4); appended = true }
                    word.append(contentsOf: Array(String(fs).utf8))
                    part.append(contentsOf: Array(String(fs).utf8))
                }
            } else if scalar.properties.generalCategory == .nonspacingMark {
                continue  // combining accents: drop, keep the word together
            } else {
                flushWord()
            }
        }
        flushWord()
        return (words, parts)
    }

    private static func gramKey(_ a: UInt8, _ b: UInt8) -> UInt32 {
        (2 << 24) | (UInt32(a) << 8) | UInt32(b)
    }

    private static func gramKey(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt32 {
        (3 << 24) | (UInt32(a) << 16) | (UInt32(b) << 8) | UInt32(c)
    }

    private static func hasPrefix(_ s: [UInt8], _ p: [UInt8]) -> Bool {
        guard s.count >= p.count else { return false }
        for i in 0..<p.count where s[i] != p[i] { return false }
        return true
    }

    private static func contains(_ s: [UInt8], _ p: [UInt8]) -> Bool {
        guard !p.isEmpty, s.count >= p.count else { return p.isEmpty }
        var start = 0
        while start + p.count <= s.count {
            var j = 0
            while j < p.count, s[start + j] == p[j] { j += 1 }
            if j == p.count { return true }
            start += 1
        }
        return false
    }

    /// Optimal-string-alignment distance (Levenshtein + adjacent transpositions) between `a` and
    /// the first `compareLen` bytes of `b`, or nil when it exceeds `maxDistance`.
    private static func editDistance(_ a: [UInt8], _ b: [UInt8], compareLen m: Int, maxDistance: Int,
                                     scratch: inout [Int]) -> Int? {
        let n = a.count
        guard m <= b.count, abs(n - m) <= maxDistance else { return nil }
        let width = m + 1
        if scratch.count < 3 * width { scratch = [Int](repeating: 0, count: 3 * width) }
        // Rows: (i-2) at offset r0, (i-1) at r1, i at r2 — rotated each iteration.
        var r0 = 0, r1 = width, r2 = 2 * width
        for j in 0...m { scratch[r1 + j] = j }
        if n == 0 { return m <= maxDistance ? m : nil }
        for i in 1...n {
            scratch[r2] = i
            var rowMin = i
            let ai = a[i - 1]
            if m >= 1 {
                for j in 1...m {
                    let bj = b[j - 1]
                    let cost = ai == bj ? 0 : 1
                    var value = min(scratch[r1 + j] + 1, scratch[r2 + j - 1] + 1, scratch[r1 + j - 1] + cost)
                    if i > 1, j > 1, ai == b[j - 2], a[i - 2] == bj {
                        value = min(value, scratch[r0 + j - 2] + 1)
                    }
                    scratch[r2 + j] = value
                    if value < rowMin { rowMin = value }
                }
            }
            if rowMin > maxDistance { return nil }
            (r0, r1, r2) = (r1, r2, r0)
        }
        let d = scratch[r1 + m]
        return d <= maxDistance ? d : nil
    }
}
