import Foundation

// Workout timeline engine: plan, reduce, replay (docs/WORKOUT_MODEL_RFC.md §4, §5).
//
// A line-for-line port of the Python reference tools/barpath/workout_engine.py. The parity tests
// (Tests/BarPathKitTests/WorkoutEngineParityTests.swift) run the fixtures Python writes into
// Fixtures/workouts and require the same plan (canonical JSON and SHA-256), effects, facts and
// score. Change the Python first, regenerate (`python3 tools/make_workout_fixtures.py`), then
// port the change here.
//
// - `WorkoutEngine.plan(_:)` expands a v2 `structure` into steps and its clock boundaries.
// - `WorkoutEngine.reduce(_:_:)` is the state machine. Time is an argument (integer ms); nothing
//   here reads a clock. It returns the new state and the effects (haptics, questions, hints).
// - `WorkoutEngine.replay(_:_:until:)` rebuilds a state from saved events (crash recovery).
//
// The reader is total (RFC 14.4, lenient on read): where Python would raise on malformed input,
// this file picks a safe default, and `plan` refuses (WorkoutNotRunnable "invalid" / "tooLarge" /
// "empty") any number it would consume outside MAX_SECONDS / MAX_TIMES / MAX_RATIO, or a plan
// past 400 steps, instead of trapping or expanding without end. Python uses the same bounds.
// Canonical JSON matches Python for every value a plan holds (integer ms, whole or decimal
// numbers, any Unicode); see WorkoutJSON.swift for the limits outside that domain.
//
// Clocks are start-anchored (§4.2.2): a step starts at the planned end of the step before it when
// the clock ended that step, and at its actual end when the athlete ended it. No format names
// appear here: Tabata, EMOM, AMRAP, caps and Hyrox are all the same five blocks.

// MARK: - Structure (the reader's side of workout_structure.py)

public enum WorkoutStructureV2 {
    public static let schemaVersion: Int = 2
    public static let draftSchemaVersion: Int = 0
    static let nodeKinds: [String] = ["part", "rest", "group", "repeat", "timed"]
    static let featureKeys: [String: [String]] = [
        "repeat": ["resume"],
        "timed": ["startAt", "interrupt"],
        "part": ["interrupt"],
        "group": ["interrupt"],
    ]
    static let countUnits: [String] = ["reps", "calories"]
    public static let maxSteps: Int = 400
    public static let maxSeconds: Double = 86400     // a window, rest or seconds target: at most 24 h
    public static let maxTimes: Double = 10000       // repeat times and listRounds
    public static let maxRatio: Double = 100         // a ratio rest
    public static let maxRounds: Int = 10000         // rounds expanded in one plan (a work budget)

    /// Int(v) when v is a number with lo <= v <= hi, else nil (Python `_bounded`).
    static func bounded(_ v: JSONValue?, _ lo: Double, _ hi: Double) -> Int? {
        guard let d = v?.number, d.isFinite, d >= lo, d <= hi else { return nil }
        return Int(d)
    }

    struct NodeRef {
        let kind: String
        let content: [String: JSONValue]
    }

    /// The kind and content of a node wrapper `{"part": {...}}`, or nil.
    static func nodeKind(_ wrapper: JSONValue) -> NodeRef? {
        guard let o = wrapper.object else { return nil }
        var kinds: [String] = []
        for k in o.keys where nodeKinds.contains(k) {
            kinds.append(k)
        }
        guard kinds.count == 1, let c = o[kinds[0]]?.object else { return nil }
        return NodeRef(kind: kinds[0], content: c)
    }

    static func unbounded(_ repeatContent: [String: JSONValue]) -> Bool {
        guard let t = repeatContent["times"] else { return true }
        return t.isNull
    }

    static func structures(_ doc: JSONValue) -> [[String: JSONValue]] {
        var out: [[String: JSONValue]] = []
        if let s = doc["structure"]?.object {
            out.append(s)
        }
        for sc in doc["scales"]?.array ?? [] {
            if let s = sc["structure"]?.object {
                out.append(s)
            }
        }
        return out
    }

    /// Feature names used anywhere in the definition, sorted (what the compiler lists in `requires`).
    public static func features(_ doc: JSONValue) -> [String] {
        var found: Set<String> = []
        for st in structures(doc) {
            collectFeatures(st["body"]?.array ?? [], into: &found)
        }
        return found.sorted()
    }

    private static func collectFeatures(_ body: [JSONValue], into found: inout Set<String>) {
        for w in body {
            guard let n = nodeKind(w) else { continue }
            for key in featureKeys[n.kind] ?? [] where n.content[key] != nil {
                found.insert(key)
            }
            if let b = n.content["body"]?.array {
                collectFeatures(b, into: &found)
            }
        }
    }

    /// ("ok", []) if this engine may run the definition; ("draft", []) for a draft; otherwise
    /// ("updateApp", [missing]): the watch shows "Update the app" and offers "Run as stopwatch"
    /// (RFC §14.3 A2, A4). A feature used counts even when `requires` leaves it out.
    public static func checkRunnable(_ doc: JSONValue, engineFeatures: Set<String> = []) -> (status: String, missing: [String]) {
        let version: JSONValue = doc["schemaVersion"] ?? .null
        if let v = version.number, v == Double(draftSchemaVersion) {
            return ("draft", [])
        }
        if version.number != Double(schemaVersion) {
            return ("updateApp", ["schemaVersion " + pythonRepr(version)])
        }
        var needed: Set<String> = Set(features(doc))
        for r in doc["requires"]?.array ?? [] {
            if let s = r.string {
                needed.insert(s)
            }
        }
        let missing: [String] = needed.filter { !engineFeatures.contains($0) }.sorted()
        if !missing.isEmpty {
            return ("updateApp", missing)
        }
        return ("ok", [])
    }

    static func pythonRepr(_ v: JSONValue) -> String {
        switch v {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d): return "\(d)"
        case .string(let s): return "'" + s + "'"
        default: return v.canonicalJSON
        }
    }
}

// MARK: - Plan types

public struct RoundRef: Equatable, Sendable {
    public let key: String
    public let round: Int
}

public struct EngineStep: Equatable, Sendable {
    public let index: Int
    public let id: String
    public let kind: String                  // part | rest
    public let node: String
    public let part: [String: JSONValue]?    // resolved part content
    public let restSeconds: Int?
    public let ratio: JSONValue?
    public let ratioOf: String?
    public let auto: Bool                    // automatic rest after an early finish
    public let waitWindow: String?
    public let mergedWindow: String?         // a clocked rest that also holds that window's automatic rest
    public let windows: [String]             // outer to inner
    public let rounds: [RoundRef]
    public let repeats: [String]
    public let scopes: [String]
    public let extra: Bool                   // a round added past listRounds
    public let asStep: Bool

    public var target: [String: JSONValue]? {
        return part?["target"]?.object
    }

    public var isMax: Bool {
        return kind == "part" && (target?["max"]?.truthy ?? false)
    }

    public var secondsTarget: Int? {
        guard kind == "part", let t = target, t["unit"]?.string == "seconds",
              let v = t["value"]?.number, v.isFinite, abs(v) <= WorkoutStructureV2.maxSeconds else { return nil }
        return Int(v.rounded(.toNearestOrEven))
    }

    /// A part whose count is asked when the clock ends it (reps or calories).
    public var countsReps: Bool {
        guard kind == "part", let u = target?["unit"]?.string else { return false }
        return WorkoutStructureV2.countUnits.contains(u)
    }

    /// Who ends this step, as declared (§4.2.1). A bell can still cut an athlete step.
    public var ends: String {
        if kind == "rest" {
            if restSeconds != nil || ratio != nil || auto {
                return "clock"
            }
            return "athlete"
        }
        if secondsTarget != nil || (isMax && !windows.isEmpty) {
            return "clock"
        }
        return "athlete"
    }

    func toJSON() -> JSONValue {
        var d: [String: JSONValue] = [
            "index": .int(index), "id": .string(id), "kind": .string(kind), "node": .string(node),
            "ends": .string(ends),
        ]
        if let p = part {
            let names: [(String, String)] = [("movement", "partMovement"), ("kind", "partKind"),
                                             ("name", "partName"), ("target", "partTarget"),
                                             ("load", "partLoad"), ("who", "partWho")]
            for (k, out) in names {
                if let v = p[k] {
                    d[out] = v
                }
            }
        }
        if let r = restSeconds {
            d["restSeconds"] = .int(r)
        }
        if let r = ratio {
            d["ratio"] = r
            d["ratioOf"] = ratioOf.map { JSONValue.string($0) } ?? .null
        }
        if auto {
            d["auto"] = .bool(true)
        }
        if extra {
            d["extra"] = .bool(true)
        }
        if asStep {
            d["asStep"] = .bool(true)
        }
        if let w = waitWindow, !w.isEmpty {
            d["waitWindow"] = .string(w)
        }
        if let w = mergedWindow, !w.isEmpty {
            d["mergedWindow"] = .string(w)
        }
        d["windows"] = .array(windows.map { JSONValue.string($0) })
        d["rounds"] = .array(rounds.map { JSONValue.array([.string($0.key), .int($0.round)]) })
        return .object(d)
    }
}

public struct EngineWindow: Equatable, Sendable {
    public let key: String
    public let id: String
    public let secondsMs: Int
    public let early: String
    public let late: String
    public let depth: Int                    // 1 = outermost
    public let ancestors: [String]
    public let stops: String?                // repeat key a late: end stops

    func toJSON() -> JSONValue {
        var d: [String: JSONValue] = [
            "key": .string(key), "id": .string(id), "seconds": .int(secondsMs / 1000),
            "early": .string(early), "late": .string(late), "depth": .int(depth),
        ]
        if let s = stops, !s.isEmpty {
            d["stops"] = .string(s)
        }
        return .object(d)
    }
}

