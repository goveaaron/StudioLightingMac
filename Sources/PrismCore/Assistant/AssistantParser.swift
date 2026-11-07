import Foundation

/// The offline, deterministic parser behind "Ask Prism" and voice control.
///
/// It understands relative phrasing ("a bit", "a little", "way more"), lighting roles (key, fill,
/// back, background, hair), spatial words ("left", "back left", "above"), colours and colour
/// temperatures, compound sentences, wake phrases ("All right, light app") and scene requests
/// ("teal on the left, blue on the right, pink above"). It never needs a network or a model —
/// Foundation Models and cloud models only enhance it.
///
/// The output is a ``ParsedRequest`` (what the user asked for, before it is bound to the rig);
/// ``AssistantPlanner`` turns it into a ``LightingPlan``.
public struct AssistantParser: Sendable {
    /// Names from the user's rig (fixtures, groups, looks).
    public var vocabulary: RigVocabulary
    /// Wake phrases removed from the start of an utterance.
    public var wake: WakePhraseMatcher

    public init(vocabulary: RigVocabulary = .empty, wake: WakePhraseMatcher = .standard) {
        self.vocabulary = vocabulary
        self.wake = wake
    }

    /// A parser that knows a project's fixture, group and look names.
    public init(project: Project, wake: WakePhraseMatcher = .standard) {
        self.init(vocabulary: RigVocabulary(project: project), wake: wake)
    }

    /// Parses one typed or spoken request.
    public func parse(_ text: String) -> ParsedRequest {
        let raw = AssistantText.tokenize(text)
        let stripped = wake.strip(raw)
        var tokens = stripped.tokens
        // "Okay." / "Right." on their own are replies, not greetings.
        if stripped.match == nil, !tokens.contains(where: { !AssistantText.clausePunctuation.contains($0) }) {
            tokens = raw
        }
        tokens = Self.applyAliases(tokens)
        tokens = AssistantText.correctTypos(tokens, vocabulary: AssistantLexicon.vocabulary.union(vocabulary.words))
        let lexed = AssistantLexer(vocabulary: vocabulary).lex(tokens)

        var request = ParsedRequest(text: text, tokens: tokens, wakePhrase: stripped.match)
        request.unknownWords = lexed.compactMap { tok -> String? in
            guard case .word(let w) = tok.lex, w.count > 1, !AssistantLexicon.stopWords.contains(w),
                  !w.allSatisfy({ $0.isNumber }) else { return nil }
            return w
        }
        if let look = detectLook(lexed) {
            request.actions = [look]
            return request
        }
        let readings = makeClauses(lexed).map { read($0) }
        let outcome = Self.discourse(readings)
        request.actions = Self.mergeScenes(outcome.actions)
        request.isCorrection = outcome.isCorrection
        request.fadeSeconds = outcome.fade
        return request
    }

    // MARK: - Normalization

    /// Fixes common speech-recognition and typing slips ("phil" → "fill", "the feel" → "the fill").
    static func applyAliases(_ tokens: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(tokens.count)
        for (i, t) in tokens.enumerated() {
            if let replacement = AssistantLexicon.aliases[t] {
                out.append(contentsOf: replacement)
                continue
            }
            if t == "feel", i > 0, tokens[i - 1] == "the" {
                out.append("fill")
                continue
            }
            out.append(t)
        }
        return out
    }

