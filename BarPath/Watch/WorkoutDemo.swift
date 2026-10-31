import Foundation
import BarPathKit

/// "Screen demo" (start screen → Screen demo): runs the real workout screen with mock data so
/// the athlete can try the Crown, timers and border without a workout.
///
/// Nothing here touches HealthKit, motion, the CSV or the phone. The model calls these pure
/// helpers when `isDemo` is true:
/// - `demoDefinition`: a copy of the workout with every *clock-driven* time shortened by
///   `timeScale` (timed rests, "every N:00" interval, AMRAP cap), so rest countdowns and the
///   cap happen within seconds. All timers on screen still tick in real seconds.
/// - `runLine`: fake run distance growing so any run reaches its target in
///   `runSecondsPerSegment` (border fills, "Exit soon" shows at ~30 s), with a realistic
///   5:05–5:30 /km pace and ~170 spm cadence.
/// - `HeartRate`: a moving fake HR (135–172 bpm, higher on stations), stepped once a second.
enum WorkoutDemo {
    /// Clock-driven times in the demo definition are divided by this.
    static let timeScale: Double = 6.0
    /// Shortened times are never below this (s), so a countdown is still visible.
    static let minimumScaledSeconds: Double = 10.0
    /// Any run reaches its target distance after this long (s).
    static let runSecondsPerSegment: Double = 35.0
    /// Distance used for a run without a metre target.
    static let defaultRunMeters: Double = 1000.0
    /// Fake distance stops growing at this share of the target.
    static let maxRunFraction: Double = 1.2

    // MARK: Definition

    static func scaled(_ seconds: Double) -> Double {
        let value: Double = (seconds / WorkoutDemo.timeScale).rounded()
        return max(WorkoutDemo.minimumScaledSeconds, value)
    }

    /// The workout with timed rests, the interval and the cap shortened by `timeScale`.
    static func demoDefinition(from definition: WorkoutDefinition) -> WorkoutDefinition {
        var d: WorkoutDefinition = definition
        if let cap = d.timeCapSeconds, cap > 0 {
            d.timeCapSeconds = WorkoutDemo.scaled(cap)
        }
        if let interval = d.intervalSeconds, interval > 0 {
            d.intervalSeconds = WorkoutDemo.scaled(interval)
        }
        var segments: [WorkoutSegment] = []
        for segment in d.segments {
            var s: WorkoutSegment = segment
            if s.kind == .rest, let target = s.target, target.unit == .seconds, target.value > 0 {
                s.target = SegmentTarget(WorkoutDemo.scaled(target.value), .seconds)
            }
            segments.append(s)
        }
        d.segments = segments
        return d
    }

    // MARK: Run

    /// Deterministic pseudo-random 0…1 for an integer second (stable across re-renders).
    static func noise(_ second: Int, salt: Double) -> Double {
        let x: Double = sin(Double(second) * 12.9898 + salt * 78.233) * 43758.5453
        return x - x.rounded(.down)
    }

    /// Run line for a run segment `elapsed` seconds in, at wall time `now`.
    /// @MainActor: builds the model's nested RunLine; only called from the model.
    @MainActor
    static func runLine(segment: WorkoutSegment, elapsed: Double, now: Double) -> WorkoutSessionModel.RunLine {
        var meters: Double = WorkoutDemo.defaultRunMeters
        if let target = segment.target, target.unit == .meters, target.value > 0 {
            meters = target.value
        }
        let fraction: Double = min(WorkoutDemo.maxRunFraction, max(0.0, elapsed / WorkoutDemo.runSecondsPerSegment))
        let second: Int = Int(now.rounded(.down))
        // 5:05–5:30 /km: slow sine around 5:17 plus a little noise.
        let pace: Double = 317.0 + 9.0 * sin(now / 9.0) + (WorkoutDemo.noise(second, salt: 1.0) - 0.5) * 6.0
        let cadence: Double = 170.0 + (WorkoutDemo.noise(second, salt: 2.0) - 0.5) * 6.0
        return WorkoutSessionModel.RunLine(distance: meters * fraction,
                                           paceSecondsPerKm: min(330.0, max(305.0, pace)),
                                           cadence: cadence)
    }

    // MARK: Heart rate

    /// Fake HR that drifts toward a per-segment-kind level, with a slow sine and noise.
    struct HeartRate {
        private(set) var bpm: Double = 138.0

        mutating func step(now: Double, kind: SegmentKind?) -> Double {
            let base: Double
            switch kind {
            case .some(.station):
                base = 162.0
            case .some(.run):
                base = 155.0
            case .some(.rest), .some(.transition):
                base = 141.0
            case .none:
                base = 140.0
            }
            let target: Double = base + 6.0 * sin(now / 20.0) + Double.random(in: -2.5...2.5)
            bpm += (target - bpm) * 0.2
            bpm = min(172.0, max(135.0, bpm))
            return bpm.rounded()
        }
    }
}
