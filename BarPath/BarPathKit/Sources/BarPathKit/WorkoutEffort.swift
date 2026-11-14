import Foundation

/// Effort: heart rate load of a workout and a day (docs/DESIGN_GUIDELINES.md section 5). Pure;
/// mirrored in tools/barpath/effort.py (parity: Fixtures/effort_cases.json).
///
/// Effort is Edwards TRIMP: minutes in each heart rate zone × the zone number (1-5), from the
/// start to the finish. Zones are shares of max heart rate; the max in use is
/// `effectiveMaxHeartRate` (manual value, else the larger of the age estimate and the highest
/// sustained value in the athlete's results).
public enum WorkoutEffort {
    /// Lower bound of zones 1-5, as a share of max heart rate.
    public static let zoneFloors: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9]

    /// 0 below zone 1, else 1-5.
    public static func zone(bpm: Double, maxHeartRate: Double) -> Int {
        if maxHeartRate <= 0 { return 0 }
        let share: Double = bpm / maxHeartRate
        return zoneFloors.filter({ (floor: Double) -> Bool in share >= floor }).count
    }

    /// Sum of zone × minutes of the buckets whose centre is before `finish` (seconds since 1970).
    /// Nil when no such bucket has a reading.
    public static func effort(series: HeartRateSeries, finish: Double, maxHeartRate: Double) -> Double? {
        if series.interval <= 0 { return nil }
        var total: Double = 0
        var readings: Int = 0
        for k in 0..<series.bpm.count {
            guard let bpm = series.bpm[k], series.centre(k) < finish else { continue }
            readings += 1
            total += Double(zone(bpm: bpm, maxHeartRate: maxHeartRate)) * series.interval / 60.0
        }
        return readings > 0 ? total : nil
    }

    /// Highest heart rate recorded in any result, from its series or its stored max (results
    /// without a series have only the max). Nil when there is none.
    public static func highestHeartRate(_ results: [WorkoutResult]) -> Double? {
        var best: Double? = nil
        for r in results {
            var values: [Double] = r.heartRateSeries?.bpm.compactMap({ (b: Double?) -> Double? in b }) ?? []
            if let m = r.heartRateMax { values.append(m) }
            for bpm in values {
                if let b = best { best = Swift.max(b, bpm) } else { best = bpm }
            }
        }
        return best
    }

    /// Where the max heart rate in use comes from.
    public enum MaxSource: String, Equatable {
        case manual, age, workouts
    }

    /// The max heart rate in use and where it comes from.
    public struct MaxHeartRate: Equatable {
        public let value: Double
        public let source: MaxSource

        public init(value: Double, source: MaxSource) {
            self.value = value
            self.source = source
        }
    }

    /// The highest heart rate the athlete held, not a spike. A series holds a value every 5 s; a
    /// value counts only if the neighbouring point reaches it too, so the result is the best over
    /// pairs of neighbouring readings of min(a, b) (held for at least ~5 s). A lone optical-sensor
    /// spike counts as its higher neighbour. Results with a series use only the series (their
    /// `heartRateMax` is one sample); results without one (old results) count their stored max.
    /// Nil when there is no data.
    public static func sustainedHeartRate(_ results: [WorkoutResult]) -> Double? {
        var best: Double? = nil
        for r in results {
            if let series = r.heartRateSeries {
                let values: [Double?] = series.bpm
                if values.count < 2 { continue }
                for k in 0..<(values.count - 1) {
                    guard let a = values[k], let b = values[k + 1] else { continue }
                    let low: Double = Swift.min(a, b)
                    if let current = best {
                        if low > current { best = low }
                    } else {
                        best = low
                    }
                }
            } else if let m = r.heartRateMax {
                if let current = best {
                    if m > current { best = m }
                } else {
                    best = m
                }
            }
        }
        return best
    }

    /// Max heart rate in use, or nil when there is no override, no usable birth year and no heart
    /// rate data. A manual value (100-230) wins; else the larger of Tanaka 208 - 0.7 * age (birth
    /// year not after `year`, age at most 100) and `sustainedHeartRate`. Adding results can only
    /// raise the observed part, so new data never lowers the value.
    public static func effectiveMaxHeartRate(results: [WorkoutResult], birthYear: Int?,
                                             override: Double?, year: Int) -> MaxHeartRate? {
        if let o = override, o >= 100.0, o <= 230.0 {
            return MaxHeartRate(value: o, source: MaxSource.manual)
        }
        var estimate: Double? = nil
        if let b = birthYear, b <= year, year - b <= 100 {
            estimate = 208.0 - 0.7 * Double(year - b)
        }
        let observed: Double? = sustainedHeartRate(results)
        if let o = observed, estimate == nil || o > (estimate ?? 0) {
            return MaxHeartRate(value: o, source: MaxSource.workouts)
        }
        if let e = estimate {
            return MaxHeartRate(value: e, source: MaxSource.age)
        }
        return nil
    }

    /// One local day of results.
    public struct Day: Equatable {
        /// "yyyy-MM-dd" in the calendar's time zone.
        public let day: String
        /// Nil when no result of the day has heart rate data.
        public let effort: Double?
        public let minutes: Double
        public let weightKg: Double
    }

    /// One entry per local day, oldest first.
    public static func days(_ results: [WorkoutResult], calendar: Calendar, birthYear: Int? = nil,
                            override: Double? = nil, year: Int = 0) -> [Day] {
        let maxHeartRate: Double? = effectiveMaxHeartRate(results: results, birthYear: birthYear,
                                                          override: override, year: year)?.value
        var byDay: [String: Day] = [:]
        for r in results {
            let c: DateComponents = calendar.dateComponents([.year, .month, .day], from: r.startDate)
            let key: String = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            let old: Day? = byDay[key]
            var effort: Double? = old?.effort
            if let hr = maxHeartRate, let e = r.effort(maxHeartRate: hr) {
                effort = (effort ?? 0) + e
            }
            byDay[key] = Day(day: key, effort: effort,
                             minutes: (old?.minutes ?? 0) + r.totalSeconds / 60.0,
                             weightKg: (old?.weightKg ?? 0) + r.weightLiftedKg)
        }
        return byDay.keys.sorted().compactMap({ (k: String) -> Day? in byDay[k] })
    }
}

extension WorkoutResult {
    public func effort(maxHeartRate: Double) -> Double? {
        guard let series = heartRateSeries else { return nil }
        let finish: Date = finishDate ?? endDate
        return WorkoutEffort.effort(series: series, finish: finish.timeIntervalSince1970,
                                    maxHeartRate: maxHeartRate)
    }

    /// Reps × load of the stations with a known load. A workout that wasn't finished counts its
    /// last segment by `partialReps`. Results can run past the definition (AMRAP): indexes wrap.
    public var weightLiftedKg: Double {
        let planned: [WorkoutSegment] = definition.segments
        if planned.isEmpty { return 0 }
        var total: Double = 0
        for (i, done) in segments.enumerated() {
            let segment: WorkoutSegment = planned[done.index % planned.count]
            guard done.kind == .station, let load = segment.load, let target = segment.target,
                  target.unit == .reps else { continue }
            var reps: Double = target.value
            if i == segments.count - 1 && finishDate == nil {
                reps = Double(partialReps ?? 0)
            }
            total += reps * load.kilograms
        }
        return total
    }
}
