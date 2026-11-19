import Foundation

/// W46: the "vs last time" line under the score (docs/RESULTS_INSIGHTS.md section 2).
/// Swift port of tools/barpath/result_compare.py; parity fixture result_compare_cases.json.
///
/// Two results are compared only when they are the same workout at the same scale: same
/// definition id, format and time cap, the same segments (kind, movement, target, load within
/// 0.25 kg) and, when both are answered (W19), the same Rx / Scaled.
///
/// | both finished        | "2:04 faster" / "0:38 slower" / "Same time"                  |
/// | AMRAP                | "+12 reps" / "−1 round" (total reps; whole rounds as rounds) |
/// | finished vs capped   | "Finished (last time capped at 12:00 + 84)"                  |
/// | capped vs finished   | "Capped (last time finished in 11:48)"                       |
/// | both capped          | "+9 reps at the cap"                                         |
/// | other scale or loads | "Different scale, not compared"                              |
/// | no earlier result    | nil                                                          |
/// Anything that can't be scored honestly (ended early, reps at the cap unknown, an interval
/// workout) gives nil.
public enum ResultCompare {
    public static let notComparedText: String = "Different scale, not compared"

    public enum Kind: String, Equatable {
        case time
        case finishedVsCapped
        case cappedVsFinished
        case bothCapped
        case amrap
        case notCompared
    }

    /// How the line is coloured: better (green), worse and same (secondary), neutral (secondary,
    /// no pill).
    public enum Tone: String, Equatable {
        case better, worse, same, neutral
    }

    public struct Comparison: Equatable {
        public let kind: Kind
        public let text: String
        public let tone: Tone
        /// Time: current − previous seconds (negative = faster).
        public let seconds: Double?
        /// AMRAP (when reps add up) and both capped: current − previous total reps.
        public let reps: Int?

        public init(kind: Kind, text: String, tone: Tone, seconds: Double? = nil, reps: Int? = nil) {
            self.kind = kind
            self.text = text
            self.tone = tone
            self.seconds = seconds
            self.reps = reps
        }
    }

    /// The comparison line, nil when there is nothing to say.
    public static func compare(current: ResultScore, previous: ResultScore?) -> Comparison? {
        guard let prev = previous else { return nil }
        if current.definition.id != prev.definition.id { return nil }
        if !sameScale(current.definition, prev.definition, rxA: current.rx, rxB: prev.rx) {
            return Comparison(kind: .notCompared, text: notComparedText, tone: .neutral)
        }
        switch current.definition.format {
        case .amrap:
            return amrap(current, prev)
        case .forTime:
            return forTime(current, prev)
        default:
            return nil
        }
    }

    // MARK: - Scale

    /// Same workout at the same scale (see the type comment).
    public static func sameScale(_ a: WorkoutDefinition, _ b: WorkoutDefinition,
                                 rxA: Bool? = nil, rxB: Bool? = nil) -> Bool {
        if a.id != b.id || a.format != b.format { return false }
        if !sameNumber(positive(a.timeCapSeconds), positive(b.timeCapSeconds)) { return false }
        if a.segments.count != b.segments.count { return false }
        for i in 0..<a.segments.count {
            if !sameSegment(a.segments[i], b.segments[i]) { return false }
        }
        if let x = rxA, let y = rxB, x != y { return false }
        return true
    }

    private static func positive(_ v: Double?) -> Double? {
        guard let x = v, x != 0 else { return nil }
        return x
    }

    private static func sameNumber(_ a: Double?, _ b: Double?) -> Bool {
        if let x = a, let y = b { return abs(x - y) < 1e-6 }
        return a == nil && b == nil
    }

    private static func sameSegment(_ a: WorkoutSegment, _ b: WorkoutSegment) -> Bool {
        if a.kind != b.kind || a.movement != b.movement { return false }
        if (a.target == nil) != (b.target == nil) { return false }
        if let x = a.target, let y = b.target {
            if x.unit != y.unit || !sameNumber(x.value, y.value) { return false }
        }
        if (a.load == nil) != (b.load == nil) { return false }
        if let x = a.load, let y = b.load {
            if abs(x.kilograms - y.kilograms) > 0.25 { return false }
        }
        return true
    }