public struct EngineBell: Equatable, Sendable {
    public let id: String
    public let anchor: String                // "start" or the step / window whose actual end it counts from
    public let offsetMs: Int

    func toJSON() -> JSONValue {
        return .object(["id": .string(id), "anchor": .string(anchor), "offsetMs": .int(offsetMs)])
    }
}

struct ExpansionContext: @unchecked Sendable {
    var prefix: String = ""
    var windows: [String] = []
    var rounds: [RoundRef] = []
    var repeats: [String] = []
    var scopes: [String] = []
    var patches: [(String, JSONValue)] = []  // (node id, patch), outer first
    var omitted: Set<String> = []
    var directRepeat: String? = nil
    var directUnbounded: Bool = false
    var extra: Bool = false
}

struct RepeatInstance: @unchecked Sendable {
    let key: String
    let id: String
    let content: [String: JSONValue]
    let ctx: ExpansionContext
    let path: String                         // structural path of the node (children are path.i)
    let times: Int?
    let listRounds: Int
    let until: String?
}

final class ExpansionSink {
    let offset: Int
    var steps: [EngineStep] = []
    var windows: [String: EngineWindow] = [:]
    var windowOrder: [String] = []
    var repeats: [String: RepeatInstance] = [:]
    var repeatOrder: [String] = []
    var invalid: String? = nil              // "invalid" or "tooLarge": the expansion stopped there
    var rounds: Int = 0                      // round() calls: repeats that add no steps can't hang

    init(offset: Int = 0) {
        self.offset = offset
    }

    func fail(_ reason: String = "invalid") {
        if invalid == nil {
            invalid = reason
        }
    }

    func addWindow(_ w: EngineWindow) {
        if windows[w.key] == nil {
            windowOrder.append(w.key)
        }
        windows[w.key] = w
    }

    func addRepeat(_ r: RepeatInstance) {
        if repeats[r.key] == nil {
            repeatOrder.append(r.key)
        }
        repeats[r.key] = r
    }

    func add(id: String, kind: String, node: String, part: [String: JSONValue]? = nil,
             restSeconds: Int? = nil, ratio: JSONValue? = nil, ratioOf: String? = nil,
             auto: Bool = false, waitWindow: String? = nil, mergedWindow: String? = nil,
             ctx: ExpansionContext, windows: [String]? = nil, scopes: [String],
             asStep: Bool = false) {
        if invalid != nil {
            return
        }
        if steps.count >= WorkoutStructureV2.maxSteps {
            invalid = "tooLarge"
            return
        }
        let s = EngineStep(index: offset + steps.count, id: id, kind: kind, node: node, part: part,
                           restSeconds: restSeconds, ratio: ratio, ratioOf: ratioOf, auto: auto,
                           waitWindow: waitWindow, mergedWindow: mergedWindow,
                           windows: windows ?? ctx.windows, rounds: ctx.rounds, repeats: ctx.repeats,
                           scopes: scopes, extra: ctx.extra, asStep: asStep)
        steps.append(s)
    }
}

/// The structure expanded into steps (unbounded repeats at listRounds), with its windows and repeat
/// instances. Rounds past listRounds are generated on demand by `roundSteps`.
/// Immutable once `init` returns (only `roundSteps` runs later, and it writes into its own sink).
final class WorkoutExpansion: @unchecked Sendable {
    let structure: [String: JSONValue]
    let standard: String
    let choices: [String: String]
    private var ids: [String: String] = [:]       // structural path -> node id
    private var unknownIds: [String: String] = [:]
    private(set) var steps: [EngineStep] = []
    private(set) var windows: [String: EngineWindow] = [:]
    private(set) var windowOrder: [String] = []
    private(set) var repeats: [String: RepeatInstance] = [:]
    private(set) var repeatOrder: [String] = []
    private(set) var invalid: String? = nil

    init(structure: [String: JSONValue], standard: String = "M", choices: [String: String] = [:]) {
        self.structure = structure
        self.standard = standard
        self.choices = choices
        var n: Int = 0
        assignIds(structure["body"]?.array ?? [], path: "", counter: &n)
        let sink = ExpansionSink()
        body(structure["body"]?.array ?? [], path: "", ctx: ExpansionContext(), sink: sink)
        steps = sink.steps
        windows = sink.windows
        windowOrder = sink.windowOrder
        repeats = sink.repeats
        repeatOrder = sink.repeatOrder
        invalid = sink.invalid
    }

    static func childPath(_ path: String, _ i: Int) -> String {
        return path.isEmpty ? String(i) : path + "." + String(i)
    }

    private func assignIds(_ body: [JSONValue], path: String, counter n: inout Int) {
        for (i, w) in body.enumerated() {
            let p: String = WorkoutExpansion.childPath(path, i)
            guard let node = WorkoutStructureV2.nodeKind(w) else {
                n += 1
                unknownIds[p] = "_unknown" + String(n)
                continue
            }
            if let s = node.content["id"]?.string {
                ids[p] = s
            } else {
                n += 1
                ids[p] = "_" + node.kind + String(n)
            }
            if let b = node.content["body"]?.array {
                assignIds(b, path: p, counter: &n)
            }
        }
    }

    // MARK: patches

    private func patchesFor(_ nid: String, _ ctx: ExpansionContext) -> [JSONValue] {
        var out: [JSONValue] = []
        for (k, p) in ctx.patches where k == nid {
            out.append(p)
        }
        return out
    }

    private func apply(_ kind: String, _ content: [String: JSONValue], _ patches: [JSONValue]) -> [String: JSONValue] {
        if patches.isEmpty {
            return content
        }
        var c: [String: JSONValue] = content
        let baseTarget: [String: JSONValue] = content["target"]?.object ?? [:]
        let base: JSONValue? = baseTarget["value"]
        let baseF: JSONValue? = baseTarget["valueF"]
        for p in patches {
            var isPair: Bool = false
            if let o = p.object, !o.isEmpty {
                isPair = o.keys.allSatisfy { $0 == "value" || $0 == "valueF" }
            }
            if p.isNumber || isPair {
                var value: JSONValue? = p.isNumber ? p : p["value"]
                if let v = value, v.isNull {
                    value = nil
                }
                if kind == "part" {
                    var t: [String: JSONValue] = ["unit": .string("reps")]
                    if let existing = c["target"]?.object, !existing.isEmpty {
                        t = existing
                    }
                    t.removeValue(forKey: "max")
                    if let v = value {
                        t["value"] = v
                    }
                    if isPair, let vf = p["valueF"] {
                        t["valueF"] = vf
                    } else if let bf = baseF?.number, let b = base, b.truthy, let bv = b.number,
                              let v = value?.number {
                        let scaled: Double = bf * v / bv + 0.5
                        if scaled.isFinite && abs(scaled) < 9.0e15 {
                            t["valueF"] = .int(Int(scaled))
                        }
                    }
                    c["target"] = .object(t)
                } else if kind == "repeat" {
                    c["times"] = value ?? .null
                } else if kind == "timed" || kind == "rest" {
                    c["seconds"] = value ?? .null
                }
            } else if let o = p.object {
                for (k, v) in o {
                    c[k] = v
                }
            }
        }
        return c
    }

    private func resolvePart(_ content: [String: JSONValue], _ nid: String) -> [String: JSONValue] {
        var p: [String: JSONValue] = content
        p["id"] = .string(nid)
        if standard == "F" {
            if var t = p["target"]?.object, let vf = t["valueF"] {
                t["value"] = vf
                p["target"] = .object(t)
            }
            if var ld = p["load"]?.object, let vf = ld["valueF"] {
                ld["value"] = vf
                p["load"] = .object(ld)
            }
        }
        if let mv = p["movement"]?.object {
            if let chosen = choices[nid], !chosen.isEmpty {
                p["movement"] = .string(chosen)
            } else if let choice = mv["choice"]?.array, let first = choice.first {
                p["movement"] = first
            } else {
                p["movement"] = .string("part")
            }
        }
        return p
    }

    // MARK: body

    private struct Item {
        let kind: String
        let content: [String: JSONValue]
        let nid: String
        let path: String
    }

