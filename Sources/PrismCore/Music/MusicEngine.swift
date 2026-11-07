import Foundation

/// Applies the music-reactive layer (moods) driven by `AudioFeatures`.
public enum MusicEngine {
    public static func apply(_ settings: MusicModeSettings, targetIDs: [UUID], context: EffectContext,
                             states: inout [UUID: FixtureState]) {
        guard settings.enabled, !targetIDs.isEmpty else { return }
        MusicMoodLibrary.apply(settings, targetIDs: targetIDs, context: context, states: &states)
    }
}

/// Mood implementations (baseline: gentle hue drift with level-following intensity).
public enum MusicMoodLibrary {
    public static func apply(_ settings: MusicModeSettings, targetIDs: [UUID], context: EffectContext,
                             states: inout [UUID: FixtureState]) {
        let a = context.audio
        let byID = Dictionary(context.fixtures.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in targetIDs {
            guard let rf = byID[id], rf.fixture.limits.allowEffects else { continue }
            let g = context.geometry[id]?.center ?? .zero
            let hue = wrapDegrees(200 + 80 * sin(context.time * 0.1 + g.x * 3))
            let level = a.isActive ? lerp(0.35, 1, a.level * settings.reactivity + (1 - settings.reactivity) * 0.6) : 0.5
            var s = states[id] ?? FixtureState()
            s.color = .rgb(RGB(hue: hue, saturation: 0.9, value: 1))
            s.cells = nil
            s.intensity = clamp01(level * settings.brightness)
            states[id] = s
        }
    }
}
