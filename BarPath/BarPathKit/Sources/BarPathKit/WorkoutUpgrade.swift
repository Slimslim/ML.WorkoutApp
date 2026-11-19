import Foundation

/// Legacy (schema 1) workout definitions to the v2 structure (docs/WORKOUT_MODEL_RFC.md §7.3).
/// Python reference: tools/barpath/workout_upgrade.py; parity fixtures in
/// Fixtures/workouts/upgrade.json.
///
/// `upgrade(_:)` is pure: it returns the old definition with `schemaVersion: 2` and a `structure`
/// added (every old key is kept, since older builds run them), plus a label and its reasons:
/// exact (the planned steps reproduce the old segment list), review (it runs, but the owner
/// checks it) or reencode (the old keys can't say what the workout is). Reasons that start with
/// "note:" are informational and don't change the label.
///
/// Only legacy rows are upgraded (`schemaVersion` absent, null or 1). A draft (0), a v2 row or an
/// unknown version comes back unchanged with the label "notLegacy": its authored structure is the
/// truth (RFC §14.3 A1, A4). Total: any JSON value gives a result, never a trap.
public enum WorkoutUpgrade {
    public static let labels: [String] = ["exact", "review", "reencode"]
    public static let notLegacy: String = "notLegacy"
    private static let partKeys: Set<String> = ["kind", "movement", "name", "target", "load"]
    private static let intLimit: Double = 9.0e18      // Python `_INT_LIMIT`
    private static let targetUnits: Set<String> = ["reps", "calories", "meters", "seconds", "ft", "yd", "mi"]
    private static let loadUnits: Set<String> = ["lb", "kg"]

    public struct Outcome: Equatable, Sendable {
        public let definition: JSONValue
        public let label: String
        public let reasons: [String]
    }

    private struct Flags {
        var label: String = "exact"
        var reasons: [String] = []
        var notes: [String] = []

        mutating func flag(_ lab: String, _ reason: String) {
            let a: Int = WorkoutUpgrade.labels.firstIndex(of: lab) ?? 0
            let b: Int = WorkoutUpgrade.labels.firstIndex(of: label) ?? 0
            if a > b {
                label = lab
            }
            if !reasons.contains(reason) {
                reasons.append(reason)
            }
        }

        mutating func note(_ n: String) {
            if !notes.contains(n) {
                notes.append(n)
            }
        }
    }

    /// Python `_pos_int`: a number >= 1 and below 9e18, truncated; nil for anything else. Below 1
    /// is refused: truncated, it would be 0 (a zero round size divides by zero).
    private static func positiveInt(_ v: JSONValue?) -> Int? {
        guard let v = v, let d = v.number, d.isFinite, d >= 1, d < intLimit else {
            return nil
        }
        return v.intValue
    }

    /// Python `_whole`: a finite number with no fraction.
    private static func whole(_ v: JSONValue?) -> Bool {
        guard let d = v?.number, d.isFinite else {
            return false
        }
        return d == d.rounded()
    }

    /// Python `_seconds_target`: the positive whole seconds of a seconds target.
    private static func secondsTarget(_ seg: [String: JSONValue]) -> Int? {
        guard let t = seg["target"]?.object, t["unit"]?.string == "seconds" else {
            return nil
        }
        return positiveInt(t["value"])
    }

    /// Python `_invalid`: a field the v2 validator refuses.
    private static func invalid(_ seg: [String: JSONValue]) -> Bool {
        guard let kind = seg["kind"]?.string else {
            return true
        }
        let t: [String: JSONValue]? = seg["target"]?.object
        if kind == "rest" {
            if let t = t, t["unit"]?.string == "seconds" {
                return positiveInt(t["value"]) == nil
            }
            return false
        }
        guard let mv = seg["movement"]?.string, !mv.isEmpty else {
            return true
        }
        if let t = t {
            guard let unit = t["unit"]?.string, targetUnits.contains(unit),
                  let value = t["value"]?.number, value.isFinite, value > 0 else {
                return true
            }
        }
        if let ld = seg["load"]?.object {
            guard let lv = ld["value"]?.number, lv.isFinite, let unit = ld["unit"]?.string,
                  loadUnits.contains(unit) else {
                return true
            }
            if let count = ld["count"], !(whole(count) && (count.number ?? 0) >= 1) {
                return true
            }
        }
        return false
    }