    private func body(_ nodes: [JSONValue], path: String, ctx: ExpansionContext, sink: ExpansionSink) {
        var items: [Item] = []
        for (i, w) in nodes.enumerated() {
            let p: String = WorkoutExpansion.childPath(path, i)
            guard let node = WorkoutStructureV2.nodeKind(w) else {
                // An unknown node falls back to an athlete-paced part showing its text (RFC 14.3 A4).
                let nid: String = unknownIds[p] ?? "_unknown"
                var text: String? = nil
                if let s = w["rawText"]?.string, !s.isEmpty {
                    text = s
                } else if let s = w["note"]?.string, !s.isEmpty {
                    text = s
                }
                let content: [String: JSONValue] = ["movement": .string("part"),
                                                    "name": .string(text ?? "Unknown block"),
                                                    "unknown": .bool(true)]
                items.append(Item(kind: "part", content: content, nid: nid, path: p))
                continue
            }
            let nid: String = ids[p] ?? p
            if ctx.omitted.contains(nid) {
                continue
            }
            items.append(Item(kind: node.kind, content: apply(node.kind, node.content, patchesFor(nid, ctx)),
                              nid: nid, path: p))
        }
        var prevKey: String? = nil
        var merged: String? = nil
        for (i, item) in items.enumerated() {
            if sink.invalid != nil {
                return
            }
            let key: String = ctx.prefix + item.nid
            let c: [String: JSONValue] = item.content
            switch item.kind {
            case "part":
                let resolved: [String: JSONValue] = resolvePart(c, item.nid)
                // Resolved: with standard F, valueF is the value.
                if let t = resolved["target"]?.object, t["unit"]?.string == "seconds", let v = t["value"],
                   WorkoutStructureV2.bounded(v, 0, WorkoutStructureV2.maxSeconds) == nil {
                    sink.fail()
                    return
                }
                sink.add(id: key, kind: "part", node: item.nid, part: resolved, ctx: ctx,
                         scopes: ctx.scopes + [key])
            case "rest":
                var seconds: Int? = nil
                if let s = c["seconds"], !s.isNull {
                    guard let b = WorkoutStructureV2.bounded(s, 1, WorkoutStructureV2.maxSeconds) else {
                        sink.fail()
                        return
                    }
                    seconds = b
                }
                var ratio: JSONValue? = nil
                if let r = c["ratio"], !r.isNull {
                    guard let d = r.number, d.isFinite, d > 0, d <= WorkoutStructureV2.maxRatio else {
                        sink.fail()
                        return
                    }
                    ratio = r
                }
                sink.add(id: key, kind: "rest", node: item.nid, restSeconds: seconds, ratio: ratio,
                         ratioOf: c["ratio"] != nil ? prevKey : nil,
                         mergedWindow: seconds != nil ? merged : nil, ctx: ctx, scopes: ctx.scopes + [key])
            case "group":
                if c["asStep"]?.truthy ?? false {
                    var part: [String: JSONValue] = ["id": .string(item.nid), "movement": .string("complex")]
                    if let label = c["label"], label.truthy {
                        part["name"] = label
                    } else {
                        part["name"] = .string(item.nid)
                    }
                    if let ld = c["load"] {
                        part["load"] = ld
                    }
                    sink.add(id: key, kind: "part", node: item.nid, part: resolvePart(part, item.nid), ctx: ctx,
                             scopes: ctx.scopes + [key], asStep: true)
                } else {
                    var inner: ExpansionContext = ctx
                    inner.scopes = ctx.scopes + [key]
                    inner.directRepeat = nil
                    inner.directUnbounded = false
                    body(c["body"]?.array ?? [], path: item.path, ctx: inner, sink: sink)
                }
            case "repeat":
                repeatNode(c, nid: item.nid, key: key, path: item.path, ctx: ctx, sink: sink)
            case "timed":
                var merge: Bool = false
                if c["early"]?.string == "wait", i + 1 < items.count, items[i + 1].kind == "rest",
                   let s = items[i + 1].content["seconds"], !s.isNull {
                    merge = true
                }
                timedNode(c, nid: item.nid, key: key, path: item.path, ctx: ctx, sink: sink, merge: merge)
            default:
                break
            }
            merged = (item.kind == "timed" && c["early"]?.string == "wait") ? key : nil
            prevKey = key
        }
    }

    private func timedNode(_ c: [String: JSONValue], nid: String, key: String, path: String,
                           ctx: ExpansionContext, sink: ExpansionSink, merge: Bool) {
        var stops: String? = nil
        if c["late"]?.string == "end" {
            var candidates: [(String, String)] = []
            for (j, w) in (c["body"]?.array ?? []).enumerated() {
                if let n = WorkoutStructureV2.nodeKind(w), n.kind == "repeat", WorkoutStructureV2.unbounded(n.content) {
                    let cid: String = ids[WorkoutExpansion.childPath(path, j)] ?? ""
                    candidates.append((cid, ctx.prefix + cid))
                }
            }
            if let dr = ctx.directRepeat, ctx.directUnbounded {
                let last: String = dr.components(separatedBy: ".").last ?? dr
                candidates.append((last, dr))
            }
            let named: String? = c["stops"]?.string
            for (cid, ckey) in candidates {
                if let nm = named {
                    if nm == cid || ckey.hasSuffix("." + nm) || ckey == nm {
                        stops = ckey
                        break
                    }
                } else {
                    stops = ckey
                    break
                }
            }
        }
        let early: String = c["early"]?.string ?? ""
        guard let seconds = WorkoutStructureV2.bounded(c["seconds"], 1, WorkoutStructureV2.maxSeconds) else {
            sink.fail()
            return
        }
        let w = EngineWindow(key: key, id: nid, secondsMs: seconds * 1000, early: early,
                             late: c["late"]?.string ?? "", depth: ctx.windows.count + 1,
                             ancestors: ctx.windows, stops: stops)
        sink.addWindow(w)
        var inner: ExpansionContext = ctx
        inner.windows = ctx.windows + [key]
        inner.scopes = ctx.scopes + [key]
        inner.directRepeat = nil
        inner.directUnbounded = false
        body(c["body"]?.array ?? [], path: path, ctx: inner, sink: sink)
        if early == "wait" && !merge {
            sink.add(id: key + ".wait", kind: "rest", node: nid, auto: true, waitWindow: key, ctx: ctx,
                     windows: ctx.windows + [key], scopes: ctx.scopes + [key])
        }
    }

    private func repeatNode(_ c: [String: JSONValue], nid: String, key: String, path: String,
                            ctx: ExpansionContext, sink: ExpansionSink) {
        var times: Int? = nil
        var lr: Int = 1
        if let t = c["times"], !t.isNull {
            guard let b = WorkoutStructureV2.bounded(t, 0, WorkoutStructureV2.maxTimes) else {
                sink.fail()
                return
            }
            times = b
            lr = b
        } else {
            var raw: JSONValue = .int(1)
            if let l = c["listRounds"], l.truthy {
                raw = l
            }
            guard let b = WorkoutStructureV2.bounded(raw, 1, WorkoutStructureV2.maxTimes) else {
                sink.fail()
                return
            }
            lr = b
        }
        var until: String? = nil
        if let u = c["until"]?.string {
            until = u
        }
        let inst = RepeatInstance(key: key, id: nid, content: c, ctx: ctx, path: path, times: times,
                                  listRounds: lr, until: until)
        sink.addRepeat(inst)
        if lr < 1 {
            return
        }
        for r in 1...lr {
            if sink.invalid != nil || !round(inst, r, sink: sink) {
                break
            }
        }
    }

    /// The vary value for round r, or nil when an unbounded list stops the repeat.
    private func varyValue(_ spec: JSONValue, _ r: Int, _ inst: RepeatInstance) -> JSONValue? {
        if let list = spec.array {
            if r <= list.count {
                return list[r - 1]
            }
            if inst.content["then"]?.string == "stop" {
                return nil
            }
            return list.last ?? .null
        }
        let from: JSONValue = spec["from"] ?? .int(0)
        let step: JSONValue = spec["step"] ?? .int(0)
        if case .int(let f) = from, case .int(let s) = step {
            let m = s.multipliedReportingOverflow(by: r - 1)
            if !m.overflow {
                let a = f.addingReportingOverflow(m.partialValue)
                if !a.overflow {
                    return .int(a.partialValue)
                }
            }
        }
        return .double((from.number ?? 0) + (step.number ?? 0) * Double(r - 1))
    }

    /// Expands round r of a repeat into sink; false when a vary list stops the repeat.
    @discardableResult
    func round(_ inst: RepeatInstance, _ r: Int, sink: ExpansionSink) -> Bool {
        sink.rounds += 1
        if sink.rounds > WorkoutStructureV2.maxRounds {
            sink.fail("tooLarge")
            return false
        }
        let ctx: ExpansionContext = inst.ctx
        var patches: [(String, JSONValue)] = ctx.patches
        if let vary = inst.content["vary"]?.object {
            for vid in vary.keys.sorted() {
                guard let spec = vary[vid], let v = varyValue(spec, r, inst) else { return false }
                patches.append((vid, v))
            }
        }
        var omitted: Set<String> = ctx.omitted
        for o in inst.content["override"]?.array ?? [] {
            let rounds: [JSONValue] = o["rounds"]?.array ?? []
            var hit: Bool = false
            for x in rounds {
                if let n = x.number, n == Double(r) {
                    hit = true
                }
                if x.string == "last", let t = inst.times, r == t {
                    hit = true
                }
            }
            if !hit {
                continue
            }
            let oid: String = o["id"]?.string ?? ""
            if o["omit"]?.truthy ?? false {
                omitted.insert(oid)
            } else if let set = o["set"] {
                patches.append((oid, set))
            }
        }
        let rkey: String = inst.key + "." + String(r)
        var inner = ExpansionContext()
        inner.prefix = rkey + "."
        inner.windows = ctx.windows
        inner.rounds = ctx.rounds + [RoundRef(key: inst.key, round: r)]
        inner.repeats = ctx.repeats + [inst.key]
        inner.scopes = ctx.scopes + [inst.key, rkey]
        inner.patches = patches
        inner.omitted = omitted
        inner.directRepeat = inst.key
        inner.directUnbounded = inst.times == nil
        inner.extra = ctx.extra || (inst.times == nil && r > inst.listRounds)
        body(inst.content["body"]?.array ?? [], path: inst.path, ctx: inner, sink: sink)
        return true
    }

    /// Round r of the unbounded repeat `key` (past listRounds), indexed from offset; nil when the
    /// repeat has no more rounds.
    func roundSteps(_ key: String, _ r: Int, offset: Int) -> ExpansionSink? {
        guard let inst = repeats[key] else { return nil }
        let sink = ExpansionSink(offset: offset)
        if !round(inst, r, sink: sink) || sink.steps.isEmpty || sink.invalid != nil {
            return nil
        }
        return sink
    }
}

// MARK: - Plan

public struct WorkoutNotRunnable: Error, Equatable, Sendable {
    public let reason: String                // draft | updateApp
    public let missing: [String]
}

public final class WorkoutPlan: @unchecked Sendable {
    public static let plannerVersion: Int = 1

    public let definition: JSONValue
    public let structure: [String: JSONValue]
    public let scale: String?
    public let score: [String: JSONValue]
    let expansion: WorkoutExpansion
    public var steps: [EngineStep] { return expansion.steps }
    public var windows: [String: EngineWindow] { return expansion.windows }
    public var windowOrder: [String] { return expansion.windowOrder }
    public let bells: [EngineBell]

