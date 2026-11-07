import Foundation

/// What a request changes.
public enum AssistantAttribute: String, Codable, Sendable, CaseIterable {
    case intensity, warmth, tint, saturation, color
}

enum AssistantVerb: String, Sendable {
    case brighten, dim, bring, turn, set, warm, cool, add, remove, recall, save, stop, start, identify, swap, saturate, desaturate, kill, lower
}

enum AssistantParticle: String, Sendable { case up, down, on, off }

enum AssistantUnit: String, Sendable { case percent, kelvin, stops, seconds, minutes }

enum AssistantPrep: String, Sendable { case to, by, over, within, from, with, at, on, of, toward, like, as, called, for_ }

enum AssistantControl: Hashable, Sendable {
    case undo, redo, help, whatsOn, blackout, lightsOn, freeze, unfreeze, recording, recordingOff, acknowledge, otherSide, tooMuch, again, same
}

/// A word or phrase that names lights.
enum TargetWord: Hashable, Sendable {
    case everything, rest, previous, selection
    case generic(plural: Bool)
    case one(plural: Bool)
    case role(FixtureRole)
    case category(FixtureCategory, plural: Bool)
    case area(SpatialArea)
    case label(String)
    case name(String)
}

/// Word classes recognized by the rule parser.
enum Lexeme: Hashable, Sendable {
    case verb(AssistantVerb)
    case particle(AssistantParticle)
    case comparative(AssistantAttribute, Int)
    case adjective(AssistantAttribute, Int)
    case quantity(NudgeAmount)
    case more, less, too
    case attribute(AssistantAttribute)
    case color(ColorSpec)
    case colorComparative(ColorSpec)
    case effectOrColor(EffectKind, ColorSpec)
    case number(Double)
    case unit(AssistantUnit)
    case level(Double)
    case target(TargetWord)
    case conj, then, except, but
    case negation
    case control(AssistantControl)
    case look
    case effect(EffectKind)
    case effectWord
    case flicker
    case music
    case mood(MusicMood)
    case fade(Double)
    case gradientWord
    case question(String)
    case prep(AssistantPrep)
    case det(String)
    case punct(String)
    case word(String)
}

/// A lexeme with the words it came from.
struct LexToken: Hashable, Sendable {
    var lex: Lexeme
    var text: String
}

/// Names from the user's rig (fixtures, groups, looks) so "the round light", "floor tubes" and
/// "B3" are understood, and so typo correction knows the rig's words.
public struct RigVocabulary: Hashable, Sendable {
    /// Normalized multi-word phrase → display name (fixture and group names).
    public var namePhrases: [String: String]
    /// Normalized short label ("b3") → display label ("B3").
    public var labels: [String: String]
    /// Look names.
    public var looks: [String]
    /// Every word in names and labels (for typo correction).
    public var words: Set<String>

    public init(fixtureNames: [String] = [], shortNames: [String] = [], groupNames: [String] = [], lookNames: [String] = []) {
        var phrases: [String: String] = [:]
        var words = Set<String>()
        for name in fixtureNames + groupNames {
            let norm = SelectorResolver.normalize(name)
            guard !norm.isEmpty else { continue }
            let parts = norm.split(separator: " ").map(String.init)
            parts.filter { $0.count >= 3 }.forEach { words.insert($0) }
            // Single generic words ("Key", "Background") stay with the built-in meaning.
            if parts.count == 1 && AssistantLexicon.table[norm] != nil { continue }
            phrases[norm] = name
        }
        var labels: [String: String] = [:]
        for s in shortNames {
            let norm = SelectorResolver.normalize(s).replacingOccurrences(of: " ", with: "")
            guard !norm.isEmpty else { continue }
            labels[norm] = s
        }
        for look in lookNames {
            SelectorResolver.normalize(look).split(separator: " ").filter { $0.count >= 4 }.forEach { words.insert(String($0)) }
        }
        self.namePhrases = phrases
        self.labels = labels
        self.looks = lookNames
        self.words = words
    }

    /// Vocabulary for a project.
    public init(project: Project) {
        self.init(fixtureNames: project.fixtures.map(\.name), shortNames: project.fixtures.map(\.shortName),
                  groupNames: project.groups.map(\.name), lookNames: project.looks.map(\.name))
    }

    public static let empty = RigVocabulary()

    /// Longest phrase length in words.
    var maxPhraseWords: Int {
        namePhrases.keys.map { $0.split(separator: " ").count }.max() ?? 0
    }