    private static func isRest(_ seg: [String: JSONValue]) -> Bool {
        return seg["kind"]?.string == "rest"
    }

    private static func node(_ seg: [String: JSONValue], _ pid: String, _ team: String,
                             _ flags: inout Flags) -> JSONValue {
        if isRest(seg) {
            var rest: [String: JSONValue] = ["id": .string(pid)]
            if let secs = secondsTarget(seg) {
                rest["seconds"] = .int(secs)
            }
            return .object(["rest": .object(rest)])
        }
        var part: [String: JSONValue] = ["id": .string(pid)]
        for k in ["kind", "movement", "name"] {
            if let v = seg[k] {
                part[k] = v
            }
        }
        if let t = seg["target"]?.object {
            part["target"] = .object(["value": t["value"] ?? .null, "unit": t["unit"] ?? .null])
        }
        if let ld = seg["load"]?.object {
            part["load"] = .object(["value": ld["value"] ?? .null, "unit": ld["unit"] ?? .null,
                                    "count": ld["count"] ?? .int(1)])
        }
        if team == "doubles" || team == "team" {
            part["who"] = .string(seg["kind"]?.string == "run" ? "together" : "shared")
            flags.note("note:partnerSplitAssumed")
        }
        return .object(["part": .object(part)])
    }

    private static func content(_ n: JSONValue) -> [String: JSONValue] {
        return n["rest"]?.object ?? n["part"]?.object ?? [:]
    }

    /// (body of round 1, vary) when every round has the same shape, else nil. Positions whose
    /// content differs between rounds get a `vary` list of full patches.
    private static func roundsBody(_ rounds: [[[String: JSONValue]]], _ team: String, _ flags: inout Flags,
                                   prefix: String = "p") -> (body: [JSONValue], vary: [String: JSONValue])? {
        guard let first = rounds.first else {
            return nil
        }
        let shape: [Bool] = first.map { isRest($0) }
        for r in rounds where r.count != shape.count || r.map({ isRest($0) }) != shape {
            return nil
        }
        var body: [JSONValue] = []
        var vary: [String: JSONValue] = [:]
        for j in 0..<shape.count {
            let pid: String = "\(prefix)\(j + 1)"
            var nodes: [JSONValue] = []
            for r in rounds {
                nodes.append(node(r[j], pid, team, &flags))
            }
            body.append(nodes[0])
            let contents: [[String: JSONValue]] = nodes.map { content($0) }
            let c0: String = JSONValue.object(contents[0]).canonicalJSON
            if contents.allSatisfy({ JSONValue.object($0).canonicalJSON == c0 }) {
                continue
            }
            let keys0: Set<String> = Set(contents[0].keys)
            if contents.contains(where: { Set($0.keys) != keys0 }) {
                return nil                  // a patch can't remove a key: not expressible as vary
            }
            vary[pid] = .array(contents.map { c -> JSONValue in
                var p: [String: JSONValue] = c
                p.removeValue(forKey: "id")
                return .object(p)
            })
        }
        return (body, vary)
    }

    private static func chunks(_ segs: [[String: JSONValue]], _ size: Int) -> [[[String: JSONValue]]] {
        var out: [[[String: JSONValue]]] = []
        let n: Int = max(size, 1)
        var i: Int = 0
        while i < segs.count {
            out.append(Array(segs[i..<min(i + n, segs.count)]))
            i += n
        }
        return out
    }

