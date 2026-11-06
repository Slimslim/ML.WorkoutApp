import Foundation

public enum AdvanceSource: String, Codable { case crown, press, button, auto, edit }

public enum WorkoutEventKind: String, Codable { case start, advance, undo, finish, unfinish, end }

public struct WorkoutEvent: Codable, Equatable {
    public var t: Double                  // seconds since 1970
    public var kind: WorkoutEventKind
    public var segmentIndex: Int          // current segment index AFTER the event
    public var source: AdvanceSource?

    public init(t: Double, kind: WorkoutEventKind, segmentIndex: Int, source: AdvanceSource? = nil) {
        self.t = t
        self.kind = kind
        self.segmentIndex = segmentIndex
        self.source = source
    }
}

public struct SegmentSplit: Codable, Equatable {
    public var index: Int
    public var start: Double
    public var end: Double
    public var duration: Double { return end - start }

    public init(index: Int, start: Double, end: Double) {
        self.index = index
        self.start = start
        self.end = end
    }
}

public struct WorkoutProgress: Codable, Equatable {
    public let definition: WorkoutDefinition
    public private(set) var segmentStarts: [Double]   // start time of segments 0...currentIndex
    public private(set) var finishTime: Double?
    public private(set) var events: [WorkoutEvent]

    public init(definition: WorkoutDefinition) {
        self.definition = definition
        self.segmentStarts = []
        self.finishTime = nil
        self.events = []
    }

    public var isStarted: Bool { return !segmentStarts.isEmpty }
    public var isFinished: Bool { return finishTime != nil }
    public var currentIndex: Int { return max(0, segmentStarts.count - 1) }

    public var currentSegment: WorkoutSegment? {
        if !isStarted { return nil }
        let i = currentIndex
        if i < definition.segments.count { return definition.segments[i] }
        return nil
    }

    public var nextSegment: WorkoutSegment? {
        if !isStarted || isFinished { return nil }
        let i = currentIndex + 1
        if i < definition.segments.count { return definition.segments[i] }
        return nil
    }

    public var startTime: Double? { return segmentStarts.first }

    /// No-op if already started.
    public mutating func start(at t: Double) {
        if isStarted { return }
        segmentStarts.append(t)
        events.append(WorkoutEvent(t: t, kind: .start, segmentIndex: 0, source: nil))
    }

    /// Moves to the next segment; on the last segment it finishes. Returns false if not
    /// started, already finished, or t is before the current segment's start.
    @discardableResult
    public mutating func advance(at t: Double, source: AdvanceSource) -> Bool {
        guard isStarted, !isFinished, let last = segmentStarts.last else { return false }
        if t < last { return false }
        if currentIndex >= definition.segments.count - 1 {
            finishTime = t
            events.append(WorkoutEvent(t: t, kind: .finish, segmentIndex: currentIndex, source: source))
        } else {
            segmentStarts.append(t)
            events.append(WorkoutEvent(t: t, kind: .advance, segmentIndex: currentIndex, source: source))
        }
        return true
    }

    /// Finished: unfinish. Otherwise back to the previous segment (keeps its start time).
    /// Returns false on segment 0 or before start.
    @discardableResult
    public mutating func undo(at t: Double, source: AdvanceSource) -> Bool {
        if !isStarted { return false }
        if isFinished {
            finishTime = nil
            events.append(WorkoutEvent(t: t, kind: .unfinish, segmentIndex: currentIndex, source: nil))
            return true
        }
        if segmentStarts.count < 2 { return false }
        segmentStarts.removeLast()
        events.append(WorkoutEvent(t: t, kind: .undo, segmentIndex: currentIndex, source: source))
        return true
    }

    /// Finishes the workout now, whatever the current segment (AMRAP time cap).
    @discardableResult
    public mutating func finish(at t: Double, source: AdvanceSource) -> Bool {
        guard isStarted, !isFinished, let last = segmentStarts.last, t >= last else { return false }
        finishTime = t
        events.append(WorkoutEvent(t: t, kind: .finish, segmentIndex: currentIndex, source: source))
        return true
    }

