import Foundation

/// For-time caps (WORKOUT_SPEC §5b, user story W7): a for-time workout with a cap does not stop
/// at the cap. The athlete is told and keeps going, so `totalSeconds` stays the time for the
/// full workout; the result also says how far the athlete was at the cap (`repsAtCap` in the
/// segment running then). Everything here is derived from the stored fields, so older files
/// that went past a cap read as capped too (with `repsAtCap` nil). AMRAP caps are not this
/// (they finish the workout; see `partialReps`). Mirrored in tools/barpath/workout.py.
extension WorkoutResult {
    /// The definition's cap for a for-time workout (> 0), else nil.
    public var forTimeCapSeconds: Double? {
        guard definition.format == .forTime, let cap = definition.timeCapSeconds, cap > 0 else { return nil }
        return cap
    }

    /// For time and the workout ran past the cap (finished after it, or ended after it).
    public var isCapped: Bool {
        guard let cap = forTimeCapSeconds else { return false }
        return totalSeconds > cap
    }

    /// When the cap was reached (start + cap), nil when not capped.
    public var capReachedAt: Date? {
        guard isCapped, let cap = forTimeCapSeconds else { return nil }
        return startDate.addingTimeInterval(cap)
    }

    /// Definition index of the segment running at the cap: the recorded segment with
    /// start ≤ cap < end, else the last one started at or before the cap; nil when not capped.
    public var capSegmentIndex: Int? {
        guard let at = capReachedAt else { return nil }
        let t: Double = at.timeIntervalSince1970
        var best: Int? = nil
        for s in segments {
            if s.start <= t && t < s.end { return s.index }
            if s.start <= t { best = s.index }
        }
        return best
    }

    /// The definition's segment running at the cap, nil when not capped.
    public var capSegment: WorkoutSegment? {
        guard let i = capSegmentIndex, i >= 0, i < definition.segments.count else { return nil }
        return definition.segments[i]
    }

    /// Upper bound for `repsAtCap`: the reps target of the segment running at the cap, or nil
    /// when it has no reps target (or the workout is not capped).
    public var repsAtCapLimit: Int? {
        guard let segment = capSegment, let target = segment.target, target.unit == .reps else { return nil }
        return Swift.max(0, Int(target.value.rounded()))
    }

    /// Sets repsAtCap (nil or 0…repsAtCapLimit; clamped, only the lower bound without a reps
    /// target) and editedAt.
    public mutating func setRepsAtCap(_ reps: Int?, now: Date = Date()) {
        if let r = reps {
            var v: Int = Swift.max(0, r)
            if let limit = repsAtCapLimit {
                v = Swift.min(v, limit)
            }
            repsAtCap = v
        } else {
            repsAtCap = nil
        }
        editedAt = now
    }

    /// Where the athlete was at the cap: "12/21 KB Swings (R3)", "12 Burpees" (no reps target),
    /// "in Burpees" (reps not entered). The round suffix only for workouts with roundSize > 1.
    /// Nil when not capped. The overview shows it as "at the cap: …" (WorkoutSummary headline).
    public var capPositionText: String? {
        guard let segment = capSegment, let index = capSegmentIndex else { return nil }
        var name: String = segment.name
        if let r = definition.roundSize, r > 1, definition.segments.count > r {
            name += " (R\(index / r + 1))"
        }
        guard let reps = repsAtCap else { return "in " + name }
        if let limit = repsAtCapLimit {
            return "\(reps)/\(limit) " + name
        }
        return "\(reps) " + name
    }
}
