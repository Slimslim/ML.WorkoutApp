import Foundation

// The shared workout timeline (docs/WORKOUT_OVERVIEW_V2.md, "The shared element").
// All times here are seconds from the workout start (relative), not seconds since 1970.

extension WorkoutSummary {

    /// One coloured band behind the curve: one per recorded segment, in race order.
    public struct Band: Equatable, Identifiable {
        public let segmentIndex: Int
        public let kind: SegmentKind
        public let movement: String
        /// Full segment title, e.g. "Run 1000 m", "KB Swings 21".
        public let title: String
        /// Movement name without the target, e.g. "KB Swings".
        public let name: String
        /// "R1"…"R8" for runs (run number), "Ski", "KB", "Pull", "Rest", …
        public let shortLabel: String
        public let start: Double
        public let end: Double
        public let duration: Double
        /// Round (or set) index, 0-based, when the workout has a round size.
        public let round: Int?
        /// Position inside the round, 0-based, when the workout has a round size.
        public let column: Int?
        /// The segment was cut off (AMRAP cap, or the workout was ended without finishing).
        public let isPartial: Bool
        /// As recorded by the watch for this segment (raw samples, not the 5 s grid).
        public let heartRateAvg: Double?
        public let heartRateMax: Double?
        public let heartRateMin: Double?
        /// Runs only (target distance when it is in meters, else measured).
        public let paceSecondsPerKm: Double?

        public var id: Int { return segmentIndex }
    }

    /// A stretch with no heart-rate value (draw hatched, "no HR").
    public struct Gap: Equatable, Identifiable {
        public let start: Double
        public let end: Double
        public var duration: Double { return end - start }
        public var id: Double { return start }
    }

    /// A stretch of consecutive 5 s values in the same zone (1…5). Gaps have no run.
    public struct ZoneRun: Equatable, Identifiable {
        public let zone: Int
        public let start: Double
        public let end: Double
        public var id: Double { return start }
    }

    /// Heart-rate numbers over a time range of the 5 s grid.
    public struct RangeStats: Equatable {
        public let average: Double?
        public let max: Double?
        public let min: Double?
        /// Seconds of the range whose 5 s value is nil.
        public let gapSeconds: Double
        /// Number of non-nil 5 s values used.
        public let count: Int
    }

    /// The heart rate after the finish, drawn after the workout on the same chart
    /// (WORKOUT_SPEC §6). Only when the result has a `HeartRateRecovery` (finished, and at least
    /// 60 s recorded after the finish). Times are relative like the rest of the timeline: the
    /// tail starts at the workout's `duration` (the finish) and second τ after the finish is at
    /// `start + τ`. Nothing here feeds the workout numbers (stats, zones, gaps, low / high).
    public struct RecoveryTail: Equatable {
        /// Relative time of the finish = `Timeline.duration`.
        public let start: Double
        /// start + `coveredSeconds` of the recovery (End, or the end of the series if earlier).
        public let end: Double
        /// Grid step of `heartRate`, seconds (5).
        public let interval: Double
        /// One value per `interval` from the finish (value k covers [start + k·interval,
        /// start + (k+1)·interval), the last one cut at `end`), nil = no reading.
        /// Count = ceil((end − start) / interval).
        public let heartRate: [Double?]
        /// HR at the finish (`HeartRateRecovery.heartRateAtFinish`), the reference for "since finish".
        public let heartRateAtFinish: Double
        /// The +1 / +2 / +3 min marks that are covered and have a value (`HeartRateRecovery.marks`).
        public let marks: [HeartRateRecovery.Mark]
        /// Lowest and highest non-nil value of `heartRate`.
        public let heartRateLow: Double?
        public let heartRateHigh: Double?

        public init(start: Double, end: Double, interval: Double, heartRate: [Double?],
                    heartRateAtFinish: Double, marks: [HeartRateRecovery.Mark],
                    heartRateLow: Double?, heartRateHigh: Double?) {
            self.start = start
            self.end = end
            self.interval = interval
            self.heartRate = heartRate
            self.heartRateAtFinish = heartRateAtFinish
            self.marks = marks
            self.heartRateLow = heartRateLow
            self.heartRateHigh = heartRateHigh
        }

        /// Seconds recorded after the finish.
        public var duration: Double { return end - start }

        /// Relative time of the centre of value k (the last value's centre is the middle of
        /// its shortened stretch, like the workout grid).
        public func time(ofSample k: Int) -> Double {
            return start + WorkoutSummary.bucketCentre(k, interval: interval, duration: duration)
        }

