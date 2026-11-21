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

    /// Insights on a block result read each step's part (the block written out, never stored).
    func testInsightsOfABlockResultUseItsParts() {
        let r: WorkoutResult = result(cappedProgress())
        let viaResult: [ResultInsight] = ResultInsights.insights(result: r, definition: r.definition)
        let viaShown: [ResultInsight] = ResultInsights.insights(result: r, definition: r.displayDefinition)
        XCTAssertEqual(viaResult.map { (i: ResultInsight) -> String in i.id },
                       viaShown.map { (i: ResultInsight) -> String in i.id })
    }

    /// A listed-once fixed list (Hyrox marked) on the new engine stores today's result: same splits,
    /// no passes, no pass numbers (the E3 review blocker).
    func testAMarkedFixedListStoresTodaysResultOnTheNewEngine() {
        var marked: WorkoutDefinition = WorkoutLibrary.hyroxSolo
        marked.listedOnce = true
        var onNew: WorkoutProgress = RepeatBlock.startProgress(for: marked, engine: .v2)
        var classic: WorkoutProgress = RepeatBlock.startProgress(for: WorkoutLibrary.hyroxSolo, engine: .legacy)
        XCTAssertEqual(onNew.block?.kind, RepeatBlock.Kind.fixed)
        XCTAssertFalse(onNew.isRepeatingBlock)
        let t0: Double = 1_800_000_000
        onNew.start(at: t0)
        classic.start(at: t0)
        for k in 1...5 {
            onNew.advance(at: t0 + Double(60 * k), source: .crown)
            classic.advance(at: t0 + Double(60 * k), source: .crown)
        }
        XCTAssertNil(onNew.passesStarted)
        XCTAssertEqual(onNew.partIndex(ofStep: 5), 5)
        let a: [SegmentResult] = SplitStats.compute(progress: onNew, now: t0 + 400, heartRates: [], pedometer: [])
        let b: [SegmentResult] = SplitStats.compute(progress: classic, now: t0 + 400, heartRates: [], pedometer: [])
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.allSatisfy { (s: SegmentResult) -> Bool in s.pass == nil })
    }

    func testPartIndexAndPassesOfARepeatingBlock() {
        let p: WorkoutProgress = cappedProgress()
        XCTAssertTrue(p.isRepeatingBlock)
        XCTAssertEqual(p.partIndex(ofStep: 3), 1)
        XCTAssertEqual(p.passesStarted, 2)
        var legacy = WorkoutProgress(definition: WorkoutLibrary.helen)
        legacy.start(at: 0)
        XCTAssertEqual(legacy.partIndex(ofStep: 7), 7)
        XCTAssertNil(legacy.passesStarted)
    }

    func testDisplayDefinitionIsClampedForACorruptIndex() {
        var r: WorkoutResult = result(cappedProgress())
        r.segments[3].index = 1_000_000
        XCTAssertLessThanOrEqual(r.displayDefinition.segments.count, r.segments.count + r.definition.segments.count)
    }

    /// Rounds for time × 5 ended in round 2: the display definition plans all 5 rounds.
    func testDisplayDefinitionPlansTheRounds() {
        var d: WorkoutDefinition = amrap()
        d.format = .forTime
        d.timeCapSeconds = nil
        d.rounds = 5
        var p: WorkoutProgress = RepeatBlock.startProgress(for: d, engine: .v2)
        p.start(at: 0)
        p.advance(at: 30, source: .crown)
        p.advance(at: 60, source: .crown)
        p.finish(at: 70, source: .button)
        let segs: [SegmentResult] = SplitStats.compute(progress: p, now: 70, heartRates: [], pedometer: [])
        let r = WorkoutResult(definition: d, startDate: Date(timeIntervalSince1970: 0),
                              finishDate: nil, endDate: Date(timeIntervalSince1970: 70), totalSeconds: 70,
                              segments: segs, events: p.events, passes: p.passesStarted)
        XCTAssertEqual(r.displayDefinition.segments.count, 10)
        XCTAssertEqual(r.displayDefinition.roundSize, 2)
    }

    /// A capped rounds-for-time block: the cap text keeps its round ("(R2)"), as Classic does.
    func testCapTextOfACappedRoundsBlockKeepsItsRound() {
        var d: WorkoutDefinition = amrap()
        d.format = .forTime
        d.timeCapSeconds = 100
        d.rounds = 5
        d.segments.append(station(Movement.pushUps, 10))   // 3 parts
        var p: WorkoutProgress = RepeatBlock.startProgress(for: d, engine: .v2)
        p.start(at: 0)
        for k in 1...7 {
            p.advance(at: Double(20 * k), source: .crown)
        }
        p.finish(at: 150, source: .button)
        let segs: [SegmentResult] = SplitStats.compute(progress: p, now: 150, heartRates: [], pedometer: [])
        let r = WorkoutResult(definition: d, startDate: Date(timeIntervalSince1970: 0), finishDate: nil,
                              endDate: Date(timeIntervalSince1970: 150), totalSeconds: 150,
                              segments: segs, events: p.events, passes: p.passesStarted)
        XCTAssertEqual(r.capSegmentIndex, 5)
        XCTAssertEqual(r.capPositionText?.hasSuffix("(R2)"), true, r.capPositionText ?? "nil")
    }
}
