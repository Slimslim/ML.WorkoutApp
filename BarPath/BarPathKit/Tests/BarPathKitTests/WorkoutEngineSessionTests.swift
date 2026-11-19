import Foundation
import XCTest
@testable import BarPathKit

/// Parity with tools/barpath/workout_session.py (the watch session on the engine): routing, event
/// decoding, the checkpoint byte for byte, the views the watch shows, and the CSV lines written as
/// the run goes. Fixtures: Fixtures/workouts/session.json; regenerate with
/// `python3 tools/make_workout_fixtures.py`. A missing fixture fails.
final class WorkoutEngineSessionTests: XCTestCase {

    // MARK: fixtures (same layout as WorkoutEngineParityTests)

    private func workoutFixture(_ rel: String) throws -> JSONValue {
        let parts: [String] = rel.components(separatedBy: "/")
        let file: String = parts.last ?? rel
        let dir: String = (["Fixtures", "workouts"] + parts.dropLast()).joined(separator: "/")
        let name: String = (file as NSString).deletingPathExtension
        var url: URL? = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: dir)
        if url == nil, let base = Bundle.module.resourceURL {
            let candidate: URL = base.appendingPathComponent(dir).appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: candidate.path) {
                url = candidate
            }
        }
        guard let u = url else {
            XCTFail("missing fixture \(rel): run python3 tools/make_workout_fixtures.py")
            throw NSError(domain: "WorkoutEngineSessionTests", code: 1)
        }
        return try JSONValue.parse(try Data(contentsOf: u))
    }

    private func optionsFor(_ name: String) throws -> JSONValue {
        if Bundle.module.url(forResource: "options", withExtension: "json",
                             subdirectory: "Fixtures/workouts/\(name)") != nil {
            return try workoutFixture("\(name)/options.json")
        }
        return .object([:])
    }

    private func choices(_ opts: JSONValue) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in opts["choices"]?.object ?? [:] {
            if let s = v.string {
                out[k] = s
            }
        }
        return out
    }

    private func planFor(_ name: String) throws -> WorkoutPlan {
        let opts: JSONValue = try optionsFor(name)
        return try WorkoutEngine.plan(try workoutFixture("\(name)/definition.json"), scale: opts["scale"]?.string,
                                      standard: opts["standard"]?.string ?? "M", choices: choices(opts))
    }

    /// Python `expand_events`.
    private func events(_ spec: JSONValue) -> [EngineEvent] {
        if let stream = spec["stream"]?.array {
            return stream.map { EngineEvent(json: $0) }
        }
        struct Keyed {
            let t: Int
            let order: Int
            let i: Int
            let event: EngineEvent
        }
        var all: [Keyed] = [Keyed(t: 0, order: 0, i: 0, event: EngineEvent(kind: "start", t: 0))]
        let every: Int = spec["ticks"]?["every"]?.intValue ?? 0
        let until: Int = spec["ticks"]?["until"]?.intValue ?? 0
        if every > 0 {
            var t: Int = every
            while t <= until {
                all.append(Keyed(t: t, order: 1, i: 0, event: EngineEvent(kind: "tick", t: t)))
                t += every
            }
        }
        for (i, e) in (spec["events"]?.array ?? []).enumerated() {
            let ev = EngineEvent(json: e)
            all.append(Keyed(t: ev.t, order: 2, i: i, event: ev))
        }
        all.sort { (a: Keyed, b: Keyed) -> Bool in
            if a.t != b.t {
                return a.t < b.t
            }
            if a.order != b.order {
                return a.order < b.order
            }
            return a.i < b.i
        }
        return all.map { $0.event }
    }

    private func session() throws -> JSONValue {
        return try workoutFixture("session.json")
    }

    private func index() throws -> JSONValue {
        return try workoutFixture("INDEX.json")
    }

    /// Python `_view`.
    private func view(_ st: EngineState) -> JSONValue {
        let pr = WorkoutEngineSession.project(st)
        var bell: JSONValue = .null
        if let b = WorkoutEngineSession.nextBell(st) {
            bell = .object(["t": .int(b.t), "finish": .bool(b.finish)])
        }
        return .object([
            "count": .int(pr.segments.count),
            "starts": .array(pr.starts.map { JSONValue.int($0) }),
            "sources": .array(pr.sources.map { JSONValue.string($0) }),
            "finish": pr.finish.map { JSONValue.int($0) } ?? .null,
            "finishSource": pr.finishSource.map { JSONValue.string($0) } ?? .null,
            "latestAsk": WorkoutEngineSession.latestAsk(st).map { JSONValue.string($0) } ?? .null,
            "nextBell": bell,
        ])
    }

    private func withoutKey(_ v: JSONValue, _ key: String) -> JSONValue {
        var o: [String: JSONValue] = v.object ?? [:]
        o[key] = nil
        return .object(o)
    }

    // MARK: parity

    func testCountsMatchIndex() throws {
        let s = try session()
        let idx = try index()
        XCTAssertEqual(s["events"]?.array?.count, idx["sessionEvents"]?.intValue)
        XCTAssertEqual(s["routes"]?.array?.count, idx["sessionRoutes"]?.intValue)
        XCTAssertEqual(s["views"]?.array?.count, idx["sessionViews"]?.intValue)
        XCTAssertEqual(s["checkpoints"]?.array?.count, idx["sessionCheckpoints"]?.intValue)
        XCTAssertEqual(s["lines"]?.array?.count, idx["sessionLines"]?.intValue)
        XCTAssertEqual(s["maxEventMs"]?.intValue, EngineEvent.maxMs)
        XCTAssertEqual(s["checkpointVersion"]?.intValue, WorkoutEngineSession.checkpointVersion)
        XCTAssertGreaterThanOrEqual(s["views"]?.array?.count ?? 0, 40)
    }

    func testEventsDecodeLikePython() throws {
        for c in try session()["events"]?.array ?? [] {
            let raw: JSONValue = c["raw"] ?? .null
            let want: String = c["decoded"]?.canonicalJSON ?? "?"
            let e = EngineEvent(json: raw)
            XCTAssertEqual(e.toJSON().canonicalJSON, want, raw.canonicalJSON)
            // Through Codable (how a checkpoint file is read) too, and back.
            let data: Data = try JSONEncoder().encode(raw)
            let d: EngineEvent = try JSONDecoder().decode(EngineEvent.self, from: data)
            XCTAssertEqual(d.toJSON().canonicalJSON, want, "Codable: \(raw.canonicalJSON)")
            let again: EngineEvent = try JSONDecoder().decode(EngineEvent.self, from: try JSONEncoder().encode(d))
            XCTAssertEqual(again, d, "encode then decode: \(raw.canonicalJSON)")
        }
    }

    func testUnknownEventKeysSurvive() {
        let raw: JSONValue = .object(["kind": .string("end"), "t": .int(5), "x-later": .array([.int(1), .null])])
        let e = EngineEvent(json: raw)
        XCTAssertEqual(e.extra["x-later"], .array([.int(1), .null]))
        XCTAssertEqual(e.toJSON(), raw)
    }

    func testRoutesMatchPython() throws {
        for c in try session()["routes"]?.array ?? [] {
            let name: String = c["name"]?.string ?? "?"
            var raw: JSONValue = c["raw"] ?? .null
            var opts: JSONValue = .object([:])
            if let caseName = c["case"]?.string {
                raw = try workoutFixture("\(caseName)/definition.json")
                opts = c["options"] ?? .object([:])
            }
            let r = WorkoutEngineSession.route(raw, scale: opts["scale"]?.string,
                                               standard: opts["standard"]?.string ?? "M", choices: choices(opts))
            XCTAssertEqual(WorkoutEngineSession.routeJSON(r).canonicalJSON, c["expected"]?.canonicalJSON, name)
        }
    }

    func testEveryBuiltInWorkoutKeepsTheOldPath() throws {
        for d in WorkoutLibrary.known {
            let raw: JSONValue = try JSONValue.parse(try JSONEncoder().encode(d))
            XCTAssertEqual(WorkoutEngineSession.route(raw), .legacy(reason: nil, missing: []), d.id)
        }
    }

    func testViewsMatchPython() throws {
        for v in try session()["views"]?.array ?? [] {
            let name: String = v["case"]?.string ?? "?"
            let scen: String = v["scenario"]?.string ?? "?"
            let plan = try planFor(name)
            let evs: [EngineEvent] = events(try workoutFixture("\(name)/events/\(scen).json"))
            let segs: [JSONValue] = v["segments"]?.array ?? []
            var finalState: EngineState? = nil
            for at in v["at"]?.array ?? [] {
                let k: Int = at["events"]?.intValue ?? 0
                let (st, _) = WorkoutEngine.run(plan, Array(evs.prefix(k)))
                XCTAssertEqual(view(st).canonicalJSON, withoutKey(at, "events").canonicalJSON, "\(name)/\(scen) @\(k)")
                finalState = st
                // The typed progress the views read agrees with the projection.
                let pr = WorkoutEngineSession.project(st)
                let p = WorkoutEngineSession.progress(.object(["id": .string(name)]), pr, startEpoch: 1_800_000_000)
                XCTAssertEqual(p.segmentStarts.count, pr.starts.count, "\(name)/\(scen) @\(k): starts")
                XCTAssertEqual(p.isFinished, pr.finish != nil, "\(name)/\(scen) @\(k): finished")
                XCTAssertEqual(p.definition.segments.count, pr.segments.count, "\(name)/\(scen) @\(k): segments")
            }
            if let st = finalState {
                let pr = WorkoutEngineSession.project(st)
                XCTAssertEqual(pr.segments.count, segs.count, "\(name)/\(scen): segment count")
                for (i, (g, w)) in zip(pr.segments, segs).enumerated() {
                    XCTAssertEqual(g.canonicalJSON, w.canonicalJSON, "\(name)/\(scen): segment \(i)")
                }
            }
        }
    }

    func testCheckpointsMatchPythonByteForByte() throws {
        for c in try session()["checkpoints"]?.array ?? [] {
            let name: String = c["case"]?.string ?? "?"
            let scen: String = c["scenario"]?.string ?? "?"
            let text: String = c["text"]?.string ?? ""
            let saved: Int = c["savedAtMs"]?.intValue ?? 0
            let plan = try planFor(name)
            let opts: JSONValue = try optionsFor(name)
            let evs = events(try workoutFixture("\(name)/events/\(scen).json")).filter { $0.t <= saved }
            let (live, _) = WorkoutEngine.run(plan, evs)
            let written: JSONValue = try JSONValue.parse(Data(text.utf8))
            let cp = WorkoutEngineSession.makeCheckpoint(
                definition: try workoutFixture("\(name)/definition.json"), plan: plan, state: live,
                startEpochMs: Int64(c["startEpochMs"]?.intValue ?? 0), savedAtMs: saved,
                options: WorkoutEngineSession.options(scale: opts["scale"]?.string,
                                                      standard: opts["standard"]?.string ?? "M",
                                                      choices: choices(opts)),
                watch: written["watch"] ?? .object([:]))
            XCTAssertEqual(WorkoutEngineSession.checkpointData(cp), Data(text.utf8), "\(name)/\(scen): bytes")
            // Byte-exact round trip: what a relaunch reads, written again, is the same file.
            XCTAssertEqual(WorkoutEngineSession.checkpointData(written), Data(text.utf8), "\(name)/\(scen): round trip")
            switch WorkoutEngineSession.recover(written) {
            case .ok(_, let st):
                XCTAssertEqual(view(st).canonicalJSON, c["view"]?.canonicalJSON, "\(name)/\(scen): recovered")
                XCTAssertEqual(view(live).canonicalJSON, c["liveView"]?.canonicalJSON, "\(name)/\(scen): live")
            case .refused(let reason):
                XCTFail("\(name)/\(scen): refused \(reason)")
            }
        }
    }

    func testRecoveryRefusesWhatItCannotReplay() throws {
        let c = try XCTUnwrap(try session()["checkpoints"]?.array?.first)
        let cp: JSONValue = try JSONValue.parse(Data((c["text"]?.string ?? "").utf8))
        func with(_ key: String, _ v: JSONValue?) -> JSONValue {
            var o = cp.object ?? [:]
            o[key] = v
            return .object(o)
        }
        func reason(_ x: JSONValue) -> String? {
            if case .refused(let r) = WorkoutEngineSession.recover(x) {
                return r
            }
            return nil
        }
        XCTAssertNil(reason(cp))
        XCTAssertEqual(reason(with("version", .int(2))), "version")
        XCTAssertEqual(reason(with("version", .bool(true))), "version")
        XCTAssertEqual(reason(with("version", nil)), "version")
        XCTAssertEqual(reason(with("planHash", .string("0"))), "planChanged")
        XCTAssertEqual(reason(with("definition", .string("x"))), "invalid")
        var def = cp["definition"]?.object ?? [:]
        def["requires"] = .array([.string("teleport")])
        XCTAssertEqual(reason(with("definition", .object(def))), "updateApp")
        def["requires"] = nil
        def["schemaVersion"] = .int(0)
        XCTAssertEqual(reason(with("definition", .object(def))), "draft")
        XCTAssertEqual(reason(.null), "version")
        // Corrupt event times are clamped, never trap, and replay stops at savedAtMs.
        var evs = cp["events"]?.array ?? []
        evs.append(.object(["kind": .string("crown"), "t": .double(9.0e18)]))
        if case .ok(_, let st) = WorkoutEngineSession.recover(with("events", .array(evs))) {
            XCTAssertLessThanOrEqual(st.now ?? 0, EngineEvent.maxMs)
        } else {
            XCTFail("a clamped event must not refuse the checkpoint")
        }
    }

    func testLinesMatchPython() throws {
        for c in try session()["lines"]?.array ?? [] {
            let name: String = c["case"]?.string ?? "?"
            let scen: String = c["scenario"]?.string ?? "?"
            let plan = try planFor(name)
            var st = WorkoutEngine.initial(plan)
            var written: [String: Int] = [:]
            var got: [JSONValue] = []
            for (i, e) in events(try workoutFixture("\(name)/events/\(scen).json")).enumerated() {
                st = WorkoutEngine.reduce(st, e).0
                let new = WorkoutEngineSession.newLines(st, written: &written)
                if !new.isEmpty {
                    got.append(.object(["after": .int(i + 1),
                                        "lines": .array(new.map { JSONValue.array([.int($0.t), .string($0.text)]) })]))
                }
            }
            XCTAssertEqual(JSONValue.array(got).canonicalJSON, c["batches"]?.canonicalJSON, "\(name)/\(scen)")
        }
    }

    func testPhoneRouteAndFidelityMatchPython() throws {
        let list = try workoutFixture("phone.json").array ?? []
        XCTAssertEqual(list.count, try index()["phone"]?.intValue)
        XCTAssertGreaterThanOrEqual(list.count, 60)
        for c in list {
            let name: String = c["name"]?.string ?? "?"
            let raw: JSONValue = c["raw"] ?? .null
            let r = WorkoutEngineSession.phoneRoute(raw)
            XCTAssertEqual(WorkoutEngineSession.phoneRouteJSON(r).canonicalJSON, c["route"]?.canonicalJSON, "\(name): route")
            XCTAssertEqual(WorkoutEngineSession.phoneFidelity(raw).toJSON().canonicalJSON,
                           c["fidelity"]?.canonicalJSON, "\(name): fidelity")
            // The payload is sent exactly when the route says engine, and the watch routes it there.
            let payload: Data? = WorkoutEngineSession.phonePayload(raw)
            XCTAssertEqual(payload != nil, r == .engine, "\(name): payload")
            if let p = payload {
                XCTAssertEqual(WorkoutEngineSession.route(try JSONValue.parse(p)), .engine, "\(name): watch route")
            }
        }
    }

    // MARK: Swift-only

    func testEpochMillisecondsNeverNeedA64BitInt() {
        XCTAssertEqual(WorkoutEngineSession.wholeNumber(1_795_000_000_123).canonicalJSON, "1795000000123")
        XCTAssertEqual(WorkoutEngineSession.wholeNumber(-3).canonicalJSON, "-3")
    }

    func testUpgradeRefusesNonFiniteTargetsAndLoads() {
        func row(_ target: JSONValue, _ load: JSONValue?) -> JSONValue {
            var seg: [String: JSONValue] = ["kind": .string("station"), "movement": .string("burpees"),
                                            "name": .string("Burpees"), "target": target]
            if let l = load {
                seg["load"] = l
            }
            return .object(["id": .string("x"), "name": .string("x"), "shortName": .string("x"),
                            "format": .string("forTime"), "team": .string("solo"),
                            "healthKitActivity": .string("crossTraining"), "segments": .array([.object(seg)])])
        }
        let reps: JSONValue = .object(["value": .int(10), "unit": .string("reps")])
        let ok = WorkoutUpgrade.upgrade(row(reps, nil))
        XCTAssertEqual(ok.label, "exact")
        XCTAssertEqual(ok.definition["fidelity"], .string("exact"))
        XCTAssertNil(ok.definition["approx"])
        let inf = WorkoutUpgrade.upgrade(row(.object(["value": .double(.infinity), "unit": .string("reps")]), nil))
        XCTAssertTrue(inf.reasons.contains("invalidField"), "\(inf.reasons)")
        XCTAssertEqual(inf.definition["fidelity"], .string("approx"))
        let heavy: JSONValue = .object(["value": .double(.infinity), "unit": .string("kg")])
        let load = WorkoutUpgrade.upgrade(row(reps, heavy))
        XCTAssertTrue(load.reasons.contains("invalidField"), "\(load.reasons)")
        XCTAssertTrue(load.definition["approx"]?.array?.contains(.string("upgrade:invalidField")) ?? false)
    }
}