        /// Relative time of a mark (start + mark.seconds).
        public func time(of mark: HeartRateRecovery.Mark) -> Double {
            return start + mark.seconds
        }

        /// True when t lies in the tail: start ≤ t ≤ end.
        public func contains(_ t: Double) -> Bool {
            return t.isFinite && t >= start && t <= end
        }

        /// Index of the value covering t, clamped to the grid; nil when t is before the finish
        /// or the grid is empty.
        public func sampleIndex(at t: Double) -> Int? {
            if heartRate.isEmpty || interval <= 0 || !t.isFinite || t < start { return nil }
            var k: Int = Int(((t - start) / interval).rounded(.down))
            if k >= heartRate.count { k = heartRate.count - 1 }
            if k < 0 { k = 0 }
            return k
        }

        /// Heart rate at relative time t in the tail, nil before the finish or in a gap.
        public func heartRate(at t: Double) -> Double? {
            guard let k = sampleIndex(at: t) else { return nil }
            let values: [Double?] = self.heartRate
            return values[k]
        }

        /// What the chip shows at relative time t: seconds after the finish, HR there and its
        /// change since the finish (negative = went down). Nil outside the tail.
        public func moment(at t: Double) -> RecoveryMoment? {
            if !contains(t) { return nil }
            let hr: Double? = heartRate(at: t)
            var change: Double? = nil
            if let v = hr { change = v - heartRateAtFinish }
            return RecoveryMoment(secondsAfterFinish: t - start, heartRate: hr, change: change)
        }

        /// The tail of a recovery, placed at `start` (the timeline's duration). Values are read
        /// from `series` at finishTime + bucket centre (the same way the workout grid reads it).
        /// Nil when the series has no value anywhere after the finish.
        public static func make(recovery: HeartRateRecovery, series: HeartRateSeries,
                                start: Double) -> RecoveryTail? {
            let interval: Double = WorkoutSummary.timelineInterval
            let covered: Double = recovery.coveredSeconds
            if !(covered > 0) || !start.isFinite { return nil }
            let n: Int = Int((covered / interval).rounded(.up))
            var hr: [Double?] = []
            hr.reserveCapacity(n)
            var low: Double? = nil
            var high: Double? = nil
            for k in 0..<n {
                let c: Double = WorkoutSummary.bucketCentre(k, interval: interval, duration: covered)
                let v: Double? = series.value(at: recovery.finishTime + c)
                if let x = v {
                    low = Swift.min(low ?? x, x)
                    high = Swift.max(high ?? x, x)
                }
                hr.append(v)
            }
            if high == nil { return nil }
            return RecoveryTail(start: start, end: start + covered, interval: interval, heartRate: hr,
                                heartRateAtFinish: recovery.heartRateAtFinish, marks: recovery.marks,
                                heartRateLow: low, heartRateHigh: high)
        }
    }

    /// One moment of the recovery tail (see `RecoveryTail.moment(at:)`).
    public struct RecoveryMoment: Equatable {
        public let secondsAfterFinish: Double
        /// Nil when there is no reading there.
        public let heartRate: Double?
        /// heartRate − heartRateAtFinish (negative = went down), nil without a reading.
        public let change: Double?
    }

    public struct Timeline: Equatable {
        /// Workout length in seconds (start to finish, or to the end if not finished).
        public let duration: Double
        /// Grid step of `heartRate`, seconds (5).
        public let interval: Double
        public let bands: [Band]
        /// One value per `interval` from the start (value k covers [k·interval, (k+1)·interval)),
        /// nil = gap. Count = ceil(duration / interval).
        public let heartRate: [Double?]
        /// True when the result had no `heartRateSeries` (version 1): values are each segment's
        /// average drawn as a flat step. Show "Detailed heart rate not recorded for this workout".
        public let isEstimated: Bool
        /// At least one non-nil value in `heartRate`.
        public let hasHeartRate: Bool
        public let gaps: [Gap]
        public let zones: [ZoneRun]
        /// Seconds spent in zone 1…5 (index 0…4), from `heartRate`.
        public let zoneSeconds: [Double]
        /// Max HR used for the zones.
        public let maxHeartRate: Double
        /// True when no max HR was set (zones use max(190, highest HR in this workout)).
        public let zonesEstimated: Bool
        /// Lower bounds of zones 2…5: 60 / 70 / 80 / 90 % of `maxHeartRate`.
        public let zoneLowerBounds: [Double]
        /// Lowest and highest non-nil value of `heartRate` (for the y axis).
        public let heartRateLow: Double?
        public let heartRateHigh: Double?
        /// HR after the finish, drawn after `duration` (nil for older results, unfinished
        /// workouts or when End came less than 60 s after the finish). Not part of any number above.
        public let recovery: RecoveryTail?

