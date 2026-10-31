import Foundation

public struct TimedValue: Codable, Equatable {
    public var t: Double
    public var value: Double

    public init(t: Double, value: Double) {
        self.t = t
        self.value = value
    }
}

/// Cumulative since the workout start (CMPedometer semantics).
public struct PedometerSample: Codable, Equatable {
    public var t: Double
    public var steps: Double
    public var distance: Double?

    public init(t: Double, steps: Double, distance: Double? = nil) {
        self.t = t
        self.steps = steps
        self.distance = distance
    }
}

public struct SegmentResult: Codable, Equatable {
    public var index: Int
    public var kind: SegmentKind
    public var movement: String
    public var title: String
    public var start: Double
    public var end: Double
    public var duration: Double
    public var heartRateAvg: Double?
    public var heartRateMax: Double?
    public var steps: Double?
    public var distance: Double?
    public var cadence: Double?
    public var paceSecondsPerKm: Double?
    /// Lowest HR sample with start ≤ t < end (useful for rest recovery). Optional in JSON.
    public var heartRateMin: Double?

    public init(index: Int, kind: SegmentKind, movement: String, title: String,
                start: Double, end: Double, duration: Double,
                heartRateAvg: Double? = nil, heartRateMax: Double? = nil,
                steps: Double? = nil, distance: Double? = nil,
                cadence: Double? = nil, paceSecondsPerKm: Double? = nil,
                heartRateMin: Double? = nil) {
        self.index = index
        self.kind = kind
        self.movement = movement
        self.title = title
        self.start = start
        self.end = end
        self.duration = duration
        self.heartRateAvg = heartRateAvg
        self.heartRateMax = heartRateMax
        self.steps = steps
        self.distance = distance
        self.cadence = cadence
        self.paceSecondsPerKm = paceSecondsPerKm
        self.heartRateMin = heartRateMin
    }
}

/// Heart rate on a fixed grid: `bpm[k]` is the value for [start + k·interval, start + (k+1)·interval),
/// nil (JSON null) where the watch had no reading. `start` is seconds since 1970.
public struct HeartRateSeries: Codable, Equatable {
    public var start: Double
    public var interval: Double
    public var bpm: [Double?]

    public init(start: Double, interval: Double, bpm: [Double?]) {
        self.start = start
        self.interval = interval
        self.bpm = bpm
    }

    /// Time (seconds since 1970) of the centre of bucket k.
    public func centre(_ k: Int) -> Double {
        return start + (Double(k) + 0.5) * interval
    }

    /// Value of the bucket containing t (seconds since 1970), nil outside or in a gap.
    public func value(at t: Double) -> Double? {
        if interval <= 0 || t < start { return nil }
        let k: Int = Int(((t - start) / interval).rounded(.down))
        if k < 0 || k >= bpm.count { return nil }
        return bpm[k]
    }

