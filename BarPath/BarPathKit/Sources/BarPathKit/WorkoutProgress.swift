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

/// Progress through a definition's segments, as today. With `block` (the `RepeatBlock.Plan` of a
/// listed-once definition, WORKOUT_SPEC 5c) it counts steps instead: step s is part s % P of pass
/// s / P, and the plan decides when it finishes. Without `block` every method is exactly today's.
/// Python mirror: WorkoutProgress in tools/barpath/workout.py.
public struct WorkoutProgress: Codable, Equatable {
    public let definition: WorkoutDefinition
    public private(set) var segmentStarts: [Double]   // start time of segments (steps) 0...currentIndex
    public private(set) var finishTime: Double?
    public private(set) var events: [WorkoutEvent]
    /// Block mode (5c). Nil: today's path. Optional in a checkpoint (older ones have none).
    public private(set) var block: RepeatBlock.Plan?

    public init(definition: WorkoutDefinition, block: RepeatBlock.Plan? = nil) {
        self.definition = definition
        self.segmentStarts = []
        self.finishTime = nil
        self.events = []
        self.block = block
    }

    /// The listed segment a step does (block mode), or the segment at that index (today).
    public func part(atStep step: Int) -> WorkoutSegment? {
        let segs: [WorkoutSegment] = definition.segments
        guard let plan = block else {
            return step >= 0 && step < segs.count ? segs[step] : nil
        }
        if segs.isEmpty || step < 0 { return nil }
        if let limit = plan.stepLimit, step >= limit { return nil }
        return segs[step % segs.count]
    }

    /// (pass, part index) of a step in block mode; on today's path (0, step).
    public func position(ofStep step: Int) -> (pass: Int, part: Int)? {
        guard let plan = block else {
            return step >= 0 && step < definition.segments.count ? (0, step) : nil
        }
        return RepeatBlock.position(plan, step: step)
    }

    private func isLastStep(_ step: Int) -> Bool {
        guard let plan = block else { return step >= definition.segments.count - 1 }
        return RepeatBlock.advanceFinishes(plan, step: step)
    }

    /// Block mode with an interval: the current step is the block's closing rest, the wait for the
    /// next window. The athlete's Crown is ignored there (the watch shows a hint); only the clock
    /// moves on, so every window starts on the clock. Always false on today's path.
    public var isWaitingForWindow: Bool {
        guard let plan = block, plan.intervalSeconds != nil, isStarted, !isFinished,
              let segment = currentSegment, segment.kind == .rest, plan.parts > 0 else { return false }
        return currentIndex % plan.parts == plan.parts - 1
    }

    /// Block mode (5c): (when the current step ends by itself or nil, the step the clock moves to).
    /// With an interval, one window is one pass: a part with a seconds target ends on its timer and
    /// hands over to the next part, unless the window ends first; the block's last part (its rest,
    /// the wait for the next window) ends on the window; at the window end the clock moves to the
    /// first part of the next pass, or finishes after the last one. Without an interval: a timed
    /// rest ends after its seconds, as today.
    private func blockAuto(_ plan: RepeatBlock.Plan) -> (time: Double?, target: Int) {
        let i: Int = currentIndex
        let next: Int = i + 1
        guard isStarted, !isFinished, let segment = currentSegment,
              let segmentStart = segmentStarts.last, let start = startTime else { return (nil, next) }
        var timer: Double? = nil
        if let target = segment.target, target.unit == .seconds, target.value > 0 {
            timer = target.value
        }
        guard plan.intervalSeconds != nil,
              let windowElapsed = RepeatBlock.windowEnd(plan, stepStartElapsed: segmentStart - start) else {
            if segment.kind == .rest, let v = timer { return (segmentStart + v, next) }
            return (nil, next)
        }
        let window: Double = start + windowElapsed
        let lastPart: Bool = plan.parts > 0 && i % plan.parts == plan.parts - 1
        if let v = timer, !(segment.kind == .rest && lastPart), segmentStart + v < window {
            return (segmentStart + v, next)
        }
        if let target = RepeatBlock.windowTargetStep(plan, step: i) {
            return (window, target)
        }
        return (window, plan.stepLimit ?? next)
    }

    public var isStarted: Bool { return !segmentStarts.isEmpty }
    public var isFinished: Bool { return finishTime != nil }
    public var currentIndex: Int { return max(0, segmentStarts.count - 1) }

    public var currentSegment: WorkoutSegment? {
        if !isStarted { return nil }
        return part(atStep: currentIndex)
    }

    public var nextSegment: WorkoutSegment? {
        if !isStarted || isFinished { return nil }
        return part(atStep: currentIndex + 1)
    }

    public var startTime: Double? { return segmentStarts.first }

    /// No-op if already started.
    public mutating func start(at t: Double) {
        if isStarted { return }
        segmentStarts.append(t)
        events.append(WorkoutEvent(t: t, kind: .start, segmentIndex: 0, source: nil))
    }

    /// Moves to the next segment; on the last segment it finishes. Returns false if not
    /// started, already finished, or t is before the current segment's start. Block mode: false
    /// while waiting for the next window, unless the clock (source .auto) moves on.
    @discardableResult
    public mutating func advance(at t: Double, source: AdvanceSource) -> Bool {
        guard isStarted, !isFinished, let last = segmentStarts.last else { return false }
        if t < last { return false }
        if source != .auto && isWaitingForWindow { return false }
        if isLastStep(currentIndex) {
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
        if let plan = block { return blockAuto(plan).time }
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
        if let plan = block { return blockAuto(plan).target }
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

    /// AMRAP time cap: when the workout finishes by itself, or nil. Block mode: every plan whose
    /// cap ends it (AMRAP, EMOM / Tabata with a cap).
    public var capTime: Double? {
        if let plan = block {
            guard plan.capEnds, let cap = plan.capSeconds, let start = startTime else { return nil }
            return start + cap
        }
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
