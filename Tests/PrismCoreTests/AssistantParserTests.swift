import XCTest
@testable import PrismCore

/// Table-driven tests for the offline assistant parser. Each case is the text a user typed or said
/// and the expected actions in a compact form (see `ParsedAction.compact` below).
final class AssistantParserTests: XCTestCase {
    static let parser = AssistantParser(project: DemoRig.londonStudio())

    func check(_ cases: [(String, String)], file: StaticString = #filePath, line: UInt = #line) {
        var failures: [String] = []
        for (text, expected) in cases {
            let got = Self.parser.parse(text).actions.map(\.compact).joined(separator: "; ")
            if got != expected {
                failures.append("\"\(text)\"\n    expected: \(expected)\n    got:      \(got)")
            }
        }
        XCTAssert(failures.isEmpty, "\(failures.count)/\(cases.count) failed:\n" + failures.joined(separator: "\n"),
                  file: file, line: line)
    }

    // MARK: - The user's own words

    func testUserSentencesVerbatim() {
        check([
            ("All right, light app, warm up the background a bit. Bit more blue to the left, back left, right. Bring the tubes down a little bit. Brighten up the key a little bit. Bring down the fill a little bit.",
             "warm(background,+,bit); shift(@backLeft,blue,bit); bright(tube,-,little); bright(key,+,little); bright(fill,-,little)"),
            ("I want a blue and teal background, teal on the left-hand side, blue on the right-hand side, and pink above",
             "scene(@left=teal,@right=blue,@top=pink)"),
            ("All right, Prism — warm up the background a bit. Bit more blue to the back left. Bring the tubes down a little. Brighten up the key a little. Bring down the fill a little.",
             "warm(background,+,bit); shift(@backLeft,blue,bit); bright(tube,-,little); bright(key,+,little); bright(fill,-,little)"),
            ("Teal on the left, blue on the right, pink above.", "scene(@left=teal,@right=blue,@top=pink)"),
            // Speech recognizers often drop punctuation.
            ("all right light app warm up the background a bit", "warm(background,+,bit)"),
            ("bit more blue to the left back left right", "shift(@backLeft,blue,bit)"),
            ("teal on the left blue on the right and pink above", "scene(@left=teal,@right=blue,@top=pink)"),
            ("I want a blue and teal background teal on the left hand side blue on the right hand side and pink above",
             "scene(@left=teal,@right=blue,@top=pink)"),
        ])
    }

    func testUserPhraseVariations() {
        check([
            ("warm up the background a little", "warm(background,+,little)"),
            ("warm the background up", "warm(background,+,bit)"),
            ("make the background warmer", "warm(background,+,bit)"),
            ("background warmer please", "warm(background,+,bit)"),
            ("a bit warmer on the background", "warm(background,+,bit)"),
            ("bit more blue on the back left", "shift(@backLeft,blue,bit)"),
            ("more blue to the back left", "shift(@backLeft,blue,bit)"),
            ("a bit more blue back left", "shift(@backLeft,blue,bit)"),
            ("bring the tubes down", "bright(tube,-,bit)"),
            ("tubes down a little", "bright(tube,-,little)"),
            ("drop the tubes a bit", "bright(tube,-,bit)"),
            ("brighten the key a little", "bright(key,+,little)"),
            ("key up a little bit", "bright(key,+,little)"),
            ("bring down the fill", "bright(fill,-,bit)"),
            ("fill down a little", "bright(fill,-,little)"),
            ("lower the fill a little bit", "bright(fill,-,little)"),
            ("teal on the left side, blue on the right side, pink above", "scene(@left=teal,@right=blue,@top=pink)"),
            ("teal on the left-hand side and blue on the right-hand side", "scene(@left=teal,@right=blue)"),
            ("pink above, teal left, blue right", "scene(@top=pink,@left=teal,@right=blue)"),
            ("teal left blue right pink above", "scene(@left=teal,@right=blue,@top=pink)"),
            ("left teal, right blue", "scene(@left=teal,@right=blue)"),
            ("make the left side teal and the right side blue", "scene(@left=teal,@right=blue)"),
            ("teal on the left, blue on the right and the rest pink", "scene(@left=teal,@right=blue); color(rest,pink)"),
            ("blue and teal background with teal on the left and blue on the right", "scene(@left=teal,@right=blue)"),
        ])
    }

    // MARK: - Brightness