    static func titleCase(_ s: String) -> String {
        s.split(separator: " ").map { word -> String in
            guard let first = word.first else { return "" }
            return first.uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    // MARK: - Looks

    /// Saving and recalling looks ("save this as Interview", "go to Chill Vibes", "Deep Blue").
    func detectLook(_ lexed: [LexToken]) -> ParsedAction? {
        var hasSave = false, hasRecall = false, hasLookWord = false
        var hasColor = false, hasTarget = false, hasOtherAction = false
        for tok in lexed {
            switch tok.lex {
            case .verb(.save): hasSave = true
            case .verb(.recall): hasRecall = true
            case .look: hasLookWord = true
            case .music, .effectWord, .flicker, .control, .question: return nil
            case .color, .colorComparative: hasColor = true
            case .target: hasTarget = true
            case .verb, .comparative, .more, .less, .particle, .number, .level, .quantity, .unit: hasOtherAction = true
            default: break
            }
        }
        if hasSave {
            var nameTokens: [LexToken] = []
            if let k = lexed.firstIndex(where: { tok in
                if case .prep(let p) = tok.lex { return p == .as_ || p == .called }
                return false
            }) {
                nameTokens = Array(lexed[(k + 1)...])
            } else if let k = lexed.firstIndex(where: { if case .look = $0.lex { return true }; return false }) {
                nameTokens = Array(lexed[(k + 1)...])
            } else if let k = lexed.firstIndex(where: { if case .verb(.save) = $0.lex { return true }; return false }) {
                nameTokens = lexed[(k + 1)...].filter { tok in
                    switch tok.lex {
                    case .target(.selection), .target(.previous), .target(.everything), .look, .prep: return false
                    default: return true
                    }
                }
            }
            let name = nameTokens.filter { tok in
                switch tok.lex {
                case .det, .punct: return false
                default: return true
                }
            }.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return .saveLook(name.isEmpty ? nil : Self.titleCase(name))
        }
        let phrase = lexed.filter { tok in
            switch tok.lex {
            case .verb, .det, .punct, .look, .prep, .negation, .quantity, .conj: return false
            default: return true
            }
        }.map(\.text).joined(separator: " ")
        if hasLookWord || hasRecall {
            if let best = vocabulary.bestLook(for: phrase), !(hasColor && hasTarget && best.score < 0.99) {
                return .recallLook(best.name)
            }
            if hasLookWord, !phrase.isEmpty, !hasColor, !hasTarget, !hasOtherAction {
                return .recallLook(Self.titleCase(phrase))
            }
            return nil
        }
        // The exact name of a look on its own ("Chill Vibes 4").
        if !hasOtherAction, !hasTarget, let best = vocabulary.bestLook(for: phrase, minimumScore: 0.99) {
            return .recallLook(best.name)
        }
        return nil
    }

    // MARK: - Clauses

    /// One clause of an utterance ("bring the tubes down a little bit").
    struct Clause {
        var toks: [LexToken]
        /// The clause began with "and" (".., and the fill").
        var leadingAnd: Bool
        /// Index of the punctuation-delimited segment it came from.
        var segment: Int
    }

    /// Splits at punctuation and "then", then at "and"/"but" between complete instructions, then
    /// between colour–place pairs said without pauses ("teal left blue right").
    func makeClauses(_ lexed: [LexToken]) -> [Clause] {
        var segments: [[LexToken]] = []
        var current: [LexToken] = []
        for tok in lexed {
            switch tok.lex {
            case .punct, .then:
                if !current.isEmpty { segments.append(current) }
                current = []
            default:
                current.append(tok)
            }
        }
        if !current.isEmpty { segments.append(current) }

        var out: [Clause] = []
        for (s, segment) in segments.enumerated() {
            var toks = segment
            var leading = false
            while let first = toks.first, first.lex.isJoiner {
                toks.removeFirst()
                leading = true
            }
            guard !toks.isEmpty else { continue }
            for (n, part) in Self.splitJoiners(toks).enumerated() {
                for (m, pair) in Self.splitPairs(part).enumerated() where !pair.isEmpty {
                    let isFirst = n == 0 && m == 0
                    out.append(Clause(toks: pair, leadingAnd: isFirst ? leading : (m == 0), segment: s))
                }
            }
        }
        return out
    }

    static func splitJoiners(_ toks: [LexToken]) -> [[LexToken]] {
        var parts: [[LexToken]] = []
        var start = 0
        var i = 0
        while i < toks.count {
            if toks[i].lex.isJoiner, i > start {
                var end = i + 1
                while end < toks.count, !toks[end].lex.isJoiner { end += 1 }
                let left = Array(toks[start..<i])
                let right = Array(toks[(i + 1)..<end])
                if shouldSplit(left: left, right: right) {
                    parts.append(left)
                    start = i + 1
                }
            }
            i += 1
        }
        if start < toks.count { parts.append(Array(toks[start...])) }
        return parts.filter { !$0.isEmpty }
    }

    /// "dim the key and brighten the fill" splits; "the key and the fill", "blue and teal" and
    /// "turn the key and the fill off" do not.
    static func shouldSplit(left: [LexToken], right: [LexToken]) -> Bool {
        guard left.contains(where: { $0.lex.isValue }), right.contains(where: { $0.lex.isValue }) else { return false }
        let rightContent = right.filter { !$0.lex.isFiller }
        if !rightContent.isEmpty, rightContent.allSatisfy({ $0.lex.isColor }) { return false }
        let leftContent = left.filter { tok in
            if tok.lex.isFiller || tok.lex.isJoiner { return false }
            if case .verb(let v) = tok.lex, v == .set || v == .turn || v == .bring { return false }
            return true
        }
        if !leftContent.isEmpty, leftContent.allSatisfy({ $0.lex.isColor }), right.contains(where: { $0.lex.isColor }) {
            return false
        }
        return true
    }

    static func splitPairs(_ toks: [LexToken]) -> [[LexToken]] {
        var parts: [[LexToken]] = []
        var current: [LexToken] = []
        var hasColor = false, hasTarget = false
        var lastContent: Lexeme?
        for tok in toks {
            var split = false
            if hasColor, hasTarget, let last = lastContent, !last.isJoiner, !last.isExcept {
                if tok.lex.isPlainColor {
                    split = true
                } else if tok.lex.isStrongTarget, last.isPlainColor {
                    split = true
                }
            }
            if split {
                parts.append(current)
                current = []
                hasColor = false
                hasTarget = false
            }
            current.append(tok)
            if tok.lex.isPlainColor { hasColor = true }
            if tok.lex.isStrongTarget { hasTarget = true }
            if !tok.lex.isFiller { lastContent = tok.lex }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    // MARK: - Reading one clause

    enum ReadingKind: Equatable {
        case actions, bareTarget, colorsOnly, ack, negationOnly, loneRight, empty
    }

    /// What one clause means on its own.
    struct Reading {
        var actions: [ParsedAction] = []
        var target: TargetSpec?
        var negated = false
        var kind: ReadingKind = .actions
        var colors: [ColorSpec] = []
        /// "too", "as well", "same for".
        var also = false
        var leadingAnd = false
        var segment = 0
        var fade: Double?
    }

    func read(_ clause: Clause) -> Reading {
        let toks = Self.contextualize(clause.toks)
        var r = Reading()
        r.leadingAnd = clause.leadingAnd
        r.segment = clause.segment
        let content = toks.filter { !$0.lex.isFiller }
        if content.isEmpty {
            r.kind = .empty
            return r
        }
        if content.allSatisfy({ if case .negation = $0.lex { return true }; return false }) {
            r.kind = .negationOnly
            return r
        }
        if toks.count == 1, case .target(.area(.right)) = toks[0].lex, toks[0].text == "right" {
            r.kind = .loneRight
            r.target = .area(.right)
            return r
        }
        let f = Self.features(toks)
        r.negated = f.negated
        r.colors = f.colors
        r.target = buildTarget(toks)
        let meaningful = content.filter { tok in
            switch tok.lex {
            case .control(.acknowledge), .negation: return false
            default: return true
            }
        }
        if meaningful.isEmpty {
            r.kind = .ack
            return r
        }
        r.actions = Self.interpret(f, target: r.target)
        r.also = f.controls.contains(.same) || (f.too && r.actions.isEmpty)
        let isEffect = r.actions.contains { if case .startEffect = $0 { return true }; return false }
        var fade: Double? = isEffect ? nil : f.fades.last
        for n in f.numbers {
            if n.unit == .seconds { fade = n.value } else if n.unit == .minutes { fade = n.value * 60 }
        }
        r.fade = fade.map { clamp($0.finiteOr(0), 0, 600) }
        if r.actions.isEmpty {
            r.kind = r.target != nil ? .bareTarget : .empty
        } else if r.target == nil, !f.colors.isEmpty, r.actions.count == 1, case .setColor = r.actions[0] {
            r.kind = .colorsOnly
        }
        return r
    }

    /// Context-dependent word meanings.
    static func contextualize(_ input: [LexToken]) -> [LexToken] {
        var out: [LexToken] = []
        out.reserveCapacity(input.count)
        for (i, tok) in input.enumerated() {
            let prev: Lexeme? = i > 0 ? input[i - 1].lex : nil
            let next: Lexeme? = i + 1 < input.count ? input[i + 1].lex : nil
            switch tok.lex {
            case .particle(.on) where tok.text == "on":
                // "teal on the left": a preposition, not "switch on".
                let switchVerbBefore = input[..<i].contains { t in
                    if case .verb(let v) = t.lex { return v == .turn || v == .kill }
                    return false
                }
                let isLastContent = !input[(i + 1)...].contains { !$0.lex.isFiller }
                var nextIsPlace = false
                if let next {
                    switch next {
                    case .det, .target: nextIsPlace = true
                    default: break
                    }
                }
                if !switchVerbBefore, !isLastContent, nextIsPlace {
                    out.append(LexToken(lex: .prep(.on), text: tok.text))
                    continue
                }
            case .verb(.lower):
                // "the lower tubes".
                if case .det? = prev {
                    out.append(LexToken(lex: .target(.area(.bottom)), text: tok.text))
                    continue
                }
            case .target(.area(.back)):
                // "bring the tubes back up": "back" is a particle here, not a place.
                var prevIsTarget = false
                if case .target? = prev { prevIsTarget = true }
                var nextAllows = true
                if let next {
                    switch next {
                    case .particle, .quantity, .punct, .more, .less, .comparative: nextAllows = true
                    default: nextAllows = false
                    }
                }
                if prevIsTarget, nextAllows { continue }
            case .question:
                if i != 0 { continue }
            case .negation:
                if i != 0, tok.text != "instead" { continue }
            case .verb(.stop):
                // "one stop brighter", "half a stop", "a stop down".
                var isUnit = false
                if let prev {
                    switch prev {
                    case .number, .level, .target(.one): isUnit = true
                    case .det:
                        if let next {
                            switch next {
                            case .comparative, .particle, .more, .less: isUnit = true
                            default: break
                            }
                        } else {
                            isUnit = true
                        }
                    default: break
                    }
                }
                if isUnit {
                    if case .target(.one)? = prev, !out.isEmpty {
                        out[out.count - 1] = LexToken(lex: .number(1), text: input[i - 1].text)
                    }
                    out.append(LexToken(lex: .unit(.stops), text: tok.text))
                    continue
                }
            default:
                break
            }
            out.append(tok)
        }
        return out
    }

    // MARK: - Features

    struct NumberMention {
        var value: Double
        var unit: AssistantUnit?
        var prep: AssistantPrep?
    }

    /// Everything a clause mentions, by kind.
    struct Features {
        var verbs: [AssistantVerb] = []
        var particles: [AssistantParticle] = []
        var comparatives: [(attr: AssistantAttribute, dir: Int)] = []
        var adjectives: [(attr: AssistantAttribute, dir: Int)] = []
        var quantity: NudgeAmount?
        var more = false
        var less = false
        var too = false
        var attributes: [(attr: AssistantAttribute, text: String)] = []
        var colors: [ColorSpec] = []
        var colorComparatives: [ColorSpec] = []
        var effectOrColors: [(kind: EffectKind, color: ColorSpec)] = []
        var numbers: [NumberMention] = []
        var levels: [Double] = []
        var negated = false
        var controls: [AssistantControl] = []
        var effects: [EffectKind] = []
        var effectWord = false
        var flicker = false
        var music = false
        var moods: [MusicMood] = []
        var fades: [Double] = []
        var gradientWord = false
        var question: String?
        var preps: [AssistantPrep] = []
        var hasTarget = false

        /// The amount said, or "a bit".
        var amount: AmountSpec { quantity.map { AmountSpec.nudge($0) } ?? .standard }
        /// The amount said, if any.
        var explicitAmount: AmountSpec? { quantity.map { AmountSpec.nudge($0) } }
    }

    static func features(_ toks: [LexToken]) -> Features {
        var f = Features()
        var lastPrep: AssistantPrep?
        var i = 0
        while i < toks.count {
            let tok = toks[i]
            switch tok.lex {
            case .verb(let v):
                f.verbs.append(v)
                if tok.text == "fade" { f.fades.append(2) }
            case .particle(let p):
                f.particles.append(p)
                if tok.text.hasPrefix("fade") { f.fades.append(2) }
            case .comparative(let a, let d): f.comparatives.append((a, d))
            case .adjective(let a, let d): f.adjectives.append((a, d))
            case .quantity(let q): f.quantity = q
            case .more: f.more = true
            case .less: f.less = true
            case .too: f.too = true
            case .attribute(let a): f.attributes.append((a, tok.text))
            case .color(let c): f.colors.append(c)
            case .colorComparative(let c): f.colorComparatives.append(c)
            case .effectOrColor(let k, let c): f.effectOrColors.append((k, c))
            case .number(let v):
                var unit: AssistantUnit?
                if i + 1 < toks.count, case .unit(let u) = toks[i + 1].lex {
                    unit = u
                    i += 1
                }
                if v.isFinite { f.numbers.append(NumberMention(value: v, unit: unit, prep: lastPrep)) }
            case .unit(let u):
                if u == .stops {
                    var value = 1.0
                    if let k = f.levels.lastIndex(of: 0.5) {
                        f.levels.remove(at: k)
                        value = 0.5
                    }
                    f.numbers.append(NumberMention(value: value, unit: .stops, prep: lastPrep))
                }
            case .level(let l): f.levels.append(l)
            case .target: f.hasTarget = true
            case .negation: f.negated = true
            case .control(let c): f.controls.append(c)
            case .effect(let k): f.effects.append(k)
            case .effectWord: f.effectWord = true
            case .flicker: f.flicker = true
            case .music: f.music = true
            case .mood(let m): f.moods.append(m)
            case .fade(let s): f.fades.append(s)
            case .gradientWord: f.gradientWord = true
            case .question(let q): f.question = q
            case .prep(let p): f.preps.append(p)
            case .look, .conj, .then, .except, .but, .det, .punct, .word: break
            }
            if case .prep(let p) = tok.lex {
                lastPrep = p
            } else if !tok.lex.isFiller {
                if case .number = tok.lex {} else { lastPrep = nil }
            }
            i += 1
        }
        return f
    }

    // MARK: - Interpretation

    static func interpret(_ f: Features, target: TargetSpec?) -> [ParsedAction] {
        let t = target ?? .unspecified
        let amount = f.amount

        // 1. Controls.
        if let c = f.controls.first(where: { $0 != .acknowledge && $0 != .same }) {
            switch c {
            case .undo: return [.undo]
            case .redo: return [.redo]
            case .help: return [.query(.help)]
            case .whatsOn: return [.query(.whatsOn)]
            case .blackout: return f.negated ? [.lightsOn] : [.blackout(true)]
            case .lightsOn: return [.lightsOn]
            case .freeze: return [.freeze(true)]
            case .unfreeze: return [.freeze(false)]
            case .recording: return [.recordingMode(!f.negated)]
            case .recordingOff: return [.recordingMode(false)]
            case .otherSide: return [.otherSide]
            case .tooMuch: return [.less(f.explicitAmount)]
            case .again: return [.more(f.explicitAmount, target)]
            case .acknowledge, .same: break
            }
        }

        // 2. Questions ("how bright is the key?", "which one is B3?").
        if f.question != nil, f.verbs.allSatisfy({ $0 == .identify }), f.colors.isEmpty, f.comparatives.isEmpty,
           f.numbers.isEmpty, f.levels.isEmpty, !f.more, !f.less {
            if f.verbs.contains(.identify) { return [.identify(t)] }
            if target != nil { return [.query(.state(t))] }
            return [.query(.whatsOn)]
        }

        // 3. Music.
        let startish = f.verbs.contains(.start) || f.verbs.contains(.recall) || f.verbs.contains(.set) || f.verbs.contains(.turn)
        if f.music || (!f.moods.isEmpty && (startish || (target == nil && f.verbs.isEmpty && f.colors.isEmpty))) {
            let stopping = f.particles.contains(.off) || f.verbs.contains(.stop) || f.verbs.contains(.kill) || f.negated
            if stopping, !f.verbs.contains(.start) { return [.music(enabled: false, mood: nil)] }
            let mood = f.moods.last ?? f.effects.compactMap(musicMood(for:)).last ?? f.effectOrColors.compactMap { musicMood(for: $0.kind) }.last
            return [.music(enabled: true, mood: mood)]
        }

        // 4. Effects ("make it flicker like a candle", "stop the effects").
        let effectish = f.flicker || f.effectWord || f.verbs.contains(.start)
        let kinds = f.effects + (effectish ? f.effectOrColors.map(\.kind) : [])
        if f.flicker || f.effectWord || !kinds.isEmpty {
            let stopping = (f.verbs.contains(.stop) || f.verbs.contains(.kill) || f.particles.contains(.off) || f.negated || f.less)
                && !f.verbs.contains(.start)
            if stopping { return [.stopEffects(target)] }
            let kind = kinds.last ?? (f.flicker ? .candle : .breathe)
            var speed: Double?
            if f.fades.contains(where: { $0 >= 10 }) { speed = 0.25 } else if f.fades.contains(where: { $0 >= 4 }) { speed = 0.5 }
            else if f.fades.contains(where: { $0 > 0 && $0 < 1 }) { speed = 2 }
            return [.startEffect(kind, t, speed: speed)]
        }

        // 5. Swaps ("swap the key and the fill", "flip the sides").
        if f.verbs.contains(.swap) {
            if case .any(let items)? = target, items.count == 2 { return [.swapColors(items[0], items[1])] }
            return [.swapColors(target, nil)]
        }

        // 6. Identify ("which one is B3", "flash the left tube").
        if f.verbs.contains(.identify) { return [.identify(t)] }

        // 7. "Stop" on its own stops effects.
        if f.verbs.contains(.stop), f.colors.isEmpty, f.numbers.isEmpty, f.comparatives.isEmpty, f.particles.isEmpty {
            return [.stopEffects(target)]
        }

        // 8. Gradients ("orange to pink across the back").
        if f.colors.count >= 2, f.gradientWord || f.preps.contains(.from) || (f.preps.contains(.to) && f.preps.contains(.over)) {
            return [.gradient(t, f.colors)]
        }

        // 9. "Too bright", "too blue": the opposite, a little.
        if f.too {
            let fix = f.explicitAmount ?? .nudge(.aLittle)
            if let adj = f.adjectives.first {
                switch adj.attr {
                case .intensity: return [.adjustIntensity(t, direction: -adj.dir, amount: fix)]
                case .warmth: return [.adjustWarmth(t, direction: -adj.dir, amount: fix)]
                case .saturation: return [.adjustSaturation(t, direction: -adj.dir, amount: fix)]
                case .tint: return [.adjustTint(t, direction: -adj.dir, amount: fix)]
                case .color: break
                }
            }
            if f.verbs.contains(.warm) { return [.adjustWarmth(t, direction: -1, amount: fix)] }
            if f.verbs.contains(.cool) { return [.adjustWarmth(t, direction: 1, amount: fix)] }
            if f.verbs.contains(.dim) { return [.adjustIntensity(t, direction: 1, amount: fix)] }
            if let c = f.colorComparatives.last ?? f.colors.last { return [.reduceColor(t, c, amount: fix)] }
            if let comp = f.comparatives.first {
                switch comp.attr {
                case .intensity: return [.adjustIntensity(t, direction: -comp.dir, amount: fix)]
                case .warmth: return [.adjustWarmth(t, direction: -comp.dir, amount: fix)]
                case .saturation: return [.adjustSaturation(t, direction: -comp.dir, amount: fix)]
                default: break
                }
            }
        }

        // 10. Colours.
        if let colour = f.colorComparatives.last ?? f.colors.last {
            let kelvinNumber = f.numbers.first { n in
                n.unit == .kelvin || (n.unit == nil && n.value >= 1000 && n.value <= 20000)
            }
            if let k = kelvinNumber, f.colors.allSatisfy(\.isWhite), f.colorComparatives.isEmpty {
                return [.setKelvin(t, kelvin: clamp(k.value, 1000, 20000))]
            }
            var dir = 0
            if f.particles.contains(.up) || f.verbs.contains(.brighten) { dir = 1 }
            if f.particles.contains(.down) || f.verbs.contains(.dim) || f.verbs.contains(.lower) { dir = -1 }
            if f.less || f.verbs.contains(.remove) || dir < 0 {
                return [.reduceColor(t, colour, amount: amount)]
            }
            if f.more || f.verbs.contains(.add) || !f.colorComparatives.isEmpty || dir > 0 {
                return [.shiftColor(t, toward: colour, amount: amount)]
            }
            var out: [ParsedAction] = [.setColor(t, f.colors.isEmpty ? [colour] : f.colors)]
            if let level = setLevel(f) { out.append(.setIntensity(t, level: level)) }
            return out
        }

        // 11. Numbers: Kelvin, percent, stops; bare numbers by range.
        for n in f.numbers {
            switch n.unit {
            case .seconds?, .minutes?:
                continue
            case .kelvin?:
                return [kelvinAction(n, f, t)]
            case .percent?:
                return [percentAction(n, f, t)]
            case .stops?:
                let d = intensityDirection(f)
                return [.scaleStops(t, stops: clamp(n.value, 0, 10) * Double(d == 0 ? 1 : d))]
            case nil:
                if n.value >= 1000, n.value <= 20000 { return [kelvinAction(n, f, t)] }
                if n.value >= 0, n.value <= 100 { return [percentAction(n, f, t)] }
            }
        }

        // 12. Levels ("full", "half").
        if let level = f.levels.last { return [.setIntensity(t, level: level)] }

        // 13. Warmth.
        let warmth = warmthDirection(f)
        if warmth != 0 {
            let plainSet = f.verbs.contains(.set) && f.particles.isEmpty && f.quantity == nil && !f.more && !f.less
                && f.comparatives.isEmpty && f.attributes.isEmpty
            if plainSet {
                let white = warmth > 0
                    ? (AssistantColors.lookup("warm white") ?? ColorSpec(name: "warm white", color: .kelvin(2700, tint: 0)))
                    : (AssistantColors.lookup("cool white") ?? ColorSpec(name: "cool white", color: .kelvin(6500, tint: 0)))
                return [.setColor(t, [white])]
            }
            return [.adjustWarmth(t, direction: warmth, amount: amount)]
        }

        // 14. Saturation and tint.
        var saturation = 0
        if f.verbs.contains(.saturate) {
            saturation = 1
        } else if f.verbs.contains(.desaturate) {
            saturation = -1
        } else if let c = f.comparatives.first(where: { $0.attr == .saturation }) {
            saturation = c.dir
        } else if f.attributes.contains(where: { $0.attr == .saturation }) {
            saturation = generalDirection(f)
        }
        if saturation != 0 { return [.adjustSaturation(t, direction: saturation, amount: amount)] }
        if let tint = f.attributes.first(where: { $0.attr == .tint }) {
            var d = generalDirection(f)
            if tint.text.contains("plus green") { d = -1 } else if tint.text.contains("minus green") { d = 1 }
            if d != 0 { return [.adjustTint(t, direction: d, amount: amount)] }
        }

        // 15. On / off.
        let off = f.particles.contains(.off) || f.verbs.contains(.kill)
        if off || f.particles.contains(.on) {
            let everything = target.map(isEverything) ?? false
            if off { return everything ? [.blackout(true)] : [.turnOff(t)] }
            return everything ? [.lightsOn] : [.turnOn(t)]
        }

        // 16. Brighter / dimmer.
        let dir = intensityDirection(f)
        if dir != 0 { return [.adjustIntensity(t, direction: dir, amount: amount)] }

        // 17. Follow-ups: "a bit more", "less".
        if f.more { return [.more(f.explicitAmount, target)] }
        if f.less { return [.less(f.explicitAmount)] }

        // 18. "Show the key".
        if f.verbs.contains(.recall), target != nil { return [.identify(t)] }
        return []
    }

    static func setLevel(_ f: Features) -> Double? {
        if let p = f.numbers.first(where: { $0.unit == .percent || ($0.unit == nil && $0.value <= 100) }) {
            return clamp(p.value / 100, 0, 1)
        }
        return f.levels.last
    }

    static func percentAction(_ n: NumberMention, _ f: Features, _ t: TargetSpec) -> ParsedAction {
        let dir = intensityDirection(f)
        let value = clamp(n.value / 100, 0, 1)
        if n.prep == .by || (dir != 0 && n.prep != .to && n.prep != .at) {
            return .adjustIntensity(t, direction: dir == 0 ? 1 : dir, amount: .percent(value))
        }
        return .setIntensity(t, level: value)
    }

    static func kelvinAction(_ n: NumberMention, _ f: Features, _ t: TargetSpec) -> ParsedAction {
        var dir = warmthDirection(f)
        if dir == 0 {
            if f.particles.contains(.up) { dir = -1 } else if f.particles.contains(.down) { dir = 1 }
        }
        if n.prep == .by || (dir != 0 && n.prep != .to && n.prep != .at) {
            return .adjustWarmth(t, direction: dir == 0 ? 1 : dir, amount: .kelvin(clamp(n.value, 0, 10000)))
        }
        return .setKelvin(t, kelvin: clamp(n.value, 1000, 20000))
    }

    /// +1 up / −1 down from particles, brighten/dim verbs and more/less.
    static func generalDirection(_ f: Features) -> Int {
        if f.particles.contains(.up) || f.verbs.contains(.brighten) { return 1 }
        if f.particles.contains(.down) || f.verbs.contains(.dim) || f.verbs.contains(.lower) { return -1 }
        if f.more { return 1 }
        if f.less { return -1 }
        return 0
    }

    static func intensityDirection(_ f: Features) -> Int {
        if let c = f.comparatives.first(where: { $0.attr == .intensity }) { return c.dir }
        if f.verbs.contains(.brighten) { return 1 }
        if f.verbs.contains(.dim) || f.verbs.contains(.lower) { return -1 }
        if f.particles.contains(.up) { return 1 }
        if f.particles.contains(.down) { return -1 }
        if f.attributes.contains(where: { $0.attr == .intensity }) {
            if f.more { return 1 }
            if f.less { return -1 }
        }
        return 0
    }

    /// +1 warmer, −1 cooler, 0 when warmth isn't mentioned.
    static func warmthDirection(_ f: Features) -> Int {
        var d = 0
        if f.verbs.contains(.warm) { d = 1 } else if f.verbs.contains(.cool) { d = -1 }
        if d != 0 { return f.less ? -d : d }
        if let c = f.comparatives.first(where: { $0.attr == .warmth }) { return c.dir }
        if let a = f.attributes.first(where: { $0.attr == .warmth }) {
            let g = generalDirection(f)
            // "Temperature up" means more Kelvin — cooler.
            return a.text.contains("warmth") ? g : -g
        }
        if f.verbs.contains(.set), let adj = f.adjectives.first(where: { $0.attr == .warmth }) { return adj.dir }
        return 0
    }

    static func isEverything(_ t: TargetSpec) -> Bool {
        switch t {
        case .everything: return true
        default: return false
        }
    }

    static func musicMood(for effect: EffectKind) -> MusicMood? {
        switch effect {
        case .aurora: return .aurora
        case .lava: return .lavaLamp
        case .sunset: return .sunset
        case .gradientSweep: return .gradientSweep
        case .ocean: return .oceanDrift
        case .twinkle: return .starfield
        case .pulse: return .neonPulse
        case .rainbow, .colorCycle: return .spectrum
        case .party: return .club
        default: return nil
        }
    }

    // MARK: - Targets

    /// Builds the lights a clause is about: unions ("the key and the fill"), intersections
    /// ("the left tubes"), exclusions ("everything except the key") and single lights ("the left tube").
    func buildTarget(_ toks: [LexToken]) -> TargetSpec? {
        var groups: [[TargetWord]] = [[]]
        var exclusionStart: Int?
        var pendingJoin = false
        for tok in toks {
            switch tok.lex {
            case .target(let w):
                if pendingJoin, let last = groups.last, !last.isEmpty { groups.append([]) }
                pendingJoin = false
                groups[groups.count - 1].append(w)
            case .conj:
                if let last = groups.last, !last.isEmpty { pendingJoin = true }
            case .except, .but:
                if case .but = tok.lex, groups.allSatisfy({ $0.isEmpty }) { break }
                if exclusionStart == nil {
                    if let last = groups.last, !last.isEmpty { groups.append([]) }
                    exclusionStart = groups.count - 1
                }
                pendingJoin = false
            case .det, .prep, .word, .punct, .quantity:
                break
            default:
                pendingJoin = false
            }
        }
        let split = min(exclusionStart ?? groups.count, groups.count)
        let baseGroups = groups[..<split].filter { !$0.isEmpty }
        let excludedGroups = groups[split...].filter { !$0.isEmpty }
        let base = Self.combineGroups(Array(baseGroups), inheritedHead: nil)
        if exclusionStart != nil, !excludedGroups.isEmpty {
            let head = base.flatMap(Self.headOf)
            if let excluded = Self.combineGroups(Array(excludedGroups), inheritedHead: head) {
                return .except(base ?? .everything, excluded)
            }
        }
        return base
    }

    static func combineGroups(_ groups: [[TargetWord]], inheritedHead: TargetSpec?) -> TargetSpec? {
        var gs = groups
        // "the left and right tubes": the later head applies to earlier place-only groups.
        var laterHeads: [TargetWord] = []
        for k in stride(from: gs.count - 1, through: 0, by: -1) {
            let heads = gs[k].filter(isHeadWord)
            let placeOnly = gs[k].allSatisfy { if case .area = $0 { return true }; return false }
            if heads.isEmpty, placeOnly, !laterHeads.isEmpty {
                gs[k] += laterHeads
            } else if !heads.isEmpty {
                laterHeads = heads
            }
        }
        let specs = gs.compactMap { groupSpec($0, inheritedHead: inheritedHead) }
        if specs.isEmpty { return nil }
        return specs.count == 1 ? specs[0] : .any(specs)
    }

    static func isHeadWord(_ w: TargetWord) -> Bool {
        switch w {
        case .role, .category: return true
        default: return false
        }
    }

    static func headOf(_ t: TargetSpec) -> TargetSpec? {
        switch t {
        case .role, .category, .name, .label: return t
        case .single(let s): return headOf(s)
        case .all(let items): return items.lazy.compactMap { headOf($0) }.first
        default: return nil
        }
    }

    static func groupSpec(_ words: [TargetWord], inheritedHead: TargetSpec?) -> TargetSpec? {
        var areas: [SpatialArea] = []
        var names: [TargetSpec] = []
        var heads: [TargetSpec] = []
        var specials: [TargetSpec] = []
        var singular = false, generic = false, genericPlural = false, one = false, everything = false
        for w in words {
            switch w {
            case .area(let a): areas.append(a)
            case .label(let l): names.append(.label(l))
            case .name(let n): names.append(.name(n))
            case .role(let r):
                if !heads.contains(.role(r)) { heads.append(.role(r)) }
            case .category(let c, let plural):
                if !heads.contains(.category(c)) { heads.append(.category(c)) }
                if !plural { singular = true }
            case .generic(let plural):
                generic = true
                if plural { genericPlural = true } else { singular = true }
            case .one(let plural):
                one = true
                if !plural { singular = true }
            case .everything: everything = true
            case .rest: specials.append(.rest)
            case .previous: specials.append(.previous)
            case .selection: specials.append(.selection)
            }
        }
        let run = resolveAreaRun(areas)
        let areaSpec: TargetSpec? = run.isEmpty ? nil : (run.count == 1 ? .area(run[0]) : .any(run.map { TargetSpec.area($0) }))
        var parts: [TargetSpec] = []
        if let a = areaSpec { parts.append(a) }
        if !names.isEmpty {
            parts.append(names.count == 1 ? names[0] : .any(names))
        } else if !heads.isEmpty {
            parts.append(contentsOf: heads)
        } else if one, let h = inheritedHead {
            parts.append(h)
        }
        for s in specials where !parts.contains(s) { parts.append(s) }
        if parts.isEmpty {
            if everything || genericPlural { return .everything }
            if one { return .previous }
            if generic { return .unspecified }
            return nil
        }
        let spec: TargetSpec = parts.count == 1 ? parts[0] : .all(parts)
        if singular, areaSpec != nil, names.isEmpty, specials.isEmpty { return .single(spec) }
        return spec
    }

    /// Areas said together: "back left" → back-left; "left, back left, right" said without pauses →
    /// back-left (a self-correction plus an affirmation).
    static func resolveAreaRun(_ areas: [SpatialArea]) -> [SpatialArea] {
        guard !areas.isEmpty else { return [] }
        if let c = SpatialArea.combine(areas) { return [c] }
        if areas.count >= 2, areas.last == .right, let c = SpatialArea.combine(Array(areas.dropLast())) { return [c] }
        for k in 1..<areas.count {
            if let tail = SpatialArea.combine(Array(areas[k...])), let head = SpatialArea.combine(Array(areas[..<k])),
               Set(tail.components).isSuperset(of: head.components) {
                return [tail]
            }
        }
        var seen = Set<SpatialArea>()
        return areas.filter { seen.insert($0).inserted }
    }

    /// True when `new` narrows `old` ("the left" → "the back left"; "the tubes" → "the left tubes").
    static func refines(_ old: TargetSpec?, _ new: TargetSpec) -> Bool {
        guard let old else { return false }
        let oldParts = Set(old.areas.flatMap(\.components))
        let newParts = Set(new.areas.flatMap(\.components))
        if !oldParts.isEmpty, newParts.isStrictSuperset(of: oldParts) { return true }
        let oldHead = headOf(old), newHead = headOf(new)
        if let oh = oldHead, oh == newHead, oldParts.isEmpty, !newParts.isEmpty { return true }
        return false
    }

    // MARK: - Discourse

    struct Outcome {
        var actions: [ParsedAction]
        var isCorrection: Bool
        var fade: Double?
    }

    /// Joins clause readings: self-corrections ("to the left, back left"), affirmations ("…, right."),
    /// continuations ("dim the key, the fill too"), pronouns and targets carried between clauses.
    static func discourse(_ readings: [Reading]) -> Outcome {
        var frames: [Reading] = []
        var pendingNegation = false
        var pendingTarget: TargetSpec?
        var lastTarget: TargetSpec?
        var isCorrection = false
        var sawContent = false
        var sawAck = false
        var fade: Double?

        for (index, original) in readings.enumerated() {
            var r = original
            if let f = r.fade { fade = f }
            switch r.kind {
            case .empty: continue
            case .negationOnly:
                pendingNegation = true
                continue
            case .ack:
                sawAck = true
                continue
            case .loneRight where sawContent:
                continue
            default:
                break
            }
            if pendingNegation {
                r.negated = true
                pendingNegation = false
            }
            let firstContent = !sawContent
            sawContent = true
            let prev = frames.lastIndex(where: { !$0.actions.isEmpty })

            // Pronouns inside one request ("dim the key and warm it up").
            if case .previous? = r.target, let lt = lastTarget {
                r.target = lt
                r.actions = r.actions.map { a in
                    if case .previous? = a.target { return a.retargeted(lt) }
                    return a
                }
            }

            if r.kind == .bareTarget || r.kind == .loneRight, let target = r.target {
                if let p = prev {
                    if r.negated || refines(frames[p].target, target) {
                        frames[p].actions = frames[p].actions.map { $0.target != nil ? $0.retargeted(target) : $0 }
                        frames[p].target = target
                    } else {
                        var copy = frames[p]
                        copy.actions = frames[p].actions.compactMap { $0.target != nil ? $0.retargeted(target) : nil }
                        copy.target = target
                        if !copy.actions.isEmpty { frames.append(copy) }
                    }
                } else if r.negated {
                    r.actions = [.retarget(target)]
                    frames.append(r)
                } else if r.also || r.leadingAnd {
                    r.actions = [.repeatOn(target)]
                    frames.append(r)
                } else {
                    pendingTarget = target
                }
                lastTarget = target
                continue
            }

            if r.negated {
                if r.kind == .colorsOnly {
                    if let p = prev {
                        frames[p].actions = frames[p].actions.map { recolored($0, r.colors) }
                    } else {
                        r.actions = [.recolor(r.colors)]
                        frames.append(r)
                    }
                    continue
                }
                if let p = prev, !firstContent {
                    if r.target == nil, let t = frames[p].target {
                        r.actions = r.actions.map { a in
                            if case .unspecified? = a.target { return a.retargeted(t) }
                            return a
                        }
                        r.target = t
                    }
                    frames[p] = r
                    if let t = r.target { lastTarget = t }
                    continue
                }
                if firstContent, r.actions.contains(where: isFreshChange) { isCorrection = true }
            }

            // Clauses without lights borrow them ("the key, a bit brighter"; "dim and warm the key").
            if r.target == nil, r.actions.contains(where: { $0.target != nil }) {
                var inherited = pendingTarget ?? lastTarget
                if inherited == nil, index + 1 < readings.count {
                    inherited = readings[(index + 1)...].first(where: { $0.segment == r.segment && $0.target != nil })?.target
                }
                if let t = inherited {
                    r.actions = r.actions.map { a in
                        if case .unspecified? = a.target { return a.retargeted(t) }
                        return a
                    }
                    r.target = t
                }
            }
            pendingTarget = nil
            if let t = r.target { lastTarget = t }
            frames.append(r)
        }

        var actions = frames.flatMap(\.actions)
        if let t = pendingTarget { actions.append(.clarifyTarget(t)) }
        if actions.isEmpty {
            if pendingNegation {
                actions = [.undo]
            } else if sawAck {
                actions = [.acknowledge]
            }
        }
        return Outcome(actions: actions, isCorrection: isCorrection, fade: fade)
    }

    /// Changes that stand on their own (not follow-ups like "more" or "the other side").
    static func isFreshChange(_ a: ParsedAction) -> Bool {
        switch a {
        case .undo, .redo, .more, .less, .otherSide, .retarget, .recolor, .repeatOn, .acknowledge, .clarifyTarget, .query:
            return false
        default:
            return true
        }
    }

    static func recolored(_ a: ParsedAction, _ colors: [ColorSpec]) -> ParsedAction {
        guard let first = colors.first else { return a }
        switch a {
        case .setColor(let t, _): return .setColor(t, colors)
        case .shiftColor(let t, _, let amount): return .shiftColor(t, toward: first, amount: amount)
        case .reduceColor(let t, _, let amount): return .reduceColor(t, first, amount: amount)
        case .gradient(let t, _): return colors.count >= 2 ? .gradient(t, colors) : .setColor(t, colors)
        default: return a
        }
    }

    // MARK: - Scenes

    /// Two or more single-colour, place-based requests become one scene ("teal on the left, blue on
    /// the right, pink above"). A summary said first ("a blue and teal background") is dropped when
    /// the zones repeat its colours.
    static func mergeScenes(_ actions: [ParsedAction]) -> [ParsedAction] {
        var zones: [SceneZone] = []
        var firstIndex: Int?
        for (i, a) in actions.enumerated() {
            if case .setColor(let t, let colors) = a, colors.count == 1, t.isSpatial {
                zones.append(SceneZone(target: t, color: colors[0]))
                if firstIndex == nil { firstIndex = i }
            }
        }
        guard zones.count >= 2, let first = firstIndex else { return actions }
        let zoneColors = Set(zones.map { $0.color.name })
        var out: [ParsedAction] = []
        for (i, a) in actions.enumerated() {
            if i == first { out.append(.scene(zones)) }
            if case .setColor(let t, let colors) = a {
                if colors.count == 1, t.isSpatial { continue }
                if isSceneSummary(t), colors.allSatisfy({ zoneColors.contains($0.name) }) { continue }
            }
            out.append(a)
        }
        return out
    }

    static func isSceneSummary(_ t: TargetSpec) -> Bool {
        switch t {
        case .unspecified, .everything, .role(.background), .category: return true
        default: return false
        }
    }
}

// MARK: - Lexeme classification

extension Lexeme {
    /// Words that carry no meaning on their own ("the", "please", "to").
    var isFiller: Bool {
        switch self {
        case .det, .word, .prep, .punct: return true
        default: return false
        }
    }

    var isTarget: Bool {
        if case .target = self { return true }
        return false
    }

    /// Places and named lights — not pronouns or bare nouns ("it", "light").
    var isStrongTarget: Bool {
        guard case .target(let w) = self else { return false }
        switch w {
        case .area, .role, .category, .label, .name, .everything, .rest: return true
        case .previous, .selection, .generic, .one: return false
        }
    }

    var isPlainColor: Bool {
        if case .color = self { return true }
        return false
    }

    var isColor: Bool {
        switch self {
        case .color, .colorComparative: return true
        default: return false
        }
    }

    var isJoiner: Bool {
        switch self {
        case .conj, .but: return true
        default: return false
        }
    }

    var isExcept: Bool {
        if case .except = self { return true }
        return false
    }

    /// A word that makes a clause a complete instruction ("dim", "up", "blue", "50%").
    var isValue: Bool {
        switch self {
        case .verb(let v): return v != .turn && v != .bring && v != .set
        case .particle, .comparative, .colorComparative, .color, .number, .level, .more, .less, .control,
             .effect, .effectOrColor, .flicker, .effectWord, .music, .mood, .adjective:
            return true
        default:
            return false
        }
    }
}
