import Foundation

/// Effort: heart rate load of a workout and a day (docs/DESIGN_GUIDELINES.md section 5). Pure;
/// mirrored in tools/barpath/effort.py (parity: Fixtures/effort_cases.json).
///
/// Effort is Edwards TRIMP: minutes in each heart rate zone × the zone number (1-5), from the
/// start to the finish. Zones are shares of max heart rate, and max heart rate is the highest
/// value recorded in the athlete's results (series or stored max).
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
    public static func days(_ results: [WorkoutResult], calendar: Calendar) -> [Day] {
        let maxHeartRate: Double? = highestHeartRate(results)
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