    private static func flat(_ segs: [[String: JSONValue]], _ team: String, _ flags: inout Flags) -> [JSONValue] {
        var out: [JSONValue] = []
        for (i, s) in segs.enumerated() {
            out.append(node(s, "s\(i + 1)", team, &flags))
        }
        return out
    }

    /// {definition, label, reasons} for one old definition.
    public static func upgrade(_ old: JSONValue) -> Outcome {
        let o: [String: JSONValue] = old.object ?? [:]
        if let sv = o["schemaVersion"], !sv.isNull, sv.number != 1 {
            var why: String = "unknownSchemaVersion"
            if let d = sv.number {
                if d == 0 {
                    why = "draft"
                } else if d >= 2 {
                    why = "alreadyV2"
                }
            }
            return Outcome(definition: old, label: notLegacy, reasons: [why])
        }
        let segs: [[String: JSONValue]] = (o["segments"]?.array ?? []).compactMap { $0.object }
        let fmt: String? = o["format"]?.string
        let team: String = o["team"]?.string ?? "solo"
        let cap: Int? = positiveInt(o["timeCapSeconds"])
        let r: Int? = positiveInt(o["roundSize"])
        let interval: Int? = positiveInt(o["intervalSeconds"])
        var flags = Flags()

        for k in ["timeCapSeconds", "roundSize", "intervalSeconds"] {
            if let v = o[k], !v.isNull, positiveInt(v) == nil || !whole(v) {
                flags.flag("reencode", "invalidField")   // e.g. 0, 0.5, 600.5, -1 or "x"
            }
        }
        for s in segs {
            if invalid(s) {
                flags.flag("reencode", "invalidField")
            }
            if isRest(s), let secs = secondsTarget(s), let v = s["target"]?["value"]?.number, v != Double(secs) {
                flags.flag("review", "restSecondsRounded")
            }
            if isRest(s), let t = s["target"]?.object, t["unit"]?.string != "seconds" {
                flags.flag("review", "restTargetDropped")   // a rest keeps only seconds
            }
            if s.keys.contains(where: { !partKeys.contains($0) }) {
                flags.note("note:segmentKeysNotCopied")  // they stay in the old `segments`
            }
            if isRest(s) {
                continue
            }
            guard let t = s["target"]?.object else {
                flags.flag("review", "partWithoutTarget")
                continue
            }
            if t["unit"]?.string == "seconds" {
                flags.flag("review", "secondsTargetPart")  // the old app let the athlete end it; the engine's clock will
            }
        }

        var body: [JSONValue] = []
        var score: [String: JSONValue] = ["type": .string("none")]
        if segs.isEmpty {
            flags.flag("reencode", "noSegments")
        } else if fmt == "forTime" {
            let timedRests: Int = segs.filter { isRest($0) && $0["target"]?.object?["unit"]?.string == "seconds" }.count
            if cap != nil && timedRests >= 2 {
                flags.flag("reencode", "windowsStoredAsRests")
            }
            body = forTimeBody(segs, r, team, &flags)
            if let c = cap {
                body = [.object(["timed": .object(["id": .string("cap"), "seconds": .int(c), "early": .string("next"),
                                                   "late": .string("continue"), "body": .array(body)])])]
                score = ["type": .string("time"), "atCap": .string("totalReps")]
            } else {
                score = ["type": .string("time")]
            }
        } else if fmt == "amrap" && cap == nil {
            flags.flag("reencode", "amrapWithoutCap")   // the old app ran the list and stopped: keep that
            body = flat(segs, team, &flags)
            score = ["type": .string("roundsReps")]
        } else if fmt == "amrap", let c = cap {
            flags.flag("review", "listedRounds")
            let size: Int = r ?? segs.count
            var rounds = chunks(segs, size)
            if let last = rounds.last, last.count != size, rounds.count > 1 {
                rounds.removeLast()
                flags.flag("review", "partialLastRound")
            }
            var rbody: [JSONValue]
            let vary: [String: JSONValue]
            if let rb = roundsBody(rounds, team, &flags) {
                rbody = rb.body
                vary = rb.vary
            } else {
                flags.flag("reencode", "roundsDiffer")
                rbody = []
                for (i, s) in rounds[0].enumerated() {
                    rbody.append(node(s, "p\(i + 1)", team, &flags))
                }
                vary = [:]
            }
            var rep: [String: JSONValue] = ["id": .string("rp"), "times": .null, "listRounds": .int(rounds.count),
                                            "body": .array(rbody)]
            if !vary.isEmpty {
                rep["vary"] = .object(vary)
                rep["then"] = .string("repeatLast")
                flags.flag("review", "listedRoundsVary")
            }
            body = [.object(["timed": .object(["id": .string("amrap"), "seconds": .int(c), "early": .string("next"),
                                               "late": .string("end"),
                                               "body": .array([.object(["repeat": .object(rep)])])])])]
            score = ["type": .string("roundsReps")]
        } else if fmt == "emom" {
            flags.flag("review", "movesToEngine")
            if interval == nil || r == nil {
                flags.flag("reencode", "emomWithoutRounds")
            }
            body = emomBody(segs, interval ?? 60, r ?? segs.count, team, &flags)
            let nWindows: Int = chunks(segs, r ?? segs.count).count
            if let c = cap, let iv = interval {
                let product = iv.multipliedReportingOverflow(by: nWindows)
                if product.overflow || c != product.partialValue {
                    flags.flag("review", "capNotWindows")
                }
            }
            score = ["type": .string("windowsCompleted")]
        } else {
            flags.flag("reencode", "unknownFormat")
            body = flat(segs, team, &flags)
        }

        var out: [String: JSONValue] = o
        out["schemaVersion"] = .int(2)
        out["structure"] = .object(["score": .object(score), "body": .array(body)])
        if let p = try? WorkoutEngine.plan(.object(out)) {
            if flags.label == "exact" && !stepsMatch(p, segs) {
                flags.flag("review", "stepsDiffer")
            }
        } else {
            flags.flag("reencode", "notRunnable")
        }
        setFidelity(&out, flags.label, flags.reasons)
        return Outcome(definition: .object(out), label: flags.label, reasons: flags.reasons + flags.notes)
    }

