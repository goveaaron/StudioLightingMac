import Foundation

/// Global safety settings applied at render time regardless of who asked for what.
public struct SafetySettings: Codable, Hashable, Sendable {
    /// Hard cap on strobe rate (Hz). Photosensitivity guidance: ≤ 3 flashes/second.
    public var maxStrobeHz: Double
    /// When true, flashy effects are slowed/smoothed to stay under 3 flashes per second.
    public var photosensitiveSafe: Bool

    public init(maxStrobeHz: Double = 12, photosensitiveSafe: Bool = true) {
        self.maxStrobeHz = maxStrobeHz
        self.photosensitiveSafe = photosensitiveSafe
    }

    public var effectiveMaxStrobeHz: Double { photosensitiveSafe ? min(maxStrobeHz, 3) : maxStrobeHz }
}

/// Normalized geometry of a fixture on the stage, used by spatial effects, gradients,
/// music moods and region selectors. All coordinates are 0…1 across the stage bounds
/// (x → right, y → down).
public struct FixtureGeometry: Sendable, Hashable {
    public var center: SIMDPoint
    /// One position per pixel/cell (empty when the mode has no pixels).
    public var cellPositions: [SIMDPoint]
    /// Unit direction along the fixture (cell 0 → last cell).
    public var axis: SIMDPoint

    public init(center: SIMDPoint, cellPositions: [SIMDPoint], axis: SIMDPoint) {
        self.center = center; self.cellPositions = cellPositions; self.axis = axis
    }
}

/// Minimal 2D point (keeps PrismCore free of CoreGraphics so it builds on Linux).
public struct SIMDPoint: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static let zero = SIMDPoint(0, 0)
}

public enum SpatialLayout {
    /// Computes normalized geometry for each fixture from stage transforms.
    public static func compute(fixtures: [ResolvedFixture], stage: StageSettings) -> [UUID: FixtureGeometry] {
        let w = max(stage.width, 0.1), h = max(stage.height, 0.1)
        var out: [UUID: FixtureGeometry] = [:]
        for rf in fixtures {
            let t = rf.fixture.transform
            let rad = t.rotation * .pi / 180
            let ax = cos(rad), ay = sin(rad)
            let length = rf.visualLengthMeters * t.scale
            var cells: [SIMDPoint] = []
            let n = rf.cellCount
            if n > 0 {
                cells.reserveCapacity(n)
                for i in 0..<n {
                    let u = n == 1 ? 0.5 : (Double(i) + 0.5) / Double(n)
                    var along = (u - 0.5) * length
                    if rf.fixture.reversePixels { along = -along }
                    let px = t.x + ax * along, py = t.y + ay * along
                    cells.append(SIMDPoint(px / w, py / h))
                }
            }
            out[rf.id] = FixtureGeometry(center: SIMDPoint(t.x / w, t.y / h), cellPositions: cells,
                                         axis: SIMDPoint(rf.fixture.reversePixels ? -ax : ax, rf.fixture.reversePixels ? -ay : ay))
        }
        return out
    }

