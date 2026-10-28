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

    public init(index: Int, kind: SegmentKind, movement: String, title: String,
                start: Double, end: Double, duration: Double,
                heartRateAvg: Double? = nil, heartRateMax: Double? = nil,
                steps: Double? = nil, distance: Double? = nil,
                cadence: Double? = nil, paceSecondsPerKm: Double? = nil) {
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
            for h in heartRates where h.t >= split.start && h.t < split.end {
                hrSum += h.value
                hrCount += 1
                if let m = hrMax { hrMax = max(m, h.value) } else { hrMax = h.value }
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
                                     cadence: cadence, paceSecondsPerKm: pace))
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

    public init(version: Int = 1, id: UUID = UUID(), definition: WorkoutDefinition,
                startDate: Date, finishDate: Date?, endDate: Date, totalSeconds: Double,
                segments: [SegmentResult], events: [WorkoutEvent],
                heartRateAvg: Double? = nil, heartRateMax: Double? = nil,
                recordingFileName: String? = nil) {
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