    /// `approx` reasons written by `upgrade()` start with this (Python `UPGRADE_REASON_PREFIX`).
    public static let upgradeReasonPrefix: String = "upgrade:"

    /// Python `_set_fidelity`: the label saved on the definition (RFC §14.3 B2, A4).
    /// `fidelity: "exact"` only when the structure runs what the old keys ran; otherwise
    /// `fidelity: "approx"` with the reasons in `approx` as "upgrade:<reason>" (notes stay out).
    private static func setFidelity(_ out: inout [String: JSONValue], _ label: String, _ reasons: [String]) {
        out["approx"] = nil
        if label == "exact" {
            out["fidelity"] = .string("exact")
        } else {
            out["fidelity"] = .string("approx")
            out["approx"] = .array(reasons.map { JSONValue.string(upgradeReasonPrefix + $0) })
        }
    }

    private static func forTimeBody(_ segs: [[String: JSONValue]], _ r: Int?, _ team: String,
                                    _ flags: inout Flags) -> [JSONValue] {
        if let r = r, segs.count % r == 0, segs.count / r >= 2 {
            let rounds = chunks(segs, r)
            if let rb = roundsBody(rounds, team, &flags) {
                var rep: [String: JSONValue] = ["id": .string("rp"), "times": .int(rounds.count), "body": .array(rb.body)]
                if !rb.vary.isEmpty {
                    rep["vary"] = .object(rb.vary)
                }
                return [.object(["repeat": .object(rep)])]
            }
        }
        return flat(segs, team, &flags)
    }