        /// Where the chart's x axis ends: the end of the recovery tail, else `duration`.
        public var chartEnd: Double {
            if let r = recovery { return Swift.max(duration, r.end) }
            return duration
        }

        /// True when t lies in the recovery tail (after the finish). Always false without one.
        public func isRecovery(at t: Double) -> Bool {
            guard let r = recovery else { return false }
            return t >= r.start && t.isFinite
        }

        /// Centre time of grid value k (where to draw the point). The last value may cover a
        /// shorter stretch (up to `duration`); its centre is the middle of that stretch.
        public func time(ofSample k: Int) -> Double {
            return WorkoutSummary.bucketCentre(k, interval: interval, duration: duration)
        }

        /// Index of the 5 s value covering t, clamped to the grid; nil when the grid is empty.
        public func sampleIndex(at t: Double) -> Int? {
            if heartRate.isEmpty || interval <= 0 { return nil }
            var k: Int = 0
            if t > 0 && t.isFinite {
                k = Int((t / interval).rounded(.down))
            }
            if k >= heartRate.count { k = heartRate.count - 1 }
            if k < 0 { k = 0 }
            return k
        }

        /// Heart rate at time t (the 5 s value covering it), nil in a gap.
        public func heartRate(at t: Double) -> Double? {
            guard let k = sampleIndex(at: t) else { return nil }
            let values: [Double?] = self.heartRate
            return values[k]
        }

        /// The band under time t. Before the first band: the first; after the last: the last.
        public func band(at t: Double) -> Band? {
            if bands.isEmpty { return nil }
            if t < bands[0].start { return bands[0] }
            var found: Band? = nil
            for b in bands {
                if t >= b.start && t < b.end { return b }
                if b.start <= t { found = b }
            }
            return found ?? bands[bands.count - 1]
        }

        /// Segment index under time t (see `band(at:)`), nil when there are no bands.
        public func segment(at t: Double) -> Int? {
            return band(at: t)?.segmentIndex
        }

        /// The band of a segment index.
        public func band(segmentIndex: Int) -> Band? {
            for b in bands where b.segmentIndex == segmentIndex { return b }
            return nil
        }

        /// Avg / max / min over the 5 s values whose centre lies in [from, to), plus the
        /// seconds of that range with no value.
        public func stats(from: Double, to: Double) -> RangeStats {
            var sum: Double = 0
            var count: Int = 0
            var hi: Double? = nil
            var lo: Double? = nil
            var gap: Double = 0
            for k in 0..<heartRate.count {
                let c: Double = time(ofSample: k)
                if c < from || c >= to { continue }
                if let v = heartRate[k] {
                    sum += v
                    count += 1
                    if let h = hi { hi = Swift.max(h, v) } else { hi = v }
                    if let l = lo { lo = Swift.min(l, v) } else { lo = v }
                } else {
                    gap += interval
                }
            }
            let avg: Double? = count > 0 ? sum / Double(count) : nil
            return RangeStats(average: avg, max: hi, min: lo, gapSeconds: gap, count: count)
        }

        /// Stats over one segment's band.
        public func stats(segmentIndex: Int) -> RangeStats {
            guard let b = band(segmentIndex: segmentIndex) else {
                return RangeStats(average: nil, max: nil, min: nil, gapSeconds: 0, count: 0)
            }
            return stats(from: b.start, to: b.end)
        }

        /// Zone 1…5 of a heart rate with this timeline's max HR.
        public func zone(for bpm: Double) -> Int {
            return WorkoutSummary.zone(bpm: bpm, maxHeartRate: maxHeartRate)
        }
    }

    /// Middle of [k·interval, min((k+1)·interval, duration)].
    static func bucketCentre(_ k: Int, interval: Double, duration: Double) -> Double {
        let s: Double = Double(k) * interval
        let e: Double = Swift.max(s, Swift.min(Double(k + 1) * interval, duration))
        return (s + e) / 2
    }

    /// Zone 1…5: zone 2 from 60 %, 3 from 70 %, 4 from 80 %, 5 from 90 % of max HR.
    public static func zone(bpm: Double, maxHeartRate: Double) -> Int {
        var z: Int = 1
        for f in zoneFractions where bpm >= f * maxHeartRate { z += 1 }
        return z
    }