    // MARK: - Reps

    /// Reps a segment counts for in a score: reps and Cal targets (Cal counts as reps); 0 for a
    /// rest; nil otherwise (a distance, a time, no target).
    static func countable(_ seg: WorkoutSegment) -> Int? {
        if seg.kind == .rest { return 0 }
        if let t = seg.target, t.unit == .reps || t.unit == .calories {
            return whole(t.value)
        }
        return nil
    }

    /// Reps of one full round (the first `roundSize` segments), nil when a work segment has no
    /// rep count or there is no round size.
    public static func repsPerRound(_ d: WorkoutDefinition, roundSize: Int?) -> Int? {
        guard let size = roundSize, size >= 1, size <= d.segments.count else { return nil }
        var total: Int = 0
        for i in 0..<size {
            guard let n = countable(d.segments[i]) else { return nil }
            total += n
        }
        return total > 0 ? total : nil
    }

    /// For time past the cap: reps of the segments finished by the cap plus `repsAtCap` of the
    /// segment running then. Nil when not capped, when reps at the cap were not entered, or when
    /// a finished work segment has no rep count (a run).
    public static func repsDoneAtCap(_ result: WorkoutResult) -> Int? {
        let d: WorkoutDefinition = result.definition
        guard d.format == .forTime, let cap = d.timeCapSeconds, cap > 0, result.totalSeconds > cap else {
            return nil
        }
        guard let atCap = result.repsAtCap else { return nil }
        let at: Double = result.startDate.timeIntervalSince1970 + cap
        var total: Int = 0
        for s in result.segments {
            if s.end > at { continue }
            if s.index < 0 || s.index >= d.segments.count { return nil }
            guard let n = countable(d.segments[s.index]) else { return nil }
            total += n
        }
        return total + atCap
    }

    // MARK: - Formats

    private static func amrap(_ cur: ResultScore, _ prev: ResultScore) -> Comparison? {
        guard let cr = cur.rounds, let pr = prev.rounds else { return nil }
        let ce: Int = cur.extraReps ?? 0
        let pe: Int = prev.extraReps ?? 0
        if let per = repsPerRound(cur.definition, roundSize: cur.roundSize) {
            let diff: Int = (cr * per + ce) - (pr * per + pe)
            if diff == 0 {
                return Comparison(kind: .amrap, text: "Same score", tone: .same, reps: 0)
            }
            let text: String = diff % per == 0 ? count(diff / per, "round") : count(diff, "rep")
            return Comparison(kind: .amrap, text: text, tone: tone(diff), reps: diff)
        }
        // A round with a distance: rounds and reps can't be added up.
        let dr: Int = cr - pr
        let de: Int = ce - pe
        if dr == 0 && de == 0 {
            return Comparison(kind: .amrap, text: "Same score", tone: .same)
        }
        if dr == 0 {
            return Comparison(kind: .amrap, text: count(de, "rep"), tone: tone(de))
        }
        let text: String = de == 0 ? count(dr, "round") : count(dr, "round") + ", " + count(de, "rep")
        return Comparison(kind: .amrap, text: text, tone: tone(dr))
    }

    private static func forTime(_ cur: ResultScore, _ prev: ResultScore) -> Comparison? {
        let cap: Double? = positive(cur.definition.timeCapSeconds)
        let curDone: Bool = cur.finished && !cur.capped
        let prevDone: Bool = prev.finished && !prev.capped
        if curDone && prevDone {
            let diff: Double = cur.totalSeconds - prev.totalSeconds
            let w: Int = whole(diff)
            if w == 0 {
                return Comparison(kind: .time, text: "Same time", tone: .same, seconds: diff)
            }
            let word: String = w < 0 ? " faster" : " slower"
            return Comparison(kind: .time, text: SummaryFormat.clock(abs(diff)) + word,
                              tone: w < 0 ? .better : .worse, seconds: diff)
        }
        if curDone && prev.capped, let c = cap {
            var text: String = "Finished (last time capped at " + SummaryFormat.clock(c)
            if let reps = prev.repsAtCap {
                text += " + " + String(reps)
            }
            return Comparison(kind: .finishedVsCapped, text: text + ")", tone: .better)
        }
        if cur.capped && prevDone {
            return Comparison(kind: .cappedVsFinished,
                              text: "Capped (last time finished in " + SummaryFormat.clock(prev.totalSeconds) + ")",
                              tone: .worse)
        }
        if cur.capped && prev.capped {
            guard let a = cur.repsAtCap, let b = prev.repsAtCap else { return nil }
            let diff: Int = a - b
            if diff == 0 {
                return Comparison(kind: .bothCapped, text: "Same reps at the cap", tone: .same, reps: 0)
            }
            return Comparison(kind: .bothCapped, text: count(diff, "rep") + " at the cap",
                              tone: tone(diff), reps: diff)
        }
        return nil
    }

