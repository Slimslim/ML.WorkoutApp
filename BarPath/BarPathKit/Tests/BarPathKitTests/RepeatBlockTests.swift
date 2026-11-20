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

    /// Hyrox and every other fixed-list built-in: same steps and the same Finish as WorkoutProgress.
    func testFixedListBuiltInsStepExactlyAsToday() {
        var checked: Int = 0
        let known: [WorkoutDefinition] = WorkoutLibrary.all + [WorkoutLibrary.amrap20, WorkoutLibrary.quickTest]
        for d in known {
            let plan: RepeatBlock.Plan = RepeatBlock.plan(for: d)
            guard plan.kind == .fixed else { continue }
            checked += 1
            var p = WorkoutProgress(definition: d)
            let t0: Double = 1_800_000_000
            p.start(at: t0)
            var t: Double = t0
            var guardCount: Int = 0
            while !p.isFinished && guardCount < 10_000 {
                t += 10
                XCTAssertTrue(p.advance(at: t, source: .crown), d.id)
                guardCount += 1
            }
            XCTAssertEqual(plan.stepLimit, p.segmentStarts.count, d.id)
            XCTAssertEqual(plan.stepLimit, d.segments.count, d.id)
            for s in 0..<d.segments.count {
                let pos = RepeatBlock.position(plan, step: s)
                XCTAssertEqual(pos?.pass, 0, d.id)
                XCTAssertEqual(pos?.part, s, d.id)
                XCTAssertEqual(RepeatBlock.advanceFinishes(plan, step: s), s == p.currentIndex, d.id)
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 3)
    }

    /// Every interval built-in: as a block of one set, the window target is what WorkoutProgress
    /// does today (its roundSize is the block), so EMOM / Tabata timing doesn't change.
    func testTodaysIntervalRowsKeepTheirWindow() {
        var checked: Int = 0
        let known: [WorkoutDefinition] = WorkoutLibrary.all + [WorkoutLibrary.amrap20, WorkoutLibrary.quickTest]
        for d in known {
            guard let interval = d.intervalSeconds, interval > 0, let rs = d.roundSize, rs > 0,
                  d.segments.count > rs else { continue }
            var block: WorkoutDefinition = d
            block.segments = Array(d.segments.prefix(rs))
            block.rounds = (d.segments.count + rs - 1) / rs
            let plan: RepeatBlock.Plan = RepeatBlock.plan(for: block)
            guard let limit = plan.stepLimit else {
                XCTFail(d.id)
                continue
            }
            for step in 0..<(d.segments.count - 1) {
                let today: Int = (step / rs + 1) * rs
                let want: Int? = today < limit ? today : nil
                XCTAssertEqual(RepeatBlock.windowTargetStep(plan, step: step), want, "\(d.id) \(step)")
            }
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 1)
    }

    func testHyroxIsAFixedList() {
        for d in [WorkoutLibrary.hyroxSolo, WorkoutLibrary.hyroxDoubles, WorkoutLibrary.halfHyrox] {
            XCTAssertEqual(RepeatBlock.plan(for: d).kind, RepeatBlock.Kind.fixed, d.id)
        }
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