    /// Builds the series for [start, end) from raw samples (any order; samples outside
    /// [start, end] are ignored). n = ceil((end − start) / interval) buckets.
    /// Rule per bucket k (centre c):
    /// 1. one or more samples inside the bucket → their mean;
    /// 2. otherwise the nearest sample before and the nearest after c (from the samples kept):
    ///    both within `maxGap` of c → linear interpolation at c; only one within `maxGap` →
    ///    that value (carry forward / back);
    /// 3. otherwise nil (a gap).
    /// Values are rounded to 0.1 bpm to keep the JSON small.
    public static func make(samples: [TimedValue], start: Double, end: Double,
                            interval: Double = 5, maxGap: Double = 15) -> HeartRateSeries {
        if interval <= 0 || !(end > start) {
            return HeartRateSeries(start: start, interval: interval, bpm: [])
        }
        let n: Int = Int(((end - start) / interval).rounded(.up))
        let kept: [TimedValue] = samples
            .filter({ (s: TimedValue) -> Bool in s.t >= start && s.t <= end && s.value.isFinite })
            .sorted(by: { (a: TimedValue, b: TimedValue) -> Bool in a.t < b.t })
        var out: [Double?] = []
        out.reserveCapacity(n)
        var j: Int = 0   // first kept sample with t >= bucket start
        for k in 0..<n {
            let lo: Double = start + Double(k) * interval
            let hi: Double = lo + interval
            let c: Double = lo + 0.5 * interval
            while j < kept.count && kept[j].t < lo { j += 1 }
            var sum: Double = 0
            var count: Int = 0
            var m: Int = j
            while m < kept.count && (kept[m].t < hi || (k == n - 1 && kept[m].t <= hi)) {
                sum += kept[m].value
                count += 1
                m += 1
            }
            if count > 0 {
                out.append(roundTenth(sum / Double(count)))
                continue
            }
            // No sample inside: neighbours are kept[j - 1] (before lo) and kept[j] (at/after hi).
            var before: TimedValue? = nil
            var after: TimedValue? = nil
            if j > 0 && c - kept[j - 1].t <= maxGap { before = kept[j - 1] }
            if j < kept.count && kept[j].t - c <= maxGap { after = kept[j] }
            if let b = before, let a = after {
                let span: Double = a.t - b.t
                let v: Double = span > 0 ? b.value + (a.value - b.value) * (c - b.t) / span : b.value
                out.append(roundTenth(v))
            } else if let b = before {
                out.append(roundTenth(b.value))
            } else if let a = after {
                out.append(roundTenth(a.value))
            } else {
                out.append(nil)
            }
        }
        return HeartRateSeries(start: start, interval: interval, bpm: out)
    }

    private static func roundTenth(_ v: Double) -> Double {
        return (v * 10).rounded() / 10
    }
}

public enum SplitStats {
    /// Pedometer interpolation: linear between samples; before the first sample linear from
    /// (startTime, 0); after the last, the last value. Nil stats when there is no data.
    public static func compute(progress: WorkoutProgress, now: Double,
                               heartRates: [TimedValue],
                               pedometer: [PedometerSample]) -> [SegmentResult] {
        let origin: Double = progress.startTime ?? now
        let stepPoints: [(Double, Double)] = pedometer
            .sorted(by: { (a: PedometerSample, b: PedometerSample) -> Bool in a.t < b.t })
            .map({ (p: PedometerSample) -> (Double, Double) in (p.t, p.steps) })
        var distPoints: [(Double, Double)] = []
        for p in pedometer.sorted(by: { (a: PedometerSample, b: PedometerSample) -> Bool in a.t < b.t }) {
            if let d = p.distance { distPoints.append((p.t, d)) }
        }

        var out: [SegmentResult] = []
        for split in progress.splits(now: now) {
            let seg: WorkoutSegment? = split.index < progress.definition.segments.count
                ? progress.definition.segments[split.index] : nil
            let kind: SegmentKind = seg?.kind ?? .station
            let movement: String = seg?.movement ?? ""
            let title: String = seg?.title ?? "Segment \(split.index + 1)"

            var hrSum: Double = 0
            var hrCount: Int = 0
            var hrMax: Double? = nil
            var hrMin: Double? = nil
            for h in heartRates where h.t >= split.start && h.t < split.end {
                hrSum += h.value
                hrCount += 1
                if let m = hrMax { hrMax = max(m, h.value) } else { hrMax = h.value }
                if let m = hrMin { hrMin = min(m, h.value) } else { hrMin = h.value }
            }
            let hrAvg: Double? = hrCount > 0 ? hrSum / Double(hrCount) : nil

            var steps: Double? = nil
            if !stepPoints.isEmpty {
                steps = interpolate(stepPoints, at: split.end, origin: origin)
                    - interpolate(stepPoints, at: split.start, origin: origin)
            }
            var distance: Double? = nil
            if !distPoints.isEmpty {
                distance = interpolate(distPoints, at: split.end, origin: origin)
                    - interpolate(distPoints, at: split.start, origin: origin)
            }
            let duration: Double = split.duration
            var cadence: Double? = nil
            if let s = steps, duration > 0 {
                cadence = s / duration * 60.0
            }
            var pace: Double? = nil
            if kind == .run, let d = distance, d > 50 {
                pace = duration / (d / 1000.0)
            }
            out.append(SegmentResult(index: split.index, kind: kind, movement: movement, title: title,
                                     start: split.start, end: split.end, duration: duration,
                                     heartRateAvg: hrAvg, heartRateMax: hrMax,
                                     steps: steps, distance: distance,
                                     cadence: cadence, paceSecondsPerKm: pace,
                                     heartRateMin: hrMin))
        }
        return out
    }

