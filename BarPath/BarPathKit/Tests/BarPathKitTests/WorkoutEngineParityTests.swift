import Foundation
import XCTest
@testable import BarPathKit

/// Parity with the Python reference (tools/barpath/workout_engine.py): every case and scenario
/// that Python wrote into Fixtures/workouts must give the same plan (canonical JSON and SHA-256),
/// effects, facts and score. Regenerate with `python3 tools/make_workout_fixtures.py`.
/// A missing fixture fails (it never skips), and INDEX.json holds the counts.
final class WorkoutEngineParityTests: XCTestCase {

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
            throw NSError(domain: "WorkoutEngineParityTests", code: 1)
        }
        return try JSONValue.parse(try Data(contentsOf: u))
    }

    /// The plan arguments a case needs (scale, standard, machine choice), from options.json.
    private func planFor(_ name: String) throws -> WorkoutPlan {
        let definition = try workoutFixture("\(name)/definition.json")
        var opts: JSONValue = .object([:])
        if Bundle.module.url(forResource: "options", withExtension: "json",
                             subdirectory: "Fixtures/workouts/\(name)") != nil {
            opts = try workoutFixture("\(name)/options.json")
        }
        var choices: [String: String] = [:]
        for (k, v) in opts["choices"]?.object ?? [:] {
            if let s = v.string {
                choices[k] = s
            }
        }
        return try WorkoutEngine.plan(definition, scale: opts["scale"]?.string,
                                      standard: opts["standard"]?.string ?? "M", choices: choices)
    }

    private func index() throws -> JSONValue {
        return try workoutFixture("INDEX.json")
    }

    /// The event list a scenario file describes, expanded exactly like Python's `expand_events`.
    private func events(_ spec: JSONValue) throws -> [EngineEvent] {
        let decoder = JSONDecoder()
        func decode(_ v: JSONValue) throws -> EngineEvent {
            return try decoder.decode(EngineEvent.self, from: try JSONEncoder().encode(v))
        }
        if let stream = spec["stream"]?.array {
            return try stream.map { try decode($0) }
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
            let ev: EngineEvent = try decode(e)
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

    private func cases() throws -> [String] {
        return (try index()["cases"]?.array ?? []).compactMap { $0.string }
    }

    private func scenarios(_ name: String) throws -> [String] {
        // Scenario names come from the expected plan's sibling folder; Python lists them in the
        // INDEX count, and each must exist.
        let base: URL? = Bundle.module.resourceURL?
            .appendingPathComponent("Fixtures/workouts/\(name)/events")
        guard let dir = base,
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            XCTFail("no events folder for \(name)")
            return []
        }
        return files.filter { $0.hasSuffix(".json") }.map { ($0 as NSString).deletingPathExtension }.sorted()
    }

    func testIndexCountsEveryCaseAndScenario() throws {
        let idx = try index()
        let names = try cases()
        XCTAssertGreaterThanOrEqual(names.count, 23)
        XCTAssertTrue(names.contains("unknownNodes") && names.contains("variantsF") && names.contains("variantsL1"))
        XCTAssertEqual(idx["planner"]?.intValue, WorkoutPlan.plannerVersion)
        var total: Int = 0
        for name in names {
            let s = try scenarios(name)
            XCTAssertFalse(s.isEmpty, name)
            total += s.count
        }
        XCTAssertEqual(total, idx["scenarios"]?.intValue)
    }

    func testPlansMatchPythonByteForByte() throws {
        for name in try cases() {
            let expected = try workoutFixture("\(name)/expected_plan.json")
            let plan = try planFor(name)
            XCTAssertEqual(plan.canonicalJSON, expected["plan"]?.canonicalJSON, "\(name): plan")
            XCTAssertEqual(plan.hash, expected["hash"]?.string, "\(name): plan hash")
        }
    }

    func testScenariosMatchPython() throws {
        for name in try cases() {
            let plan = try planFor(name)
            for scen in try scenarios(name) {
                let spec = try workoutFixture("\(name)/events/\(scen).json")
                let expected = try workoutFixture("\(name)/expected/\(scen).result.json")
                let (st, effects) = WorkoutEngine.run(plan, try events(spec))
                let label: String = "\(name)/\(scen)"
                XCTAssertEqual(JSONValue.array(effects.map { $0.toJSON() }).canonicalJSON,
                               expected["effects"]?.canonicalJSON, "\(label): effects")
                XCTAssertEqual(WorkoutEngine.facts(st).canonicalJSON, expected["facts"]?.canonicalJSON,
                               "\(label): facts")
                XCTAssertEqual(WorkoutEngine.score(st).canonicalJSON, expected["score"]?.canonicalJSON,
                               "\(label): score")
                XCTAssertEqual(JSONValue.array(WorkoutEngine.boundaries(st).map { JSONValue.int($0) }).canonicalJSON,
                               expected["boundaries"]?.canonicalJSON, "\(label): boundaries")
                XCTAssertEqual(st.done, expected["done"]?.bool, "\(label): done")
                XCTAssertEqual(st.doneT, expected["doneT"]?.intValue, "\(label): doneT")
                XCTAssertEqual(st.endedBy, expected["endedBy"]?.string, "\(label): endedBy")
                XCTAssertEqual(st.asks, (expected["asks"]?.array ?? []).compactMap { $0.string }, "\(label): asks")
                XCTAssertEqual(st.current?.id, expected["current"]?.string, "\(label): current")
            }
        }
    }

    func testReplayOfTheLogEqualsLive() throws {
        for name in try cases() {
            let plan = try planFor(name)
            for scen in try scenarios(name) {
                let (live, _) = WorkoutEngine.run(plan, try events(try workoutFixture("\(name)/events/\(scen).json")))
                let replayed = WorkoutEngine.replay(plan, live.log, until: live.now)
                XCTAssertEqual(WorkoutEngine.facts(replayed).canonicalJSON, WorkoutEngine.facts(live).canonicalJSON,
                               "\(name)/\(scen): replay")
                XCTAssertEqual(WorkoutEngine.score(replayed).canonicalJSON, WorkoutEngine.score(live).canonicalJSON,
                               "\(name)/\(scen): replay score")
            }
        }
    }

    func testRunnableMatchesPython() throws {
        let list = try workoutFixture("runnable.json").array ?? []
        XCTAssertEqual(list.count, try index()["runnable"]?.intValue)
        for c in list {
            let doc: JSONValue = c["doc"] ?? .null
            let features: Set<String> = Set((c["engineFeatures"]?.array ?? []).compactMap { $0.string })
            let got = WorkoutStructureV2.checkRunnable(doc, engineFeatures: features)
            let expected: [JSONValue] = c["expected"]?.array ?? []
            let name: String = c["name"]?.string ?? "?"
            XCTAssertEqual(got.status, expected.first?.string, name)
            XCTAssertEqual(got.missing, (expected.last?.array ?? []).compactMap { $0.string }, name)
            if got.status != "ok" {
                XCTAssertThrowsError(try WorkoutEngine.plan(doc, engineFeatures: features), name)
            }
        }
    }

    /// The reader is total: out-of-range numbers, a plan past 400 steps or an empty plan are refused
    /// with the same reason as Python, never a trap or an endless expansion.
    func testPlanErrorsMatchPython() throws {
        let list = try workoutFixture("planErrors.json").array ?? []
        XCTAssertEqual(list.count, try index()["planErrors"]?.intValue)
        for c in list {
            let name: String = c["name"]?.string ?? "?"
            do {
                _ = try WorkoutEngine.plan(c["doc"] ?? .null, standard: c["options"]?["standard"]?.string ?? "M")
                XCTFail("\(name): planned")
            } catch let e as WorkoutNotRunnable {
                XCTAssertEqual(e.reason, c["reason"]?.string, name)
            }
        }
    }

    /// Raw pass-through (RFC §14.3 A5): a definition decoded and encoded again keeps every key.
    func testDefinitionsRoundTripUnchanged() throws {
        for name in try cases() {
            let definition = try workoutFixture("\(name)/definition.json")
            let again = try JSONValue.parse(try JSONEncoder().encode(definition))
            XCTAssertEqual(again.canonicalJSON, definition.canonicalJSON, name)
        }
        let withUnknown = try JSONValue.parse(Data("""
        {"schemaVersion": 2, "x-coach": {"cue": "hips"}, "structure": {"score": {"type": "none"},
         "body": [{"part": {"id": "a", "movement": "run", "tempo": "2-0-1-0", "x-video": "v1"}}]}}
        """.utf8))
        let again = try JSONValue.parse(try JSONEncoder().encode(withUnknown))
        XCTAssertEqual(again, withUnknown)
        XCTAssertEqual(again["x-coach"]?["cue"]?.string, "hips")
    }

    /// RFC §7.3: every legacy row upgrades to the same definition, label and reasons as Python,
    /// and the upgraded definition plans to the same hash.
    func testUpgradeMatchesPython() throws {
        let list = try workoutFixture("upgrade.json").array ?? []
        XCTAssertEqual(list.count, try index()["upgrade"]?.intValue)
        XCTAssertGreaterThanOrEqual(list.count, 20)
        for c in list {
            let name: String = c["name"]?.string ?? "?"
            let u = WorkoutUpgrade.upgrade(c["input"] ?? .null)
            XCTAssertEqual(u.definition.canonicalJSON, c["definition"]?.canonicalJSON, "\(name): definition")
            XCTAssertEqual(u.label, c["label"]?.string, "\(name): label")
            XCTAssertEqual(u.reasons, (c["reasons"]?.array ?? []).compactMap { $0.string }, "\(name): reasons")
            XCTAssertEqual(try WorkoutEngine.plan(u.definition).hash, c["planHash"]?.string, "\(name): plan hash")
            // Idempotent: upgrading the upgraded definition changes nothing but keeps the label.
            let again = WorkoutUpgrade.upgrade(u.definition)
            XCTAssertEqual(again.definition.canonicalJSON, u.definition.canonicalJSON, "\(name): idempotent")
        }
    }

    /// RFC §9: the plan, bell, step and ignored-input lines match Python's text exactly.
    func testCSVLinesMatchPython() throws {
        let list = try workoutFixture("csv.json").array ?? []
        XCTAssertEqual(list.count, try index()["csv"]?.intValue)
        for c in list {
            let name: String = c["case"]?.string ?? "?"
            let scen: String = c["scenario"]?.string ?? "?"
            let plan = try planFor(name)
            let lines = WorkoutEngineCSV.planLines(plan, startEpochMs: c["startEpochMs"]?.intValue ?? 0,
                                                   startUptimeMs: c["startUptimeMs"]?.intValue ?? 0)
            XCTAssertEqual(lines, (c["planLines"]?.array ?? []).compactMap { $0.string }, "\(name)/\(scen): plan lines")
            let (st, _) = WorkoutEngine.run(plan, try events(try workoutFixture("\(name)/events/\(scen).json")))
            let got: [WorkoutEngineCSV.Line] = WorkoutEngineCSV.eventLines(st)
            let want: [JSONValue] = c["eventLines"]?.array ?? []
            XCTAssertEqual(got.count, want.count, "\(name)/\(scen): event line count")
            for (g, w) in zip(got, want) {
                XCTAssertEqual(g.t, w.array?.first?.intValue, "\(name)/\(scen): t")
                XCTAssertEqual(g.text, w.array?.last?.string, "\(name)/\(scen): line")
            }
        }
    }

    func testCSVEncodingRoundTrips() {
        let raw: String = "a b,c%d\te\nf\rg"
        let e: String = WorkoutEngineCSV.enc(raw)
        XCTAssertFalse(e.contains(" ") || e.contains(",") || e.contains("\t") || e.contains("\n"))
        XCTAssertEqual(e, "a%20b%2Cc%25d%09e%0Af%0Dg")
        XCTAssertEqual(WorkoutEngineCSV.dec(e), raw)
        XCTAssertEqual(WorkoutEngineCSV.dec(WorkoutEngineCSV.enc("%20")), "%20")
    }

    /// The plain-Swift SHA-256 (used where CryptoKit is missing) gives the standard digests and the
    /// same plan hashes as the platform hash.
    func testPlainSHA256MatchesStandardVectors() throws {
        func sha(_ s: String) -> String {
            return WorkoutSHA256.hex(WorkoutSHA256.digest(Array(s.utf8)))
        }
        XCTAssertEqual(sha(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(sha("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(sha("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(sha(String(repeating: "a", count: 1000)),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
        for name in try cases() {
            let plan = try planFor(name)
            XCTAssertEqual(WorkoutSHA256.hex(WorkoutSHA256.digest(Array(plan.canonicalJSON.utf8))), plan.hash, name)
        }
    }

    func testCanonicalJSONMatchesPythonRules() {
        let v: JSONValue = .object(["b": .double(40.0), "a": .array([.double(0.5), .string("é\"\n")]), "c": .null])
        XCTAssertEqual(v.canonicalJSON, "{\"a\":[0.5,\"é\\\"\\n\"],\"b\":40,\"c\":null}")
        XCTAssertEqual(JSONValue.double(1e16).canonicalJSON, "10000000000000000")
        XCTAssertEqual(JSONValue.double(1e20).canonicalJSON, "100000000000000000000")
        XCTAssertNil(JSONValue.double(1e20).intValue)
    }
}