    func testIntensity() {
        check([
            ("brighten the key", "bright(key,+,bit)"),
            ("make the key brighter", "bright(key,+,bit)"),
            ("key up a bit", "bright(key,+,bit)"),
            ("turn up the key", "bright(key,+,bit)"),
            ("turn the key up a lot", "bright(key,+,lot)"),
            ("dim the tubes", "bright(tube,-,bit)"),
            ("lower the background a touch", "bright(background,-,little)"),
            ("bring the fill up slightly", "bright(fill,+,little)"),
            ("the key is a bit too bright", "bright(key,-,bit)"),
            ("it's too dark", "bright(prev,+,little)"),
            ("way brighter", "bright(_,+,lot)"),
            ("much dimmer please", "bright(_,-,lot)"),
            ("a little brighter", "bright(_,+,little)"),
            ("brighter", "bright(_,+,bit)"),
            ("Turn the lights down", "bright(all,-,bit)"),
            ("boost the back tubes", "bright('Back Tubes',+,bit)"),
            ("set the key to 50%", "level(key,0.5)"),
            ("key at 80 percent", "level(key,0.8)"),
            ("dim the background by 20%", "bright(background,-,20%)"),
            ("bring the tubes up 10 percent", "bright(tube,+,10%)"),
            ("key to full", "level(key,1)"),
            ("tubes at half", "level(tube,0.5)"),
            ("one stop brighter on the key", "stops(key,1)"),
            ("half a stop down on the tubes", "stops(tube,-0.5)"),
            ("two stops down", "stops(_,-2)"),
            ("dim the round light to 30%", "level('Round Light',0.3)"),
            ("more light on the key", "bright(key,+,bit)"),
        ])
    }

    // MARK: - Colour and temperature

    func testColorAndTemperature() {
        check([
            ("make the background blue", "color(background,blue)"),
            ("turn the tubes pink", "color(tube,pink)"),
            ("set the key to 3200K", "kelvin(key,3200)"),
            ("key to 5600 kelvin", "kelvin(key,5600)"),
            ("warmer key", "warm(key,+,bit)"),
            ("make the key a bit cooler", "warm(key,-,bit)"),
            ("cool down the background", "warm(background,-,bit)"),
            ("warm the key up a little", "warm(key,+,little)"),
            ("make it warm", "color(prev,warm white)"),
            ("the key is too warm", "warm(key,-,little)"),
            ("too cold", "warm(_,+,little)"),
            ("warmer by 500K", "warm(_,+,500K)"),
            ("turn the temperature up", "warm(_,-,bit)"),
            ("more blue on the left", "shift(@left,blue,bit)"),
            ("add some pink to the back", "shift(@back,pink,bit)"),
            ("less green on the key", "reduce(key,green,bit)"),
            ("the background is too blue", "reduce(background,blue,little)"),
            ("a bit bluer on the right", "shift(@right,blue,bit)"),
            ("make it way more pink", "shift(prev,pink,lot)"),
            ("tungsten on the key", "color(key,tungsten)"),
            ("warm white key", "color(key,warm white)"),
            ("blue at 50% on the left", "color(@left,blue); level(@left,0.5)"),
            ("orange to pink gradient on the tubes", "gradient(tube,orange+pink)"),
            ("from blue to teal across the back", "gradient(@back,blue+teal)"),
            ("more saturated", "sat(_,+,bit)"),
            ("make the colours a bit more pastel", "sat(_,-,bit)"),
            ("add a little magenta to the key", "shift(key,magenta,little)"),
            ("everything blue", "color(all,blue)"),
        ])
    }

    // MARK: - Places and lights

    func testTargets() {
        check([
            ("dim the left tubes", "bright(@left+tube,-,bit)"),
            ("brighten the back left tube", "bright(one(@backLeft+tube),+,bit)"),
            ("turn off the floor tubes", "off('Floor Tubes')"),
            ("teal on top", "color(@top,teal)"),
            ("pink overhead", "color(@top,pink)"),
            ("blue behind me", "color(@back,blue)"),
            ("red on the left and right", "color(@sides,red)"),
            ("dim everything except the key", "bright(all-key,-,bit)"),
            ("turn off all the tubes except the left one", "off(tube-one(@left+tube))"),
            ("the key and the fill up a bit", "bright((key|fill),+,bit)"),
            ("brighten B3", "bright(#B3,+,bit)"),
            ("turn on the round light", "on('Round Light')"),
            ("dim the left and right tubes", "bright(@sides+tube,-,bit)"),
            ("warm up the back and side tubes", "warm((@back|'Side Tubes'),+,bit)"),
            ("brighten these", "bright(sel,+,bit)"),
        ])
    }