    /// Linear interpolation of a cumulative series (points sorted by time, non-empty).
    static func interpolate(_ pts: [(Double, Double)], at t: Double, origin: Double) -> Double {
        let first: (Double, Double) = pts[0]
        if t <= first.0 {
            if first.0 <= origin { return first.1 }
            if t <= origin { return 0 }
            return first.1 * (t - origin) / (first.0 - origin)
        }
        let last: (Double, Double) = pts[pts.count - 1]
        if t >= last.0 { return last.1 }
        for i in 1..<pts.count {
            let a: (Double, Double) = pts[i - 1]
            let b: (Double, Double) = pts[i]
            if t <= b.0 {
                if b.0 == a.0 { return b.1 }
                return a.1 + (b.1 - a.1) * (t - a.0) / (b.0 - a.0)
            }
        }
        return last.1
    }
}

public struct WorkoutResult: Codable, Equatable, Identifiable {
    /// Version written by this build. 2 adds `heartRateSeries`, `heartRateMin` per segment and
    /// `definition.roundSize` (all optional); version 1 files decode unchanged. `partialReps`
    /// and `editedAt` (§5) are optional too and need no version bump.
    public static let currentVersion: Int = 2

    public var version: Int
    public var id: UUID
    public var definition: WorkoutDefinition
    public var startDate: Date
    public var finishDate: Date?
    public var endDate: Date
    public var totalSeconds: Double
    public var segments: [SegmentResult]
    public var events: [WorkoutEvent]
    public var heartRateAvg: Double?
    public var heartRateMax: Double?
    public var recordingFileName: String?
    /// HR every 5 s from the start to the finish (or end). Nil in version 1 files.
    public var heartRateSeries: HeartRateSeries?
    /// Reps done in the segment that was cut by the cap / end (WORKOUT_SPEC §5). Optional in
    /// JSON (absent in older files); set on the watch or with `setPartialReps(_:now:)`.
    public var partialReps: Int?
    /// When the athlete corrected the result (splits or partial reps) on the phone. Optional.
    public var editedAt: Date?

    public init(version: Int = WorkoutResult.currentVersion, id: UUID = UUID(), definition: WorkoutDefinition,
                startDate: Date, finishDate: Date?, endDate: Date, totalSeconds: Double,
                segments: [SegmentResult], events: [WorkoutEvent],
                heartRateAvg: Double? = nil, heartRateMax: Double? = nil,
                recordingFileName: String? = nil, heartRateSeries: HeartRateSeries? = nil,
                partialReps: Int? = nil, editedAt: Date? = nil) {
        self.version = version
        self.id = id
        self.definition = definition
        self.startDate = startDate
        self.finishDate = finishDate
        self.endDate = endDate
        self.totalSeconds = totalSeconds
        self.segments = segments
        self.events = events
        self.heartRateAvg = heartRateAvg
        self.heartRateMax = heartRateMax
        self.recordingFileName = recordingFileName
        self.heartRateSeries = heartRateSeries
        self.partialReps = partialReps
        self.editedAt = editedAt
    }

    /// Pretty JSON, ISO8601 dates (same helpers as LiftRecording).
    public func encoded() throws -> Data {
        let encoder: JSONEncoder = BarPathJSON.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> WorkoutResult {
        return try BarPathJSON.makeDecoder().decode(WorkoutResult.self, from: data)
    }

    public var runSeconds: Double {
        var sum: Double = 0
        for s in segments where s.kind == .run { sum += s.duration }
        return sum
    }

    public var stationSeconds: Double {
        var sum: Double = 0
        for s in segments where s.kind != .run { sum += s.duration }
        return sum
    }
}