    /// One window per old round: its work parts; the rest that ends an old round (no target) is
    /// the automatic rest. A rest with seconds inside an interval (Tabata 20/10 was stored that
    /// way) can't be said in the old keys' meaning: re-encode.
    private static func emomBody(_ segs: [[String: JSONValue]], _ interval: Int, _ r: Int, _ team: String,
                                 _ flags: inout Flags) -> [JSONValue] {
        var windows: [[[String: JSONValue]]] = []
        for chunk in chunks(segs, r) {
            var work = chunk
            while let last = work.last, isRest(last), last["target"]?.object == nil {
                work.removeLast()
            }
            if work.contains(where: { isRest($0) }) {
                flags.flag("reencode", "restInsideInterval")
                work = work.filter { !isRest($0) }
            }
            if !work.isEmpty {
                windows.append(work)
            }
        }
        if windows.isEmpty {
            return []
        }
        func timed(_ id: String, _ wbody: [JSONValue]) -> JSONValue {
            return .object(["timed": .object(["id": .string(id), "seconds": .int(interval), "early": .string("wait"),
                                              "late": .string("cut"), "body": .array(wbody)])])
        }
        if let rb = roundsBody(windows, team, &flags) {
            var rep: [String: JSONValue] = ["id": .string("rp"), "times": .int(windows.count),
                                            "body": .array([timed("w", rb.body)])]
            if !rb.vary.isEmpty {
                rep["vary"] = .object(rb.vary)
            }
            return [.object(["repeat": .object(rep)])]
        }
        var out: [JSONValue] = []
        for (k, w) in windows.enumerated() {
            var nodes: [JSONValue] = []
            for (i, s) in w.enumerated() {
                nodes.append(node(s, "w\(k + 1)p\(i + 1)", team, &flags))
            }
            out.append(timed("w\(k + 1)", nodes))
        }
        return out
    }

    /// Python `_same_number`: numbers compare by value (15 == 15.0), anything else by equality.
    private static func sameNumber(_ a: JSONValue?, _ b: JSONValue?) -> Bool {
        let x: JSONValue = a ?? .null
        let y: JSONValue = b ?? .null
        if let p = x.number, let q = y.number {
            return p == q
        }
        return x == y
    }

    /// The planned (non-automatic) steps reproduce the old segments in order: kind, movement,
    /// name, target and load, rests with the same seconds.
    private static func stepsMatch(_ p: WorkoutPlan, _ segs: [[String: JSONValue]]) -> Bool {
        let steps: [EngineStep] = p.steps.filter { !$0.auto }
        if steps.count != segs.count {
            return false
        }
        for (st, seg) in zip(steps, segs) {
            if isRest(seg) {
                let want: Int? = secondsTarget(seg)
                if st.kind != "rest" || st.restSeconds != want {
                    return false
                }
                continue
            }
            guard st.kind == "part" else {
                return false
            }
            let part: [String: JSONValue] = st.part ?? [:]
            for k in ["kind", "movement", "name"] where (part[k] ?? .null) != (seg[k] ?? .null) {
                return false
            }
            let t: [String: JSONValue]? = seg["target"]?.object
            let pt: [String: JSONValue]? = part["target"]?.object
            if (t == nil) != (pt == nil) {
                return false
            }
            if let t = t, let pt = pt {
                if (t["unit"] ?? .null) != (pt["unit"] ?? .null) || !sameNumber(t["value"], pt["value"]) {
                    return false
                }
            }
            let ld: [String: JSONValue]? = seg["load"]?.object
            let pl: [String: JSONValue]? = part["load"]?.object
            if (ld == nil) != (pl == nil) {
                return false
            }
            if let ld = ld, let pl = pl {
                if (ld["unit"] ?? .null) != (pl["unit"] ?? .null) || !sameNumber(ld["value"], pl["value"])
                    || !sameNumber(ld["count"] ?? .int(1), pl["count"] ?? .int(1)) {
                    return false
                }
            }
        }
        return true
    }
}
