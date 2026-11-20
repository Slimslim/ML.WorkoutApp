import Foundation
import XCTest
@testable import BarPathKit

/// E3 (0.18): results of a listed-once definition run in block mode (WORKOUT_SPEC 5c). Segment
/// index = step, with its pass; the definition stays the listed block; views find the part.
final class WorkoutBlockResultTests: XCTestCase {

    private func station(_ movement: String, _ reps: Double) -> WorkoutSegment {
        return WorkoutSegment(kind: .station, movement: movement, name: Movement.displayName(movement),
                              target: SegmentTarget(reps, .reps))
    }

    /// Invented AMRAP 5:00 of a couplet, listed once.
    private func amrap() -> WorkoutDefinition {
        return WorkoutDefinition(id: "test.blockAmrap", name: "Test AMRAP", shortName: "T", format: .amrap,
                                 team: .solo, timeCapSeconds: 300, healthKitActivity: "crossTraining",
                                 segments: [station(Movement.burpees, 10), station(Movement.airSquats, 20)],
                                 listedOnce: true)
    }

    /// Start at t0, Crowns at +40, +80, +120 (step 3 = pass 1, Air Squats), undo and redo across
    /// the pass, then the cap at +300 in the middle of step 3.
    private func cappedProgress() -> WorkoutProgress {
        let d: WorkoutDefinition = amrap()
        var p = WorkoutProgress(definition: d, block: RepeatBlock.enginePlan(for: d, engineOn: true))
        let t0: Double = 1_800_000_000
        p.start(at: t0)
        XCTAssertTrue(p.advance(at: t0 + 40, source: .crown))
        XCTAssertTrue(p.advance(at: t0 + 80, source: .crown))
        XCTAssertTrue(p.undo(at: t0 + 85, source: .crown))       // pass 1 part 0 -> pass 0 part 1
        XCTAssertEqual(p.currentIndex, 1)
        XCTAssertTrue(p.advance(at: t0 + 90, source: .crown))
        XCTAssertTrue(p.advance(at: t0 + 120, source: .crown))
        XCTAssertEqual(p.capTime, t0 + 300)
        XCTAssertTrue(p.finish(at: t0 + 300, source: .auto))
        return p
    }

    private func result(_ p: WorkoutProgress) -> WorkoutResult {
        let t0: Double = p.startTime ?? 0
        let segs: [SegmentResult] = SplitStats.compute(progress: p, now: t0 + 300, heartRates: [], pedometer: [])
        return WorkoutResult(definition: p.definition, startDate: Date(timeIntervalSince1970: t0),
                             finishDate: Date(timeIntervalSince1970: t0 + 300),
                             endDate: Date(timeIntervalSince1970: t0 + 300), totalSeconds: 300,
                             segments: segs, events: p.events, engine: WorkoutEngine.v2.recordName,
                             passes: (p.position(ofStep: p.currentIndex)?.pass ?? 0) + 1)
    }

    func testSplitsStoreStepsWithTheirPassAndPart() {
        let p: WorkoutProgress = cappedProgress()
        let r: WorkoutResult = result(p)
        XCTAssertEqual(r.segments.map { (s: SegmentResult) -> Int in s.index }, [0, 1, 2, 3])
        XCTAssertEqual(r.segments.map { (s: SegmentResult) -> Int? in s.pass }, [0, 0, 1, 1])
        XCTAssertEqual(r.segments.map { (s: SegmentResult) -> String in s.movement },
                       [Movement.burpees, Movement.airSquats, Movement.burpees, Movement.airSquats])
        XCTAssertEqual(r.passes, 2)
        XCTAssertEqual(r.definition.segments.count, 2)          // the listed block, never copied
        XCTAssertTrue(r.isBlockResult)
        XCTAssertEqual(r.definitionSegment(forIndex: 3)?.movement, Movement.airSquats)
        XCTAssertNil(r.definitionSegment(forIndex: -1))
    }

    func testPartialRepsLimitIsThePartsTarget() {
        let r: WorkoutResult = result(cappedProgress())
        XCTAssertEqual(r.partialRepsLimit, 20)                   // step 3 = Air Squats, 20 reps
    }

    func testDisplayDefinitionWritesTheBlockOutForViews() {
        let r: WorkoutResult = result(cappedProgress())
        let shown: WorkoutDefinition = r.displayDefinition
        XCTAssertEqual(shown.segments.count, 4)
        XCTAssertEqual(shown.roundSize, 2)
        XCTAssertNil(shown.listedOnce)
        XCTAssertEqual(shown.segments[3], r.definition.segments[1])
        let summary: WorkoutSummary = WorkoutSummary.make(result: r, previous: nil, maxHeartRate: nil)
        XCTAssertEqual(summary.rows.isEmpty, false)
        XCTAssertEqual(summary.roundSize, 2)
    }

    func testBlockResultRoundTripsAndOldResultsReadAsToday() throws {
        let r: WorkoutResult = result(cappedProgress())
        let back: WorkoutResult = try WorkoutResult.decode(from: try r.encoded())
        XCTAssertEqual(back, r)
        XCTAssertEqual(back.engine, "new")

        var p = WorkoutProgress(definition: WorkoutLibrary.helen)
        p.start(at: 0)
        p.advance(at: 60, source: .crown)
        let segs: [SegmentResult] = SplitStats.compute(progress: p, now: 90, heartRates: [], pedometer: [])
        XCTAssertNil(segs[0].pass)
        let legacy = WorkoutResult(definition: WorkoutLibrary.helen, startDate: Date(timeIntervalSince1970: 0),
                                   finishDate: nil, endDate: Date(timeIntervalSince1970: 90), totalSeconds: 90,
                                   segments: segs, events: p.events)
        let text: String = String(data: try legacy.encoded(), encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("\"passes\""))
        XCTAssertFalse(text.contains("\"pass\""))
        XCTAssertFalse(legacy.isBlockResult)
        XCTAssertEqual(legacy.displayDefinition, legacy.definition)
        XCTAssertEqual(legacy.definitionSegment(forIndex: 1), WorkoutLibrary.helen.segments[1])
    }

    func testABlockResultIsNotOfferedADefinitionSwap() {
        let r: WorkoutResult = result(cappedProgress())
        var newer: WorkoutDefinition = r.definition
        newer.name = "Renamed"
        XCTAssertFalse(r.canApplyDefinition(newer))
    }
}
