import Foundation

/// Repeating blocks and fixed lists (docs/WORKOUT_SPEC.md 5c, #138). Port of
/// tools/barpath/repeat_block.py; shared cases in Fixtures/repeat_block_cases.json and
/// Fixtures/repeat_block_progress_cases.json. Pure; `WorkoutProgress` takes a plan in block mode.
///
/// A part is one listed segment (`segments[p]`, `0 <= p < P`). A step is one part as it is actually
/// done, numbered from START. A pass is one time through the block: step `s` is pass `s / P`, part
/// `s % P`. A fixed list has exactly `P` steps, so its step numbers are today's segment indices.
///
/// Only a definition marked `listedOnce` may repeat. Every row stored today is unmarked: it lists
/// its rounds or windows out and takes the legacy route (today's WorkoutProgress, with the §5a AMRAP
/// expansion), whatever the engine switch says. The block is the whole listed list; `roundSize` is
/// display only and plays no part here.
public enum RepeatBlock {

    public enum Kind: String, Codable, Equatable {
        case legacy
        case fixed
        case repeating = "repeat"
    }

    public enum EndReason: String, Codable, Equatable {
        case listDone      // fixed list: Crown on the last part
        case roundsDone    // repeating block with N rounds: Crown on the last step of pass N
        case cap           // AMRAP / EMOM: the clock
    }

    public struct Plan: Codable, Equatable {
        public let kind: Kind
        public let parts: Int
        /// Passes to do; nil = until the clock (or End).
        public let rounds: Int?
        public let capSeconds: Double?
        /// The cap finishes the workout (AMRAP, EMOM); for time keeps going (5b).
        public let capEnds: Bool
        /// One window = one pass of the block (5c Q3).
        public let intervalSeconds: Double?
        /// Rests after the block's last work part, skipped on the last pass (no interval only).
        /// Any field added to Plan later must be optional: the plan is stored in checkpoints.
        public let trailingRests: Int

        public init(kind: Kind, parts: Int, rounds: Int?, capSeconds: Double?, capEnds: Bool,
                    intervalSeconds: Double?, trailingRests: Int = 0) {
            self.kind = kind
            self.parts = parts
            self.rounds = rounds
            self.capSeconds = capSeconds
            self.capEnds = capEnds
            self.intervalSeconds = intervalSeconds
            self.trailingRests = trailingRests
        }

        /// Steps in the whole workout; nil when only the clock (or End) stops it. Without an
        /// interval the last pass ends on its last work part (a rest after the last round is not
        /// done); with one, the last window keeps its rest and the clock ends it.
        public var stepLimit: Int? {
            if kind != .repeating { return parts }
            guard let r = rounds else { return nil }
            return r * parts - trailingRests
        }
    }

    private static func positive(_ x: Double?) -> Double? {
        guard let v = x, v > 0 else { return nil }
        return v
    }

    private static func trailingRests(_ d: WorkoutDefinition) -> Int {
        var n: Int = 0
        for s in d.segments.reversed() {
            if s.kind != .rest { break }
            n += 1
        }
        return n < d.segments.count ? n : 0
    }

    /// Why a definition marked listedOnce cannot run as a block (it then takes the legacy route).
    /// An interval block must end with a rest: that rest is the wait until the next window, so an
    /// early Crown never starts the next pass before its window.
    public static func listedOnceProblems(_ d: WorkoutDefinition) -> [String] {
        var out: [String] = []
        if d.segments.isEmpty {
            out.append("no segments")
        } else if d.segments.allSatisfy({ (s: WorkoutSegment) -> Bool in s.kind == .rest }) {
            out.append("only rests")
        } else if positive(d.intervalSeconds) != nil, let last = d.segments.last, last.kind != .rest {
            out.append("interval block does not end with a rest")
        }
        return out
    }

