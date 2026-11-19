import Foundation

/// The watch session on the engine (docs/WORKOUT_MODEL_RFC.md §11 step 4, §4.2, §8, §14.3 E6).
/// Python reference: tools/barpath/workout_session.py; parity fixtures in
/// Fixtures/workouts/session.json. Pure: no clock, no files, no UI.
///
/// - `route`: which watch path runs a definition. Only a definition that carries a v2 structure
///   goes to the engine; everything else keeps the old path, unchanged.
/// - `EngineEvent(json:)` (WorkoutEngine.swift): events read back from a checkpoint, clamped and
///   with unknown keys kept.
/// - `makeCheckpoint` / `recover`: the engine's crash checkpoint, canonical JSON (Swift and Python
///   write the same bytes; decode then encode gives the bytes back).
/// - `project` / `progress`: the engine state as the old flat segment list and a
///   `WorkoutProgress`, so the watch's existing workout views and result show an engine run.
/// - `latestAsk`, `nextBell`, `newLines`: the reps question, the timer's clock, the CSV lines.
///
/// Times: engine times are Int ms on the session's monotonic clock (START = 0 on the watch).
/// Wall-clock epochs are Int64 ms or Double seconds, never Int: on arm64_32 watches Int is 32 bits.
public enum WorkoutEngineSession {
    public static let checkpointVersion: Int = 1

    // MARK: - Routing

    public enum Route: Equatable, Sendable {
        /// The old path. `reason` is set when the engine refused the definition but its old keys
        /// are exact (`fidelity: "exact"` with `segments`, RFC §14.3 A4).
        case legacy(reason: String?, missing: [String])
        case engine
        /// The engine can't run it: draft, updateApp, invalid, tooLarge, empty, noScale.
        case refused(reason: String, missing: [String])
    }

    /// Python `carries_v2`: a `structure` key, or a schema version other than 1.
    public static func carriesV2(_ raw: JSONValue) -> Bool {
        guard let o = raw.object else {
            return false
        }
        if o["structure"] != nil {
            return true
        }
        if let d = o["schemaVersion"]?.number {
            return d != 1
        }
        return false
    }

    /// Python `route`.
    public static func route(_ raw: JSONValue, engineFeatures: Set<String> = [], scale: String? = nil,
                             standard: String = "M", choices: [String: String] = [:]) -> Route {
        guard carriesV2(raw) else {
            return .legacy(reason: nil, missing: [])
        }
        var reason: String = "invalid"
        var missing: [String] = []
        if let st = raw["structure"], st.object == nil {
            reason = "invalid"
        } else {
            do {
                _ = try WorkoutEngine.plan(raw, scale: scale, standard: standard, choices: choices,
                                           engineFeatures: engineFeatures)
                return .engine
            } catch let e as WorkoutNotRunnable {
                reason = e.reason
                missing = e.missing
            } catch {
                reason = "invalid"
            }
        }
        if raw["fidelity"]?.string == "exact", let segs = raw["segments"]?.array, !segs.isEmpty {
            return .legacy(reason: reason, missing: missing)
        }
        return .refused(reason: reason, missing: missing)
    }

    /// The route as Python writes it ({"route", "reason", "missing"}), for the parity test.
    public static func routeJSON(_ r: Route) -> JSONValue {
        switch r {
        case .engine:
            return .object(["route": .string("engine")])
        case .legacy(let reason, let missing):
            guard let reason = reason else {
                return .object(["route": .string("legacy")])
            }
            return .object(["route": .string("legacy"), "reason": .string(reason),
                            "missing": .array(missing.map { JSONValue.string($0) })])
        case .refused(let reason, let missing):
            return .object(["route": .string("refused"), "reason": .string(reason),
                            "missing": .array(missing.map { JSONValue.string($0) })])
        }
    }

    // MARK: - Checkpoint

    /// A whole number as JSON without trapping on 32-bit Int: `.int` when it fits, else `.double`
    /// (canonical JSON writes both as the same digits).
    public static func wholeNumber(_ v: Int64) -> JSONValue {
        if let i = Int(exactly: v) {
            return .int(i)
        }
        return .double(Double(v))
    }

    /// Python `options_dict`.
    public static func options(scale: String?, standard: String, choices: [String: String]) -> JSONValue {
        var c: [String: JSONValue] = [:]
        for (k, v) in choices {
            c[k] = .string(v)
        }
        var d: [String: JSONValue] = ["standard": .string(standard), "choices": .object(c)]
        if let s = scale {
            d["scale"] = .string(s)
        }
        return .object(d)
    }

