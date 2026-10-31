import Foundation

/// Result corrections (WORKOUT_SPEC §5): moving a split boundary after a Crown mix-up, and the
/// reps done in the segment that was cut by the cap. Mirrored in tools/barpath/workout.py
/// (`move_segment_start`, `set_partial_reps`).
extension WorkoutResult {
    /// Moves the boundary between segment index-1 and index to `start` (s since 1970).
    /// Valid only for 1 ≤ index < segments.count; clamps to [segments[index-1].start + 1,
    /// segments[index].end − 1]. Updates start/end/duration of both segments, recomputes
    /// their heart-rate avg/max/min from heartRateSeries when present, and splits
    /// steps/distance between the two pro rata by time (cadence/pace recomputed; pace only for
    /// runs). Sets editedAt = now. Returns false if index is out of range.
    ///
    /// Details: indices are positions in `segments` (stored in race order). When the two
    /// segments together are shorter than 2 s the boundary goes to their midpoint. A
    /// non-finite `start` is rejected (false, nothing changed). Without a heart-rate series
    /// the two segments keep their HR values.
    @discardableResult
    public mutating func moveSegmentStart(index: Int, to start: Double, now: Date = Date()) -> Bool {
        if index < 1 || index >= segments.count { return false }
        if !start.isFinite { return false }
        var a: SegmentResult = segments[index - 1]
        var b: SegmentResult = segments[index]

        let lo: Double = a.start + 1
        let hi: Double = b.end - 1
        var t: Double = start
        if hi < lo {
            t = (a.start + b.end) / 2
        } else {
            t = Swift.min(Swift.max(t, lo), hi)
        }

        a.end = t
        a.duration = t - a.start
        b.start = t
        b.duration = b.end - t

        // Steps and distance: the pair's total, shared by time.
        let span: Double = b.end - a.start
        let shareA: Double = span > 0 ? a.duration / span : 0.5
        if a.steps != nil || b.steps != nil {
            let total: Double = (a.steps ?? 0) + (b.steps ?? 0)
            let sa: Double = total * shareA
            a.steps = sa
            b.steps = total - sa
        }
        if a.distance != nil || b.distance != nil {
            let total: Double = (a.distance ?? 0) + (b.distance ?? 0)
            let da: Double = total * shareA
            a.distance = da
            b.distance = total - da
        }
        WorkoutResult.refreshRates(&a)
        WorkoutResult.refreshRates(&b)

        if let series = heartRateSeries {
            WorkoutResult.applyHeartRate(&a, series: series)
            WorkoutResult.applyHeartRate(&b, series: series)
        }

        segments[index - 1] = a
        segments[index] = b
        editedAt = now
        return true
    }

    /// Sets partialReps (nil or 0…target of the last segment's reps; clamped) and editedAt.
    /// Without a reps target on the last segment only the lower bound (0) applies.
    public mutating func setPartialReps(_ reps: Int?, now: Date = Date()) {
        if let r = reps {
            var v: Int = Swift.max(0, r)
            if let limit = partialRepsLimit {
                v = Swift.min(v, limit)
            }
            partialReps = v
        } else {
            partialReps = nil
        }
        editedAt = now
    }

    /// Upper bound for `partialReps`: the reps target of the last recorded segment, or nil when
    /// that segment has no reps target (or there are no segments).
    public var partialRepsLimit: Int? {
        guard let last = segments.last else { return nil }
        let i: Int = last.index
        if i < 0 || i >= definition.segments.count { return nil }
        guard let target = definition.segments[i].target, target.unit == .reps else { return nil }
        return Swift.max(0, Int(target.value.rounded()))
    }

    /// Heart rate of [from, to) from a 5 s series: the non-null buckets whose centre lies in the
    /// range (mean, max, min). When no bucket centre falls inside (a very short segment), the
    /// bucket containing the midpoint. All nil when there is no value.
    public static func heartRateStats(series: HeartRateSeries, from: Double,
                                      to: Double) -> (avg: Double?, max: Double?, min: Double?) {
        var sum: Double = 0
        var count: Int = 0
        var hi: Double? = nil
        var lo: Double? = nil
        var anyCentre: Bool = false
        if series.interval > 0 {
            for k in 0..<series.bpm.count {
                let c: Double = series.centre(k)
                if c < from || c >= to { continue }
                anyCentre = true
                guard let v = series.bpm[k] else { continue }
                sum += v
                count += 1
                if let m = hi { hi = Swift.max(m, v) } else { hi = v }
                if let m = lo { lo = Swift.min(m, v) } else { lo = v }
            }
        }
        if !anyCentre {
            if let v = series.value(at: (from + to) / 2) {
                return (avg: v, max: v, min: v)
            }
            return (avg: nil, max: nil, min: nil)
        }
        let avg: Double? = count > 0 ? sum / Double(count) : nil
        return (avg: avg, max: hi, min: lo)
    }

    private static func applyHeartRate(_ seg: inout SegmentResult, series: HeartRateSeries) {
        let st: (avg: Double?, max: Double?, min: Double?) = heartRateStats(series: series, from: seg.start,
                                                                             to: seg.end)
        seg.heartRateAvg = st.avg
        seg.heartRateMax = st.max
        seg.heartRateMin = st.min
    }

    /// Cadence from steps and duration; pace (runs only) from distance > 50 m.
    private static func refreshRates(_ seg: inout SegmentResult) {
        if let s = seg.steps, seg.duration > 0 {
            seg.cadence = s / seg.duration * 60.0
        } else {
            seg.cadence = nil
        }
        if seg.kind == .run, let d = seg.distance, d > 50, seg.duration > 0 {
            seg.paceSecondsPerKm = seg.duration / (d / 1000.0)
        } else {
            seg.paceSecondsPerKm = nil
        }
    }
}
