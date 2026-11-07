import Foundation

/// Context passed to effect and music renderers each frame.
public struct EffectContext: Sendable {
    public var time: Double
    public var fixtures: [ResolvedFixture]
    public var geometry: [UUID: FixtureGeometry]
    public var audio: AudioFeatures
    public var safety: SafetySettings

    public init(time: Double, fixtures: [ResolvedFixture], geometry: [UUID: FixtureGeometry], audio: AudioFeatures, safety: SafetySettings) {
        self.time = time; self.fixtures = fixtures; self.geometry = geometry; self.audio = audio; self.safety = safety
    }
}

/// Applies running software effects on top of the base look.
///
/// Effects are deterministic functions of (time, fixture geometry, parameters, audio), so all
/// fixtures stay perfectly in sync and the visualizer matches the real lights.
public enum EffectEngine {
    /// Apply `effects` (in order) to `states`. `targets` must already be resolved to fixture ids
    /// (see `SelectorResolver`). Fixtures whose `limits.allowEffects` is false are skipped.
    public static func apply(_ effects: [EffectInstance], targets: [UUID: [UUID]], context: EffectContext,
                             states: inout [UUID: FixtureState]) {
        for effect in effects where effect.enabled {
            guard let ids = targets[effect.id], !ids.isEmpty else { continue }
            EffectLibrary.apply(effect, fixtureIDs: ids, context: context, states: &states)
        }
    }
}

/// Implementations of each `EffectKind`. (Baseline: a few effects; the full library is built
/// out in Effects/EffectLibrary*.swift.)
public enum EffectLibrary {
    public static func apply(_ effect: EffectInstance, fixtureIDs: [UUID], context: EffectContext, states: inout [UUID: FixtureState]) {
        let p = effect.params
        let t = context.time * p.speed
        let byID = Dictionary(context.fixtures.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (index, id) in fixtureIDs.enumerated() {
            guard let rf = byID[id], rf.fixture.limits.allowEffects else { continue }
            var s = states[id] ?? FixtureState(intensity: 0)
            let phase = p.phaseSpread * Double(index) / Double(max(fixtureIDs.count, 1))
            switch effect.kind {
            case .breathe, .pulse:
                let wave = 0.5 - 0.5 * cos(2 * .pi * (t * 0.25 + phase))
                let level = lerp(p.minIntensity, p.maxIntensity, lerp(1 - p.amount, 1, wave))
                apply(level: level, color: nil, blend: effect.blend, to: &s)
            case .rainbow, .colorCycle:
                let hue = wrapDegrees(360 * (t * 0.05 + phase))
                apply(level: nil, color: .rgb(RGB(hue: hue, saturation: 1, value: 1)), blend: effect.blend, to: &s)
            default:
                break
            }
            states[id] = s
        }
    }

    static func apply(level: Double?, color: LightColor?, blend: EffectBlend, to s: inout FixtureState) {
        switch blend {
        case .replace:
            if let level { s.intensity = clamp01(level) }
            if let color { s.color = color; s.cells = nil }
        case .intensityOnly:
            if let level { s.intensity = clamp01(s.intensity * level) }
        case .colorOnly:
            if let color { s.color = color; s.cells = nil }
        case .multiply:
            if let level { s.intensity = clamp01(s.intensity * level) }
            if let color { s.color = color; s.cells = nil }
        }
    }
}
