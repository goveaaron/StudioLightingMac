import Foundation

/// How a mood moves: sets its pulse caps, slew limits and intensity floors (§3.0, §4.3).
public enum MoodDynamics: String, Codable, CaseIterable, Sendable {
    /// Slow breathing and drifting colour; ≤ 1.5 pulses/s.
    case gentle
    /// Beat-locked pulses and sweeps; ≤ 2.5 pulses/s.
    case rhythmic
    /// Club energy with big moves on drops — still no strobe.
    case energetic

    public var displayName: String {
        switch self { case .gentle: return "Gentle"; case .rhythmic: return "Rhythmic"; case .energetic: return "Energetic" }
    }
}

/// Curated music-reactive looks. Designed to be beautiful for hours — never strobe-y.
public enum MusicMood: String, Codable, CaseIterable, Sendable {
    /// Picks a mood that suits the music (tempo, energy, key) and changes only at section changes.
    case auto
    case aurora, neonPulse, oceanDrift, sunset, synthwave, lavaLamp, spectrum, cinematic
    case club, chill, starfield, heartbeat, gradientSweep, prismBloom
    case ember, nebula

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MusicMood(rawValue: raw) ?? .aurora
    }

    /// The 16 concrete moods (everything except `.auto`).
    public static var concrete: [MusicMood] { allCases.filter { $0 != .auto } }

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .aurora: return "Aurora"
        case .neonPulse: return "Neon Pulse"
        case .oceanDrift: return "Ocean Drift"
        case .sunset: return "Sunset"
        case .synthwave: return "Synthwave"
        case .lavaLamp: return "Lava Lamp"
        case .spectrum: return "Spectrum"
        case .cinematic: return "Cinematic"
        case .club: return "Club"
        case .chill: return "Chill / Lo-fi"
        case .starfield: return "Starfield"
        case .heartbeat: return "Heartbeat"
        case .gradientSweep: return "Gradient Sweep"
        case .prismBloom: return "Prism Bloom"
        case .ember: return "Ember"
        case .nebula: return "Nebula"
        }
    }

    /// Motion class (pulse caps, slew limits, floors).
    public var dynamics: MoodDynamics {
        switch self {
        case .auto, .aurora, .oceanDrift, .sunset, .lavaLamp, .cinematic, .chill, .starfield, .ember, .nebula:
            return .gentle
        case .neonPulse, .synthwave, .spectrum, .heartbeat, .gradientSweep, .prismBloom:
            return .rhythmic
        case .club:
            return .energetic
        }
    }

    /// One friendly line for the mood card.
    public var tagline: String {
        switch self {
        case .auto: return "Picks the right look for each song"
        case .aurora: return "Slow ribbons of green, teal and violet"
        case .neonPulse: return "Magenta and cyan that pulse with the beat"
        case .oceanDrift: return "Deep blue swells that roll across the room"
        case .sunset: return "Warm amber, coral and rose, gently breathing"
        case .synthwave: return "Retro pink and purple with a rolling horizon"
        case .lavaLamp: return "Warm blobs that drift and merge"
        case .spectrum: return "Colours that follow the chords"
        case .cinematic: return "Big, slow, dramatic washes"
        case .club: return "Energetic waves and big drops — no strobe"
        case .chill: return "Soft, cosy, barely moving"
        case .starfield: return "Twinkling points on a deep night sky"
        case .heartbeat: return "A warm double pulse on every beat"
        case .gradientSweep: return "Smooth colour sweeps across the stage"
        case .prismBloom: return "Prism's signature: rainbow blooms on the beat"
        case .ember: return "Glowing embers for acoustic and jazz"
        case .nebula: return "Swirling cosmic clouds"
        }
    }

    /// Music this mood is made for.
    public var genres: String {
        switch self {
        case .auto: return "Anything"
        case .aurora: return "Ambient, downtempo, chill-out"
        case .neonPulse: return "Synth-pop, electro, nu-disco, house"
        case .oceanDrift: return "Deep house, chill, lo-fi"
        case .sunset: return "Soul, R&B, indie, acoustic"
        case .synthwave: return "Synthwave, retrowave, 80s pop"
        case .lavaLamp: return "Lo-fi, psychedelic, soul"
        case .spectrum: return "Pop, jazz, piano, classical"
        case .cinematic: return "Film score, post-rock, ballads"
        case .club: return "House, techno, EDM, dance-pop"
        case .chill: return "Lo-fi hip hop, jazz-hop, bedroom pop"
        case .starfield: return "Ambient, piano, minimal"
        case .heartbeat: return "Ballads, R&B, minimal techno"
        case .gradientSweep: return "Pop, house, funk"
        case .prismBloom: return "Works for most music"
        case .ember: return "Acoustic, folk, jazz, singer-songwriter"
        case .nebula: return "Ambient techno, trance, IDM"
        }
    }

    /// SF Symbol for the mood card.
    public var systemImage: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .aurora: return "sparkles"
        case .neonPulse: return "waveform.path"
        case .oceanDrift: return "water.waves"
        case .sunset: return "sun.horizon.fill"
        case .synthwave: return "triangle.fill"
        case .lavaLamp: return "drop.fill"
        case .spectrum: return "pianokeys"
        case .cinematic: return "film"
        case .club: return "speaker.wave.3.fill"
        case .chill: return "cup.and.saucer.fill"
        case .starfield: return "star.fill"
        case .heartbeat: return "heart.fill"
        case .gradientSweep: return "arrow.left.and.right"
        case .prismBloom: return "rays"
        case .ember: return "flame.fill"
        case .nebula: return "hurricane"
        }
    }
}