    /// Computes per-fixture crossfade delays ("wave across the room" by stage position).
    public static func delays(for fixtureIDs: [UUID], fixtures: [ResolvedFixture], stage: StageSettings,
                              totalDelay: Double, direction: EffectDirection = .leftToRight,
                              explicitDelays: [UUID: Double] = [:]) -> [UUID: Double] {
        var result: [UUID: Double] = [:]
        let clampedTotal = clamp(totalDelay.finiteOr(0), 0, 60)
        if clampedTotal > 0, fixtureIDs.count > 1 {
            let geo = compute(fixtures: fixtures, stage: stage)
            let byID = Dictionary(fixtures.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var coords: [(UUID, Double)] = []
            coords.reserveCapacity(fixtureIDs.count)
            for id in fixtureIDs {
                let p = geo[id]?.center ?? byID[id].map {
                    SIMDPoint($0.fixture.transform.x / max(stage.width, 0.1), $0.fixture.transform.y / max(stage.height, 0.1))
                } ?? SIMDPoint(0.5, 0.5)
                let metric: Double
                switch direction {
                case .leftToRight: metric = p.x
                case .rightToLeft: metric = -p.x
                case .topToBottom: metric = p.y
                case .bottomToTop: metric = -p.y
                case .outward:
                    let dx = p.x - 0.5, dy = p.y - 0.5
                    metric = (dx * dx + dy * dy).squareRoot()
                case .inward:
                    let dx = p.x - 0.5, dy = p.y - 0.5
                    metric = -(dx * dx + dy * dy).squareRoot()
                case .random:
                    var h: UInt64 = 1469598103934665603
                    for b in id.uuidString.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
                    metric = Double(h % 10000) / 10000.0
                }
                coords.append((id, metric))
            }
            let lo = coords.map(\.1).min() ?? 0
            let hi = coords.map(\.1).max() ?? 1
            let span = hi - lo
            for (id, m) in coords {
                let u = span > 1e-6 ? clamp01((m - lo) / span) : 0
                result[id] = u * clampedTotal
            }
        }
        for (id, d) in explicitDelays {
            result[id] = clamp(d.finiteOr(0), 0, 60)
        }
        return result
    }
}

/// Immutable description of everything the engine needs to render frames.
/// Built on the main thread by the show controller whenever the show changes.
public struct ShowSnapshot: Sendable {
    public var fixtures: [ResolvedFixture]
    public var geometry: [UUID: FixtureGeometry]
    public var groups: [FixtureGroup]
    public var stage: StageSettings
    public var live: LiveState
    public var safety: SafetySettings
    /// Monotonic revision number (for change detection).
    public var revision: Int

    public init(fixtures: [ResolvedFixture] = [], groups: [FixtureGroup] = [], stage: StageSettings = StageSettings(),
                live: LiveState = LiveState(), safety: SafetySettings = SafetySettings(), revision: Int = 0) {
        self.fixtures = fixtures
        self.geometry = SpatialLayout.compute(fixtures: fixtures, stage: stage)
        self.groups = groups
        self.stage = stage
        self.live = live
        self.safety = safety
        self.revision = revision
    }

    public init(document: ShowDocument, library: ((String) -> FixtureDefinition?)? = nil,
                safety: SafetySettings = SafetySettings(), revision: Int = 0) {
        self.init(fixtures: document.project.resolvedFixtures(library: library), groups: document.project.groups,
                  stage: document.project.stage, live: document.live, safety: safety, revision: revision)
    }

    public static let empty = ShowSnapshot()
}

/// The result of one engine frame.
public struct RenderedFrame: Sendable {
    /// PrismClock time of this frame.
    public var time: Double
    public var frameNumber: UInt64
    /// Final device-independent state per fixture (after fades, effects, music, masters).
    /// Use this to draw the visualizer — it is exactly what the lights are doing.
    public var states: [UUID: FixtureState]
    /// States after fades, effects, and music, before grand master, blackout, and identify flashes.
    /// Used as the seamless starting point when a new fade interrupts an in-progress fade.
    public var preMasterStates: [UUID: FixtureState]
    /// DMX data per universe (1-based universe → 512 bytes).
    public var universes: [Int: [UInt8]]
    /// Overall crossfade progress 0…1 if any fade is currently active, otherwise `nil`.
    public var fadeProgress: Double?

    public var isFading: Bool { fadeProgress != nil }

    public init(time: Double = 0, frameNumber: UInt64 = 0, states: [UUID: FixtureState] = [:],
                preMasterStates: [UUID: FixtureState]? = nil, universes: [Int: [UInt8]] = [:],
                fadeProgress: Double? = nil) {
        self.time = time
        self.frameNumber = frameNumber
        self.states = states
        self.preMasterStates = preMasterStates ?? states
        self.universes = universes
        self.fadeProgress = fadeProgress
    }

    public static let empty = RenderedFrame()
}
