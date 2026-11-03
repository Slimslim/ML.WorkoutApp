import Foundation

/// Heart-rate recovery after the finish (WORKOUT_SPEC §6): how far HR falls 1, 2 and 3 minutes
/// after the last segment, while the watch keeps recording until End. Pure; mirrored in
/// tools/barpath/workout.py (`HeartRateRecovery`).
///
/// Everything is read from the 5 s `HeartRateSeries`:
/// - `heartRateAtFinish`: the highest 5 s value of the buckets that overlap the last
///   `finishWindow` seconds before the finish, including the bucket that holds the finish
///   (HR lags the effort, so the peak is taken rather than one bucket).
/// - HR at +60 / +120 / +180 s: the mean of the non-null buckets whose centre lies within
///   ±`markHalfWindow` of the mark (three 5 s buckets, so one noisy reading doesn't decide).
///   A mark is only reported when the recording reaches it (`coveredSeconds` ≥ mark).
/// - `coveredSeconds`: min(end, end of the series) − finish.
/// `make` returns nil when less than `minimumSeconds` were recorded after the finish, when
/// there is no HR at the finish, or when no mark has a value.
public struct HeartRateRecovery: Equatable {
    public struct Mark: Equatable, Identifiable {
        /// Seconds after the finish (60, 120, 180).
        public let seconds: Double
        public let heartRate: Double
        /// heartRateAtFinish − heartRate (positive = HR went down).
        public let drop: Double

        public init(seconds: Double, heartRate: Double, drop: Double) {
            self.seconds = seconds
            self.heartRate = heartRate
            self.drop = drop
        }

        /// 1, 2, 3.
        public var minutes: Int { return Int((seconds / 60.0).rounded()) }
        public var id: Double { return seconds }
    }

    /// Marks after the finish, seconds.
    public static let markSeconds: [Double] = [60, 120, 180]
    /// Less than this recorded after the finish: no recovery.
    public static let minimumSeconds: Double = 60
    /// HR at the finish: peak of the buckets overlapping this many seconds before the finish.
    public static let finishWindow: Double = 10
    /// HR at a mark: mean of the buckets whose centre is within ± this of the mark.
    public static let markHalfWindow: Double = 7.5

    /// Seconds since 1970.
    public let finishTime: Double
    public let heartRateAtFinish: Double
    /// Seconds of series recorded after the finish (up to End).
    public let coveredSeconds: Double
    /// The marks that are covered and have a value, in time order.
    public let marks: [Mark]

    public init(finishTime: Double, heartRateAtFinish: Double, coveredSeconds: Double, marks: [Mark]) {
        self.finishTime = finishTime
        self.heartRateAtFinish = heartRateAtFinish
        self.coveredSeconds = coveredSeconds
        self.marks = marks
    }

    /// The mark `minutes` (1…3) after the finish, nil when not covered or in a gap.
    public func mark(minutes: Int) -> Mark? {
        for m in marks where m.minutes == minutes { return m }
        return nil
    }

    /// HRR1 / HRR2 / HRR3 in bpm (drop since the finish), nil when not available.
    public var drop1: Double? { return mark(minutes: 1)?.drop }
    public var drop2: Double? { return mark(minutes: 2)?.drop }
    public var drop3: Double? { return mark(minutes: 3)?.drop }

    // MARK: Building

    /// Recovery from a series that runs past the finish (see the type comment). `finish` and
    /// `end` are seconds since 1970.
    public static func make(series: HeartRateSeries, finish: Double, end: Double) -> HeartRateRecovery? {
        if series.interval <= 0 || series.bpm.isEmpty || !finish.isFinite || !end.isFinite { return nil }
        let seriesEnd: Double = series.start + Double(series.bpm.count) * series.interval
        let covered: Double = Swift.max(0, Swift.min(end, seriesEnd) - finish)
        if covered < HeartRateRecovery.minimumSeconds { return nil }
        guard let atFinish = HeartRateRecovery.finishHeartRate(series: series, finish: finish) else { return nil }
        var marks: [Mark] = []
        for s in HeartRateRecovery.markSeconds where s <= covered {
            if let v = HeartRateRecovery.heartRate(series: series, around: finish + s) {
                marks.append(Mark(seconds: s, heartRate: v, drop: atFinish - v))
            }
        }
        if marks.isEmpty { return nil }
        return HeartRateRecovery(finishTime: finish, heartRateAtFinish: atFinish, coveredSeconds: covered,
                                 marks: marks)
    }

    /// Highest non-null bucket among those overlapping [finish − finishWindow, finish]
    /// (bucket [lo, hi) with lo ≤ finish and hi > finish − finishWindow). Nil when none.
    public static func finishHeartRate(series: HeartRateSeries, finish: Double) -> Double? {
        if series.interval <= 0 { return nil }
        var best: Double? = nil
        for k in 0..<series.bpm.count {
            let lo: Double = series.start + Double(k) * series.interval
            let hi: Double = lo + series.interval
            if lo > finish || hi <= finish - HeartRateRecovery.finishWindow { continue }
            guard let v = series.bpm[k] else { continue }
            if let b = best { best = Swift.max(b, v) } else { best = v }
        }
        return best
    }

    /// Mean of the non-null buckets whose centre lies in [t − markHalfWindow, t + markHalfWindow).
    /// Nil when there is none.
    public static func heartRate(series: HeartRateSeries, around t: Double) -> Double? {
        if series.interval <= 0 { return nil }
        let from: Double = t - HeartRateRecovery.markHalfWindow
        let to: Double = t + HeartRateRecovery.markHalfWindow
        var sum: Double = 0
        var count: Int = 0
        for k in 0..<series.bpm.count {
            let c: Double = series.centre(k)
            if c < from || c >= to { continue }
            guard let v = series.bpm[k] else { continue }
            sum += v
            count += 1
        }
        return count > 0 ? sum / Double(count) : nil
    }
}

