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
/// `seq` orders lines written at the same time. Times are integer ms from START.
///
/// Text values (ids, anchors, inputs, reasons) are percent-encoded: every UTF-8 byte outside
/// `[A-Za-z0-9._:-]` becomes `%XX`, so no whitespace or comma reaches the loader's
/// `key=([^,\s]+)`. The Python loader turns anything `float()` accepts into a number, so a value
/// that starts like a number (a digit, `.` or `-`) or spells inf / infinity / nan has its first
/// character encoded too: `step=007` is written `step=%3007`.
public enum WorkoutEngineCSV {
    public static let planSchema: Int = 2

    private static let safe: Set<UInt8> = Set(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-".utf8))
    private static let numberStart: Set<UInt8> = Set(Array("0123456789.-".utf8))
    private static let numberWords: Set<String> = ["inf", "infinity", "nan"]
    private static let hexDigits: [Character] = Array("0123456789ABCDEF")

    public static func enc(_ s: String) -> String {
        let bytes: [UInt8] = Array(s.utf8)
        let word: Bool = numberWords.contains(s.lowercased())
        var out: String = ""
        for (i, b) in bytes.enumerated() {
            let firstNumeric: Bool = i == 0 && (numberStart.contains(b) || word)
            if safe.contains(b) && !firstNumeric {
                out.unicodeScalars.append(Unicode.Scalar(b))
            } else {
                out.append("%")
                out.append(hexDigits[Int(b >> 4)])
                out.append(hexDigits[Int(b & 0x0f)])
            }
        }
        return out
    }

    public static func dec(_ s: String) -> String {
        return s.removingPercentEncoding ?? s
    }

    /// The `plan` line and one `bell` line per planned boundary. The epochs are Int64: epoch ms
    /// doesn't fit a 32-bit Int (arm64_32 watches).
    public static func planLines(_ plan: WorkoutPlan, startEpochMs: Int64, startUptimeMs: Int64) -> [String] {
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

    /// Reps as text: a whole number without a decimal point, other numbers as written by Python's
    /// repr, anything else as encoded text (Python `_reps_text`).
    static func repsText(_ v: JSONValue) -> String {
        switch v {
        case .bool(let b):
            return b ? "true" : "false"
        case .int(let i):
            return String(i)
        case .double(let d):
            if let i = Int(exactly: d) {
                return String(i)
            }
            if d.isFinite && d == d.rounded() {
                return String(format: "%.0f", d)
            }
            return "\(d)"
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

/// The CSV time (systemUptime, seconds) of engine lines (docs/WORKOUT_MODEL_RFC.md §9). The
/// engine counts ms on `CLOCK_MONOTONIC`, which counts sleep; `systemUptime`, which every other
/// CSV line uses, does not. So the sleep measured so far is taken off, and a line is never
/// stamped before START or before a line already written. The clamp moves only when a line is
/// written (`stamp`), so a tick that writes nothing leaves the next line at its own time.
public struct WorkoutEngineCSVClock: Equatable, Sendable {
    public let startUptime: Double
    public private(set) var lastLineUptime: Double

    public init(startUptime: Double) {
        self.startUptime = startUptime
        self.lastLineUptime = startUptime
    }

    /// The uptime of engine time `ms`, given the sleep measured so far (seconds), unclamped.
    public func uptime(ms: Int, sleep: Double) -> Double {
        return startUptime + Double(ms) / 1000 - max(0, sleep)
    }

    /// The uptime for a line written now at engine time `ms`: never before START nor before the
    /// last line written. Moves the clamp.
    public mutating func stamp(ms: Int, sleep: Double) -> Double {
        let v: Double = max(uptime(ms: ms, sleep: sleep), startUptime, lastLineUptime)
        lastLineUptime = v
        return v
    }
}