    /// The look whose name best matches `phrase` (word overlap), if the match is convincing.
    public func bestLook(for phrase: String, minimumScore: Double = 0.6) -> (name: String, score: Double)? {
        let q = Set(SelectorResolver.normalize(phrase).split(separator: " ").map(String.init).filter { !RigVocabulary.lookNoise.contains($0) })
        guard !q.isEmpty else { return nil }
        var best: (String, Double)?
        for look in looks {
            let words = Set(SelectorResolver.normalize(look).split(separator: " ").map(String.init).filter { !RigVocabulary.lookNoise.contains($0) })
            guard !words.isEmpty else { continue }
            let inter = Double(q.intersection(words).count)
            guard inter > 0 else { continue }
            // Reward covering the look's name; tolerate extra words in the request a little.
            let score = inter / Double(words.count) * 0.75 + inter / Double(q.count) * 0.25
            if score > (best?.1 ?? 0) { best = (look, score) }
        }
        guard let b = best, b.1 >= minimumScore else { return nil }
        return (b.0, b.1)
    }

    static let lookNoise: Set<String> = ["the", "a", "an", "look", "scene", "preset", "setup", "my", "our", "one", "please", "to", "that", "this", "again", "back", "on"]
}

/// The built-in word list of the rule parser.
enum AssistantLexicon {
    /// Phrase (normalized tokens joined by spaces) → lexeme.
    static let table: [String: Lexeme] = build()

    /// Longest phrase in words.
    static let maxPhraseWords = 5

    /// Common words that are never typo-corrected into lighting words.
    static let stopWords: Set<String> = [
        "i", "me", "my", "we", "us", "our", "you", "your", "it", "its", "is", "am", "are", "was", "be", "been",
        "a", "an", "the", "this", "that", "these", "those", "and", "or", "but", "so", "to", "of", "in", "on", "at",
        "for", "with", "from", "by", "as", "like", "please", "could", "would", "should", "can", "will", "just",
        "maybe", "kindly", "let", "want", "need", "really", "actually", "think", "feel", "real", "realy", "well",
        "very", "quite", "pretty", "kind", "sort", "thing", "things", "stuff", "here", "there", "where", "what",
        "when", "which", "how", "who", "why", "now", "then", "than", "them", "they", "their", "have", "has", "had",
        "do", "does", "did", "done", "get", "got", "going", "come", "know", "see", "look", "looks", "looking",
        "said", "say", "tell", "told", "make", "made", "same", "other", "another", "some", "any", "every", "each",
        "into", "onto", "about", "around", "over", "under", "again", "still", "also", "too", "okay", "yeah", "yes",
        "nope", "sure", "fine", "good", "great", "nice", "thanks", "thank", "cheers", "hello", "hey", "while",
        "keep", "leave", "stay", "hold", "time", "times", "camera", "shot", "frame", "face", "person", "people",
        "head", "room", "studio", "today", "tonight", "video", "recording", "record", "stream", "live", "call",
        "meeting", "want", "wanted", "wants", "mean", "meant", "sorry", "wait", "were", "being", "seems", "seem",
        "though", "touching", "touch", "touched", "don", "doesn", "isn", "app", "sound", "sounds", "words", "word"
    ]