    // MARK: - Follow-ups and corrections

    func testFollowUps() {
        check([
            ("a bit more", "more(bit)"),
            ("more", "more"),
            ("a lot more", "more(lot)"),
            ("a little more key", "more(little,key)"),
            ("too much", "less"),
            ("a little less", "less(little)"),
            ("no, the other side", "otherSide"),
            ("no, the fill", "retarget(fill)"),
            ("actually, pink", "recolor(pink)"),
            ("undo", "undo"),
            ("undo that", "undo"),
            ("put it back", "undo"),
            ("no", "undo"),
            ("redo", "redo"),
            ("same for the fill", "repeatOn(fill)"),
            ("the right too", "repeatOn(@right)"),
            ("and the background", "repeatOn(background)"),
            ("thanks", "ack"),
            ("perfect, thank you", "ack"),
            ("the key", "clarify(key)"),
            ("again", "more"),
            ("keep going", "more"),
        ])
    }

    // MARK: - Looks, effects, music, global

    func testLooksEffectsMusic() {
        check([
            ("go to chill vibes", "recall(Chill Vibes 4)"),
            ("recall deep blue", "recall(Deep Blue)"),
            ("Deep Blue", "recall(Deep Blue)"),
            ("load the greenscreen look", "recall(Greenscreen)"),
            ("save this as Interview", "save(Interview)"),
            ("save this look", "save(nil)"),
            ("call this cozy evening", "save(Cozy Evening)"),
            ("back to white", "recall(White Background)"),
            ("deep blue background", "color(background,deep blue)"),
            ("make it flicker like a candle", "effect(candle,prev)"),
            ("candle flicker on the practical", "effect(candle,practical)"),
            ("fire effect on the tubes", "effect(fire,tube)"),
            ("slow rainbow on the background", "effect(rainbow,background,0.5)"),
            ("stop the effects", "stopEffects(nil)"),
            ("stop", "stopEffects(nil)"),
            ("police lights", "effect(police,_)"),
            ("start music mode", "music(on)"),
            ("sync the lights to the music", "music(on)"),
            ("chill music", "music(on,chill)"),
            ("turn off the music", "music(off)"),
        ])
    }

    func testGlobalCommandsAndQuestions() {
        check([
            ("blackout", "blackout(true)"),
            ("lights out", "blackout(true)"),
            ("turn everything off", "blackout(true)"),
            ("lights on", "lightsOn"),
            ("turn the tubes off", "off(tube)"),
            ("kill the tubes", "off(tube)"),
            ("fade the tubes out", "off(tube)"),
            ("what's on?", "query(whatsOn)"),
            ("what can you do", "query(help)"),
            ("how bright is the key", "query(key)"),
            ("which one is B3", "identify(#B3)"),
            ("where is the round light", "identify('Round Light')"),
            ("flash the left tube", "identify(one(@left+tube))"),
            ("show me the key", "identify(key)"),
            ("swap the key and the fill", "swap(key,fill)"),
            ("swap left and right", "swap(@sides,nil)"),
            ("freeze", "freeze(true)"),
            ("we're recording", "recording(true)"),
        ])
    }

    // MARK: - Wake phrases, fillers, typos, compound sentences

    func testWakePhrasesFillersAndTypos() {
        check([
            ("Hey Prism, dim the key", "bright(key,-,bit)"),
            ("OK Prism dim the key", "bright(key,-,bit)"),
            ("light app, brighten the tubes", "bright(tube,+,bit)"),
            ("Alright light app bring the tubes down a little bit", "bright(tube,-,little)"),
            ("Hey Prism, what's on?", "query(whatsOn)"),
            ("please make the key a little warmer", "warm(key,+,little)"),
            ("could you bring the background down a bit please", "bright(background,-,bit)"),
            ("can you uh warm up the key", "warm(key,+,bit)"),
            ("um, could you maybe dim the tubes a tiny bit please", "bright(tube,-,little)"),
            ("I'd like the tubes brighter", "bright(tube,+,bit)"),
            ("let's make the background pink", "color(background,pink)"),
            ("BRIGHTEN THE KEY!!", "bright(key,+,bit)"),
            ("brigten the key", "bright(key,+,bit)"),
            ("dim the backround", "bright(background,-,bit)"),
            ("warmmer please", "warm(_,+,bit)"),
            ("Bring the tubs down", "bright(tube,-,bit)"),
            ("turn up the phil", "bright(fill,+,bit)"),
            ("dim the feel a bit", "bright(fill,-,bit)"),
            ("teel on the left, blue on the right", "scene(@left=teal,@right=blue)"),
        ])
    }

