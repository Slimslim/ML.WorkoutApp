import Foundation
import XCTest
@testable import BarPathKit

/// Repeating blocks and fixed lists (WORKOUT_SPEC 5c, #138). Same cases as
/// tools/tests/test_repeat_block.py (Fixtures/repeat_block_cases.json).
final class RepeatBlockTests: XCTestCase {

    struct ExpectedPlan: Decodable {
        let kind: String
        let parts: Int
        let rounds: Int?
        let capSeconds: Double?
        let capEnds: Bool
        let intervalSeconds: Double?
        let trailingRests: Int
        let stepLimit: Int?
    }

    /// [step, advanced, elapsed, reason]: mixed types, decoded by hand.
    struct EndCase: Decodable {
        let step: Int
        let advanced: Bool
        let elapsed: Double
        let reason: String?

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            step = try c.decode(Int.self)
            advanced = try c.decode(Bool.self)
            elapsed = try c.decode(Double.self)
            reason = try c.decodeIfPresent(String.self)
        }
    }

    struct Case: Decodable {
        let name: String
        let definition: WorkoutDefinition
        let plan: ExpectedPlan
        let positions: [[Int]]
        let outOfRange: [Int]
        let finishes: [Int]
        let noFinish: [Int]
        let endReasons: [EndCase]
        let windowEnds: [[Double]]
        let windowTargets: [[Int?]]
        let scores: [[Int]]
    }

    struct Fixture: Decodable {
        let cases: [Case]
    }

    private func loadCases() throws -> [Case] {
        let data: Data = try fixtureData("repeat_block_cases", "json")
        return try JSONDecoder().decode(Fixture.self, from: data).cases
    }

    func testFixtureCases() throws {
        let cases: [Case] = try loadCases()
        XCTAssertGreaterThanOrEqual(cases.count, 6)
        for c in cases {
            let plan: RepeatBlock.Plan = RepeatBlock.plan(for: c.definition)
            XCTAssertEqual(plan.kind.rawValue, c.plan.kind, c.name)
            XCTAssertEqual(plan.parts, c.plan.parts, c.name)
            XCTAssertEqual(plan.rounds, c.plan.rounds, c.name)
            XCTAssertEqual(plan.capSeconds, c.plan.capSeconds, c.name)
            XCTAssertEqual(plan.capEnds, c.plan.capEnds, c.name)
            XCTAssertEqual(plan.intervalSeconds, c.plan.intervalSeconds, c.name)
            XCTAssertEqual(plan.trailingRests, c.plan.trailingRests, c.name)
            XCTAssertEqual(plan.stepLimit, c.plan.stepLimit, c.name)
            for p in c.positions {
                guard let pos = RepeatBlock.position(plan, step: p[0]) else {
                    XCTFail("\(c.name): no position for step \(p[0])")
                    continue
                }
                XCTAssertEqual(pos.pass, p[1], "\(c.name) step \(p[0])")
                XCTAssertEqual(pos.part, p[2], "\(c.name) step \(p[0])")
            }
            for s in c.outOfRange {
                XCTAssertNil(RepeatBlock.position(plan, step: s), "\(c.name) step \(s)")
            }
            for s in c.finishes {
                XCTAssertTrue(RepeatBlock.advanceFinishes(plan, step: s), "\(c.name) step \(s)")
            }
            for s in c.noFinish {
                XCTAssertFalse(RepeatBlock.advanceFinishes(plan, step: s), "\(c.name) step \(s)")
            }
            for e in c.endReasons {
                let got: RepeatBlock.EndReason? = RepeatBlock.endReason(plan, step: e.step, advanced: e.advanced,
                                                                        elapsed: e.elapsed)
                XCTAssertEqual(got?.rawValue, e.reason, "\(c.name) \(e.step) \(e.advanced) \(e.elapsed)")
            }
            for w in c.windowEnds {
                guard let end = RepeatBlock.windowEnd(plan, stepStartElapsed: w[0]) else {
                    XCTFail("\(c.name): no window end at \(w[0])")
                    continue
                }
                XCTAssertEqual(end, w[1], accuracy: 1e-9, c.name)
            }
            if c.windowEnds.isEmpty {
                XCTAssertNil(RepeatBlock.windowEnd(plan, stepStartElapsed: 10.0), c.name)
            }
            for w in c.windowTargets {
                guard w.count == 2, let step = w[0] else {
                    XCTFail("\(c.name): bad windowTargets row")
                    continue
                }
                XCTAssertEqual(RepeatBlock.windowTargetStep(plan, step: step), w[1], "\(c.name) step \(step)")
            }
            if c.windowTargets.isEmpty {
                XCTAssertNil(RepeatBlock.windowTargetStep(plan, step: 0), c.name)
            }
            for sc in c.scores {
                let got: (passes: Int, workParts: Int) = RepeatBlock.score(plan, definition: c.definition,
                                                                          completedSteps: sc[0])
                XCTAssertEqual(got.passes, sc[1], "\(c.name) completed \(sc[0])")
                XCTAssertEqual(got.workParts, sc[2], "\(c.name) completed \(sc[0])")
            }
        }
    }

    /// The block is the whole list: roundSize changes nothing in the plan.
    func testRoundSizePlaysNoPart() throws {
        for c in try loadCases() {
            let base: RepeatBlock.Plan = RepeatBlock.plan(for: c.definition)
            for rs in [nil, 1, 2, c.definition.segments.count] as [Int?] {
                var d: WorkoutDefinition = c.definition
                d.roundSize = rs
                XCTAssertEqual(RepeatBlock.plan(for: d), base, c.name)
            }
        }
    }

    func testUndoCrossesAPassBoundary() {
        XCTAssertEqual(RepeatBlock.previousStep(6), 5)
        XCTAssertEqual(RepeatBlock.previousStep(1), 0)
        XCTAssertNil(RepeatBlock.previousStep(0))
    }

    /// Every built-in, by id, as stored today. None is marked listedOnce, so each takes the legacy
    /// route (same list as tools/tests/test_repeat_block.py).
    static let builtInIds: [String] = ["hyrox.solo", "hyrox.doubles", "hyrox.half", "partner.wod1",
                                       "partner.wod2", "wod.amrap40", "wod.helen", "wod.rowThrusters",
                                       "free.workout", "wod.nightmareAmrap", "quick.test"]

    func testTheBuiltInListIsComplete() {
        let known: [String] = WorkoutLibrary.known.map { (d: WorkoutDefinition) -> String in d.id }
        XCTAssertEqual(known.sorted(), RepeatBlockTests.builtInIds.sorted())
    }

    func testEveryStoredBuiltInTakesTheLegacyRoute() {
        for id in RepeatBlockTests.builtInIds {
            guard let d = WorkoutLibrary.definition(id: id) else {
                XCTFail("missing \(id)")
                continue
            }
            XCTAssertNil(d.listedOnce, id)
            XCTAssertEqual(RepeatBlock.plan(for: d).kind, RepeatBlock.Kind.legacy, id)
            XCTAssertNil(RepeatBlock.enginePlan(for: d, engineOn: true), id)
            XCTAssertNil(RepeatBlock.enginePlan(for: d, engineOn: false), id)
        }
    }

    /// The stored Row + Thrusters (17 segments, roundSize 3, every 3:00): the clock still jumps by
    /// set with the engine on, exactly as today.
    func testRowThrustersWindowTargetsAreTodays() {
        let d: WorkoutDefinition = WorkoutLibrary.rowThrusters
        XCTAssertEqual(d.segments.count, 17)
        var p = WorkoutProgress(definition: d, block: RepeatBlock.enginePlan(for: d, engineOn: true))
        XCTAssertNil(p.block)
        p.start(at: 0)
        var targets: [Int] = []
        for i in 0..<16 {
            targets.append(p.autoAdvanceTargetIndex)
            p.advance(at: Double(10 * (i + 1)), source: .crown)
        }
        XCTAssertEqual(targets, [3, 3, 3, 6, 6, 6, 9, 9, 9, 12, 12, 12, 15, 15, 15, 18])
    }

    func testHyroxTakesTheLegacyRoute() {
        for d in [WorkoutLibrary.hyroxSolo, WorkoutLibrary.hyroxDoubles, WorkoutLibrary.halfHyrox] {
            XCTAssertEqual(RepeatBlock.plan(for: d).kind, RepeatBlock.Kind.legacy, d.id)
            XCTAssertNil(RepeatBlock.enginePlan(for: d, engineOn: true), d.id)
        }
    }

    func testMarkedDefinitionsNeedTheEngineSwitch() throws {
        guard let c = try loadCases().first(where: { (c: Case) -> Bool in c.definition.rounds != nil }) else {
            XCTFail("no case with rounds")
            return
        }
        XCTAssertEqual(RepeatBlock.enginePlan(for: c.definition, engineOn: true)?.kind, RepeatBlock.Kind.repeating)
        XCTAssertNil(RepeatBlock.enginePlan(for: c.definition, engineOn: false))
    }

    func testAnIntervalBlockMustEndWithARest() throws {
        guard let c = try loadCases().first(where: { (c: Case) -> Bool in c.definition.intervalSeconds != nil
            && c.definition.listedOnce == true }) else {
            XCTFail("no interval case")
            return
        }
        var d: WorkoutDefinition = c.definition
        d.segments = d.segments.filter { (s: WorkoutSegment) -> Bool in s.kind != .rest }
        XCTAssertEqual(RepeatBlock.listedOnceProblems(d), ["interval block does not end with a rest"])
        XCTAssertEqual(RepeatBlock.plan(for: d).kind, RepeatBlock.Kind.legacy)
    }

    func testListedOnceKeyIsOptionalAndRoundTrips() throws {
        let c: Case = try loadCases()[0]
        XCTAssertEqual(c.definition.listedOnce, true)
        let data: Data = try JSONEncoder().encode(c.definition)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutDefinition.self, from: data), c.definition)
        var old: WorkoutDefinition = c.definition
        old.listedOnce = nil
        let oldJSON: String = String(data: try JSONEncoder().encode(old), encoding: .utf8) ?? ""
        XCTAssertFalse(oldJSON.contains("listedOnce"))
    }

    func testRoundsKeyIsOptionalAndRoundTrips() throws {
        let cases: [Case] = try loadCases()
        guard let c = cases.first(where: { (c: Case) -> Bool in c.definition.rounds != nil }) else {
            XCTFail("no case with rounds")
            return
        }
        let data: Data = try JSONEncoder().encode(c.definition)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutDefinition.self, from: data), c.definition)
        var old: WorkoutDefinition = c.definition
        old.rounds = nil
        let oldJSON: String = String(data: try JSONEncoder().encode(old), encoding: .utf8) ?? ""
        XCTAssertFalse(oldJSON.contains("\"rounds\""))
    }
}