    // swiftlint:disable:next function_body_length
    private static func build() -> [String: Lexeme] {
        var t: [String: Lexeme] = [:]
        func add(_ words: [String], _ lex: Lexeme) { for w in words { t[w] = lex } }

        // Verbs.
        add(["brighten", "raise", "increase", "boost", "lift", "crank", "pump", "bump", "intensify", "amp"], .verb(.brighten))
        add(["dim", "darken", "reduce", "decrease", "drop", "soften", "lessen", "tone"], .verb(.dim))
        add(["lower"], .verb(.lower))
        add(["bring", "put", "push", "pull", "take", "knock", "dial", "nudge", "move", "shift", "slide", "fade"], .verb(.bring))
        add(["turn", "switch", "flip on", "power"], .verb(.turn))
        add(["set", "make", "change", "paint", "go", "give", "want", "need", "would like", "like to have", "do"], .verb(.set))
        add(["warm", "warm it", "heat"], .verb(.warm))
        add(["cool", "chill down"], .verb(.cool))
        add(["add", "throw in", "mix in", "bring in"], .verb(.add))
        add(["remove", "take out", "get rid of"], .verb(.remove))
        add(["recall", "load", "apply", "activate", "go to", "switch to", "change to", "show",
             "play", "use", "put on", "open", "back to", "go back to"], .verb(.recall))
        add(["save", "store", "remember", "save as", "call this", "name this", "keep this"], .verb(.save))
        add(["stop", "end", "halt", "disable", "pause", "no more", "quit"], .verb(.stop))
        add(["kill", "shut", "shut off", "kill off"], .verb(.kill))
        add(["start", "begin", "run", "enable", "react", "react to", "sync", "sync to", "sync with", "dance", "dance to",
             "groove", "follow", "listen to", "move with", "pulse to", "respond to"], .verb(.start))
        add(["identify", "flash", "blink", "which one is", "which light is", "which is", "where is", "where are", "find",
             "locate", "highlight", "point out", "show me", "ping", "wiggle"], .verb(.identify))
        add(["swap", "flip", "mirror", "switch sides", "swap sides", "invert", "reverse", "exchange", "switch around",
             "swap around", "other way round", "other way around", "the other way round", "the other way around"], .verb(.swap))
        add(["saturate", "intensify the color", "intensify the colors"], .verb(.saturate))
        add(["desaturate", "wash out"], .verb(.desaturate))

        // Particles.
        add(["up"], .particle(.up))
        add(["down"], .particle(.down))
        add(["on", "back on", "on again", "fade in"], .particle(.on))
        add(["off", "fade out", "back off again"], .particle(.off))

        // Comparatives.
        add(["brighter", "lighter", "stronger", "higher", "louder", "punchier", "more light", "more intense"], .comparative(.intensity, 1))
        add(["dimmer", "darker", "softer", "weaker", "subtler", "gentler", "quieter", "less light", "less intense", "moodier"], .comparative(.intensity, -1))
        add(["warmer", "cozier", "cosier", "toastier", "more amber", "more tungsten", "more golden"], .comparative(.warmth, 1))
        add(["cooler", "colder", "crisper", "icier", "more daylight"], .comparative(.warmth, -1))
        add(["richer", "bolder", "more saturated", "more vivid", "more vibrant", "more colorful", "more colourful", "deeper", "juicier"], .comparative(.saturation, 1))
        add(["paler", "duller", "less saturated", "more pastel", "more muted", "less vivid", "less colorful", "washed out", "more subtle"], .comparative(.saturation, -1))

        // Adjectives (used after "too").
        add(["bright", "intense", "strong", "hot", "harsh", "loud"], .adjective(.intensity, 1))
        add(["dark", "dull", "weak", "gloomy", "moody"], .adjective(.intensity, -1))
                add(["cold", "icy", "clinical", "sterile"], .adjective(.warmth, -1))
        add(["saturated", "vivid", "garish", "colorful", "colourful", "vibrant"], .adjective(.saturation, 1))
        add(["pale", "washed", "muted", "flat"], .adjective(.saturation, -1))

        // Quantities.
        add(["a little", "a little bit", "a tiny bit", "a teeny bit", "tiny bit", "little bit", "a touch", "a tad", "tad",
             "slightly", "a smidge", "smidge", "a wee bit", "wee bit", "subtly", "gently", "barely", "a hint", "a hint of",
             "a little touch", "a tiny touch", "just a touch", "a fraction", "little"], .quantity(.aLittle))
        add(["a bit", "bit", "some", "somewhat", "a notch", "notch", "one notch", "a step", "moderately", "a few"], .quantity(.aBit))
        add(["a lot", "lots", "loads", "way", "much", "heaps", "a ton", "tons", "a bunch", "significantly", "really",
             "super", "very", "seriously", "massively", "drastically", "dramatically", "quite a bit", "a good bit",
             "a fair bit", "plenty", "a great deal", "hugely", "considerably", "substantially", "way way"], .quantity(.aLot))

        add(["more", "extra", "even more", "further"], .more)
        add(["less", "fewer", "not as", "not so"], .less)
        add(["too"], .too)

        // Attributes.
        add(["brightness", "intensity", "level", "levels", "output", "dimmer level", "power", "exposure"], .attribute(.intensity))
        add(["warmth", "temperature", "color temperature", "colour temperature", "cct", "white balance", "kelvin value"], .attribute(.warmth))
        add(["saturation", "vibrance", "vibrancy", "color intensity", "richness"], .attribute(.saturation))
        add(["tint", "green magenta", "gm", "plus green", "minus green"], .attribute(.tint))
        add(["color", "colors", "hue", "shade"], .attribute(.color))

        // Units.
        add(["percent", "per cent", "pc", "pct"], .unit(.percent))
        add(["k", "kelvin", "kelvins", "degrees kelvin"], .unit(.kelvin))
        add(["stop", "stops", "f stop", "f stops"], .unit(.stops))
        add(["second", "seconds", "sec", "secs", "s"], .unit(.seconds))
        add(["minute", "minutes", "mins"], .unit(.minutes))

        // Levels.
        add(["full", "max", "maximum", "full blast", "full power", "full brightness", "all the way up", "flat out",
             "a hundred percent", "one hundred percent", "fully"], .level(1))
        add(["half", "halfway", "half way", "half brightness", "fifty fifty"], .level(0.5))
        add(["quarter", "a quarter", "quarter brightness"], .level(0.25))
        add(["three quarters"], .level(0.75))
        add(["minimum", "lowest", "barely on", "a glimmer", "all the way down"], .level(0.02))

        // Targets: roles.
        add(["key", "keys", "key light", "key lights", "keylight", "main light", "the main light", "key panel light"], .target(.role(.key)))
        add(["fill", "fills", "fill light", "fill lights", "filler light"], .target(.role(.fill)))
        add(["backlight", "backlights", "back light", "back lights", "rim", "rim light", "rim lights", "edge light", "edge lights", "separation light"], .target(.role(.back)))
        add(["hair", "hair light", "hair lights", "hairlight"], .target(.role(.hair)))
        add(["kicker", "kickers", "kick light", "kicker light"], .target(.role(.kicker)))
        add(["background", "backgrounds", "backdrop", "bg", "background lights", "background light", "set lights", "the set", "backdrop lights"], .target(.role(.background)))
        add(["accent", "accents", "accent light", "accent lights"], .target(.role(.accent)))
        add(["practical", "practicals", "practical light", "practical lights"], .target(.role(.practical)))
        add(["ambient", "ambient light", "ambient lights", "room light", "room lights", "house lights"], .target(.role(.ambient)))

        // Targets: types.
        add(["tube", "stick", "baton", "saber", "sabre", "pixel tube", "tube light", "light saber", "pavotube", "pixel bar"], .target(.category(.tube, plural: false)))
        add(["tubes", "sticks", "batons", "sabers", "sabres", "pixel tubes", "tube lights", "light sabers", "pavotubes", "pixel bars"], .target(.category(.tube, plural: true)))
        add(["panel", "softbox", "light panel", "led panel", "soft box"], .target(.category(.panel, plural: false)))
        add(["panels", "softboxes", "light panels", "led panels"], .target(.category(.panel, plural: true)))
        add(["spot", "spotlight", "cob", "monolight"], .target(.category(.spot, plural: false)))
        add(["spots", "spotlights", "cobs", "monolights"], .target(.category(.spot, plural: true)))
        add(["fresnel"], .target(.category(.fresnel, plural: false)))
        add(["fresnels"], .target(.category(.fresnel, plural: true)))
        add(["par", "par can"], .target(.category(.par, plural: false)))
        add(["pars", "par cans", "cans"], .target(.category(.par, plural: true)))
        add(["bulb", "lamp", "light bulb"], .target(.category(.bulb, plural: false)))
        add(["bulbs", "lamps", "light bulbs"], .target(.category(.bulb, plural: true)))
        add(["strip", "led strip", "light strip", "tape"], .target(.category(.strip, plural: false)))
        add(["strips", "led strips", "light strips"], .target(.category(.strip, plural: true)))
        add(["bar", "batten", "light bar", "led bar"], .target(.category(.bar, plural: false)))
        add(["bars", "battens", "light bars", "led bars"], .target(.category(.bar, plural: true)))
        add(["wash"], .target(.category(.wash, plural: false)))
        add(["washes"], .target(.category(.wash, plural: true)))
        add(["moving head", "mover"], .target(.category(.movingHead, plural: false)))
        add(["moving heads", "movers"], .target(.category(.movingHead, plural: true)))

        // Targets: generic and quantifiers.
        add(["light", "fixture", "unit", "led", "lamp head"], .target(.generic(plural: false)))
        add(["lights", "fixtures", "units", "leds", "lighting"], .target(.generic(plural: true)))
        add(["one"], .target(.one(plural: false)))
        add(["ones"], .target(.one(plural: true)))
        add(["everything", "all", "all lights", "all the lights", "every light", "whole room", "the whole room", "whole thing",
             "the whole thing", "the room", "all of them", "all of it", "the lot", "whole studio", "the whole studio",
             "the studio", "whole set", "the whole set", "every single light", "entire room", "the entire room"], .target(.everything))
        add(["the rest", "rest", "everything else", "the others", "others", "other lights", "the other lights", "remaining",
             "the remaining lights", "all the others", "all the rest", "the remaining", "all the other lights"], .target(.rest))
        add(["it", "them", "they", "those", "that", "those lights", "those ones", "same lights", "the same lights", "that light",
             "that one", "those two"], .target(.previous))
        add(["these", "this", "this light", "this one", "these lights", "these ones", "selected", "the selected lights",
             "selected lights", "selection", "the selection", "what i selected", "highlighted", "the highlighted lights"], .target(.selection))

        // Targets: spatial.
        for (w, a) in SpatialVocabulary.words { t[w] = .target(.area(a)) }
        for (p, a) in SpatialVocabulary.phrases { t[p] = .target(.area(a)) }
        add(["side", "sides", "side lights"], .target(.area(.sides)))
        add(["behind me", "behind the subject", "behind them", "back wall"], .target(.area(.back)))
        add(["above me", "above the subject", "over me", "over my head", "above my head"], .target(.area(.top)))
        add(["to my left", "on my left"], .target(.area(.left)))
        add(["to my right", "on my right"], .target(.area(.right)))

        // Conjunctions.
        add(["and", "also", "plus", "as well as", "along with", "together with", "n"], .conj)
        add(["then", "and then", "after that", "afterwards", "next", "followed by", "finally", "and after that"], .then)
        add(["except", "except for", "but not", "apart from", "other than", "excluding", "besides", "aside from", "minus",
             "save for", "without", "not including", "leave out", "leaving out", "but leave", "but keep", "not the"], .except)
        add(["but"], .but)

        // Corrections.
        add(["no", "nope", "nah", "not that", "wrong", "actually", "i meant", "i mean", "sorry", "oops", "wait", "instead",
             "rather", "not quite", "my bad", "no no", "correction"], .negation)

        // Controls.
        add(["undo", "undo that", "undo it", "go back", "revert", "revert that", "never mind", "nevermind", "cancel",
             "cancel that", "scratch that", "forget it", "forget that", "put it back", "put that back", "change it back",
             "set it back", "turn it back", "bring it back", "take it back", "back to how it was", "as you were",
             "reset that", "undo the last thing", "undo last", "go back to how it was", "like it was", "how it was",
             "revert it", "put them back", "change them back", "back the way it was", "the way it was"], .control(.undo))
        add(["redo", "redo that", "redo it"], .control(.redo))
        add(["help", "what can you do", "what can i say", "what do you do", "how does this work", "examples",
             "show me examples", "commands", "what commands", "give me examples", "what can i ask"], .control(.help))
        add(["what is on", "what is happening", "what is going on", "what is playing", "status", "what is the status",
             "what is active", "what is running", "what look is this", "what look is on", "which look is this",
             "what are the lights doing", "what is lit", "what is the current look", "what is up"], .control(.whatsOn))
        add(["blackout", "black out", "lights out", "go dark", "kill the lights", "kill all the lights", "kill everything",
             "all dark", "everything dark", "total darkness", "go black", "cut to black", "fade to black"], .control(.blackout))
        add(["release blackout", "unblackout", "un blackout", "restore", "restore the lights",
             "end blackout", "no more blackout", "end the blackout"], .control(.lightsOn))
        add(["freeze", "freeze the lights", "freeze everything", "hold the lights", "freeze frame"], .control(.freeze))
        add(["unfreeze", "un freeze", "release", "release the lights", "resume", "unfreeze the lights", "let go"], .control(.unfreeze))
        add(["recording mode", "record mode", "we are recording", "i am recording", "going live", "we are going live",
             "we are live", "i am live", "on air", "we are rolling"], .control(.recording))
        add(["recording mode off", "stop recording", "done recording", "finished recording", "we are done recording",
             "end recording", "off air", "stop recording mode", "exit recording mode", "leave recording mode",
             "we are done", "that is a wrap"], .control(.recordingOff))
        add(["thanks", "thank you", "cheers", "perfect", "great", "nice", "awesome", "lovely", "good", "that is good",
             "that is great", "that is perfect", "looks good", "looks great", "brilliant", "excellent", "yes", "yeah",
             "yep", "yup", "sure", "okay", "fine", "that will do", "that is right", "exactly", "that is it", "that is better", "much better",
             "better", "amazing", "beautiful", "gorgeous", "sweet", "cool thanks", "nice one", "good job", "well done"], .control(.acknowledge))
        add(["the other side", "other side", "opposite side", "the opposite side", "wrong side", "the wrong side",
             "other one", "the other one", "opposite", "the opposite"], .control(.otherSide))
        add(["too much", "too far", "overdone", "too strong", "tone it down", "tone that down", "back off", "back it off",
             "ease off", "ease up", "ease it off", "not so much", "not that much", "less of that", "dial it back",
             "pull it back", "bring it back a bit", "overkill"], .control(.tooMuch))
        add(["again", "keep going", "same again", "once more", "one more time", "do that again", "do it again", "more more",
             "another bit", "a bit further", "go on", "carry on", "continue"], .control(.again))
        add(["same for", "same on", "same with", "same to", "do the same for", "do the same to", "do the same with",
             "the same for", "same thing for", "same thing on", "same goes for", "as well", "the same"], .control(.same))

        // Looks.
        add(["look", "scene", "scenes", "preset", "presets", "setup", "set up", "cue", "snapshot", "looks"], .look)

        // Effects.
        add(["candle", "candles", "candlelight", "candle light"], .effectOrColor(.candle, ColorSpec(name: "candlelight", color: .kelvin(1900, tint: 0))))
        add(["sunset", "sunrise"], .effectOrColor(.sunset, ColorSpec(name: "sunset", color: .kelvin(2000, tint: 0))))
        add(["flicker", "flickering", "flickery", "flickers", "flick"], .flicker)
        add(["fire", "fireplace", "flames", "flame", "campfire", "bonfire", "fire light", "firelight"], .effect(.fire))
        add(["lightning", "thunder", "thunderstorm", "storm", "lightning storm"], .effect(.lightning))
        add(["tv", "television", "telly", "tv flicker", "tv screen"], .effect(.tv))
        add(["police", "cop", "cops", "siren", "sirens", "police lights", "cop car", "emergency lights"], .effect(.police))
        add(["strobe", "strobing", "strobe light"], .effect(.strobe))
        add(["breathe", "breathing", "breath", "slow pulse"], .effect(.breathe))
        add(["pulse", "pulsing", "pulsate", "pulsating", "throb"], .effect(.pulse))
        add(["rainbow", "rainbows", "unicorn"], .effect(.rainbow))
        add(["color cycle", "colour cycle", "cycle colors", "cycle the colors", "cycle through colors", "cycling colors", "cycle"], .effect(.colorCycle))
        add(["wave", "waves", "wavy"], .effect(.wave))
        add(["gradient sweep", "sweep", "sweeping"], .effect(.gradientSweep))
        add(["aurora", "northern lights", "aurora borealis"], .effect(.aurora))
        add(["ocean", "sea", "underwater", "water", "ocean waves"], .effect(.ocean))
        add(["lava", "lava lamp"], .effect(.lava))
        add(["twinkle", "twinkling", "stars", "starry", "starlight"], .effect(.twinkle))
        add(["comet", "shooting star", "comets"], .effect(.comet))
        add(["chase", "chaser", "chasing", "running lights"], .effect(.chase))
        add(["scanner", "knight rider", "kitt", "larson"], .effect(.scanner))
        add(["sparkle", "sparkles", "sparkling", "glitter", "glittering"], .effect(.sparkle))
        add(["fireworks", "firework"], .effect(.fireworks))
        add(["paparazzi", "camera flashes", "photographers", "press flashes"], .effect(.paparazzi))
        add(["faulty bulb", "broken bulb", "faulty", "broken light", "dying bulb", "horror", "haunted", "spooky"], .effect(.faultyBulb))
        add(["explosion", "explode", "boom", "blast"], .effect(.explosion))
        add(["welding", "welder", "arc welder", "arc welding"], .effect(.welding))
        add(["party", "disco", "rave", "party mode", "disco mode"], .effect(.party))
        add(["effect", "effects", "animation", "animations", "animate", "fx", "movement", "motion"], .effectWord)

        // Music.
        add(["music", "music mode", "the music", "beat", "the beat", "beats", "song", "songs", "audio", "rhythm",
             "tempo", "bpm", "sound to light", "sound reactive", "audio reactive", "the song", "tunes", "track"], .music)
        add(["neon pulse"], .mood(.neonPulse))
        add(["ocean drift"], .mood(.oceanDrift))
        add(["synthwave", "synth wave", "retro", "80s", "eighties", "outrun"], .mood(.synthwave))
        add(["spectrum", "full spectrum"], .mood(.spectrum))
        add(["cinematic", "movie", "film", "filmic"], .mood(.cinematic))
        add(["club", "clubby", "nightclub", "night club", "energetic", "hype", "banger"], .mood(.club))
        add(["chill", "chilled", "chill out", "relaxed", "relaxing", "calm", "mellow", "lofi", "lo fi", "laid back"], .mood(.chill))
        add(["starfield", "star field"], .mood(.starfield))
        add(["heartbeat", "heart beat"], .mood(.heartbeat))
        add(["prism bloom", "bloom"], .mood(.prismBloom))

        // Fades.
        add(["slowly", "slow", "gradually", "slow fade", "nice and slow"], .fade(4))
        add(["really slowly", "very slowly", "super slowly", "really slow", "very slow"], .fade(10))
        add(["smoothly", "smooth", "softly"], .fade(1.5))
        add(["quickly", "quick", "fast", "rapidly", "fast fade"], .fade(0.4))
        add(["instantly", "immediately", "snap", "right away", "right now", "suddenly", "straight away", "no fade", "at once"], .fade(0))

        // Gradients.
        add(["gradient", "ombre", "blend", "blended", "fading from", "transition from", "going from"], .gradientWord)

        // Questions.
        add(["what", "how", "which", "is", "are", "does", "do you know"], .question("what"))
        t["how bright"] = .question("how")
        t["what color"] = .question("what")
        t["what colour"] = .question("what")

        // Prepositions.
        add(["to", "into"], .prep(.to))
        add(["by"], .prep(.by))
        add(["over", "across"], .prep(.over))
        add(["in", "within"], .prep(.within))
        add(["from"], .prep(.from))
        add(["with"], .prep(.with))
        add(["at"], .prep(.at))
        add(["of"], .prep(.of))
        add(["toward", "towards"], .prep(.toward))
        add(["like", "look like", "looks like", "feel like", "feels like", "similar to", "kind of like", "sort of like"], .prep(.like))
        add(["as"], .prep(.as))
        add(["called", "named"], .prep(.called))
        add(["for"], .prep(.for_))

        // Determiners.
        add(["the", "a", "an", "my", "our", "your", "these two"], .det("the"))
        return t
    }