    /// The kind of a definition (5c table). Unmarked (every row stored today): legacy. Marked
    /// `listedOnce`: repeating for the repeating formats, else fixed.
    public static func plan(for d: WorkoutDefinition) -> Plan {
        let n: Int = d.segments.count
        let cap: Double? = positive(d.timeCapSeconds)
        let interval: Double? = positive(d.intervalSeconds)
        var rounds: Int? = nil
        if let r = d.rounds, r > 0 {
            rounds = r
        }
        if d.listedOnce != true || !listedOnceProblems(d).isEmpty {
            return Plan(kind: .legacy, parts: n, rounds: 1, capSeconds: cap, capEnds: false,
                        intervalSeconds: interval)
        }
        let tr: Int = interval != nil ? 0 : trailingRests(d)
        if d.format == .amrap, cap != nil {
            return Plan(kind: .repeating, parts: n, rounds: nil, capSeconds: cap, capEnds: true,
                        intervalSeconds: interval, trailingRests: tr)
        }
        if d.format == .emom, cap != nil || rounds != nil {
            return Plan(kind: .repeating, parts: n, rounds: rounds, capSeconds: cap, capEnds: cap != nil,
                        intervalSeconds: interval, trailingRests: tr)
        }
        if d.format == .forTime, rounds != nil {
            return Plan(kind: .repeating, parts: n, rounds: rounds, capSeconds: cap, capEnds: false,
                        intervalSeconds: interval, trailingRests: tr)
        }
        if interval != nil {
            // A marked fixed list with an interval ("Go every" done once) keeps today's path: block
            // mode would end it at the first window (E3 review).
            return Plan(kind: .legacy, parts: n, rounds: 1, capSeconds: cap, capEnds: false,
                        intervalSeconds: interval)
        }
        return Plan(kind: .fixed, parts: n, rounds: 1, capSeconds: cap, capEnds: false,
                    intervalSeconds: interval)
    }

    /// Steps a repeating block plans to do: its step limit, else ceil(cap / interval) windows of an
    /// interval block; nil for an AMRAP (only the clock ends it) and for anything not repeating.
    /// Python mirror: `repeat_block.planned_steps`.
    public static func plannedSteps(_ d: WorkoutDefinition) -> Int? {
        let p: Plan = plan(for: d)
        if p.kind != .repeating { return nil }
        if let limit = p.stepLimit { return limit }
        if d.format == .emom, let i = p.intervalSeconds, let c = p.capSeconds {
            return Swift.max(1, Int((c / i - 1e-9).rounded(.up))) * p.parts
        }
        return nil
    }

    /// The plan `WorkoutProgress` runs in block mode, or nil for today's path. Block mode needs both
    /// the engine switch on and a definition marked listedOnce; anything else is today's path.
    public static func enginePlan(for d: WorkoutDefinition, engineOn: Bool) -> Plan? {
        if !engineOn { return nil }
        let p: Plan = plan(for: d)
        return p.kind == .legacy ? nil : p
    }

    /// `enginePlan(for:engineOn:)` with E2's switch value.
    public static func enginePlan(for d: WorkoutDefinition, engine: WorkoutEngine) -> Plan? {
        return enginePlan(for: d, engineOn: engine == .v2)
    }

    /// The Classic route for a definition marked listedOnce: its block written out the way today's
    /// stored rows are, so the legacy progress runs it fully (not one pass, the #138 bug). Rounds
    /// for time × N: N passes, no rest after the last round. EMOM / Tabata: the round count, else
    /// ceil(cap / interval) windows. AMRAP: unmarked with roundSize = P, then the §5a expansion.
    /// A repeating block gets roundSize = P; a marked fixed list keeps its own. The mark and
    /// `rounds` are dropped. Unmarked definitions are unchanged.
    /// Python mirror: `repeat_block.written_out`.
    public static func writtenOut(_ d: WorkoutDefinition) -> WorkoutDefinition {
        if d.listedOnce != true || d.segments.isEmpty { return d }
        let n: Int = d.segments.count
        let cap: Double? = positive(d.timeCapSeconds)
        let interval: Double? = positive(d.intervalSeconds)
        var rounds: Int? = nil
        if let r = d.rounds, r > 0 {
            rounds = r
        }
        var passes: Int? = nil
        if d.format == .forTime, let r = rounds {
            passes = r
        } else if d.format == .emom {
            if let r = rounds {
                passes = r
            } else if let i = interval, let c = cap {
                passes = Swift.max(1, Int((c / i - 1e-9).rounded(.up)))
            }
        }
        var segs: [WorkoutSegment] = d.segments
        if let k = passes {
            segs = []
            for _ in 0..<k {
                segs.append(contentsOf: d.segments)
            }
            if interval == nil {
                let tr: Int = trailingRests(d)
                if tr > 0 {
                    segs.removeLast(tr)
                }
            }
        }
        var out: WorkoutDefinition = d
        out.segments = segs
        // An AMRAP with an interval keeps roundSize unset, as the §5a expansion does (work segments
        // then don't jump at the window).
        if passes != nil || (d.format == .amrap && cap != nil && interval == nil) {
            out.roundSize = n
        }
        out.listedOnce = nil
        out.rounds = nil
        return out
    }