    init(definition: JSONValue, structure: [String: JSONValue], expansion: WorkoutExpansion, scale: String?) {
        self.definition = definition
        self.structure = structure
        self.expansion = expansion
        self.scale = scale
        self.score = structure["score"]?.object ?? ["type": .string("none")]
        self.bells = WorkoutPlan.staticBells(expansion)
    }

    public func toJSON() -> JSONValue {
        return .object([
            "planner": .int(WorkoutPlan.plannerVersion),
            "steps": .array(steps.map { $0.toJSON() }),
            "windows": .array(windowOrder.compactMap { windows[$0]?.toJSON() }),
            "bells": .array(bells.map { $0.toJSON() }),
        ])
    }

    public var canonicalJSON: String {
        return toJSON().canonicalJSON
    }

    /// SHA-256 of the canonical plan, shared with Python (crash checkpoints, recordings).
    public var hash: String {
        return toJSON().canonicalHash
    }

    private struct Anchor {
        var anchor: String
        var offset: Int
    }

    static func staticBells(_ exp: WorkoutExpansion) -> [EngineBell] {
        var bells: [EngineBell] = []
        var cur = Anchor(anchor: "start", offset: 0)
        var opened: [String: Anchor] = [:]
        let steps: [EngineStep] = exp.steps
        for (i, s) in steps.enumerated() {
            for wk in s.windows where opened[wk] == nil {
                let w: EngineWindow? = exp.windows[wk]
                let end = Anchor(anchor: cur.anchor, offset: cur.offset + (w?.secondsMs ?? 0))
                opened[wk] = end
                bells.append(EngineBell(id: wk + ".end", anchor: end.anchor, offsetMs: end.offset))
            }
            var end: Anchor
            if s.auto, let ww = s.waitWindow, let o = opened[ww] {
                end = o
            } else if let mw = s.mergedWindow, let wb = opened[mw], let rs = s.restSeconds {
                end = Anchor(anchor: wb.anchor, offset: wb.offset + rs * 1000)
                bells.append(EngineBell(id: s.id + ".end", anchor: end.anchor, offsetMs: end.offset))
            } else if s.kind == "rest", let rs = s.restSeconds {
                end = Anchor(anchor: cur.anchor, offset: cur.offset + rs * 1000)
                bells.append(EngineBell(id: s.id + ".end", anchor: end.anchor, offsetMs: end.offset))
            } else if let st = s.secondsTarget {
                end = Anchor(anchor: cur.anchor, offset: cur.offset + st * 1000)
                bells.append(EngineBell(id: s.id + ".end", anchor: end.anchor, offsetMs: end.offset))
            } else {
                end = Anchor(anchor: s.id, offset: 0)
            }
            cur = end
            let next: [String] = i + 1 < steps.count ? steps[i + 1].windows : []
            for wk in s.windows.reversed() {
                if next.contains(wk) {
                    continue
                }
                if exp.windows[wk]?.early == "wait", let o = opened[wk] {
                    cur = o
                } else {
                    cur = Anchor(anchor: wk, offset: 0)
                }
            }
        }
        return bells
    }
}

// MARK: - Events and effects

public struct EngineEvent: Equatable, Codable, Sendable {
    public var kind: String                  // start | tick | crown | undo | reps | end | blockDone
    public var t: Int                        // ms
    public var began: Int?                   // crown: when the turn began
    public var step: String?                 // reps
    public var value: JSONValue?             // reps
    /// Keys this build doesn't know, kept so a newer build's event survives a checkpoint written
    /// or read here (RFC §14.4 rule 5). Never a known key.
    public var extra: [String: JSONValue] = [:]

    public init(kind: String, t: Int, began: Int? = nil, step: String? = nil, value: JSONValue? = nil) {
        self.kind = kind
        self.t = t
        self.began = began
        self.step = step
        self.value = value
    }

    /// Python `workout_session.EVENT_KEYS`.
    public static let knownKeys: Set<String> = ["kind", "t", "began", "step", "value"]
    /// Python `workout_session.MAX_EVENT_MS`: 7 days. Far past any workout, and it fits a 32-bit
    /// Int (arm64_32 watches) with a 24 h bell offset added to it.
    public static let maxMs: Int = 604_800_000

    /// Python `workout_session._ms`: a time in ms, truncated toward zero and clamped to
    /// 0...maxMs; nil if not a finite number (a bool is not a number).
    public static func clampedMs(_ v: JSONValue?) -> Int? {
        guard let d = v?.number, d.isFinite else {
            return nil
        }
        if d <= 0 {
            return 0
        }
        if d >= Double(maxMs) {
            return maxMs
        }
        return Int(d)
    }

    /// Python `workout_session.decode_event`: never fails. A missing or bad `kind` is "" (the
    /// engine ignores it), a missing or bad `t` is 0, a bad `began` or `step` is dropped, and
    /// unknown keys are kept in `extra`. Times are clamped (`clampedMs`), so a corrupt log can't
    /// overflow `t + ms` in the engine.
    public init(json: JSONValue) {
        let o: [String: JSONValue] = json.object ?? [:]
        self.kind = o["kind"]?.string ?? ""
        self.t = EngineEvent.clampedMs(o["t"]) ?? 0
        self.began = EngineEvent.clampedMs(o["began"])
        self.step = o["step"]?.string
        self.value = o["value"]
        var extra: [String: JSONValue] = [:]
        for (k, v) in o where !EngineEvent.knownKeys.contains(k) {
            extra[k] = v
        }
        self.extra = extra
    }

    /// The event as JSON: the known keys that are set, plus `extra`.
    public func toJSON() -> JSONValue {
        var d: [String: JSONValue] = [:]
        for (k, v) in extra where !EngineEvent.knownKeys.contains(k) {
            d[k] = v
        }
        d["kind"] = .string(kind)
        d["t"] = .int(t)
        if let b = began {
            d["began"] = .int(b)
        }
        if let s = step {
            d["step"] = .string(s)
        }
        if let v = value {
            d["value"] = v
        }
        return .object(d)
    }

    public init(from decoder: Decoder) throws {
        self.init(json: (try? JSONValue(from: decoder)) ?? .null)
    }

    public func encode(to encoder: Encoder) throws {
        try toJSON().encode(to: encoder)
    }
}

public struct EngineEffect: Equatable, Sendable {
    public let kind: String                  // go | rest | time | countdown | ask | cap | hint | grace | done | start | undo
    public let t: Int
    public let step: String?
    public let n: Int?
    public let reason: String?

    public init(kind: String, t: Int, step: String? = nil, n: Int? = nil, reason: String? = nil) {
        self.kind = kind
        self.t = t
        self.step = step
        self.n = n
        self.reason = reason
    }

    public var isHaptic: Bool {
        return kind == "go" || kind == "rest" || kind == "time"
    }

    /// What the effect says, without its time (a late event can move an effect without making it new).
    struct Key: Hashable {
        let kind: String
        let step: String?
        let n: Int?
        let reason: String?
    }

    var key: Key {
        return Key(kind: kind, step: step, n: n, reason: reason)
    }

    public func toJSON() -> JSONValue {
        var d: [String: JSONValue] = ["kind": .string(kind), "t": .int(t)]
        if let s = step {
            d["step"] = .string(s)
        }
        if let n = n {
            d["n"] = .int(n)
        }
        if let r = reason {
            d["reason"] = .string(r)
        }
        return .object(d)
    }
}

// MARK: - State

public struct StepRecord: Equatable, Sendable {
    public var start: Int?
    public var end: Int?
    public var endedBy: String?
    public var status: String                // running | done | cut | skipped
    public var reps: JSONValue?
    public var relabeled: Bool = false
}

struct WindowState: Equatable, Sendable {
    var start: Int
    var end: Int
    var open: Bool
    var fired: Bool
}

struct RepeatState: Equatable, Sendable {
    var rounds: Int
    var last: Int?
    var stopped: Bool
    var until: String?
}

public struct CapState: Equatable, Sendable {
    public var step: String
    public var t: Int
    public var window: String
    public var reps: JSONValue?
    public var hard: Bool
}

public struct IgnoredInput: Equatable, Sendable {
    public let t: Int
    public let action: String
    public let reason: String
}

struct CountdownState: Equatable, Sendable {
    var bell: Int
    var armed: Bool
    var next: Int
}

final class EngineSnapshot: @unchecked Sendable {
    let t: Int
    let state: EngineState

    init(t: Int, state: EngineState) {
        self.t = t
        self.state = state
    }
}

public struct EngineState: @unchecked Sendable {
    public let plan: WorkoutPlan
    public internal(set) var steps: [EngineStep]
    var windows: [String: EngineWindow]
    var windowOrder: [String]
    public internal(set) var seq: [Int]
    public internal(set) var pos: Int = -1
    public internal(set) var t0: Int? = nil
    public internal(set) var now: Int? = nil
    public internal(set) var rec: [Int: StepRecord] = [:]
    var wstate: [String: WindowState] = [:]
    var wstateOrder: [String] = []
    var due: Int? = nil
    var repeats: [String: RepeatState] = [:]
    var repeatOrder: [String] = []
    var lastBell: Int? = nil
    var lastCut: Int? = nil
    var lastCrown: Int? = nil
    public internal(set) var cap: CapState? = nil
    public internal(set) var asks: [String] = []
    public internal(set) var done: Bool = false
    public internal(set) var doneT: Int? = nil
    public internal(set) var endedBy: String? = nil
    var snaps: [EngineSnapshot] = []
    public internal(set) var log: [EngineEvent] = []
    public internal(set) var ignored: [IgnoredInput] = []
    var cd: CountdownState? = nil