    /// Python `make_checkpoint`: everything a relaunch needs to rebuild the run (RFC §8): the
    /// definition, the compiled plan and its hash, the planner version, `requires`, the plan
    /// options, the START wall time, `savedAtMs` (engine time when written) and every event the
    /// engine judged (no ticks). `watch` holds what the watch adds, carried unchanged.
    public static func makeCheckpoint(definition: JSONValue, plan: WorkoutPlan, state: EngineState,
                                      startEpochMs: Int64, savedAtMs: Int, options: JSONValue,
                                      watch: JSONValue) -> JSONValue {
        var req: [String] = []
        for r in definition["requires"]?.array ?? [] {
            if let s = r.string {
                req.append(s)
            }
        }
        req.sort { (a: String, b: String) -> Bool in
            return a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
        }
        return .object([
            "version": .int(checkpointVersion),
            "definition": definition,
            "options": options,
            "plan": plan.toJSON(),
            "planHash": .string(plan.hash),
            "planner": .int(WorkoutPlan.plannerVersion),
            "requires": .array(req.map { JSONValue.string($0) }),
            "startEpochMs": wholeNumber(startEpochMs),
            "savedAtMs": .int(savedAtMs),
            "events": .array(state.log.map { $0.toJSON() }),
            "watch": watch,
        ])
    }

    /// The checkpoint file's bytes: canonical JSON (Python `checkpoint_text`).
    public static func checkpointData(_ cp: JSONValue) -> Data {
        return Data(cp.canonicalJSON.utf8)
    }

    public enum Recovery {
        case ok(plan: WorkoutPlan, state: EngineState)
        /// version, invalid, draft, updateApp, tooLarge, empty, noScale, planChanged. The watch
        /// moves such a checkpoint aside, never deletes it (RFC §8).
        case refused(reason: String)
    }

    /// Python `recover`: the state replayed only up to `savedAtMs`, never caught up to now
    /// (RFC §4.2.11).
    public static func recover(_ cp: JSONValue, engineFeatures: Set<String> = []) -> Recovery {
        guard let v = cp["version"], v.bool == nil, v.number == Double(checkpointVersion) else {
            return .refused(reason: "version")
        }
        guard let definition = cp["definition"], definition.object != nil else {
            return .refused(reason: "invalid")
        }
        let opts: [String: JSONValue] = cp["options"]?.object ?? [:]
        var choices: [String: String] = [:]
        for (k, x) in opts["choices"]?.object ?? [:] {
            if let s = x.string {
                choices[k] = s
            }
        }
        let plan: WorkoutPlan
        do {
            plan = try WorkoutEngine.plan(definition, scale: opts["scale"]?.string,
                                          standard: opts["standard"]?.string ?? "M", choices: choices,
                                          engineFeatures: engineFeatures)
        } catch let e as WorkoutNotRunnable {
            return .refused(reason: e.reason)
        } catch {
            return .refused(reason: "invalid")
        }
        if plan.hash != cp["planHash"]?.string {
            return .refused(reason: "planChanged")
        }
        let events: [EngineEvent] = (cp["events"]?.array ?? []).map { EngineEvent(json: $0) }
        let saved: Int? = EngineEvent.clampedMs(cp["savedAtMs"])
        return .ok(plan: plan, state: WorkoutEngine.replay(plan, events, until: saved))
    }

    // MARK: - What the existing watch views show

    public struct Projection: Equatable, Sendable {
        /// One old flat segment per step, in run order (Python `legacy_segment`), as JSON.
        public var segments: [JSONValue]
        /// ms from START of each step reached (0 s for a step the clock skipped), never decreasing.
        public var starts: [Int]
        /// "crown" or "auto" for each start after the first: how the step before it ended.
        public var sources: [String]
        /// ms from START, or nil (not finished, or ended with End).
        public var finish: Int?
        public var finishSource: String?
    }

    private static let legacyKinds: Set<String> = ["run", "station", "transition"]
    private static let distanceMeters: [String: Double] = ["meters": 1.0, "ft": 0.3048, "yd": 0.9144, "mi": 1609.344]