    func testCompoundSentences() {
        check([
            ("dim the key and brighten the fill", "bright(key,-,bit); bright(fill,+,bit)"),
            ("warm up the background and bring the tubes down", "warm(background,+,bit); bright(tube,-,bit)"),
            ("make the background blue and a bit brighter", "color(background,blue); bright(background,+,bit)"),
            ("turn the key and the fill off", "off((key|fill))"),
            ("dim the key then warm it up", "bright(key,-,bit); warm(key,+,bit)"),
            ("the key, a bit brighter", "bright(key,+,bit)"),
            ("dim and warm the key", "bright(key,-,bit); warm(key,+,bit)"),
            ("brighten the key, the fill too", "bright(key,+,bit); bright(fill,+,bit)"),
            ("warm up the key, no, cool it down", "warm(key,-,bit)"),
            ("make the left teal, no, pink", "color(@left,pink)"),
        ])
    }

    // MARK: - Request details

    func testWakePhraseAndFlags() {
        let r = Self.parser.parse("All right, light app, warm up the background a bit.")
        XCTAssertEqual(r.wakePhrase?.phrase, "all right light app")
        XCTAssertEqual(r.wakePhrase?.confidence, 1.0)
        XCTAssertFalse(r.isCorrection)

        XCTAssertNil(Self.parser.parse("warm up the background").wakePhrase)
        XCTAssertTrue(Self.parser.parse("no, make it warmer").isCorrection)
        XCTAssertTrue(Self.parser.parse("Hey Prism").actions.isEmpty)

        XCTAssertEqual(Self.parser.parse("slowly bring the key down").fadeSeconds, 4)
        XCTAssertEqual(Self.parser.parse("dim the key over 5 seconds").fadeSeconds, 5)
        XCTAssertEqual(Self.parser.parse("fade the tubes out").fadeSeconds, 2)
        XCTAssertNil(Self.parser.parse("dim the key").fadeSeconds)
        XCTAssertEqual(Self.parser.parse("make it flicker slowly").fadeSeconds, nil)

        XCTAssertEqual(Self.parser.parse("make the key zorbly").unknownWords, ["zorbly"])
    }

    func testCustomWakePhrase() {
        let parser = AssistantParser(project: DemoRig.londonStudio(), wake: WakePhraseMatcher(customPhrases: ["Studio Bot"]))
        let r = parser.parse("Studio bot, dim the key")
        XCTAssertEqual(r.actions.map(\.compact), ["bright(key,-,bit)"])
        XCTAssertEqual(r.wakePhrase?.phrase, "studio bot")
    }

    func testWakeFromLiveTranscript() {
        let m = WakePhraseMatcher.standard
        XCTAssertEqual(m.wake(in: "Hey Prism, dim the key", musicPlaying: false)?.command, "dim the key")
        XCTAssertEqual(m.wake(in: "All right, light app, warm up the background", musicPlaying: true)?.command, "warm up the background")
        // Lyrics or a lone name while music plays must not wake the assistant.
        XCTAssertNil(m.wake(in: "prism of the night", musicPlaying: true))
        XCTAssertNil(m.wake(in: "dim the key", musicPlaying: false))
        XCTAssertNotNil(m.wake(in: "Prism, dim the key", musicPlaying: false))
    }

    func testParserNeverCrashesOnOddInput() {
        let odd = ["", " ", "!!!", ",,,", "and", "the the the", "100000000000000000000%", "-5 stops", "∞", "🙂 lights",
                   "B", "b 99", "a a a a a a a a a", String(repeating: "brighter ", count: 200), "nan kelvin", "1e309 percent"]
        for text in odd {
            let r = Self.parser.parse(text)
            for a in r.actions {
                if case .setIntensity(_, let l) = a { XCTAssert(l.isFinite && l >= 0 && l <= 1, text) }
                if case .setKelvin(_, let k) = a { XCTAssert(k.isFinite && k >= 1000 && k <= 20000, text) }
            }
        }
    }
}

// MARK: - Compact descriptions for table tests