    /// When the current segment ends by itself (seconds since 1970), or nil if only the
    /// athlete ends it:
    /// - a rest with a seconds target ends after that long ("1:00 rest");
    /// - in an interval workout ("every 1:00"), any segment ends on the next interval boundary
    ///   after it began: a rest hands over to the next set, and a work segment still running at
    ///   the boundary jumps to the next set (work segments need `roundSize`). Changed 2026-11-03:
    ///   the athlete expected each minute to start by itself without a Crown turn.
    public func autoAdvanceTime() -> Double? {
        guard isStarted, !isFinished, let segment = currentSegment,
              let segmentStart = segmentStarts.last, let start = startTime else { return nil }
        if segment.kind == .rest, let target = segment.target, target.unit == .seconds, target.value > 0 {
            return segmentStart + target.value
        }
        if let interval = definition.intervalSeconds, interval > 0,
           segment.kind == .rest || (definition.roundSize ?? 0) > 0 {
            let elapsed = segmentStart - start
            let next = (elapsed / interval).rounded(.down) + 1.0
            return start + next * interval
        }
        return nil
    }

    /// The segment the clock moves to: the next one, or for a work segment of an interval
    /// workout the first segment of the next set (skipping what is left of this set).
    public var autoAdvanceTargetIndex: Int {
        let i: Int = currentIndex
        guard let segment = currentSegment, segment.kind != .rest,
              let interval = definition.intervalSeconds, interval > 0,
              let r = definition.roundSize, r > 0 else { return i + 1 }
        return (i / r + 1) * r
    }

    /// Applies the clock's change at t: one or more advances (source .auto), finishing when the
    /// target is past the last segment. Returns true if anything changed.
    @discardableResult
    public mutating func autoAdvance(at t: Double) -> Bool {
        let target: Int = autoAdvanceTargetIndex
        var changed: Bool = false
        while !isFinished && currentIndex < target {
            if !advance(at: t, source: .auto) { break }
            changed = true
        }
        return changed
    }

    /// AMRAP time cap: when the workout finishes by itself, or nil.
    public var capTime: Double? {
        guard definition.format == .amrap, let cap = definition.timeCapSeconds, cap > 0,
              let start = startTime else { return nil }
        return start + cap
    }

    /// For time with a cap (WORKOUT_SPEC §5b): when the cap is reached (start + cap), or nil.
    /// The workout does not stop there: the athlete is told and keeps going. Not AMRAP (`capTime`).
    public var forTimeCapTime: Double? {
        guard definition.format == .forTime, let cap = definition.timeCapSeconds, cap > 0,
              let start = startTime else { return nil }
        return start + cap
    }

    /// Index of the segment running at t (the last one started at or before t); nil before the
    /// start or after the finish.
    public func segmentIndex(at t: Double) -> Int? {
        guard let first = segmentStarts.first, t >= first else { return nil }
        if let f = finishTime, t > f { return nil }
        var index: Int = 0
        for i in 0..<segmentStarts.count where segmentStarts[i] <= t {
            index = i
        }
        return index
    }

    /// For time: the segment running at the cap once the cap has passed (the finish, or `now`
    /// when not finished, is later than the cap); nil otherwise.
    public func capSegmentIndex(now: Double) -> Int? {
        guard let cap = forTimeCapTime else { return nil }
        let end: Double = finishTime ?? now
        if !(end > cap) { return nil }
        return segmentIndex(at: cap)
    }

    public mutating func recordEnd(at t: Double) {
        events.append(WorkoutEvent(t: t, kind: .end, segmentIndex: currentIndex, source: nil))
    }

    public func segmentElapsed(now: Double) -> Double {
        guard let last = segmentStarts.last else { return 0 }
        let end: Double = finishTime ?? now
        return max(0, end - last)
    }

    public func totalElapsed(now: Double) -> Double {
        guard let first = segmentStarts.first else { return 0 }
        let end: Double = finishTime ?? now
        return max(0, end - first)
    }

    /// Completed segments plus the current one (ended at `now`, or at finishTime).
    public func splits(now: Double) -> [SegmentSplit] {
        var out: [SegmentSplit] = []
        let n = segmentStarts.count
        for i in 0..<n {
            let s: Double = segmentStarts[i]
            var e: Double
            if i + 1 < n {
                e = segmentStarts[i + 1]
            } else {
                e = finishTime ?? now
            }
            if e < s { e = s }
            out.append(SegmentSplit(index: i, start: s, end: e))
        }
        return out
    }
}