    /// The progress the watch starts a workout with: block mode with the engine on and a
    /// listed-once definition (nothing written out); otherwise today's progress (Classic), on the
    /// definition written out (`writtenOut`, listed-once only) with the §5a AMRAP expansion.
    /// Python mirror: `repeat_block.start_progress`.
    public static func startProgress(for d: WorkoutDefinition, engineOn: Bool) -> WorkoutProgress {
        if let plan = enginePlan(for: d, engineOn: engineOn) {
            return WorkoutProgress(definition: d, block: plan)
        }
        return WorkoutProgress(definition: writtenOut(d).expandedForAmrap())
    }

    /// `startProgress(for:engineOn:)` with E2's switch value.
    public static func startProgress(for d: WorkoutDefinition, engine: WorkoutEngine) -> WorkoutProgress {
        return startProgress(for: d, engineOn: engine == .v2)
    }

    /// (pass, part) of a step; nil for a step before START or past the workout's end.
    public static func position(_ plan: Plan, step: Int) -> (pass: Int, part: Int)? {
        if step < 0 || plan.parts == 0 { return nil }
        if let limit = plan.stepLimit, step >= limit { return nil }
        return (step / plan.parts, step % plan.parts)
    }

    /// A Crown advance from this step finishes the workout (instead of starting the next step).
    public static func advanceFinishes(_ plan: Plan, step: Int) -> Bool {
        guard let limit = plan.stepLimit else { return false }
        return step >= limit - 1
    }

    /// Undo goes back one step, across a pass boundary too; nothing before step 0.
    public static func previousStep(_ step: Int) -> Int? {
        return step > 0 ? step - 1 : nil
    }

    /// Why the workout ends now, or nil. `advanced`: the athlete just advanced from `step`;
    /// `elapsed`: seconds since START. The cap ends only AMRAP / EMOM (for time keeps going, 5b).
    public static func endReason(_ plan: Plan, step: Int, advanced: Bool, elapsed: Double) -> EndReason? {
        if advanced && advanceFinishes(plan, step: step) {
            return plan.kind == .repeating ? EndReason.roundsDone : EndReason.listDone
        }
        if plan.capEnds, let cap = plan.capSeconds, elapsed >= cap {
            return EndReason.cap
        }
        return nil
    }

    /// Interval workouts ("Go every ..."): the elapsed time at which the window holding this step
    /// ends, the next multiple of intervalSeconds after the step began. One window is one pass of
    /// the block (Q3); the window length comes from intervalSeconds, never from roundSize.
    public static func windowEnd(_ plan: Plan, stepStartElapsed: Double) -> Double? {
        guard let i = plan.intervalSeconds else { return nil }
        return ((stepStartElapsed / i).rounded(.down) + 1.0) * i
    }

    /// Interval workouts: the step the clock moves to at the window's end, the first part of the
    /// next pass (what is left of this pass is skipped). Nil without an interval, or when that pass
    /// would be past the last one (the clock then finishes).
    ///
    /// Not quite today's `WorkoutProgress.autoAdvanceTargetIndex`: today a rest goes to the next
    /// segment and roundSize is the set. Here the window end always goes to the next pass, so a rest
    /// in the middle of the block with no timer of its own skips the rest of the pass. A rest with a
    /// seconds target still ends by itself and hands over to the next part (block mode). When the
    /// rests are the block's last parts, as in every interval row today, both agree.
    public static func windowTargetStep(_ plan: Plan, step: Int) -> Int? {
        guard plan.intervalSeconds != nil, plan.parts > 0, step >= 0 else { return nil }
        let next: Int = (step / plan.parts + 1) * plan.parts
        if let limit = plan.stepLimit, next >= limit { return nil }
        return next
    }

    /// (complete passes, work parts done in the cut pass) after `completedSteps` finished steps.
    /// A pass is complete once its work is done: rests at its end don't count (Q4, as today).
    public static func score(_ plan: Plan, definition d: WorkoutDefinition,
                             completedSteps: Int) -> (passes: Int, workParts: Int) {
        if plan.parts == 0 || completedSteps <= 0 { return (0, 0) }
        var lastWork: Int = -1
        for (i, s) in d.segments.enumerated() where s.kind != .rest {
            lastWork = i
        }
        var full: Int = completedSteps / plan.parts
        var doneInPass: Int = completedSteps % plan.parts
        if lastWork >= 0 && doneInPass > lastWork {
            full += 1
            doneInPass = 0
        }
        var work: Int = 0
        if doneInPass > 0 {
            for i in 0..<doneInPass where d.segments[i].kind != .rest {
                work += 1
            }
        }
        if let r = plan.rounds {
            full = Swift.min(full, r)
        }
        return (full, work)
    }
}