    /// Single words known to the lexicon (plus colours) — the typo-correction dictionary.
    static let vocabulary: Set<String> = {
        var words = Set<String>()
        for key in table.keys {
            for w in key.split(separator: " ") where w.count >= 3 { words.insert(String(w)) }
        }
        words.formUnion(AssistantColors.vocabulary)
        words.formUnion(stopWords)
        words.formUnion(AssistantText.unitWords.keys)
        words.formUnion(AssistantText.tensWords.keys)
        words.formUnion(["hundred", "thousand", "one", "prism", "light", "app", "lights", "kelvin", "percent"])
        return words
    }()

    /// Speech-recognition and typing slips mapped to what was meant.
    static let aliases: [String: [String]] = [
        "phil": ["fill"], "fil": ["fill"], "fils": ["fills"], "lite": ["light"], "lites": ["lights"], "brite": ["bright"],
        "brighter": ["brighter"], "keylite": ["key", "light"], "tubelight": ["tube", "light"], "tubelights": ["tube", "lights"],
        "backlit": ["backlight"], "bkg": ["background"], "bgd": ["background"], "pls": ["please"], "abit": ["a", "bit"],
        "alot": ["a", "lot"], "alittle": ["a", "little"], "litle": ["little"], "lil": ["little"], "warmup": ["warm", "up"],
        "cooldown": ["cool", "down"], "turnup": ["turn", "up"], "turndown": ["turn", "down"], "blueish": ["bluish"],
        "lefthand": ["left"], "righthand": ["right"], "teel": ["teal"], "teale": ["teal"], "pinc": ["pink"]
    ]
}

