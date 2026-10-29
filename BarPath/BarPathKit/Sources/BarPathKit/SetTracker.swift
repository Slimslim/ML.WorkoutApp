import Foundation

public enum SetEvent: Equatable, Sendable {
    /// The live rep count went up (count so far in this set).
    case repCounted(Int)
    /// No rep for `setEndGap`: the set is over. Times are on the motion clock; `start`/`end`
    /// include the pre/post-roll, `firstRepStart`/`lastRepEnd` don't.
    case setEnded(start: Double, end: Double, firstRepStart: Double, lastRepEnd: Double, reps: [Rep])
}

/// Live rep counting for strength mode on the watch. Runs RepCounter on the samples since the
/// end of the previous set; a rep is "confirmed" once its top is `settle` s old (the centred
/// moving averages need that much future), so the live count lags the bar by ~2 s.
public struct SetTracker {
    public var config: RepConfig
    /// Seconds without a new rep that end the set.
    public var setEndGap: Double = 6.0
    public var preRoll: Double = 3.0
    public var postRoll: Double = 2.0
    /// While no set is in progress, keep only this much history (s).
    public var idleHistory: Double = 20.0
    /// Hard cap on the history (s); a longer set is cut at this length.
    public var maxHistory: Double = 90.0

    public private(set) var liveReps: [Rep] = []
    private var samples: [MotionSample] = []
    private var floorTime = -Double.greatestFiniteMagnitude

    public init(config: RepConfig = RepConfig()) {
        self.config = config
    }

    public var settle: Double { return config.detrend / 2 + 0.3 }
    public var latestTime: Double? { return samples.last?.t }
    public var inSet: Bool { return !liveReps.isEmpty }

    public mutating func reset() {
        liveReps = []
        samples = []
        floorTime = -Double.greatestFiniteMagnitude
    }

    /// Samples in [t0, t1] still held (for cutting the set recording).
    public func samples(from t0: Double, to t1: Double) -> [MotionSample] {
        return samples.filter { $0.t >= t0 && $0.t <= t1 }
    }

    /// Feed a batch (monotonic times). Call about once a second.
    public mutating func process(_ batch: [MotionSample]) -> [SetEvent] {
        for s in batch where s.t >= floorTime {
            if let last = samples.last, s.t <= last.t { continue }
            samples.append(s)
        }
        guard let latest = samples.last?.t else { return [] }
        trim(latest: latest)

        var events: [SetEvent] = []
        let all = RepCounter.count(MotionSeries(samples), config: config).reps
        let confirmed = all.filter { $0.end <= latest - settle }
        if confirmed.count > liveReps.count {
            events.append(.repCounted(confirmed.count))
        }
        if confirmed.count >= liveReps.count {
            liveReps = confirmed
        }
        if let last = liveReps.last, latest - last.end >= setEndGap {
            events.append(finishSet())
        }
        return events
    }

    /// Ends a set in progress now (session end / Change). Nil if no rep was counted.
    public mutating func flush() -> SetEvent? {
        guard !samples.isEmpty else { return nil }
        let all = RepCounter.count(MotionSeries(samples), config: config).reps
        if all.count > liveReps.count {
            liveReps = all
        }
        guard !liveReps.isEmpty else { return nil }
        return finishSet()
    }

    private mutating func finishSet() -> SetEvent {
        let reps = liveReps
        let first = reps[0].start
        let last = reps[reps.count - 1].end
        let event = SetEvent.setEnded(start: first - preRoll, end: last + postRoll,
                                      firstRepStart: first, lastRepEnd: last, reps: reps)
        liveReps = []
        // The next set starts after this one's post-roll; older samples are not re-counted.
        floorTime = last + postRoll
        return event
    }

    private mutating func trim(latest: Double) {
        var keepFrom = max(floorTime, latest - (inSet ? maxHistory : idleHistory))
        if inSet {
            // never cut away the set's own pre-roll
            keepFrom = min(keepFrom, max(floorTime, liveReps[0].start - preRoll))
            keepFrom = max(keepFrom, latest - maxHistory)
        }
        if let first = samples.first, first.t < keepFrom {
            let idx = samples.firstIndex(where: { $0.t >= keepFrom }) ?? samples.count
            samples.removeFirst(idx)
        }
    }
}