/// How often rhythmic moods pulse.
public enum MusicPulseRate: String, Codable, CaseIterable, Sendable {
    /// Chosen from the tempo so pulses stay comfortable.
    case auto
    case everyBeat
    case everyOtherBeat
    case everyBar

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MusicPulseRate(rawValue: raw) ?? .auto
    }

    /// Beats per pulse (nil = automatic).
    public var divisor: Int? {
        switch self { case .auto: return nil; case .everyBeat: return 1; case .everyOtherBeat: return 2; case .everyBar: return 4 }
    }

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .everyBeat: return "Every beat"
        case .everyOtherBeat: return "Every other beat"
        case .everyBar: return "Once a bar"
        }
    }
}

/// Where audio for music mode comes from.
public enum AudioSource: String, Codable, CaseIterable, Sendable {
    /// Everything playing on this Mac (Spotify, YouTube in a browser, Apple Music…).
    case systemAudio
    /// One app only (see `MusicModeSettings.sourceAppBundleID`).
    case app
    /// A microphone, audio interface input or loopback device (see `inputDeviceUID`).
    case input

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AudioSource(rawValue: raw) ?? .systemAudio
    }

    public var displayName: String {
        switch self {
        case .systemAudio: return "Everything on this Mac"
        case .app: return "One app"
        case .input: return "Microphone or input"
        }
    }
}

