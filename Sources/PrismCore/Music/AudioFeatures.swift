import Foundation

/// Real-time musical features computed from system audio, consumed by music moods and
/// audio-reactive effects at the engine frame rate. All values are normalized and smoothed
/// by the analyzer (0…1 unless noted), so consumers can use them directly.
public struct AudioFeatures: Sendable, Equatable {
    /// Engine-clock time these features were computed.
    public var timestamp: Double
    /// True when meaningful audio is present (not silence/very quiet).
    public var isActive: Bool
    /// Overall loudness after auto-gain, 0…1.
    public var level: Double
    /// Six bands: sub (20–60), bass (60–250), lowMid (250–500), mid (500–2k), highMid (2k–6k), high (6k–16k).
    public var bands: [Double]
    /// Onset (transient) strength this frame, 0…1.
    public var onset: Double
    /// True on the frame a beat was detected/predicted.
    public var beat: Bool
    /// Position within the current beat, 0…1 (0 = on the beat).
    public var beatPhase: Double
    /// Position within the current bar (4 beats), 0…1.
    public var barPhase: Double
    /// Estimated tempo in BPM (0 when unknown).
    public var bpm: Double
    /// Confidence in the tempo estimate, 0…1.
    public var tempoConfidence: Double
    /// Spectral centroid ("brightness" of the sound), 0…1.
    public var brightness: Double
    /// Chroma vector: energy per pitch class C, C#, D … B (12 values, 0…1).
    public var chroma: [Double]
    /// Novelty (section change likelihood), 0…1.
    public var novelty: Double
    /// True on the frame a section change / drop was detected.
    public var sectionChange: Bool
    /// Reduced log-frequency spectrum for visualizers (e.g. 32 bins, 0…1).
    public var spectrum: [Double]

    public init(timestamp: Double = 0, isActive: Bool = false, level: Double = 0, bands: [Double] = Array(repeating: 0, count: 6),
                onset: Double = 0, beat: Bool = false, beatPhase: Double = 0, barPhase: Double = 0, bpm: Double = 0,
                tempoConfidence: Double = 0, brightness: Double = 0, chroma: [Double] = Array(repeating: 0, count: 12),
                novelty: Double = 0, sectionChange: Bool = false, spectrum: [Double] = []) {
        self.timestamp = timestamp; self.isActive = isActive; self.level = level; self.bands = bands
        self.onset = onset; self.beat = beat; self.beatPhase = beatPhase; self.barPhase = barPhase
        self.bpm = bpm; self.tempoConfidence = tempoConfidence; self.brightness = brightness
        self.chroma = chroma; self.novelty = novelty; self.sectionChange = sectionChange; self.spectrum = spectrum
    }

    public static let silent = AudioFeatures()

    public var sub: Double { bands.count > 0 ? bands[0] : 0 }
    public var bass: Double { bands.count > 1 ? max(bands[0], bands[1]) : 0 }
    public var mid: Double { bands.count > 3 ? (bands[2] + bands[3]) / 2 : 0 }
    public var treble: Double { bands.count > 5 ? (bands[4] + bands[5]) / 2 : 0 }
}

/// Curated music-reactive looks. Designed to be beautiful for hours — not strobe-y.
public enum MusicMood: String, Codable, CaseIterable, Sendable {
    case aurora, neonPulse, oceanDrift, sunset, synthwave, lavaLamp, spectrum, cinematic
    case club, chill, starfield, heartbeat, gradientSweep, prismBloom

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MusicMood(rawValue: raw) ?? .aurora
    }

    public var displayName: String {
        switch self {
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
        }
    }
}

/// Where audio for music mode comes from.
public enum AudioSource: String, Codable, CaseIterable, Sendable {
    /// Everything playing on this Mac (Spotify, YouTube in a browser, Apple Music…).
    case systemAudio
    /// A microphone or audio interface input.
    case input

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AudioSource(rawValue: raw) ?? .systemAudio
    }
}

public struct MusicModeSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var mood: MusicMood
    /// Which fixtures dance. Default: everything except key/fill lights (so faces stay lit).
    public var targets: FixtureSelector
    /// How strongly the lights react, 0 (subtle) … 1 (energetic).
    public var reactivity: Double
    /// Overall brightness of the music look, 0…1.
    public var brightness: Double
    /// Optional palette override (empty = mood's palette).
    public var palette: [LightColor]
    /// Smoothness of motion, 0 (snappy) … 1 (silky).
    public var smoothness: Double
    /// Seconds of silence before fading back to the underlying look.
    public var silenceFadeSeconds: Double
    public var source: AudioSource

    public init(enabled: Bool = false, mood: MusicMood = .aurora,
                targets: FixtureSelector = .excluding(.all, .union([.role(.key), .role(.fill)])),
                reactivity: Double = 0.6, brightness: Double = 0.85, palette: [LightColor] = [],
                smoothness: Double = 0.6, silenceFadeSeconds: Double = 4, source: AudioSource = .systemAudio) {
        self.enabled = enabled; self.mood = mood; self.targets = targets; self.reactivity = reactivity
        self.brightness = brightness; self.palette = palette; self.smoothness = smoothness
        self.silenceFadeSeconds = silenceFadeSeconds; self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, mood, targets, reactivity, brightness, palette, smoothness, silenceFadeSeconds, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MusicModeSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        mood = try c.decodeIfPresent(MusicMood.self, forKey: .mood) ?? d.mood
        targets = try c.decodeIfPresent(FixtureSelector.self, forKey: .targets) ?? d.targets
        reactivity = clamp01((try c.decodeIfPresent(Double.self, forKey: .reactivity) ?? d.reactivity).finiteOr(0.6))
        brightness = clamp01((try c.decodeIfPresent(Double.self, forKey: .brightness) ?? d.brightness).finiteOr(0.85))
        palette = try c.decodeIfPresent([LightColor].self, forKey: .palette) ?? []
        smoothness = clamp01((try c.decodeIfPresent(Double.self, forKey: .smoothness) ?? d.smoothness).finiteOr(0.6))
        silenceFadeSeconds = clamp((try c.decodeIfPresent(Double.self, forKey: .silenceFadeSeconds) ?? 4).finiteOr(4), 0, 60)
        source = try c.decodeIfPresent(AudioSource.self, forKey: .source) ?? .systemAudio
    }
}