    /// Python `workout_structure.legacy_segment`: one old flat segment for a plan step.
    public static func legacySegment(_ step: EngineStep) -> JSONValue {
        if step.kind == "rest" {
            var seg: [String: JSONValue] = ["kind": .string("rest"), "movement": .string("rest"),
                                            "name": .string("Rest")]
            if let rs = step.restSeconds, !step.auto {
                seg["target"] = .object(["value": .int(rs), "unit": .string("seconds")])
            }
            return .object(seg)
        }
        let part: [String: JSONValue] = step.part ?? [:]
        let movement: String = part["movement"]?.string ?? "part"
        let kind: String = part["kind"]?.string ?? "station"
        var name: String = Movement.displayName(movement)
        if let n = part["name"]?.string, !n.isEmpty {
            name = n
        }
        var seg: [String: JSONValue] = ["kind": .string(legacyKinds.contains(kind) ? kind : "station"),
                                        "movement": .string(movement), "name": .string(name)]
        if let t = part["target"]?.object, !t.isEmpty, !(t["max"]?.truthy ?? false), let value = t["value"],
           let unit = t["unit"] {
            if let u = unit.string, let f = distanceMeters[u] {
                if u == "meters" {
                    seg["target"] = .object(["value": value, "unit": .string("meters")])
                } else if let v = value.number {
                    let m: Double = (v * f * 10).rounded(.toNearestOrEven) / 10
                    seg["target"] = .object(["value": JSONValue.numeric(m), "unit": .string("meters")])
                }
            } else {
                seg["target"] = .object(["value": value, "unit": unit])
            }
        }
        if let ld = part["load"]?.object, let value = ld["value"] {
            seg["load"] = .object(["value": value, "unit": ld["unit"] ?? .null, "count": ld["count"] ?? .int(1)])
        }
        return .object(seg)
    }

    /// Python `project`.
    public static func project(_ st: EngineState) -> Projection {
        var out = Projection(segments: st.seq.map { legacySegment(st.steps[$0]) }, starts: [], sources: [],
                             finish: nil, finishSource: nil)
        guard let t0 = st.t0, st.pos >= 0, !st.seq.isEmpty else {
            return out
        }
        let upto: Int = min(st.pos, st.seq.count - 1)
        var last: Int = 0
        for p in 0...upto {
            let r: StepRecord? = st.rec[st.seq[p]]
            var v: Int = last
            if let s = r?.start {
                v = max(s - t0, last)
            }
            out.starts.append(v)
            last = v
            if p > 0 {
                let prev: StepRecord? = st.rec[st.seq[p - 1]]
                out.sources.append(prev?.endedBy == "athlete" ? "crown" : "auto")
            }
        }
        if st.done, st.endedBy != "end", let d = st.doneT {
            out.finish = max(d - t0, last)
            out.finishSource = st.endedBy == "athlete" ? "crown" : "auto"
        }
        return out
    }

    /// A projected segment as the old typed model. Fields this build can't type are left out
    /// (an unknown kind is a station, an unknown target unit has no target).
    public static func segment(_ v: JSONValue) -> WorkoutSegment {
        let kind: SegmentKind = SegmentKind(rawValue: v["kind"]?.string ?? "") ?? .station
        let movement: String = v["movement"]?.string ?? "part"
        let name: String = v["name"]?.string ?? Movement.displayName(movement)
        var target: SegmentTarget? = nil
        if let t = v["target"], let value = t["value"]?.number, value.isFinite,
           let unit = TargetUnit(rawValue: t["unit"]?.string ?? "") {
            target = SegmentTarget(value, unit)
        }
        var load: SegmentLoad? = nil
        if let l = v["load"], let value = l["value"]?.number, value.isFinite,
           let unit = SegmentLoad.Unit(rawValue: l["unit"]?.string ?? "") {
            var count: Int = 1
            if let c = l["count"]?.number, c.isFinite, c >= 1, c < 1000 {
                count = Int(c)
            }
            load = SegmentLoad(value, unit, count: count)
        }
        return WorkoutSegment(kind: kind, movement: movement, name: name, target: target, load: load)
    }