extension WorkoutResult {
    /// Recovery after the finish, from `heartRateSeries` (which runs to End since 2026-11-01).
    /// Nil when the workout wasn't finished, there is no series, or less than 60 s were
    /// recorded after the finish (older files stop the series at the finish).
    public var heartRateRecovery: HeartRateRecovery? {
        guard let finish = finishDate, let series = heartRateSeries else { return nil }
        return HeartRateRecovery.make(series: series, finish: finish.timeIntervalSince1970,
                                      end: endDate.timeIntervalSince1970)
    }

    /// True when the series stops at least one 5 s bucket before End (results written before
    /// the series ran to End). Their session CSV can fill the tail (`backfillingHeartRate`).
    public var needsHeartRateBackfill: Bool {
        guard let series = heartRateSeries, series.interval > 0 else { return false }
        let seriesEnd: Double = series.start + Double(series.bpm.count) * series.interval
        return seriesEnd + series.interval <= endDate.timeIntervalSince1970
    }

    /// A copy whose series is extended to End with `samples` (seconds since 1970, e.g. from
    /// `SessionCSV.heartRateSamples`). The existing buckets stay as they are; the new ones are
    /// built exactly like the watch does (`HeartRateSeries.make` on the same grid, from the
    /// series start to End), so the tail matches what a newer watch build would have written.
    /// Nil when nothing needs or can be added (no series, already to End, or every new bucket
    /// would be null). Does not set `editedAt` (this is recorded data, not a correction).
    public func backfillingHeartRate(samples: [TimedValue]) -> WorkoutResult? {
        guard needsHeartRateBackfill, let series = heartRateSeries else { return nil }
        let full: HeartRateSeries = HeartRateSeries.make(samples: samples, start: series.start,
                                                         end: endDate.timeIntervalSince1970,
                                                         interval: series.interval)
        if full.bpm.count <= series.bpm.count { return nil }
        let tail: [Double?] = Array(full.bpm[series.bpm.count...])
        if !tail.contains(where: { (v: Double?) -> Bool in v != nil }) { return nil }
        var copy: WorkoutResult = self
        copy.heartRateSeries = HeartRateSeries(start: series.start, interval: series.interval,
                                               bpm: series.bpm + tail)
        return copy
    }
}

extension WorkoutResult {
    /// What the phone stores when a result arrives from the watch for an id it already has
    /// (W6: after End the watch keeps recording HR to finish + 3:00 in the background, then
    /// sends the same workout again with the longer `heartRateSeries` and a later `endDate`).
    /// `existing` is the phone's copy; `existingWasChanged` is true when the phone wrote it
    /// (an edit, the definition upgrade or the CSV backfill: `<id>.original.json` exists).
    /// Returns the result to write as `<id>.json`, or nil to keep `existing` as it is:
    /// - `incoming` ends before `existing` (an older copy arriving late): nil;
    /// - `existing` untouched by the phone: `incoming`, as before;
    /// - `existing` changed on the phone and `incoming` ends later: `existing` with only the
    ///   HR series and `endDate` taken over (like the CSV backfill), so edits are kept;
    /// - `existing` changed and `incoming` is not newer (a re-sent copy): nil.
    public static func storedAfterWatchUpdate(existing: WorkoutResult, incoming: WorkoutResult,
                                              existingWasChanged: Bool) -> WorkoutResult? {
        if incoming.endDate < existing.endDate { return nil }
        if !existingWasChanged { return incoming }
        if !(incoming.endDate > existing.endDate) { return nil }
        guard let series = incoming.heartRateSeries else { return nil }
        var merged: WorkoutResult = existing
        merged.heartRateSeries = series
        merged.endDate = incoming.endDate
        return merged
    }
}

extension SessionCSV {
    /// Heart-rate samples from a workout session CSV: every `# event t=<s> name=hr bpm=<n>`
    /// line, with t (seconds since the CSV's `startDate` in the `# barpath-session` header)
    /// turned into seconds since 1970. Only `#` lines are looked at (motion rows are skipped
    /// without parsing). Empty when there is no header startDate. In file order.
    public static func heartRateSamples(_ text: String) -> [TimedValue] {
        var origin: Double? = nil
        var relative: [TimedValue] = []
        text.enumerateLines { (rawLine: String, stop: inout Bool) in
            guard rawLine.hasPrefix("#") else { return }
            let body: String = String(rawLine.dropFirst()).trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("barpath-session") {
                for part in body.split(separator: ",") {
                    let item: String = part.trimmingCharacters(in: .whitespaces)
                    if item.hasPrefix("startDate=") {
                        let value: String = String(item.dropFirst("startDate=".count))
                        if let d = BarPathJSON.parseDate(value) {
                            origin = d.timeIntervalSince1970
                        }
                    }
                }
                return
            }
            guard body.hasPrefix("event ") else { return }
            var t: Double? = nil
            var bpm: Double? = nil
            var isHeartRate: Bool = false
            for token in body.split(separator: " ") {
                if token.hasPrefix("t=") {
                    t = Double(token.dropFirst(2))
                } else if token == "name=hr" {
                    isHeartRate = true
                } else if token.hasPrefix("bpm=") {
                    bpm = Double(token.dropFirst(4))
                }
            }
            if isHeartRate, let tv = t, let bv = bpm, tv.isFinite, bv.isFinite {
                relative.append(TimedValue(t: tv, value: bv))
            }
        }
        guard let o = origin else { return [] }
        return relative.map({ (s: TimedValue) -> TimedValue in TimedValue(t: o + s.t, value: s.value) })
    }
}