/// Converts normalized tokens into lexemes, preferring the longest phrase (rig names, colours,
/// built-in phrases) at each position.
struct AssistantLexer {
    var vocabulary: RigVocabulary

    func lex(_ tokens: [String]) -> [LexToken] {
        var out: [LexToken] = []
        var i = 0
        let rigMax = vocabulary.maxPhraseWords
        while i < tokens.count {
            let tok = tokens[i]
            if AssistantText.clausePunctuation.contains(tok) {
                out.append(LexToken(lex: .punct(tok), text: tok)); i += 1; continue
            }
            if tok == "one", isUnitWord(at: i + 1, in: tokens) {
                out.append(LexToken(lex: .number(1), text: tok)); i += 1; continue
            }
            // Labels: "b3", "pn1", or split "b 3" / "pn one".
            if let label = vocabulary.labels[tok] {
                out.append(LexToken(lex: .target(.label(label)), text: tok)); i += 1; continue
            }
            if tok.count <= 3, tok.allSatisfy({ $0.isLetter }), i + 1 < tokens.count,
               let n = AssistantText.number(in: tokens, at: i + 1, allowOne: true), n.consumed == 1,
               n.value == n.value.rounded(), n.value >= 0, n.value < 1000,
               let label = vocabulary.labels[tok + String(Int(n.value))] {
                out.append(LexToken(lex: .target(.label(label)), text: "\(tok) \(tokens[i + 1])")); i += 2; continue
            }
            // Rig names.
            var matched = false
            if rigMax > 0 {
                for len in stride(from: min(rigMax, tokens.count - i), through: 1, by: -1) {
                    let phrase = tokens[i..<(i + len)].joined(separator: " ")
                    if let name = vocabulary.namePhrases[phrase] {
                        // Prefer a longer built-in phrase starting here (e.g. "back tubes" vs rig "back").
                        out.append(LexToken(lex: .target(.name(name)), text: phrase))
                        i += len; matched = true
                        break
                    }
                }
            }
            if matched { continue }
            // Built-in phrases vs colour phrases: the longest wins (colours on ties of length ≥ 2).
            var best: (lex: Lexeme, len: Int)?
            for len in stride(from: min(AssistantLexicon.maxPhraseWords, tokens.count - i), through: 1, by: -1) {
                let phrase = tokens[i..<(i + len)].joined(separator: " ")
                if let lex = AssistantLexicon.table[phrase] { best = (lex, len); break }
            }
            if let c = AssistantColors.match(in: tokens, at: i), c.consumed >= (best?.len ?? 0),
               !(c.consumed == 1 && best != nil && isEffectOrControl(best?.lex)) {
                out.append(LexToken(lex: .color(c.spec), text: tokens[i..<(i + c.consumed)].joined(separator: " ")))
                i += c.consumed
                continue
            }
            if let b = best {
                out.append(LexToken(lex: b.lex, text: tokens[i..<(i + b.len)].joined(separator: " ")))
                i += b.len
                continue
            }
            // Comparative colours: "bluer", "pinker", "redder", "greener".
            if let comp = colorComparative(tok) {
                out.append(LexToken(lex: .colorComparative(comp), text: tok)); i += 1; continue
            }
            // Numbers with glued units: "3200k", "5s", "50pc".
            if let glued = gluedNumber(tok) {
                out.append(LexToken(lex: .number(glued.0), text: tok))
                if let u = glued.1 { out.append(LexToken(lex: .unit(u), text: tok)) }
                i += 1; continue
            }
            if let n = AssistantText.number(in: tokens, at: i, allowOne: isUnitWord(at: i + 1, in: tokens) || isUnitWord(at: i + 2, in: tokens)) {
                out.append(LexToken(lex: .number(n.value), text: tokens[i..<(i + n.consumed)].joined(separator: " ")))
                i += n.consumed; continue
            }
            // Unknown labels like "b9" still read as labels (the planner says it can't find them).
            if tok.count >= 2, tok.count <= 6, let first = tok.first, first.isLetter, let last = tok.last, last.isNumber,
               tok.allSatisfy({ $0.isLetter || $0.isNumber }), tok.filter({ $0.isLetter }).count <= 3 {
                out.append(LexToken(lex: .target(.label(tok.uppercased())), text: tok)); i += 1; continue
            }
            out.append(LexToken(lex: .word(tok), text: tok))
            i += 1
        }
        return out
    }