    /// The old typed definition for a projection: the raw definition's id, names, team, format
    /// and Health activity, with the projected segments and no clock fields (the engine owns the
    /// clock, so the old cap, interval and round-size logic never runs on it).
    public static func definition(_ raw: JSONValue, _ pr: Projection) -> WorkoutDefinition {
        let id: String = raw["id"]?.string ?? "engine"
        let name: String = raw["name"]?.string ?? "Workout"
        return WorkoutDefinition(id: id, name: name, shortName: raw["shortName"]?.string ?? name,
                                 format: WorkoutFormat(rawValue: raw["format"]?.string ?? "") ?? .forTime,
                                 team: TeamFormat(rawValue: raw["team"]?.string ?? "") ?? .solo,
                                 timeCapSeconds: nil,
                                 healthKitActivity: raw["healthKitActivity"]?.string ?? "crossTraining",
                                 segments: pr.segments.map { segment($0) })
    }

    /// The projection as a `WorkoutProgress` (START at `startEpoch`, seconds since 1970), which
    /// the existing views and the result's splits read.
    public static func progress(_ raw: JSONValue, _ pr: Projection, startEpoch: Double) -> WorkoutProgress {
        var p = WorkoutProgress(definition: definition(raw, pr))
        guard let first = pr.starts.first else {
            return p
        }
        p.start(at: startEpoch + Double(first) / 1000)
        var i: Int = 1
        while i < pr.starts.count {
            let source: AdvanceSource = (i - 1 < pr.sources.count && pr.sources[i - 1] == "crown") ? .crown : .auto
            p.advance(at: startEpoch + Double(pr.starts[i]) / 1000, source: source)
            i += 1
        }
        if let f = pr.finish {
            p.finish(at: startEpoch + Double(f) / 1000, source: pr.finishSource == "crown" ? .crown : .auto)
        }
        return p
    }

    /// Python `latest_ask`: only the latest reps question is shown (an earlier one a late Crown
    /// made stale never is).
    public static func latestAsk(_ st: EngineState) -> String? {
        return st.asks.last
    }

    public struct Bell: Equatable, Sendable {
        public let t: Int            // ms from START
        public let finish: Bool      // this bell ends the whole workout
    }

    /// Python `next_bell`: the earliest clock that will end the step running now, or nil when
    /// only the athlete ends it.
    public static func nextBell(_ st: EngineState) -> Bell? {
        guard let s = st.current, let t0 = st.t0 else {
            return nil
        }
        var best: (Int, Bool)? = nil
        func consider(_ t: Int, _ fin: Bool) {
            if let b = best {
                if t < b.0 || (t == b.0 && !fin && b.1) {
                    best = (t, fin)
                }
            } else {
                best = (t, fin)
            }
        }
        if let d = st.due {
            consider(d, false)
        }
        var keys: [String] = s.windows
        if let w = s.waitWindow, !w.isEmpty {
            keys.append(w)
        }
        if let w = s.mergedWindow, !w.isEmpty {
            keys.append(w)
        }
        for k in keys {
            guard let w = st.windows[k], let ws = st.wstate[k], ws.open, w.late != "continue" else {
                continue
            }
            consider(ws.end, w.depth == 1 && w.late == "end")
        }
        guard let b = best else {
            return nil
        }
        return Bell(t: b.0 - t0, finish: b.1)
    }

    // MARK: - CSV lines written as the run goes

    /// A line without its ` seq=<n>` token (Python `_key`).
    static func lineKey(_ text: String) -> String {
        return text.components(separatedBy: " ").filter { !$0.hasPrefix("seq=") }.joined(separator: " ")
    }

    /// Python `new_lines`: the step and ignored-input lines not written yet; `written` (keyed by
    /// time and line without `seq`) is updated.
    /// A step line whose reps change later is written again with them (the loader keeps the last
    /// line per step); nothing is ever removed.
    public static func newLines(_ st: EngineState, written: inout [String: Int]) -> [WorkoutEngineCSV.Line] {
        var out: [WorkoutEngineCSV.Line] = []
        var seen: [String: Int] = [:]
        for line in WorkoutEngineCSV.eventLines(st) {
            // With its time: an undone end and the real one differ only in t (Python `(t, key)`).
            let k: String = "\(line.t) " + lineKey(line.text)
            let n: Int = (seen[k] ?? 0) + 1
            seen[k] = n
            if n > (written[k] ?? 0) {
                written[k] = n
                out.append(line)
            }
        }
        return out
    }
    // MARK: - The phone: what it sends to the watch (W27 PR3b)

    /// Python `PHONE_V2_KEY`: the new application-context / message key that carries a row's v2
    /// JSON beside today's typed `workoutDefinition` (which stays, for older watches).
    public static let phoneV2Key: String = "workoutDefinitionV2"
    /// The watch payload budget (RFC §8, Python `workout_structure.MAX_PAYLOAD_BYTES`).
    public static let maxPayloadBytes: Int = 16 * 1024