extension TargetSpec {
    var compact: String {
        switch self {
        case .everything: return "all"
        case .unspecified: return "_"
        case .previous: return "prev"
        case .rest: return "rest"
        case .selection: return "sel"
        case .role(let r): return r.rawValue
        case .category(let c): return c.rawValue
        case .area(let a): return "@" + a.rawValue
        case .label(let l): return "#" + l
        case .name(let n): return "'" + n + "'"
        case .single(let t): return "one(" + t.compact + ")"
        case .all(let items): return items.map(\.compact).joined(separator: "+")
        case .any(let items): return "(" + items.map(\.compact).joined(separator: "|") + ")"
        case .except(let a, let b): return a.compact + "-" + b.compact
        }
    }
}

private func fmt(_ v: Double) -> String {
    v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : String(format: "%g", v)
}

private func sign(_ d: Int) -> String { d > 0 ? "+" : "-" }

extension AmountSpec {
    var compact: String {
        switch self {
        case .nudge(let n):
            switch n {
            case .aLittle: return "little"
            case .aBit: return "bit"
            case .aLot: return "lot"
            }
        case .percent(let p): return "\(Int((p * 100).rounded()))%"
        case .kelvin(let k): return "\(Int(k.rounded()))K"
        case .stops(let s): return "\(fmt(s))st"
        }
    }
}

extension ParsedAction {
    var compact: String {
        switch self {
        case .adjustIntensity(let t, let d, let a): return "bright(\(t.compact),\(sign(d)),\(a.compact))"
        case .setIntensity(let t, let l): return "level(\(t.compact),\(fmt(l)))"
        case .scaleStops(let t, let s): return "stops(\(t.compact),\(fmt(s)))"
        case .turnOn(let t): return "on(\(t.compact))"
        case .turnOff(let t): return "off(\(t.compact))"
        case .setColor(let t, let cs): return "color(\(t.compact),\(cs.map(\.name).joined(separator: "+")))"
        case .shiftColor(let t, let c, let a): return "shift(\(t.compact),\(c.name),\(a.compact))"
        case .reduceColor(let t, let c, let a): return "reduce(\(t.compact),\(c.name),\(a.compact))"
        case .adjustWarmth(let t, let d, let a): return "warm(\(t.compact),\(sign(d)),\(a.compact))"
        case .setKelvin(let t, let k): return "kelvin(\(t.compact),\(fmt(k)))"
        case .adjustTint(let t, let d, let a): return "tint(\(t.compact),\(sign(d)),\(a.compact))"
        case .adjustSaturation(let t, let d, let a): return "sat(\(t.compact),\(sign(d)),\(a.compact))"
        case .gradient(let t, let cs): return "gradient(\(t.compact),\(cs.map(\.name).joined(separator: "+")))"
        case .scene(let zones): return "scene(" + zones.map { "\($0.target.compact)=\($0.color.name)" }.joined(separator: ",") + ")"
        case .blackout(let b): return "blackout(\(b))"
        case .lightsOn: return "lightsOn"
        case .recallLook(let n): return "recall(\(n))"
        case .saveLook(let n): return "save(\(n ?? "nil"))"
        case .startEffect(let k, let t, let s): return "effect(\(k.rawValue),\(t.compact)\(s.map { "," + fmt($0) } ?? ""))"
        case .stopEffects(let t): return "stopEffects(\(t?.compact ?? "nil"))"
        case .music(let on, let m): return on ? "music(on\(m.map { "," + $0.rawValue } ?? ""))" : "music(off)"
        case .identify(let t): return "identify(\(t.compact))"
        case .swapColors(let a, let b): return "swap(\(a?.compact ?? "nil"),\(b?.compact ?? "nil"))"
        case .freeze(let b): return "freeze(\(b))"
        case .recordingMode(let b): return "recording(\(b))"
        case .grandMaster(let v): return "master(\(fmt(v)))"
        case .undo: return "undo"
        case .redo: return "redo"
        case .query(let q):
            switch q {
            case .whatsOn: return "query(whatsOn)"
            case .help: return "query(help)"
            case .state(let t): return "query(\(t.compact))"
            }
        case .more(let a, let t):
            var parts: [String] = []
            if let a { parts.append(a.compact) }
            if let t { parts.append(t.compact) }
            return parts.isEmpty ? "more" : "more(" + parts.joined(separator: ",") + ")"
        case .less(let a): return a.map { "less(\($0.compact))" } ?? "less"
        case .otherSide: return "otherSide"
        case .retarget(let t): return "retarget(\(t.compact))"
        case .recolor(let cs): return "recolor(\(cs.map(\.name).joined(separator: "+")))"
        case .repeatOn(let t): return "repeatOn(\(t.compact))"
        case .acknowledge: return "ack"
        case .clarifyTarget(let t): return "clarify(\(t.compact))"
        }
    }
}
