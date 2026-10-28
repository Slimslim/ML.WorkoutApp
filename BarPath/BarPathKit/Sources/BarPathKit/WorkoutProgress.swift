import Foundation

public enum AdvanceSource: String, Codable { case crown, press, button, auto }

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