    public enum PhoneSend: Equatable, Sendable {
        /// Send the row's v2 JSON in `phoneV2Key`: the watch runs it on the engine.
        case engine
        /// Old keys only, as today. reason: notV2, needsOwner, textOnly, refused, tooBig.
        case legacy(reason: String, refusal: String?)
    }

    /// Python `phone_route`. A legacy row never goes to the engine (a Swift `exact` isn't trusted
    /// until the validator is ported); nor does a row the Python upgrade labelled review or
    /// reencode (`approx` holds "upgrade:<reason>") until the owner signs it off (RFC §7.3).
    public static func phoneRoute(_ raw: JSONValue, engineFeatures: Set<String> = []) -> PhoneSend {
        guard carriesV2(raw) else {
            return .legacy(reason: "notV2", refusal: nil)
        }
        if let a = raw["approx"], !a.isNull, a.array == nil {
            return .legacy(reason: "needsOwner", refusal: nil)    // malformed: not trusted (#116 review)
        }
        if let approx = raw["approx"]?.array,
           approx.contains(where: { $0.string?.hasPrefix(WorkoutUpgrade.upgradeReasonPrefix) ?? false }) {
            return .legacy(reason: "needsOwner", refusal: nil)
        }
        if raw["fidelity"]?.string == "textOnly" {
            return .legacy(reason: "textOnly", refusal: nil)
        }
        switch route(raw, engineFeatures: engineFeatures) {
        case .engine:
            break
        case .legacy(let reason, _):
            return .legacy(reason: "refused", refusal: reason ?? "legacy")
        case .refused(let reason, _):
            return .legacy(reason: "refused", refusal: reason)
        }
        if raw.canonicalJSON.utf8.count > maxPayloadBytes {
            return .legacy(reason: "tooBig", refusal: nil)
        }
        return .engine
    }

    /// The route as Python writes it, for the parity test.
    public static func phoneRouteJSON(_ r: PhoneSend) -> JSONValue {
        switch r {
        case .engine:
            return .object(["send": .string("engine")])
        case .legacy(let reason, let refusal):
            var d: [String: JSONValue] = ["send": .string("legacy"), "reason": .string(reason)]
            if let x = refusal {
                d["refusal"] = .string(x)
            }
            return .object(d)
        }
    }

    /// The v2 JSON the phone sends in `phoneV2Key`, or nil when the row keeps the old path.
    public static func phonePayload(_ raw: JSONValue?) -> Data? {
        guard let raw = raw, phoneRoute(raw) == .engine else {
            return nil
        }
        return Data(raw.canonicalJSON.utf8)
    }

    /// The fidelity the phone stores for a row (Python `phone_fidelity`, RFC §14.3 B2).
    public struct StoredFidelity: Codable, Equatable, Sendable {
        public var fidelity: String?
        public var approx: [String]
        /// The upgrade label (exact, review, reencode) of a legacy row upgraded on the phone.
        public var label: String?

        public init(fidelity: String?, approx: [String], label: String?) {
            self.fidelity = fidelity
            self.approx = approx
            self.label = label
        }

        public func toJSON() -> JSONValue {
            return .object(["fidelity": fidelity.map { JSONValue.string($0) } ?? .null,
                            "approx": .array(approx.map { JSONValue.string($0) }),
                            "label": label.map { JSONValue.string($0) } ?? .null])
        }
    }

    /// A v2 row's own `fidelity` / `approx`; a legacy row is upgraded here (on the phone only,
    /// never on the watch) and its label saved the same way.
    public static func phoneFidelity(_ raw: JSONValue) -> StoredFidelity {
        guard raw.object != nil else {
            return StoredFidelity(fidelity: nil, approx: [], label: nil)
        }
        if carriesV2(raw) {
            let approx: [String] = (raw["approx"]?.array ?? []).compactMap { $0.string }
            return StoredFidelity(fidelity: raw["fidelity"]?.string, approx: approx, label: nil)
        }
        let u = WorkoutUpgrade.upgrade(raw)
        let approx: [String] = (u.definition["approx"]?.array ?? []).compactMap { $0.string }
        return StoredFidelity(fidelity: u.definition["fidelity"]?.string, approx: approx, label: u.label)
    }
}