    func isEffectOrControl(_ lex: Lexeme?) -> Bool {
        guard let lex else { return false }
        switch lex {
        case .effect, .effectOrColor, .control, .mood, .adjective, .verb: return true
        default: return false
        }
    }

    func isUnitWord(at i: Int, in tokens: [String]) -> Bool {
        guard i < tokens.count else { return false }
        if case .unit? = AssistantLexicon.table[tokens[i]] { return true }
        return false
    }

    func colorComparative(_ tok: String) -> ColorSpec? {
        let map: [String: String] = ["bluer": "blue", "redder": "red", "greener": "green", "pinker": "pink",
                                     "oranger": "orange", "yellower": "yellow", "purpler": "purple", "tealer": "teal",
                                     "more blue": "blue"]
        guard let base = map[tok] else { return nil }
        return AssistantColors.lookup(base)
    }

    func gluedNumber(_ tok: String) -> (Double, AssistantUnit?)? {
        guard let first = tok.first, first.isNumber else { return nil }
        let digits = String(tok.prefix { $0.isNumber || $0 == "." })
        let suffix = String(tok.dropFirst(digits.count))
        guard let v = Double(digits), v.isFinite, !suffix.isEmpty else { return nil }
        switch suffix {
        case "k", "kelvin": return (v, .kelvin)
        case "s", "sec", "secs": return (v, .seconds)
        case "pc", "pct", "percent": return (v, .percent)
        case "m", "min", "mins": return (v, .minutes)
        case "stops", "stop": return (v, .stops)
        case "x": return (v, nil)
        default: return nil
        }
    }
}
