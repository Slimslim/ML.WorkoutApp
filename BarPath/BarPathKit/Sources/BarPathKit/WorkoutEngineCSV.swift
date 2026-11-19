import Foundation

/// Engine lines in the recording CSV (docs/WORKOUT_MODEL_RFC.md §9). Python reference:
/// tools/barpath/workout_csv.py; parity fixtures in Fixtures/workouts/csv.json.
///
/// The watch writes each line as `# event t=<s> <description>`; these are the descriptions. Old
/// parsers ignore unknown names, so they sit beside today's `segment` lines:
/// - `name=plan schema=2 planner=1 hash=<sha256> startEpochMs=<ms> startUptimeMs=<ms> steps=<n> bells=<n>`
///   once at START, then one `name=bell id=<id> anchor=<anchor> offsetMs=<ms>` per planned boundary;
/// - `name=step step=<id> status=<s> endedBy=<who> seq=<n> [reps=<n>]` each time a step ends;
/// - `name=input action=ignored input=<crown|undo|...> reason=<r> seq=<n>` for each ignored input.
/// `seq` orders lines written at the same time. Values are percent-encoded where they would break
/// `key=value` parsing (%, space, comma, tab and line breaks). Times are integer ms from START.
public enum WorkoutEngineCSV {
    public static let planSchema: Int = 2

    private static let encoding: [(String, String)] = [
        ("%", "%25"), (" ", "%20"), (",", "%2C"), ("\t", "%09"), ("\n", "%0A"), ("\r", "%0D"),
    ]

    public static func enc(_ s: String) -> String {
        var out: String = s
        for (a, b) in encoding {
            out = out.replacingOccurrences(of: a, with: b)
        }
        return out
    }

    public static func dec(_ s: String) -> String {
        var out: String = s
        for (a, b) in encoding.reversed() {
            out = out.replacingOccurrences(of: b, with: a)
        }
        return out
    }

    /// The `plan` line and one `bell` line per planned boundary.
    public static func planLines(_ plan: WorkoutPlan, startEpochMs: Int, startUptimeMs: Int) -> [String] {
        var out: [String] = [
            "name=plan schema=\(planSchema) planner=\(WorkoutPlan.plannerVersion) hash=\(plan.hash) "
                + "startEpochMs=\(startEpochMs) startUptimeMs=\(startUptimeMs) "
                + "steps=\(plan.steps.count) bells=\(plan.bells.count)",
        ]
        for b in plan.bells {
            out.append("name=bell id=\(enc(b.id)) anchor=\(enc(b.anchor)) offsetMs=\(b.offsetMs)")
        }
        return out
    }

    /// Reps as text: a whole number without a decimal point (Python `_reps_text`).
    static func repsText(_ v: JSONValue) -> String {
        switch v {
        case .int(let i):
            return String(i)
        case .double(let d):
            if let i = Int(exactly: d) {
                return String(i)
            }
            return enc("\(d)")
        case .string(let s):
            return enc(s)
        default:
            return enc(v.canonicalJSON)
        }
    }

    public struct Line: Equatable, Sendable {
        public let t: Int                    // ms from START
        public let text: String
    }

    /// Every step that ended and every input the engine ignored, in time order, numbered by `seq`.
    public static func eventLines(_ state: EngineState) -> [Line] {
        struct Row {
            let t: Int
            let order: Int
            let line: String
            let reps: JSONValue?
        }
        let t0: Int = state.t0 ?? 0
        var rows: [Row] = []
        var order: Int = 0
        for idx in state.seq {
            guard let r = state.rec[idx], let end = r.end, idx >= 0, idx < state.steps.count else {
                continue
            }
            let s: EngineStep = state.steps[idx]
            let by: String = (r.endedBy?.isEmpty ?? true) ? "none" : (r.endedBy ?? "none")
            let line: String = "name=step step=\(enc(s.id)) status=\(r.status) endedBy=\(by)"
            var reps: JSONValue? = r.reps
            if reps?.isNull == true {
                reps = nil
            }
            rows.append(Row(t: end - t0, order: order, line: line, reps: reps))
            order += 1
        }
        for x in state.ignored {
            let line: String = "name=input action=ignored input=\(enc(x.action)) reason=\(enc(x.reason))"
            rows.append(Row(t: x.t - t0, order: order, line: line, reps: nil))
            order += 1
        }
        rows.sort { (a: Row, b: Row) -> Bool in
            if a.t != b.t {
                return a.t < b.t
            }
            return a.order < b.order
        }
        var out: [Line] = []
        for (i, row) in rows.enumerated() {
            var line: String = "\(row.line) seq=\(i + 1)"
            if let reps = row.reps {
                line += " reps=\(repsText(reps))"
            }
            out.append(Line(t: row.t, text: line))
        }
        return out
    }
}