public struct MusicModeSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var mood: MusicMood
    /// Which fixtures dance. Default: everything except key/fill lights (so faces stay lit).
    public var targets: FixtureSelector
    /// "Wildness": how strongly the lights react, 0 (calm) … 1 (lively).
    public var reactivity: Double
    /// Overall brightness of the music look, 0…1.
    public var brightness: Double
    /// Optional palette override (≥ 2 colours; empty = the mood's palettes).
    public var palette: [LightColor]
    /// Smoothness of motion, 0 (snappy) … 1 (silky). Can only slow things below the safety limits.
    public var smoothness: Double
    /// Seconds of silence before handing back to the underlying look (short gaps stay ambient).
    public var silenceFadeSeconds: Double
    public var source: AudioSource
    /// Bundle identifier when `source == .app` (e.g. "com.spotify.client").
    public var sourceAppBundleID: String?
    /// Core Audio device UID when `source == .input` (nil = system default input).
    public var inputDeviceUID: String?
    /// Motion speed multiplier, 0.25…2.
    public var speed: Double
    /// Pulse grid for rhythmic moods.
    public var pulseRate: MusicPulseRate
    /// How much white/pastel the moods may mix in, 0…1.
    public var whiteUse: Double
    /// Selected palette variant within the mood.
    public var paletteIndex: Int
    /// Rotate palette variants at section changes.
    public var autoRotatePalette: Bool
    /// Photosensitive-safe limits (fewer, softer pulses). On by default.
    public var photosensitiveSafe: Bool
    /// Avoids modulation that shows up as banding/flicker on camera. On by default.
    public var cameraSafe: Bool
    /// Strobe-like flashes are never used unless this is explicitly enabled (and safe mode is off).
    public var allowStrobe: Bool
    /// 0.5 = half time, 1 = as detected, 2 = double time.
    public var tempoMultiplier: Double
    /// Keep listening through silence and come back automatically when music returns.
    public var leaveRunning: Bool
    /// Look to fade to after `silenceFadeSeconds` of silence (nil = whatever was on before).
    public var silenceLookID: UUID?
    /// Auto-gain behaviour.
    public var agc: AGCPreset

    public init(enabled: Bool = false, mood: MusicMood = .auto,
                targets: FixtureSelector = .excluding(.all, .union([.role(.key), .role(.fill)])),
                reactivity: Double = 0.6, brightness: Double = 0.85, palette: [LightColor] = [],
                smoothness: Double = 0.6, silenceFadeSeconds: Double = 25, source: AudioSource = .systemAudio,
                sourceAppBundleID: String? = nil, inputDeviceUID: String? = nil, speed: Double = 1,
                pulseRate: MusicPulseRate = .auto, whiteUse: Double = 0.25, paletteIndex: Int = 0,
                autoRotatePalette: Bool = true, photosensitiveSafe: Bool = true, cameraSafe: Bool = true,
                allowStrobe: Bool = false, tempoMultiplier: Double = 1, leaveRunning: Bool = true,
                silenceLookID: UUID? = nil, agc: AGCPreset = .normal) {
        self.enabled = enabled; self.mood = mood; self.targets = targets
        self.reactivity = clamp01(reactivity.finiteOr(0.6))
        self.brightness = clamp01(brightness.finiteOr(0.85))
        self.palette = palette
        self.smoothness = clamp01(smoothness.finiteOr(0.6))
        self.silenceFadeSeconds = clamp(silenceFadeSeconds.finiteOr(25), 0, 600)
        self.source = source; self.sourceAppBundleID = sourceAppBundleID; self.inputDeviceUID = inputDeviceUID
        self.speed = clamp(speed.finiteOr(1), 0.25, 2)
        self.pulseRate = pulseRate
        self.whiteUse = clamp01(whiteUse.finiteOr(0.25))
        self.paletteIndex = max(0, min(paletteIndex, 64))
        self.autoRotatePalette = autoRotatePalette
        self.photosensitiveSafe = photosensitiveSafe
        self.cameraSafe = cameraSafe
        self.allowStrobe = allowStrobe
        self.tempoMultiplier = MusicModeSettings.sanitizeMultiplier(tempoMultiplier)
        self.leaveRunning = leaveRunning
        self.silenceLookID = silenceLookID
        self.agc = agc
    }

    static func sanitizeMultiplier(_ m: Double) -> Double {
        guard m.isFinite else { return 1 }
        if abs(m - 0.5) < 0.01 { return 0.5 }
        if abs(m - 2) < 0.01 { return 2 }
        return 1
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, mood, targets, reactivity, brightness, palette, smoothness, silenceFadeSeconds, source
        case sourceAppBundleID, inputDeviceUID, speed, pulseRate, whiteUse, paletteIndex, autoRotatePalette
        case photosensitiveSafe, cameraSafe, allowStrobe, tempoMultiplier, leaveRunning, silenceLookID, agc
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MusicModeSettings()
        func dbl(_ k: CodingKeys, _ def: Double) -> Double {
            ((try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil)?.finiteOr(def) ?? def
        }
        func bool(_ k: CodingKeys, _ def: Bool) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil) ?? def }
        enabled = bool(.enabled, d.enabled)
        mood = ((try? c.decodeIfPresent(MusicMood.self, forKey: .mood)) ?? nil) ?? d.mood
        targets = ((try? c.decodeIfPresent(FixtureSelector.self, forKey: .targets)) ?? nil) ?? d.targets
        reactivity = clamp01(dbl(.reactivity, d.reactivity))
        brightness = clamp01(dbl(.brightness, d.brightness))
        palette = ((try? c.decodeIfPresent([LightColor].self, forKey: .palette)) ?? nil) ?? []
        smoothness = clamp01(dbl(.smoothness, d.smoothness))
        silenceFadeSeconds = clamp(dbl(.silenceFadeSeconds, d.silenceFadeSeconds), 0, 600)
        source = ((try? c.decodeIfPresent(AudioSource.self, forKey: .source)) ?? nil) ?? .systemAudio
        sourceAppBundleID = ((try? c.decodeIfPresent(String.self, forKey: .sourceAppBundleID)) ?? nil)
        inputDeviceUID = ((try? c.decodeIfPresent(String.self, forKey: .inputDeviceUID)) ?? nil)
        speed = clamp(dbl(.speed, d.speed), 0.25, 2)
        pulseRate = ((try? c.decodeIfPresent(MusicPulseRate.self, forKey: .pulseRate)) ?? nil) ?? .auto
        whiteUse = clamp01(dbl(.whiteUse, d.whiteUse))
        let idx = ((try? c.decodeIfPresent(Int.self, forKey: .paletteIndex)) ?? nil) ?? 0
        paletteIndex = max(0, min(idx, 64))
        autoRotatePalette = bool(.autoRotatePalette, d.autoRotatePalette)
        photosensitiveSafe = bool(.photosensitiveSafe, d.photosensitiveSafe)
        cameraSafe = bool(.cameraSafe, d.cameraSafe)
        allowStrobe = bool(.allowStrobe, d.allowStrobe)
        tempoMultiplier = MusicModeSettings.sanitizeMultiplier(dbl(.tempoMultiplier, 1))
        leaveRunning = bool(.leaveRunning, d.leaveRunning)
        silenceLookID = ((try? c.decodeIfPresent(UUID.self, forKey: .silenceLookID)) ?? nil)
        agc = ((try? c.decodeIfPresent(AGCPreset.self, forKey: .agc)) ?? nil) ?? .normal
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(mood, forKey: .mood)
        try c.encode(targets, forKey: .targets)
        try c.encode(reactivity, forKey: .reactivity)
        try c.encode(brightness, forKey: .brightness)
        try c.encode(palette, forKey: .palette)
        try c.encode(smoothness, forKey: .smoothness)
        try c.encode(silenceFadeSeconds, forKey: .silenceFadeSeconds)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(sourceAppBundleID, forKey: .sourceAppBundleID)
        try c.encodeIfPresent(inputDeviceUID, forKey: .inputDeviceUID)
        try c.encode(speed, forKey: .speed)
        try c.encode(pulseRate, forKey: .pulseRate)
        try c.encode(whiteUse, forKey: .whiteUse)
        try c.encode(paletteIndex, forKey: .paletteIndex)
        try c.encode(autoRotatePalette, forKey: .autoRotatePalette)
        try c.encode(photosensitiveSafe, forKey: .photosensitiveSafe)
        try c.encode(cameraSafe, forKey: .cameraSafe)
        try c.encode(allowStrobe, forKey: .allowStrobe)
        try c.encode(tempoMultiplier, forKey: .tempoMultiplier)
        try c.encode(leaveRunning, forKey: .leaveRunning)
        try c.encodeIfPresent(silenceLookID, forKey: .silenceLookID)
        try c.encode(agc, forKey: .agc)
    }
}