    // MARK: - Text

    private static func tone(_ diff: Int) -> Tone {
        if diff == 0 { return .same }
        return diff > 0 ? .better : .worse
    }

    /// Swift's Int(x.rounded()) (halves away from zero), as the Python reference.
    static func whole(_ v: Double) -> Int {
        return Int(v.rounded())
    }

    /// "+1 round", "−3 reps".
    static func count(_ n: Int, _ word: String) -> String {
        let sign: String = n >= 0 ? "+" : SummaryFormat.minus
        let plural: String = abs(n) == 1 ? "" : "s"
        return sign + String(abs(n)) + " " + word + plural
    }
}

/// What the comparison needs from one result. Built with `make(result:summary:rx:)` in the app;
/// the parity test builds it from the fixture.
public struct ResultScore: Equatable {
    public let definition: WorkoutDefinition
    public let totalSeconds: Double
    /// Reached the last segment.
    public let finished: Bool
    /// For time past the cap.
    public let capped: Bool
    /// Total reps done by the cap (ResultCompare.repsDoneAtCap), nil when unknown.
    public let repsAtCap: Int?
    /// AMRAP: completed rounds and the reps of the unfinished round.
    public let rounds: Int?
    public let extraReps: Int?
    public let roundSize: Int?
    /// W19 Rx / Scaled, nil when not answered.
    public let rx: Bool?

    public init(definition: WorkoutDefinition, totalSeconds: Double, finished: Bool, capped: Bool = false,
                repsAtCap: Int? = nil, rounds: Int? = nil, extraReps: Int? = nil, roundSize: Int? = nil,
                rx: Bool? = nil) {
        self.definition = definition
        self.totalSeconds = totalSeconds
        self.finished = finished
        self.capped = capped
        self.repsAtCap = repsAtCap
        self.rounds = rounds
        self.extraReps = extraReps
        self.roundSize = roundSize
        self.rx = rx
    }

    /// From a stored result and its summary (rounds and extra reps of an AMRAP come from the
    /// summary's clock). `rx` stays nil until results store it (W19).
    public static func make(result: WorkoutResult, summary: WorkoutSummary, rx: Bool? = nil) -> ResultScore {
        let h: WorkoutSummary.Headline = summary.headline
        let isAmrap: Bool = result.definition.format == .amrap
        return ResultScore(definition: result.definition, totalSeconds: result.totalSeconds,
                           finished: h.isFinished, capped: result.isCapped,
                           repsAtCap: ResultCompare.repsDoneAtCap(result),
                           rounds: isAmrap ? h.rounds : nil, extraReps: isAmrap ? h.extraReps : nil,
                           roundSize: summary.roundSize, rx: rx)
    }

    /// Shortcut: the comparison of a result with its previous attempt (nil without one).
    public static func comparison(result: WorkoutResult, summary: WorkoutSummary,
                                  previous: WorkoutResult?, maxHeartRate: Double?) -> ResultCompare.Comparison? {
        guard let p = previous, p.id != result.id else { return nil }
        let prevSummary: WorkoutSummary = WorkoutSummary.make(result: p, previous: nil, maxHeartRate: maxHeartRate)
        return ResultCompare.compare(current: make(result: result, summary: summary),
                                     previous: make(result: p, summary: prevSummary))
    }
}
