import Foundation
import XCTest
@testable import BarPathKit

/// E4 (0.18) engine gate: every built-in and every row of Fixtures/engine_gate_cases.json
/// (tools/engine_gate.py) starts the way the watch starts it (`RepeatBlock.startProgress`) and must
/// give the same events, step starts, finish and splits with the engine off and on. CI fails on any
/// difference.
final class EngineGateTests: XCTestCase {

    typealias Action = RepeatBlockProgressTests.Action
    typealias Event = RepeatBlockProgressTests.Event

    struct Expected: Decodable {
        let events: [Event]
        let finish: Double?
        let steps: Int
    }

    struct Case: Decodable {
        let name: String
        let definition: WorkoutDefinition
        let scripts: [[Action]]
        let expected: [Expected]
    }

    struct Fixture: Decodable {
        let cases: [Case]
    }

    /// The gate's fixtures must be there: a missing file fails (it never skips like fixtureData).
    static func gateFixture(_ name: String) throws -> Data {
        guard let url = fixtureURL(name, "json") else {
            XCTFail("gate fixture \(name).json is missing from the test bundle")
            throw NSError(domain: "EngineGateTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "missing \(name).json"])
        }
        return try Data(contentsOf: url)
    }

    struct GoldenResult: Decodable, Equatable {
        let totalSeconds: Double
        let finished: Bool
        let isCapped: Bool
        let capSegmentIndex: Int?
        let partialRepsLimit: Int?
        let repsAtCapLimit: Int?
        let partialReps: Int?
        let repsAtCap: Int?
        let capPositionText: String?
        let runSeconds: Double
        let stationSeconds: Double
    }

    struct GoldenTrace: Decodable {
        let events: [Event]
        let starts: [Double]
        let finish: Double?
        let splits: [SegmentResult]
        let result: GoldenResult
    }

    /// Reps entered on the watch after a cap finish (engine_gate.PARTIAL_REPS).
    static let partialReps: Int = 7

    /// The result the watch writes at End (WorkoutSessionModel.makeResult), as engine_gate.result_fields.
    static func resultFields(_ p: WorkoutProgress, splits: [SegmentResult], end: Double) -> GoldenResult {
        let start: Double = p.startTime ?? end
        let finish: Double? = p.finishTime
        var r = WorkoutResult(definition: p.definition, startDate: Date(timeIntervalSince1970: start),
                              finishDate: finish.map { (t: Double) -> Date in Date(timeIntervalSince1970: t) },
                              endDate: Date(timeIntervalSince1970: end), totalSeconds: (finish ?? end) - start,
                              segments: splits, events: p.events)
        if finish != nil {
            if r.isCapped {
                r.repsAtCap = Swift.min(Swift.max(0, partialReps), r.repsAtCapLimit ?? partialReps)
            } else {
                r.partialReps = Swift.min(Swift.max(0, partialReps), r.partialRepsLimit ?? partialReps)
            }
        }
        return GoldenResult(totalSeconds: r.totalSeconds, finished: finish != nil, isCapped: r.isCapped,
                            capSegmentIndex: r.capSegmentIndex, partialRepsLimit: r.partialRepsLimit,
                            repsAtCapLimit: r.repsAtCapLimit, partialReps: r.partialReps,
                            repsAtCap: r.repsAtCap, capPositionText: r.capPositionText,
                            runSeconds: r.runSeconds, stationSeconds: r.stationSeconds)
    }

    struct GoldenCase: Decodable {
        let name: String
        let definition: WorkoutDefinition
        let scripts: [[Action]]
        let traces: [GoldenTrace]
    }

    struct Golden: Decodable {
        let ref: String
        let cases: [GoldenCase]
    }

    struct Run: Equatable {
        let events: [Event]
        let starts: [Double]
        let finish: Double?
        let splits: [SegmentResult]
        let block: Bool
    }

    static func run(_ d: WorkoutDefinition, engineOn: Bool, script: [Action]) -> Run {
        var p: WorkoutProgress = RepeatBlock.startProgress(for: d, engineOn: engineOn)
        let events: [Event] = RepeatBlockProgressTests.run(&p, script: script)
        var end: Double = 0
        for a in script where a.t > end {
            end = a.t
        }
        let splits: [SegmentResult] = SplitStats.compute(progress: p, now: end, heartRates: [], pedometer: [])
        return Run(events: events, starts: p.segmentStarts, finish: p.finishTime, splits: splits,
                   block: p.block != nil)
    }

    /// Same runs as `engine_gate.scripts` (tools/engine_gate.py), built here for the built-ins.
    static func scripts(for d: WorkoutDefinition) throws -> [[Action]] {
        let n: Int = d.segments.count
        var raw: [[[Any]]] = []
        var steady: [[Any]] = [[0.0, "start"]]
        for k in 0..<(n + 4) { steady.append([37.0 * Double(k + 1), "crown"]) }
        steady.append([37.0 * Double(n + 5) + 4000.0, "tick"])
        raw.append(steady)
        var fast: [[Any]] = [[0.0, "start"]]
        var t: Double = 0
        for k in 0..<(n + 6) {
            t += 13.0
            fast.append([t, "crown"])
            if k % 5 == 4 {
                t += 2.5
                fast.append([t, "undo"])
            }
        }
        fast.append([t + 4000.0, "tick"])
        raw.append(fast)
        raw.append([[0.0, "start"], [6000.0, "tick"]])
        var slow: [[Any]] = [[0.0, "start"]]
        for k in 0..<(n + 2) { slow.append([90.0 * Double(k + 1), "crown"]) }
        slow.append([90.0 * Double(n + 3) + 4000.0, "tick"])
        raw.append(slow)
        raw.append([[0.0, "start"], [41.0, "crown"], [82.0, "crown"], [150.0, "end"]])
        var double: [[Any]] = [[0.0, "start"]]
        for k in 0..<Swift.min(n, 6) {
            double.append([31.0 * Double(k + 1), "crown"])
            double.append([31.0 * Double(k + 1) + 0.4, "crown"])
        }
        double.append([31.0 * 7 + 4000.0, "tick"])
        raw.append(double)
        raw.append([[0.0, "start"], [10.0, "crown"], [200.0, "tick"], [201.0, "undo"], [205.0, "crown"],
                    [4205.0, "tick"]])
        let data: Data = try JSONSerialization.data(withJSONObject: raw, options: [])
        return try JSONDecoder().decode([[Action]].self, from: data)
    }

    func testEveryBuiltInIsIdenticalWithTheEngineOn() throws {
        XCTAssertGreaterThanOrEqual(WorkoutLibrary.known.count, 11)
        for d in WorkoutLibrary.known {
            XCTAssertEqual(RepeatBlock.plan(for: d).kind, RepeatBlock.Kind.legacy, d.id)
            for (i, script) in try EngineGateTests.scripts(for: d).enumerated() {
                let off: Run = EngineGateTests.run(d, engineOn: false, script: script)
                let on: Run = EngineGateTests.run(d, engineOn: true, script: script)
                XCTAssertFalse(on.block, "\(d.id) script \(i)")
                XCTAssertEqual(on, off, "\(d.id) script \(i)")
            }
        }
    }

    func testEveryFixedListRowIsIdenticalWithTheEngineOn() throws {
        let data: Data = try EngineGateTests.gateFixture("engine_gate_cases")
        let cases: [Case] = try JSONDecoder().decode(Fixture.self, from: data).cases
        XCTAssertGreaterThanOrEqual(cases.count, 12)
        for c in cases {
            XCTAssertEqual(c.scripts.count, c.expected.count, c.name)
            for (i, script) in c.scripts.enumerated() where i < c.expected.count {
                let off: Run = EngineGateTests.run(c.definition, engineOn: false, script: script)
                let on: Run = EngineGateTests.run(c.definition, engineOn: true, script: script)
                XCTAssertEqual(on, off, "\(c.name) script \(i)")
                // And the same as the Python reference.
                XCTAssertEqual(on.events, c.expected[i].events, "\(c.name) script \(i)")
                XCTAssertEqual(on.finish, c.expected[i].finish, "\(c.name) script \(i)")
                XCTAssertEqual(on.starts.count, c.expected[i].steps, "\(c.name) script \(i)")
            }
        }
    }

    /// A row marked listedOnce takes block mode with the engine on: the gate must see the change.
    func testTheGateCatchesADifference() throws {
        let data: Data = try EngineGateTests.gateFixture("engine_gate_cases")
        let cases: [Case] = try JSONDecoder().decode(Fixture.self, from: data).cases
        guard let c = cases.first(where: { (c: Case) -> Bool in c.definition.id == "gate.amrapOne" }) else {
            XCTFail("no gate.amrapOne")
            return
        }
        var d: WorkoutDefinition = c.definition
        d.listedOnce = true
        var differs: Bool = false
        for script in c.scripts {
            if EngineGateTests.run(d, engineOn: true, script: script) != EngineGateTests.run(d, engineOn: false, script: script) {
                differs = true
            }
        }
        XCTAssertTrue(differs)
    }

    // MARK: E5 engine test workouts

    func testEngineTestsResolveButStayOffTheGridAndKnown() {
        let ids: [String] = WorkoutLibrary.engineTests.map { (d: WorkoutDefinition) -> String in d.id }
        XCTAssertEqual(ids, ["engine.amrap", "engine.emom", "engine.tabata", "engine.rounds5", "engine.hyroxSim"])
        let known: Set<String> = Set(WorkoutLibrary.known.map { (d: WorkoutDefinition) -> String in d.id })
        for id in ids {
            XCTAssertNotNil(WorkoutLibrary.definition(id: id), id)
            XCTAssertFalse(known.contains(id), id)
        }
        XCTAssertEqual(WorkoutLibrary.all.count, 9)
    }

    func testListedOnceTestWorkoutsRunAsABlockWithTheEngineOn() {
        for d in WorkoutLibrary.engineTests where d.listedOnce == true {
            XCTAssertEqual(RepeatBlock.listedOnceProblems(d), [], d.id)
            XCTAssertEqual(RepeatBlock.plan(for: d).kind, RepeatBlock.Kind.repeating, d.id)
            XCTAssertNotNil(RepeatBlock.startProgress(for: d, engineOn: true).block, d.id)
            XCTAssertNil(RepeatBlock.startProgress(for: d, engineOn: false).block, d.id)
        }
    }

    func testHyroxSimulationIsIdenticalWithTheEngineOn() throws {
        let d: WorkoutDefinition = WorkoutLibrary.engineHyroxSim
        XCTAssertNil(d.listedOnce)
        for (i, script) in try EngineGateTests.scripts(for: d).enumerated() {
            XCTAssertEqual(EngineGateTests.run(d, engineOn: true, script: script),
                           EngineGateTests.run(d, engineOn: false, script: script), "script \(i)")
        }
    }

    func testTabataTestWorkoutIsSixteenStepsAndFourMinutes() throws {
        let raw: [[Any]] = [[0.0, "start"], [300.0, "tick"]]
        let script: [Action] = try JSONDecoder().decode([Action].self,
                                                        from: JSONSerialization.data(withJSONObject: raw, options: []))
        let on: Run = EngineGateTests.run(WorkoutLibrary.engineTabata, engineOn: true, script: script)
        XCTAssertEqual(on.starts.count, 16)
        XCTAssertEqual(on.finish, 240)
    }

    /// Classic (engine off): the listed-once test workouts are written out first, never one pass.
    func testEngineTestWorkoutsRunEveryPassOnClassic() throws {
        func classic(_ d: WorkoutDefinition, _ raw: [[Any]]) throws -> Run {
            let script: [Action] = try JSONDecoder().decode([Action].self,
                                                            from: JSONSerialization.data(withJSONObject: raw, options: []))
            return EngineGateTests.run(d, engineOn: false, script: script)
        }
        var rounds: [[Any]] = [[0.0, "start"]]
        for k in 0..<16 { rounds.append([30.0 * Double(k + 1), "crown"]) }
        let r: Run = try classic(WorkoutLibrary.engineRounds5, rounds)
        XCTAssertEqual(r.starts.count, 15)
        XCTAssertEqual(r.finish, 450)
        var emom: [[Any]] = [[0.0, "start"]]
        for k in 0..<6 { emom.append([60.0 * Double(k) + 30, "crown"]) }
        emom.append([400.0, "tick"])
        let e: Run = try classic(WorkoutLibrary.engineEmom, emom)
        XCTAssertEqual(e.starts.count, 12)
        XCTAssertEqual(e.finish, 360)
        var tabata: [[Any]] = [[0.0, "start"]]
        for k in 0..<8 { tabata.append([30.0 * Double(k) + 20, "crown"]) }
        tabata.append([300.0, "tick"])
        let t: Run = try classic(WorkoutLibrary.engineTabata, tabata)
        XCTAssertEqual(t.starts.count, 16)
        XCTAssertEqual(t.finish, 240)
        XCTAssertFalse(r.block || e.block || t.block)
    }

    /// Every listed-once interval test workout ends with a rest (the wait for the next window).
    func testEveryListedOnceIntervalTestWorkoutEndsWithARest() {
        for d in WorkoutLibrary.engineTests where d.listedOnce == true && (d.intervalSeconds ?? 0) > 0 {
            XCTAssertEqual(d.segments.last?.kind, SegmentKind.rest, d.id)
        }
    }

    /// A marked AMRAP with an interval keeps roundSize unset on Classic, as §5a does.
    func testMarkedAmrapWithAnIntervalKeepsRoundSizeUnset() {
        var d: WorkoutDefinition = WorkoutLibrary.engineAmrap
        d.intervalSeconds = 60
        XCTAssertNil(RepeatBlock.writtenOut(d).roundSize)
        XCTAssertEqual(RepeatBlock.writtenOut(WorkoutLibrary.engineAmrap).roundSize, 3)
    }

    /// Cards describe a listed-once test workout like its written-out row ("5 rounds").
    func testCardsDescribeListedOnceTestWorkoutsLikeWrittenOutRows() {
        XCTAssertEqual(WorkoutCard.make(definition: WorkoutLibrary.engineRounds5).timeDomainLine, "5 rounds")
        XCTAssertEqual(WorkoutCard.make(definition: WorkoutLibrary.engineEmom).timeDomainLine, "Every 1:00 × 6")
        XCTAssertEqual(WorkoutCard.make(definition: WorkoutLibrary.engineTabata).timeDomainLine, "Every 0:30 × 8")
        for d in WorkoutLibrary.engineTests {
            XCTAssertEqual(WorkoutCard.make(definition: d), WorkoutCard.make(definition: RepeatBlock.writtenOut(d)), d.id)
        }
    }

    /// Behaviour, not routing: both engines reproduce the full trace of every built-in and gate
    /// row that the v0.17.2 code wrote (Fixtures/engine_gate_golden.json). A difference means
    /// today's rows (Hyrox included) run differently: never regenerate the golden to get green.
    func testEveryRowRunsExactlyAs0172OnBothEngines() throws {
        let golden: Golden = try JSONDecoder().decode(Golden.self, from: try EngineGateTests.gateFixture("engine_gate_golden"))
        XCTAssertEqual(golden.ref, "v0.17.2-rc1")
        let names: Set<String> = Set(golden.cases.map { (c: GoldenCase) -> String in c.name })
        for d in WorkoutLibrary.known {
            XCTAssertTrue(names.contains(d.id), "golden lacks \(d.id)")
        }
        for c in golden.cases {
            XCTAssertEqual(c.scripts.count, 7, c.name)
            XCTAssertEqual(c.traces.count, c.scripts.count, c.name)
            for (i, script) in c.scripts.enumerated() where i < c.traces.count {
                let want: GoldenTrace = c.traces[i]
                for engineOn in [false, true] {
                    let label: String = "\(c.name) script \(i) engine \(engineOn ? "new" : "classic")"
                    var p: WorkoutProgress = RepeatBlock.startProgress(for: c.definition, engineOn: engineOn)
                    _ = RepeatBlockProgressTests.run(&p, script: script)
                    var end: Double = 0
                    for a in script where a.t > end {
                        end = a.t
                    }
                    let got: Run = EngineGateTests.run(c.definition, engineOn: engineOn, script: script)
                    let result: GoldenResult = EngineGateTests.resultFields(p, splits: got.splits, end: end)
                    XCTAssertEqual(result.finished, want.result.finished, label)
                    XCTAssertEqual(result.isCapped, want.result.isCapped, label)
                    XCTAssertEqual(result.capSegmentIndex, want.result.capSegmentIndex, label)
                    XCTAssertEqual(result.partialRepsLimit, want.result.partialRepsLimit, label)
                    XCTAssertEqual(result.repsAtCapLimit, want.result.repsAtCapLimit, label)
                    XCTAssertEqual(result.partialReps, want.result.partialReps, label)
                    XCTAssertEqual(result.repsAtCap, want.result.repsAtCap, label)
                    XCTAssertEqual(result.capPositionText, want.result.capPositionText, label)
                    XCTAssertEqual(result.totalSeconds, want.result.totalSeconds, accuracy: 1e-9, label)
                    XCTAssertEqual(result.runSeconds, want.result.runSeconds, accuracy: 1e-9, label)
                    XCTAssertEqual(result.stationSeconds, want.result.stationSeconds, accuracy: 1e-9, label)
                    XCTAssertEqual(got.events, want.events, label)
                    XCTAssertEqual(got.finish, want.finish, label)
                    XCTAssertEqual(got.starts.count, want.starts.count, label)
                    for (a, b) in zip(got.starts, want.starts) {
                        XCTAssertEqual(a, b, accuracy: 1e-9, label)
                    }
                    XCTAssertEqual(got.splits.count, want.splits.count, label)
                    for (a, b) in zip(got.splits, want.splits) {
                        XCTAssertEqual(a.index, b.index, label)
                        XCTAssertEqual(a.kind, b.kind, label)
                        XCTAssertEqual(a.movement, b.movement, label)
                        XCTAssertEqual(a.title, b.title, label)
                        XCTAssertEqual(a.start, b.start, accuracy: 1e-9, label)
                        XCTAssertEqual(a.end, b.end, accuracy: 1e-9, label)
                        XCTAssertEqual(a.duration, b.duration, accuracy: 1e-9, label)
                        XCTAssertEqual(a.pass, b.pass, label)
                        XCTAssertEqual(a.steps, b.steps, label)
                        XCTAssertEqual(a.distance, b.distance, label)
                    }
                }
            }
        }
    }
}
