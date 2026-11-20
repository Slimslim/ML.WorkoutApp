import Foundation

/// Repeating blocks and fixed lists (docs/WORKOUT_SPEC.md 5c, #138). Port of
/// tools/barpath/repeat_block.py; shared cases in Fixtures/repeat_block_cases.json. Pure: not called
/// from the watch or the phone yet.
///
/// A part is one listed segment (`segments[p]`, `0 <= p < P`). A step is one part as it is actually
/// done, numbered from START. A pass is one time through the block: step `s` is pass `s / P`, part
/// `s % P`. A fixed list has exactly `P` steps, so its step numbers are today's segment indices.
/// The block is the whole listed list; `roundSize` plays no part here.
public enum RepeatBlock {

    public enum Kind: String, Codable, Equatable {
        case fixed
        case repeating = "repeat"
    }

    public enum EndReason: String, Codable, Equatable {
        case listDone      // fixed list: Crown on the last part
        case roundsDone    // repeating block with N rounds: Crown on the last part of pass N
        case cap           // AMRAP / EMOM: the clock
    }

    public struct Plan: Equatable {
        public let kind: Kind
        public let parts: Int
        /// Passes to do; nil = until the clock (or End).
        public let rounds: Int?
        public let capSeconds: Double?
        /// The cap finishes the workout (AMRAP, EMOM); for time keeps going (5b).
        public let capEnds: Bool
        /// A window is one part (5c Q3 default).
        public let intervalSeconds: Double?

        public init(kind: Kind, parts: Int, rounds: Int?, capSeconds: Double?, capEnds: Bool,
                    intervalSeconds: Double?) {
            self.kind = kind
            self.parts = parts
            self.rounds = rounds
            self.capSeconds = capSeconds
            self.capEnds = capEnds
            self.intervalSeconds = intervalSeconds
        }

        /// Steps in the whole workout; nil when only the clock (or End) stops it.
        public var stepLimit: Int? {
            if kind == .fixed { return parts }
            guard let r = rounds else { return nil }
            return r * parts
        }
    }

    private static func positive(_ x: Double?) -> Double? {
        guard let v = x, v > 0 else { return nil }
        return v
    }

    /// The kind of a definition (5c table). Anything not listed as repeating is a fixed list.
    public static func plan(for d: WorkoutDefinition) -> Plan {
        let n: Int = d.segments.count
        let cap: Double? = positive(d.timeCapSeconds)
        let interval: Double? = positive(d.intervalSeconds)
        var rounds: Int? = nil
        if let r = d.rounds, r > 0 {
            rounds = r
        }
        if n > 0 {
            if d.format == .amrap, cap != nil {
                return Plan(kind: .repeating, parts: n, rounds: nil, capSeconds: cap, capEnds: true,
                            intervalSeconds: interval)
            }
            if d.format == .emom, cap != nil || rounds != nil {
                return Plan(kind: .repeating, parts: n, rounds: rounds, capSeconds: cap, capEnds: cap != nil,
                            intervalSeconds: interval)
            }
            if d.format == .forTime, rounds != nil {
                return Plan(kind: .repeating, parts: n, rounds: rounds, capSeconds: cap, capEnds: false,
                            intervalSeconds: interval)
            }
        }
        return Plan(kind: .fixed, parts: n, rounds: 1, capSeconds: cap, capEnds: false,
                    intervalSeconds: interval)
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
        return step == limit - 1
    }

    /// Undo goes back one step, across a pass boundary too; nothing before step 0.
    public static func previousStep(_ step: Int) -> Int? {
        return step > 0 ? step - 1 : nil
    }

    /// Why the workout ends now, or nil. `advanced`: the athlete just advanced from `step`;
    /// `elapsed`: seconds since START. The cap ends only AMRAP / EMOM (for time keeps going, 5b).
    public static func endReason(_ plan: Plan, step: Int, advanced: Bool, elapsed: Double) -> EndReason? {
        if advanced && advanceFinishes(plan, step: step) {
            return plan.kind == .fixed ? EndReason.listDone : EndReason.roundsDone
        }
        if plan.capEnds, let cap = plan.capSeconds, elapsed >= cap {
            return EndReason.cap
        }
        return nil
    }

    /// Interval workouts: the elapsed time at which the window holding this step ends (the clock
    /// starts the next step there). A window is one part (Q3 default); roundSize plays no part.
    public static func windowEnd(_ plan: Plan, stepStartElapsed: Double) -> Double? {
        guard let i = plan.intervalSeconds else { return nil }
        return ((stepStartElapsed / i).rounded(.down) + 1.0) * i
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