    public init(plan: WorkoutPlan) {
        self.plan = plan
        self.steps = plan.steps
        self.windows = plan.windows
        self.windowOrder = plan.windowOrder
        self.seq = plan.steps.map { $0.index }
        for key in plan.expansion.repeatOrder {
            guard let inst = plan.expansion.repeats[key], inst.times == nil else { continue }
            var last: Int? = nil
            for s in plan.steps where s.repeats.contains(key) {
                last = s.index
            }
            repeats[key] = RepeatState(rounds: inst.listRounds, last: last, stopped: false, until: inst.until)
            repeatOrder.append(key)
        }
    }

    /// The step running now, or nil before START and once done.
    public var current: EngineStep? {
        if pos < 0 || done || pos >= seq.count {
            return nil
        }
        return steps[seq[pos]]
    }

    public func step(id: String) -> EngineStep? {
        for s in steps where s.id == id {
            return s
        }
        return nil
    }

    mutating func setWindowState(_ key: String, _ ws: WindowState) {
        if wstate[key] == nil {
            wstateOrder.append(key)
        }
        wstate[key] = ws
    }

    mutating func addWindow(_ w: EngineWindow) {
        if windows[w.key] == nil {
            windowOrder.append(w.key)
        }
        windows[w.key] = w
    }
}

// MARK: - Engine

public enum WorkoutEngine {
    public static let bellLockoutMs: Int = 2000     // a turn less than 2 s after a bell is ignored
    public static let windowLockoutMs: Int = 4000   // inside a window: from the later of the last turn and bell
    public static let crownLockoutMs: Int = 2000    // outside any clock: from the last accepted turn
    public static let lateEventMs: Int = 5000       // a turn more than 5 s late is ignored
    public static let countdownMs: Int = 3000       // 3-2-1 only if at least 3 s are left
    public static let maxExtraRounds: Int = 1000

    /// Plans a v2 definition (or a bare structure). Throws WorkoutNotRunnable for a draft, an
    /// unknown schema version or a feature this engine doesn't run.
    public static func plan(_ definition: JSONValue, scale: String? = nil, standard: String = "M",
                            choices: [String: String] = [:], engineFeatures: Set<String> = []) throws -> WorkoutPlan {
        var doc: JSONValue = definition
        if definition["body"] != nil && definition["structure"] == nil {
            doc = .object(["schemaVersion": .int(WorkoutStructureV2.schemaVersion), "structure": definition])
        }
        let check = WorkoutStructureV2.checkRunnable(doc, engineFeatures: engineFeatures)
        if check.status != "ok" {
            throw WorkoutNotRunnable(reason: check.status, missing: check.missing)
        }
        var structure: [String: JSONValue] = doc["structure"]?.object ?? [:]
        if let scale = scale {
            var found: Bool = false
            for s in doc["scales"]?.array ?? [] where s["id"]?.string == scale {
                structure = s["structure"]?.object ?? [:]
                found = true
                break
            }
            if !found {
                throw WorkoutNotRunnable(reason: "noScale", missing: [scale])
            }
        }
        let exp = WorkoutExpansion(structure: structure, standard: standard, choices: choices)
        if let reason = exp.invalid {
            throw WorkoutNotRunnable(reason: reason, missing: [])
        }
        if exp.steps.isEmpty {
            throw WorkoutNotRunnable(reason: "empty", missing: [])
        }
        return WorkoutPlan(definition: doc, structure: structure, expansion: exp, scale: scale)
    }

    public static func initial(_ plan: WorkoutPlan) -> EngineState {
        return EngineState(plan: plan)
    }

    /// The new state and the effects after one event. The state passed in is not changed.
    public static func reduce(_ state: EngineState, _ event: EngineEvent) -> (EngineState, [EngineEffect]) {
        let t: Int = event.t
        var st: EngineState = state
        var effects: [EngineEffect] = []
        if event.kind == "start" {
            if st.t0 != nil {
                return (st, [])
            }
            st.t0 = t
            st.now = t
            st.pos = 0
            st.log.append(event)
            enter(&st, t, &effects, byClock: false)
            effects.append(EngineEffect(kind: "start", t: t))
            countdown(&st, t, &effects)
            return (st, effects)
        }
        guard st.t0 != nil, let now = st.now else {
            return (st, [])
        }
        if t < now {
            if event.kind == "tick" {
                return (st, [])
            }
            if now - t > lateEventMs {
                st.ignored.append(IgnoredInput(t: t, action: event.kind, reason: "late"))
                return (st, [EngineEffect(kind: "hint", t: now, reason: "late")])
            }
            return late(st, event)
        }
        catchUp(&st, t, &effects)
        st.now = t
        switch event.kind {
        case "crown":
            st.log.append(event)
            crown(&st, t, event.began ?? t, &effects)
        case "undo":
            st.log.append(event)
            st = undo(st, t, &effects)
        case "reps":
            st.log.append(event)
            reps(&st, event.step ?? "", event.value)
        case "end":
            st.log.append(event)
            end(&st, t, &effects)
        case "blockDone":
            st.log.append(event)
            blockDone(&st, t, &effects)
        default:
            break
        }
        countdown(&st, t, &effects)
        return (st, effects)
    }

    /// The state after `events` (sorted by time, stable). With `until`, a final tick there; replay
    /// never catches up past it (crash recovery replays only to the last checkpoint, §4.2.11).
    public static func replay(_ plan: WorkoutPlan, _ events: [EngineEvent], until: Int? = nil) -> EngineState {
        var st: EngineState = initial(plan)
        let sorted: [EngineEvent] = events.enumerated().sorted { (a, b) -> Bool in
            if a.element.t != b.element.t {
                return a.element.t < b.element.t
            }
            return a.offset < b.offset
        }.map { $0.element }
        for e in sorted {
            st = reduce(st, e).0
        }
        if let u = until, st.t0 != nil, let now = st.now, u >= now {
            st = reduce(st, EngineEvent(kind: "tick", t: u)).0
        }
        return st
    }

    /// The final state and every effect, feeding `events` in the given order (ticks included).
    public static func run(_ plan: WorkoutPlan, _ events: [EngineEvent]) -> (EngineState, [EngineEffect]) {
        var st: EngineState = initial(plan)
        var out: [EngineEffect] = []
        for e in events {
            let r = reduce(st, e)
            st = r.0
            out.append(contentsOf: r.1)
        }
        return (st, out)
    }

    // MARK: late events

    private static func timeline(_ plan: WorkoutPlan, _ log: [EngineEvent], _ t: Int, _ now: Int,
                                 extra: EngineEvent?) -> (EngineState, [EngineEffect]) {
        var st: EngineState = replay(plan, log.filter { $0.t <= t }, until: t)
        var out: [EngineEffect] = []
        if let e = extra {
            let r = reduce(st, e)
            st = r.0
            out.append(contentsOf: r.1)
        }
        for e in log where e.t > t {
            let r = reduce(st, e)
            st = r.0
            out.append(contentsOf: r.1)
        }
        let r = reduce(st, EngineEvent(kind: "tick", t: now))
        out.append(contentsOf: r.1)
        return (r.0, out)
    }

    /// A late event within 5 s is applied in time order: rebuild from the log. Only what the new
    /// timeline adds to what already played is returned, with at most the current state's haptic.
    private static func late(_ st: EngineState, _ event: EngineEvent) -> (EngineState, [EngineEffect]) {
        let t: Int = event.t
        let now: Int = st.now ?? t
        let played: [EngineEffect] = timeline(st.plan, st.log, t, now, extra: nil).1
        let fresh = timeline(st.plan, st.log, t, now, extra: event)
        var rebuilt: EngineState = fresh.0
        var ignored: [IgnoredInput] = st.ignored
        for x in rebuilt.ignored where !st.ignored.contains(x) {
            ignored.append(x)
        }
        rebuilt.ignored = ignored
        var remaining: [EngineEffect.Key: Int] = [:]
        for e in played {
            remaining[e.key, default: 0] += 1
        }
        var new: [EngineEffect] = []
        for e in fresh.1 {
            if let n = remaining[e.key], n > 0 {
                remaining[e.key] = n - 1
                continue
            }
            new.append(e)
        }
        var effects: [EngineEffect] = new.filter { !$0.isHaptic && $0.kind != "countdown" }
        let before: String? = st.current?.id
        let after: String? = rebuilt.current?.id
        let haptics: [EngineEffect] = new.filter { $0.isHaptic }
        if let last = haptics.last, before != after || rebuilt.done != st.done {
            effects.append(last)
        }
        return (rebuilt, effects)
    }

    // MARK: internals

    private static func finish(_ st: inout EngineState, _ idx: Int, _ t: Int, _ by: String, _ status: String) {
        var r: StepRecord = st.rec[idx] ?? StepRecord(start: nil, end: nil, endedBy: nil, status: "running", reps: nil)
        r.end = t
        r.endedBy = by
        r.status = status
        st.rec[idx] = r
    }

    private static func ask(_ st: inout EngineState, _ step: EngineStep) {
        if !st.asks.contains(step.id) {
            st.asks.append(step.id)
        }
    }

    private static func scopeMs(_ st: EngineState, _ key: String?) -> Int {
        guard let key = key else { return 0 }
        var starts: [Int] = []
        var ends: [Int] = []
        for (idx, r) in st.rec {
            let s: EngineStep = st.steps[idx]
            if s.scopes.contains(key) && !s.auto, let a = r.start, let b = r.end, r.status == "done" || r.status == "cut" {
                starts.append(a)
                ends.append(b)
            }
        }
        guard let mx = ends.max(), let mn = starts.min() else { return 0 }
        return mx - mn
    }