    /// Fractions of max HR where zones 2…5 begin.
    public static let zoneFractions: [Double] = [0.6, 0.7, 0.8, 0.9]

    /// Max HR used when none is set (and the workout never went higher).
    public static let defaultMaxHeartRate: Double = 190

    /// Grid step of the timeline, seconds.
    public static let timelineInterval: Double = 5

    // MARK: Building

    static func makeTimeline(ctx: SummaryContext, bands: [Band], maxHeartRate: Double?) -> Timeline {
        let interval: Double = WorkoutSummary.timelineInterval
        let duration: Double = ctx.duration
        let n: Int = duration > 0 ? Int((duration / interval).rounded(.up)) : 0
        var hr: [Double?] = []
        hr.reserveCapacity(n)
        var estimated: Bool = true
        if let series = ctx.result.heartRateSeries, series.interval > 0, !series.bpm.isEmpty {
            estimated = false
            for k in 0..<n {
                let t: Double = ctx.origin + WorkoutSummary.bucketCentre(k, interval: interval, duration: duration)
                hr.append(series.value(at: t))
            }
        } else {
            for k in 0..<n {
                let c: Double = WorkoutSummary.bucketCentre(k, interval: interval, duration: duration)
                var v: Double? = nil
                for b in bands where c >= b.start && c < b.end {
                    v = b.heartRateAvg
                    break
                }
                hr.append(v)
            }
        }

        // Max HR for zones.
        var observed: Double? = ctx.result.heartRateMax
        for v in hr {
            if let x = v { observed = Swift.max(observed ?? x, x) }
        }
        for b in bands {
            if let x = b.heartRateMax { observed = Swift.max(observed ?? x, x) }
        }
        var maxHR: Double = WorkoutSummary.defaultMaxHeartRate
        var zonesEstimated: Bool = true
        if let m = maxHeartRate, m > 0 {
            maxHR = m
            zonesEstimated = false
        } else if let o = observed, o > maxHR {
            maxHR = o
        }

        // Gaps, zone runs, time in zones, range.
        var gaps: [Gap] = []
        var zones: [ZoneRun] = []
        var zoneSeconds: [Double] = [0, 0, 0, 0, 0]
        var low: Double? = nil
        var high: Double? = nil
        var gapStart: Double? = nil
        var runZone: Int? = nil
        var runStart: Double = 0
        for k in 0..<n {
            let s: Double = Double(k) * interval
            let e: Double = Swift.min(Double(k + 1) * interval, duration)
            if let v = hr[k] {
                if let g = gapStart {
                    gaps.append(Gap(start: g, end: s))
                    gapStart = nil
                }
                low = Swift.min(low ?? v, v)
                high = Swift.max(high ?? v, v)
                let z: Int = WorkoutSummary.zone(bpm: v, maxHeartRate: maxHR)
                zoneSeconds[z - 1] += Swift.max(0, e - s)
                if let rz = runZone, rz == z {
                    // continues
                } else {
                    if let rz = runZone { zones.append(ZoneRun(zone: rz, start: runStart, end: s)) }
                    runZone = z
                    runStart = s
                }
            } else {
                if gapStart == nil { gapStart = s }
                if let rz = runZone {
                    zones.append(ZoneRun(zone: rz, start: runStart, end: s))
                    runZone = nil
                }
            }
        }
        if let g = gapStart { gaps.append(Gap(start: g, end: duration)) }
        if let rz = runZone { zones.append(ZoneRun(zone: rz, start: runStart, end: duration)) }

        // Recovery after the finish (its own grid from the finish; no effect on the numbers above).
        var tail: RecoveryTail? = nil
        if duration > 0, let rec = ctx.result.heartRateRecovery, let series = ctx.result.heartRateSeries {
            tail = RecoveryTail.make(recovery: rec, series: series, start: duration)
        }

        let bounds: [Double] = WorkoutSummary.zoneFractions.map({ (f: Double) -> Double in f * maxHR })
        return Timeline(duration: duration, interval: interval, bands: bands, heartRate: hr,
                        isEstimated: estimated, hasHeartRate: high != nil, gaps: gaps, zones: zones,
                        zoneSeconds: zoneSeconds, maxHeartRate: maxHR, zonesEstimated: zonesEstimated,
                        zoneLowerBounds: bounds, heartRateLow: low, heartRateHigh: high,
                        recovery: tail)
    }
}
