import Foundation

public enum SetEvent: Equatable, Sendable {
    /// The live rep count went up (count so far in this set).
    case repCounted(Int)
    /// No rep for `setEndGap`: the set is over. Times are on the motion clock; `start`/`end`
    /// include the pre/post-roll, `firstRepStart`/`lastRepEnd` don't.
    case setEnded(start: Double, end: Double, firstRepStart: Double, lastRepEnd: Double, reps: [Rep])
}

/// Live rep counting for strength mode on the watch (mirrors `SetTracker` in
/// tools/barpath/reps.py). RepCounter runs on the last `countWindow` s; a rep is confirmed
/// once its top is `settle` s old (the centred moving averages need that much future, so the
/// live count lags the bar by ~2 s) and is appended, never recomputed, if it starts after the
/// last confirmed rep. The set ends `setEndGap` s after the last *detected* rep (so slow sets
/// are not split), or when its recording would exceed `maxHistory` s.
public struct SetTracker {
    public var config: RepConfig
    /// Seconds without a new rep that end the set.
    public var setEndGap: Double = 6.0
    public var preRoll: Double = 3.0
    public var postRoll: Double = 2.0
    /// While no set is in progress, keep only this much history (s).
    public var idleHistory: Double = 20.0
    /// RepCounter looks at this much recent history (s) per batch.
    public var countWindow: Double = 30.0
    /// Longest set recording (s); a longer set is ended there.
    public var maxHistory: Double = 180.0

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
        let keepFrom: Double
        if let first = liveReps.first {
            keepFrom = max(floorTime, first.start - preRoll)
        } else {
            keepFrom = max(floorTime, latest - idleHistory)
        }
        drop(before: keepFrom)

        var events: [SetEvent] = []
        let reps = countRecent(latest: latest)
        let after = liveReps.last?.end ?? -Double.greatestFiniteMagnitude
        let fresh = reps.filter { $0.start > after }
        let confirmed = fresh.filter { $0.end <= latest - settle }
        if !confirmed.isEmpty {
            liveReps += confirmed
            events.append(.repCounted(liveReps.count))
        }
        if let first = liveReps.first, let last = liveReps.last {
            var lastEnd = last.end
            for r in fresh where r.end > lastEnd {
                lastEnd = r.end
            }
            let tooLong = latest - (first.start - preRoll) >= maxHistory
            if latest - lastEnd >= setEndGap || tooLong {
                events.append(finishSet())
            }
        }
        return events
    }

    /// Ends a set in progress now (session end / Change). Nil if no rep was counted.
    public mutating func flush() -> SetEvent? {
        // Samples of a set that already ended are not counted again.
        drop(before: floorTime)
        if let latest = samples.last?.t {
            let after = liveReps.last?.end ?? -Double.greatestFiniteMagnitude
            liveReps += countRecent(latest: latest).filter { $0.start > after }
        }
        guard !liveReps.isEmpty else { return nil }
        return finishSet()
    }

    private func countRecent(latest: Double) -> [Rep] {
        let from = latest - countWindow
        let start = samples.firstIndex(where: { $0.t >= from }) ?? samples.count
        guard start < samples.count else { return [] }
        return RepCounter.count(MotionSeries(Array(samples[start...])), config: config).reps
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

    private mutating func drop(before t: Double) {
        if let first = samples.first, first.t < t {
            let idx = samples.firstIndex(where: { $0.t >= t }) ?? samples.count
            samples.removeFirst(idx)
        }
    }
}