    private static func enter(_ st: inout EngineState, _ t: Int, _ effects: inout [EngineEffect], byClock: Bool) {
        let idx: Int = st.seq[st.pos]
        let s: EngineStep = st.steps[idx]
        st.rec[idx] = StepRecord(start: t, end: nil, endedBy: nil, status: "running", reps: nil)
        for wk in s.windows where st.wstate[wk] == nil {
            let ms: Int = st.windows[wk]?.secondsMs ?? 0
            st.setWindowState(wk, WindowState(start: t, end: t + ms, open: true, fired: false))
        }
        var due: Int? = nil
        if s.auto {
            due = nil                                   // the window's bell ends it
        } else if let mw = s.mergedWindow, let ws = st.wstate[mw], let rs = s.restSeconds {
            due = ws.end + rs * 1000
        } else if s.kind == "rest", let rs = s.restSeconds {
            due = t + rs * 1000
        } else if s.kind == "rest", let ratio = s.ratio?.number {
            let milli: Int = Int((ratio * 1000.0).rounded(.toNearestOrEven))   // integer maths only
            let seconds: Int = (milli * scopeMs(st, s.ratioOf) + 500000) / 1000000
            due = t + seconds * 1000
        } else if let secs = s.secondsTarget {
            due = t + secs * 1000
        }
        st.due = due
        if byClock {
            effects.append(EngineEffect(kind: s.kind == "part" ? "go" : "rest", t: t, step: s.id))
        }
    }

    /// The next step in order, adding a round to an unbounded repeat at the end of its list.
    private static func nextIndex(_ st: inout EngineState) -> Int? {
        let cur: Int = st.seq[st.pos]
        for key in st.repeatOrder {
            guard var rs = st.repeats[key], !rs.stopped, rs.last == cur else { continue }
            let listed: Int = st.plan.expansion.repeats[key]?.listRounds ?? 0
            if rs.rounds - listed >= maxExtraRounds {
                rs.stopped = true
                st.repeats[key] = rs
                continue
            }
            guard let sink = st.plan.expansion.roundSteps(key, rs.rounds + 1, offset: st.steps.count) else {
                rs.stopped = true
                st.repeats[key] = rs
                continue
            }
            st.steps.append(contentsOf: sink.steps)
            for wk in sink.windowOrder {
                if let w = sink.windows[wk] {
                    st.addWindow(w)
                }
            }
            st.seq.insert(contentsOf: sink.steps.map { $0.index }, at: st.pos + 1)
            rs.rounds += 1
            rs.last = sink.steps.last?.index
            st.repeats[key] = rs
        }
        if st.pos + 1 < st.seq.count {
            return st.seq[st.pos + 1]
        }
        return nil
    }

    private static func advance(_ st: inout EngineState, _ t: Int, _ effects: inout [EngineEffect], byClock: Bool) {
        let old: EngineStep = st.steps[st.seq[st.pos]]
        guard let nxt = nextIndex(&st) else {
            for k in st.wstateOrder {
                st.wstate[k]?.open = false
            }
            st.done = true
            st.doneT = t
            st.endedBy = byClock ? "clock" : "athlete"
            st.due = nil
            if byClock {
                effects.append(EngineEffect(kind: "time", t: t))
            }
            effects.append(EngineEffect(kind: "done", t: t))
            return
        }
        let new: EngineStep = st.steps[nxt]
        for wk in old.windows where !new.windows.contains(wk) && st.wstate[wk] != nil {
            st.wstate[wk]?.open = false
        }
        st.pos += 1
        enter(&st, t, &effects, byClock: byClock)
    }

    struct PendingBell {
        let time: Int
        let depth: Int
        let kind: String                        // window | step
        let window: String?
        let step: Int?
    }

    /// Pending boundaries, earliest first, outer first at equal times.
    static func bells(_ st: EngineState) -> [PendingBell] {
        if st.done || st.pos < 0 {
            return []
        }
        var out: [PendingBell] = []
        for wk in st.wstateOrder {
            guard let ws = st.wstate[wk], ws.open, !ws.fired else { continue }
            out.append(PendingBell(time: ws.end, depth: st.windows[wk]?.depth ?? 0, kind: "window", window: wk, step: nil))
        }
        if let d = st.due {
            out.append(PendingBell(time: d, depth: 1000, kind: "step", window: nil, step: st.seq[st.pos]))
        }
        // Stable: equal (time, depth) keep their order, as Python's sort does.
        let indexed = out.enumerated().sorted { (a, b) -> Bool in
            if a.element.time != b.element.time {
                return a.element.time < b.element.time
            }
            if a.element.depth != b.element.depth {
                return a.element.depth < b.element.depth
            }
            return a.offset < b.offset
        }
        return indexed.map { $0.element }
    }

    private static func catchUp(_ st: inout EngineState, _ t: Int, _ effects: inout [EngineEffect]) {
        var applied: [EngineEffect] = []
        var guardCount: Int = 0
        while true {
            let pending: [PendingBell] = bells(st)
            guard let b = pending.first, b.time <= t else { break }
            applyBell(&st, b, &applied)
            guardCount += 1
            if guardCount > 100000 {
                break
            }
        }
        // Only the entry haptic of the state you are in now plays, once (§4.2.4).
        var lastHaptic: Int? = nil
        for (i, e) in applied.enumerated() where e.isHaptic {
            lastHaptic = i
        }
        for (i, e) in applied.enumerated() {
            if e.isHaptic && i != lastHaptic {
                continue
            }
            effects.append(e)
        }
    }

    private static func lastInWindow(_ st: inout EngineState, _ key: String) -> Bool {
        guard let nxt = nextIndex(&st) else { return true }
        return !st.steps[nxt].windows.contains(key)
    }

    private static func applyBell(_ st: inout EngineState, _ bell: PendingBell, _ effects: inout [EngineEffect]) {
        let b: Int = bell.time
        st.lastBell = b
        st.lastCut = nil
        let idx: Int = st.seq[st.pos]
        let s: EngineStep = st.steps[idx]
        if bell.kind == "step" {
            finish(&st, idx, b, "clock", "done")
            advance(&st, b, &effects, byClock: true)
            return
        }
        guard let key = bell.window, let w = st.windows[key] else { return }
        if w.late == "continue" {
            st.wstate[key]?.fired = true
            st.cap = CapState(step: s.id, t: b, window: key, reps: nil, hard: false)
            if s.countsReps {
                ask(&st, s)
            }
            effects.append(EngineEffect(kind: "time", t: b))
            effects.append(EngineEffect(kind: "cap", t: b, step: s.id))
            return
        }
        if s.auto {
            // Finished early: the bell only ends the automatic rest; a late: end stops nothing.
            finish(&st, idx, b, "clock", "done")
            st.wstate[key]?.open = false
            advance(&st, b, &effects, byClock: true)
            return
        }
        let plannedEnd: Bool = s.secondsTarget != nil && st.due == b
        if w.late == "end" && w.stops == nil && st.plan.score["type"]?.string == "time" && st.cap == nil {
            var finishedOnTheBell: Bool = false
            if plannedEnd {
                finishedOnTheBell = lastInWindow(&st, key)
            }
            if !finishedOnTheBell {
                // A hard cap: the workout's time is CAP + reps, ranked below every finisher (RFC 3.4, D6).
                st.cap = CapState(step: s.id, t: b, window: key, reps: nil, hard: true)
                effects.append(EngineEffect(kind: "cap", t: b, step: s.id))
            }
        }
        if s.kind == "rest" {
            finish(&st, idx, b, "clock", "done")
        } else if plannedEnd {
            finish(&st, idx, b, "clock", "done")        // a seconds part ending on the bell: as planned
        } else if s.isMax {
            finish(&st, idx, b, "clock", "done")        // the bell is a max part's planned ending
            ask(&st, s)
            effects.append(EngineEffect(kind: "ask", t: b, step: s.id))
        } else {
            finish(&st, idx, b, "clock", "cut")
            st.lastCut = idx
            if s.countsReps {
                ask(&st, s)
                effects.append(EngineEffect(kind: "ask", t: b, step: s.id))
            }
        }
        let stop: String? = w.late == "end" ? w.stops : nil
        if let stop = stop, st.repeats[stop] != nil {
            st.repeats[stop]?.stopped = true
        }
        // Skip what is left of the window (and of the repeat a late: end stops).
        while true {
            guard let nxt = nextIndex(&st) else { break }
            let n: EngineStep = st.steps[nxt]
            var inStop: Bool = false
            if let stop = stop {
                inStop = n.repeats.contains(stop)
            }
            if n.windows.contains(key) || inStop {
                st.pos += 1
                st.rec[nxt] = StepRecord(start: b, end: b, endedBy: "clock", status: "skipped", reps: nil)
                continue
            }
            break
        }
        for wk in st.wstateOrder {
            guard let other = st.wstate[wk], other.open else { continue }
            if wk == key || (st.windows[wk]?.ancestors.contains(key) ?? false) {
                st.wstate[wk]?.open = false
            }
        }
        advance(&st, b, &effects, byClock: true)
    }

    private static func ignore(_ st: inout EngineState, _ t: Int, _ reason: String, _ effects: inout [EngineEffect],
                               action: String = "crown") {
        st.ignored.append(IgnoredInput(t: t, action: action, reason: reason))
        effects.append(EngineEffect(kind: "hint", t: t, reason: reason))
    }

    /// The windows around a step whose clock ends work. A `late: continue` cap closes nothing.
    private static func clockedWindows(_ st: EngineState, _ s: EngineStep) -> [String] {
        return s.windows.filter { st.windows[$0]?.late != "continue" }
    }

    private static func crown(_ st: inout EngineState, _ t: Int, _ began: Int, _ effects: inout [EngineEffect]) {
        guard let s = st.current else {
            ignore(&st, t, st.done ? "done" : "notStarted", &effects)
            return
        }
        if let lb = st.lastBell, began < lb, lb <= t {
            if let lc = st.lastCut {
                // Grace: the turn began before the bell that cut this part: it was done at the bell.
                st.rec[lc]?.status = "done"
                st.rec[lc]?.endedBy = "athlete"
                let cut: EngineStep = st.steps[lc]
                st.asks.removeAll { $0 == cut.id }
                st.lastCut = nil
                effects.append(EngineEffect(kind: "grace", t: t, step: cut.id))
                return
            }
            ignore(&st, t, "bell", &effects)
            return
        }
        if let lb = st.lastBell, t - lb < bellLockoutMs {
            ignore(&st, t, "bell", &effects)
            return
        }
        let clocked: [String] = clockedWindows(st, s)
        let inWindow: Bool = !clocked.isEmpty || s.mergedWindow != nil
        if inWindow {
            let refs: [Int] = [st.lastCrown, st.lastBell].compactMap { $0 }
            if let ref = refs.max(), t - ref < windowLockoutMs {
                ignore(&st, t, "lockout", &effects)
                return
            }
        } else if let lc = st.lastCrown, t - lc < crownLockoutMs {
            ignore(&st, t, "lockout", &effects)
            return
        }
        if s.kind == "rest" {
            if s.auto || s.mergedWindow != nil || s.ratio != nil || (s.restSeconds != nil && !clocked.isEmpty) {
                ignore(&st, t, "clock", &effects)    // "Clock starts the next part"
                return
            }
        } else if s.secondsTarget != nil {
            ignore(&st, t, "clock", &effects)
            return
        }
        var snapshot: EngineState = st
        snapshot.snaps = []
        st.snaps.append(EngineSnapshot(t: t, state: snapshot))
        st.lastCrown = t
        let idx: Int = st.seq[st.pos]
        finish(&st, idx, t, "athlete", "done")
        if s.isMax {
            ask(&st, s)                              // "I stopped": its count is asked
            effects.append(EngineEffect(kind: "ask", t: t, step: s.id))
        }
        advance(&st, t, &effects, byClock: false)
    }

    private static func undo(_ state: EngineState, _ t: Int, _ effects: inout [EngineEffect]) -> EngineState {
        var st: EngineState = state
        guard let snapshot = st.snaps.last else {
            ignore(&st, t, "nothingToUndo", &effects, action: "undo")
            return st
        }
        let ct: Int = snapshot.t
        let snap: EngineState = snapshot.state
        if let lb = st.lastBell, lb >= ct {
            ignore(&st, t, "bell", &effects, action: "undo")   // undo never crosses a bell
            return st
        }
        if !st.done {
            let idx: Int = st.seq[st.pos]
            let s: EngineStep = st.steps[idx]
            if st.due != nil && st.rec[idx]?.start == ct && s.mergedWindow == nil {
                ignore(&st, t, "clockRunning", &effects, action: "undo")
                return st
            }
            for wk in st.wstateOrder {
                guard let ws = st.wstate[wk] else { continue }
                if ws.open && ws.start == ct && snap.wstate[wk] == nil {
                    ignore(&st, t, "clockRunning", &effects, action: "undo")
                    return st
                }
            }
        }
        var new: EngineState = snap
        new.snaps = Array(st.snaps.dropLast())
        new.log = st.log
        new.ignored = st.ignored
        new.now = t
        new.cd = nil
        effects.append(EngineEffect(kind: "undo", t: t, step: new.current?.id))
        return new
    }

    private static func reps(_ st: inout EngineState, _ sid: String, _ value: JSONValue?) {
        var v: JSONValue? = value
        if let x = v, x.isNull {
            v = nil
        }
        guard let s = st.step(id: sid) else {
            st.ignored.append(IgnoredInput(t: st.now ?? 0, action: "reps", reason: "unknownStep"))
            return
        }
        if let cap = st.cap, cap.step == sid, st.rec[s.index]?.status != "cut" {
            st.cap?.reps = v
            st.asks.removeAll { $0 == sid }
            return
        }
        if let r = st.rec[s.index], r.status == "skipped", let w = s.windows.last {
            // "I was further": the athlete was on a later part of the window than the watch thought.
            guard let posNamed = st.seq.firstIndex(of: s.index) else { return }
            var cutPos: Int? = nil
            var p: Int = posNamed - 1
            while p >= 0 {
                let o: EngineStep = st.steps[st.seq[p]]
                if !o.windows.contains(w) {
                    break
                }
                if st.rec[o.index]?.status == "cut" {
                    cutPos = p
                    break
                }
                p -= 1
            }
            if let cp = cutPos {
                let cut: EngineStep = st.steps[st.seq[cp]]
                st.rec[cut.index]?.status = "done"
                st.rec[cut.index]?.end = nil
                st.rec[cut.index]?.relabeled = true
                if cp + 1 < posNamed {
                    for q in (cp + 1)..<posNamed {
                        let qi: Int = st.seq[q]
                        st.rec[qi]?.status = "done"
                        st.rec[qi]?.start = nil
                        st.rec[qi]?.end = nil
                        st.rec[qi]?.endedBy = "athlete"
                        st.rec[qi]?.relabeled = true
                    }
                }
                st.rec[s.index]?.status = "cut"
                st.rec[s.index]?.start = nil
                st.rec[s.index]?.end = nil
                st.rec[s.index]?.reps = v
                st.rec[s.index]?.relabeled = true
                st.asks.removeAll { $0 == cut.id }
                return
            }
        }
        guard st.rec[s.index] != nil else {
            st.ignored.append(IgnoredInput(t: st.now ?? 0, action: "reps", reason: "notReached"))
            return
        }
        st.rec[s.index]?.reps = v
        st.asks.removeAll { $0 == sid }
    }

    private static func end(_ st: inout EngineState, _ t: Int, _ effects: inout [EngineEffect]) {
        guard let s = st.current else {
            ignore(&st, t, "done", &effects, action: "end")
            return
        }
        let idx: Int = st.seq[st.pos]
        finish(&st, idx, t, "end", s.kind == "part" ? "cut" : "done")
        st.done = true
        st.doneT = t
        st.endedBy = "end"
        st.due = nil
        for k in st.wstateOrder {
            st.wstate[k]?.open = false
        }
        effects.append(EngineEffect(kind: "done", t: t))
    }

    private static func blockDone(_ st: inout EngineState, _ t: Int, _ effects: inout [EngineEffect]) {
        var key: String? = nil
        if let s = st.current {
            for k in s.repeats.reversed() {
                if let rs = st.repeats[k], rs.until == "athlete" {
                    key = k
                    break
                }
            }
        }
        guard let k = key else {
            ignore(&st, t, "noBlock", &effects, action: "blockDone")
            return
        }
        st.repeats[k]?.stopped = true
        let idx: Int = st.seq[st.pos]
        finish(&st, idx, t, "athlete", "skipped")
        while true {
            guard let nxt = nextIndex(&st), st.steps[nxt].repeats.contains(k) else { break }
            st.pos += 1
            st.rec[nxt] = StepRecord(start: t, end: t, endedBy: "athlete", status: "skipped", reps: nil)
        }
        st.lastCrown = t
        advance(&st, t, &effects, byClock: false)
    }

    /// 3-2-1 before a bell that changes what you do, only if at least 3 s were left when it was
    /// first seen; a mark passed late plays only the latest one (§4.2.4).
    private static func countdown(_ st: inout EngineState, _ t: Int, _ effects: inout [EngineEffect]) {
        var signal: Int? = nil
        for b in bells(st) {
            if b.kind == "window", let wk = b.window, st.windows[wk]?.late == "continue" {
                continue
            }
            signal = b.time
            break
        }
        guard let bell = signal else {
            st.cd = nil
            return
        }
        if st.cd == nil || st.cd?.bell != bell {
            st.cd = CountdownState(bell: bell, armed: bell - t >= countdownMs, next: 3)
        }
        guard let cd = st.cd, cd.armed else { return }
        var passed: [Int] = []
        for n in [3, 2, 1] where n <= cd.next && bell - n * 1000 <= t {
            passed.append(n)
        }
        if let n = passed.min() {
            effects.append(EngineEffect(kind: "countdown", t: bell - n * 1000, n: n))
            st.cd?.next = n - 1
        }
    }

    // MARK: - Results and score

    /// Per-step facts (RFC §5), times in ms from the start: status done | cut | skipped | running | notReached.
    public static func facts(_ st: EngineState) -> JSONValue {
        var out: [JSONValue] = []
        let t0: Int = st.t0 ?? 0
        for idx in st.seq {
            let s: EngineStep = st.steps[idx]
            var d: [String: JSONValue] = [
                "id": .string(s.id), "kind": .string(s.kind),
                "rounds": .array(s.rounds.map { JSONValue.array([.string($0.key), .int($0.round)]) }),
            ]
            if s.auto {
                d["auto"] = .bool(true)
            }
            if s.extra {
                d["extra"] = .bool(true)
            }
            if let r = st.rec[idx] {
                d["status"] = .string(r.status)
                d["start"] = r.start.map { JSONValue.int($0 - t0) } ?? .null
                d["end"] = r.end.map { JSONValue.int($0 - t0) } ?? .null
                d["endedBy"] = r.endedBy.map { JSONValue.string($0) } ?? .null
                if let reps = r.reps {
                    d["reps"] = reps
                }
            } else {
                d["status"] = .string("notReached")
            }
            out.append(.object(d))
        }
        return .array(out)
    }

    /// Actual times (ms from the start) at which the clock ended a step.
    public static func boundaries(_ st: EngineState) -> [Int] {
        var out: Set<Int> = []
        let t0: Int = st.t0 ?? 0
        for idx in st.seq {
            guard let r = st.rec[idx], r.endedBy == "clock", let e = r.end, r.status != "skipped" else { continue }
            out.insert(e - t0)
        }
        return out.sorted()
    }

    private static func stepReps(_ st: EngineState, _ s: EngineStep) -> (Double, Bool) {
        guard let r = st.rec[s.index], r.status != "skipped" && r.status != "notReached" else {
            if let r = st.rec[s.index], r.status == "skipped", let n = r.reps?.number {
                return (n, true)
            }
            return (0, true)                         // a part never reached counts 0
        }
        if s.isMax || r.status == "cut" {
            guard let n = r.reps?.number else { return (0, false) }   // not entered: "?"
            return (n, true)
        }
        if r.status == "done" {
            return (s.target?["value"]?.number ?? 0, true)
        }
        return (0, true)
    }

    private static func counted(_ s: EngineStep, _ parts: [String]?) -> Bool {
        if s.kind != "part" || s.auto {
            return false
        }
        if let p = parts {
            return p.contains(s.node)
        }
        return s.countsReps
    }

    private static func repsUntil(_ st: EngineState, _ parts: [String]?, _ cap: CapState?) -> (Double, Bool) {
        var total: Double = 0
        var complete: Bool = true
        for idx in st.seq {
            let s: EngineStep = st.steps[idx]
            if !counted(s, parts) {
                continue
            }
            if let cap = cap {
                let r: StepRecord? = st.rec[idx]
                if s.id == cap.step {
                    var n: Double? = cap.reps?.number
                    if n == nil, let r = r, r.status == "cut" {
                        n = r.reps?.number                 // a hard cap: the cut step's own count
                    }
                    if let n = n {
                        total += n
                    } else {
                        complete = false
                    }
                    break
                }
                if r == nil {
                    break
                }
            }
            let sr = stepReps(st, s)
            total += sr.0
            complete = complete && sr.1
        }
        return (total, complete)
    }

    private static func scoreRepeat(_ st: EngineState) -> String? {
        let exp: WorkoutExpansion = st.plan.expansion
        for key in exp.repeatOrder where exp.repeats[key]?.times == nil {
            return key
        }
        return exp.repeatOrder.first
    }

    private static func roundsOf(_ st: EngineState, _ key: String) -> [(Int, [EngineStep])] {
        var out: [Int: [EngineStep]] = [:]
        for idx in st.seq {
            let s: EngineStep = st.steps[idx]
            for rr in s.rounds where rr.key == key {
                out[rr.round, default: []].append(s)
            }
        }
        return out.keys.sorted().map { ($0, out[$0] ?? []) }
    }

    private static func roundsReps(_ st: EngineState, _ key: String, _ parts: [String]?) -> (Int, Double, Bool) {
        var rounds: Int = 0
        var reps: Double = 0
        var ok: Bool = true
        for (_, steps) in roundsOf(st, key) {
            let work: [EngineStep] = steps.filter { $0.kind == "part" }
            if !work.isEmpty && work.allSatisfy({ st.rec[$0.index]?.status == "done" }) {
                rounds += 1
                continue
            }
            for s in work where counted(s, parts) {
                let sr = stepReps(st, s)
                reps += sr.0
                ok = ok && sr.1
            }
            break
        }
        return (rounds, reps, ok)
    }

    static func clock(_ ms: Int) -> String {
        let s: Int = ms / 1000
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Python's str() of a number that is usually whole (integer reps).
    static func numberText(_ x: Double) -> String {
        if x.isFinite && x == x.rounded() {
            return wholeText(x)
        }
        return "\(x)"
    }

    /// Python's "%d" % x: truncates toward zero; never traps on a huge value.
    static func intText(_ x: Double) -> String {
        guard x.isFinite else { return "\(x)" }
        return wholeText(x.rounded(.towardZero))
    }

    private static func wholeText(_ x: Double) -> String {
        if let i = Int(exactly: x) {
            return String(i)
        }
        return String(format: "%.0f", x)
    }

    /// The declared score (RFC §5), from the per-step facts. `complete` is false while a count it
    /// needs is not entered (the score shows "?").
    public static func score(_ st: EngineState) -> JSONValue {
        let sc: [String: JSONValue] = st.plan.score
        let typ: String = sc["type"]?.string ?? "none"
        var parts: [String]? = nil
        if let p = sc["parts"]?.array {
            parts = p.compactMap { $0.string }
        }
        var out: [String: JSONValue] = ["type": .string(typ)]
        switch typ {
        case "none":
            return .object(out)
        case "time":
            if let cap = st.cap {
                let r = repsUntil(st, parts, cap)
                out["capped"] = .bool(true)
                out["reps"] = JSONValue.numeric(r.0)
                out["complete"] = .bool(r.1)
                out["text"] = .string("CAP + " + intText(r.0))
                out["type"] = sc["atCap"] ?? .string("totalReps")
                out["afterCapMs"] = st.doneT.map { JSONValue.int($0 - cap.t) } ?? .null
                return .object(out)
            }
            guard st.done, st.endedBy != "end", let doneT = st.doneT, let t0 = st.t0 else {
                out["value"] = .null
                out["complete"] = .bool(false)
                return .object(out)
            }
            var ms: Int = doneT - t0
            if sc["includeRest"] == .bool(false) {
                for idx in st.seq {
                    let s: EngineStep = st.steps[idx]
                    if s.kind == "rest", let r = st.rec[idx], let e = r.end, let a = r.start {
                        ms -= e - a
                    }
                }
            }
            out["value"] = .int(ms)
            out["complete"] = .bool(true)
            out["text"] = .string(clock(ms))
            return .object(out)
        case "totalReps":
            let r = repsUntil(st, parts, nil)
            out["value"] = JSONValue.numeric(r.0)
            out["complete"] = .bool(r.1)
            out["text"] = .string(numberText(r.0))
            let key: String? = scoreRepeat(st)
            if sc["show"]?.string == "lowestReps", let key = key {
                var per: [Double] = []
                for (_, steps) in roundsOf(st, key) {
                    var sum: Double = 0
                    for s in steps where counted(s, parts) {
                        sum += stepReps(st, s).0
                    }
                    per.append(sum)
                }
                out["perRound"] = .array(per.map { JSONValue.numeric($0) })
                out["lowest"] = per.min().map { JSONValue.numeric($0) } ?? .null
            }
            if sc["show"]?.string == "roundsReps", let key = key {
                let rr = roundsReps(st, key, parts)
                out["roundsReps"] = .object(["rounds": .int(rr.0), "reps": JSONValue.numeric(rr.1), "complete": .bool(rr.2)])
            }
            return .object(out)
        case "roundsReps":
            var rr: (Int, Double, Bool) = (0, 0, true)
            if let key = scoreRepeat(st) {
                rr = roundsReps(st, key, parts)
            }
            out["rounds"] = .int(rr.0)
            out["reps"] = JSONValue.numeric(rr.1)
            out["complete"] = .bool(rr.2)
            out["text"] = .string(String(rr.0) + " + " + intText(rr.1))
            return .object(out)
        case "windowsCompleted":
            var total: Int = 0
            var ok: Int = 0
            for wk in st.windowOrder {
                let work: [EngineStep] = st.steps.filter { $0.windows.contains(wk) && !$0.auto && $0.kind == "part" }
                if work.isEmpty || !work.contains(where: { st.rec[$0.index] != nil }) {
                    if st.plan.windows[wk] != nil {
                        total += 1
                    }
                    continue
                }
                total += 1
                if work.allSatisfy({ st.rec[$0.index]?.status == "done" }) {
                    ok += 1
                }
            }
            out["value"] = .int(ok)
            out["of"] = .int(total)
            out["text"] = .string(String(ok) + "/" + String(total))
            return .object(out)
        case "load":
            var best: (Double, [String: JSONValue], JSONValue)? = nil
            for idx in st.seq {
                let s: EngineStep = st.steps[idx]
                guard let r = st.rec[idx], r.status == "done", let ld = s.part?["load"]?.object,
                      let v = ld["value"]?.number else { continue }
                let perUnit: Double = ld["unit"]?.string == "kg" ? 1.0 : 0.45359237
                let kg: Double = v * perUnit * (ld["count"]?.number ?? 1)
                if let b = best, kg <= b.0 {
                    continue
                }
                best = (kg, ld, s.target?["value"] ?? .null)
            }
            if let b = best {
                out["value"] = .object(["load": .object(b.1), "reps": b.2])
            } else {
                out["value"] = .null
            }
            return .object(out)
        case "perPiece":
            if (sc["metric"]?.string ?? "time") != "time" {
                out["factsOnly"] = .bool(true)           // distance / reps per piece: not yet implemented
                return .object(out)
            }
            let exp: WorkoutExpansion = st.plan.expansion
            var key: String? = nil
            if let of = sc["of"], of.truthy, let s = of.string {
                key = s
            } else {
                key = exp.repeatOrder.first
            }
            if let k = key, exp.repeats[k] == nil {
                key = exp.repeatOrder.first { exp.repeats[$0]?.id == k }
            }
            var pieces: [JSONValue] = []
            var vals: [Int] = []
            if let k = key {
                for (_, steps) in roundsOf(st, k) {
                    var starts: [Int] = []
                    var ends: [Int] = []
                    var cut: Bool = false
                    for s in steps where s.kind == "part" {
                        guard let r = st.rec[s.index], let a = r.start, let e = r.end else { continue }
                        starts.append(a)
                        ends.append(e)
                        if r.status == "cut" {
                            cut = true
                        }
                    }
                    guard let mx = ends.max(), let mn = starts.min() else { continue }
                    pieces.append(.object(["ms": .int(mx - mn), "cut": .bool(cut)]))
                    vals.append(mx - mn)
                }
            }
            let show: String = sc["show"]?.string ?? "avg"
            var agg: JSONValue = .null
            if !vals.isEmpty {
                let sum: Int = vals.reduce(0, +)
                switch show {
                case "sum": agg = .int(sum)
                case "avg": agg = .int(Int(Double(sum) / Double(vals.count) + 0.5))
                case "best": agg = .int(vals.min() ?? 0)
                case "slowest": agg = .int(vals.max() ?? 0)
                default: agg = .null
                }
            }
            out["pieces"] = .array(pieces)
            out["show"] = .string(show)
            out["value"] = agg
            return .object(out)
        default:
            out["factsOnly"] = .bool(true)               // an unknown preset never guesses a number
            return .object(out)
        }
    }
}
