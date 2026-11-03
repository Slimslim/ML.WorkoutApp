import Foundation
import XCTest
@testable import BarPathKit

/// For-time caps (WORKOUT_SPEC §5b, W7). Same cases as tools/tests/test_workout.py
/// ("for-time cap" section).
final class WorkoutCapTests: XCTestCase {
    static let t0: Double = 1_800_000_000
    static let editNow: Date = Date(timeIntervalSince1970: 1_793_448_000)   // 2026-10-31T12:00:00Z

    /// Helen (16:00 cap), segments of `step` s from t0 for segments 0…7, finishing at
    /// t0 + finishOffset (nil: not finished).
    private func helenProgress(step: Double = 110, finishOffset: Double?) -> WorkoutProgress {
        let t0: Double = WorkoutCapTests.t0
        var p = WorkoutProgress(definition: WorkoutLibrary.helen)
        p.start(at: t0)
        for i in 1...8 {
            XCTAssertTrue(p.advance(at: t0 + step * Double(i), source: .crown))
        }
        if let f = finishOffset {
            XCTAssertTrue(p.advance(at: t0 + f, source: .crown))
        }
        return p
    }

    private func result(_ p: WorkoutProgress, total: Double) -> WorkoutResult {
        let t0: Double = WorkoutCapTests.t0
        let segs: [SegmentResult] = SplitStats.compute(progress: p, now: t0 + total, heartRates: [], pedometer: [])
        let finish: Date? = p.finishTime.map({ (x: Double) -> Date in Date(timeIntervalSince1970: x) })
        return WorkoutResult(definition: p.definition, startDate: Date(timeIntervalSince1970: t0),
                             finishDate: finish, endDate: Date(timeIntervalSince1970: t0 + total),
                             totalSeconds: total, segments: segs, events: p.events)
    }

    func testForTimeCapTimeOnlyForTime() {
        let t0: Double = WorkoutCapTests.t0
        var p = WorkoutProgress(definition: WorkoutLibrary.helen)
        XCTAssertNil(p.forTimeCapTime)                         // not started
        p.start(at: t0)
        XCTAssertEqual(p.forTimeCapTime, t0 + 960)
        XCTAssertNil(p.capTime)                                // AMRAP cap only: Helen doesn't stop
        var a = WorkoutProgress(definition: WorkoutLibrary.amrap20)
        a.start(at: t0)
        XCTAssertNil(a.forTimeCapTime)
        XCTAssertEqual(a.capTime, t0 + 1200)
        var q = WorkoutProgress(definition: WorkoutLibrary.quickTest)
        q.start(at: t0)
        XCTAssertNil(q.forTimeCapTime)
        XCTAssertNil(q.capSegmentIndex(now: t0 + 99999))
    }

    func testCapSegmentIndexLiveAndFinished() {
        let t0: Double = WorkoutCapTests.t0
        var p = helenProgress(finishOffset: nil)
        XCTAssertNil(p.capSegmentIndex(now: t0 + 959))         // cap not reached yet
        XCTAssertNil(p.capSegmentIndex(now: t0 + 960))         // exactly at the cap: not past it
        XCTAssertEqual(p.capSegmentIndex(now: t0 + 961), 8)    // Pull-ups R3 (from 880 s)
        XCTAssertEqual(p.segmentIndex(at: t0 + 109.9), 0)
        XCTAssertEqual(p.segmentIndex(at: t0 + 110), 1)
        XCTAssertNil(p.segmentIndex(at: t0 - 1))
        XCTAssertTrue(p.advance(at: t0 + 1000, source: .crown))  // finished after the cap
        XCTAssertTrue(p.isFinished)
        XCTAssertEqual(p.totalElapsed(now: 0), 1000, accuracy: 1e-9)
        XCTAssertEqual(p.capSegmentIndex(now: t0), 8)          // `now` is ignored once finished
        let under = helenProgress(finishOffset: 950)
        XCTAssertNil(under.capSegmentIndex(now: t0 + 2000))
    }

    func testResultCapFieldsAndText() throws {
        let t0: Double = WorkoutCapTests.t0
        var r = result(helenProgress(finishOffset: 1100), total: 1100)   // 18:20, cap 16:00
        XCTAssertEqual(r.forTimeCapSeconds, 960)
        XCTAssertTrue(r.isCapped)
        XCTAssertEqual(r.totalSeconds, 1100, accuracy: 1e-9)   // the time for the full workout
        XCTAssertEqual(r.capReachedAt?.timeIntervalSince1970 ?? -1, t0 + 960, accuracy: 1e-6)
        XCTAssertEqual(r.capSegmentIndex, 8)
        XCTAssertEqual(r.repsAtCapLimit, 12)                   // Pull-ups 12
        XCTAssertEqual(r.capPositionText, "in Pull-ups (R3)")
        r.setRepsAtCap(40, now: WorkoutCapTests.editNow)
        XCTAssertEqual(r.repsAtCap, 12)
        XCTAssertEqual(r.editedAt, WorkoutCapTests.editNow)
        r.setRepsAtCap(-3, now: WorkoutCapTests.editNow)
        XCTAssertEqual(r.repsAtCap, 0)
        r.setRepsAtCap(7, now: WorkoutCapTests.editNow)
        XCTAssertEqual(r.capPositionText, "7/12 Pull-ups (R3)")
        r.repsAtCap = 15                                       // stale after a split edit: shown clamped
        XCTAssertEqual(r.capPositionText, "12/12 Pull-ups (R3)")
        r.repsAtCap = 7
        XCTAssertNil(r.partialReps)                            // AMRAP field untouched

        let data = try r.encoded()
        let obj = try jsonObject(data)
        XCTAssertEqual(number(obj["repsAtCap"]), 7)
        XCTAssertNil(obj["partialReps"])
        let back = try WorkoutResult.decode(from: data)
        XCTAssertEqual(back.repsAtCap, 7)
        XCTAssertTrue(back.isCapped)
        XCTAssertEqual(back, r)

        // Summary: the score is the full time; the context says where the cap was.
        let s = WorkoutSummary.make(result: r, previous: nil, maxHeartRate: nil)
        XCTAssertEqual(s.headline.scoreText, "18:20")
        XCTAssertEqual(s.headline.repsAtCap, 7)
        XCTAssertEqual(s.headline.contextText,
                       "3 rounds for time · 2:20 over the 16:00 cap · at the cap: 7/12 Pull-ups (R3)")

        r.setRepsAtCap(nil, now: WorkoutCapTests.editNow)
        XCTAssertNil(r.repsAtCap)
        let s2 = WorkoutSummary.make(result: r, previous: nil, maxHeartRate: nil)
        XCTAssertEqual(s2.headline.contextText,
                       "3 rounds for time · 2:20 over the 16:00 cap · at the cap: in Pull-ups (R3)")
    }

    func testOlderFileWithoutRepsAtCapDecodes() throws {
        let r = result(helenProgress(finishOffset: 1100), total: 1100)
        var obj = try jsonObject(try r.encoded())
        obj.removeValue(forKey: "repsAtCap")
        let data = try JSONSerialization.data(withJSONObject: obj, options: [])
        let back = try WorkoutResult.decode(from: data)
        XCTAssertNil(back.repsAtCap)
        XCTAssertTrue(back.isCapped)
    }

    func testResultCapBoundaries() {
        let t0: Double = WorkoutCapTests.t0
        let under = result(helenProgress(finishOffset: 950), total: 950)
        XCTAssertFalse(under.isCapped)
        XCTAssertNil(under.capReachedAt)
        XCTAssertNil(under.capSegmentIndex)
        XCTAssertNil(under.capPositionText)
        let su = WorkoutSummary.make(result: under, previous: nil, maxHeartRate: nil)
        XCTAssertEqual(su.headline.contextText, "3 rounds for time · 0:10 under the 16:00 cap")
        XCTAssertNil(su.headline.repsAtCap)
        let exact = result(helenProgress(finishOffset: 960), total: 960)   // on the cap: not capped
        XCTAssertFalse(exact.isCapped)

        // Segments of 120 s: segment 8 (Pull-ups R3) starts exactly on the cap and owns it.
        let r = result(helenProgress(step: 120, finishOffset: 1200), total: 1200)
        XCTAssertEqual(r.capSegmentIndex, 8)
        XCTAssertEqual(r.repsAtCapLimit, 12)

        // Ended (not finished) after the cap: still capped, segment at the cap.
        var q = WorkoutProgress(definition: WorkoutLibrary.helen)
        q.start(at: t0)
        XCTAssertTrue(q.advance(at: t0 + 900, source: .crown))  // KB Swings R1 from 900 s
        let e = result(q, total: 1000)
        XCTAssertTrue(e.isCapped)
        XCTAssertEqual(e.capSegmentIndex, 1)
        XCTAssertEqual(e.capPositionText, "in KB Swings (R1)")
        let se = WorkoutSummary.make(result: e, previous: nil, maxHeartRate: nil)
        XCTAssertEqual(se.headline.contextText,
                       "3 rounds for time · Not finished · ended in KB Swings · at the cap: in KB Swings (R1)")

        // Run at the cap: no reps target, only the lower bound applies.
        var only = WorkoutProgress(definition: WorkoutLibrary.helen)
        only.start(at: t0)
        var e2 = result(only, total: 1000)
        XCTAssertEqual(e2.capSegmentIndex, 0)
        XCTAssertNil(e2.repsAtCapLimit)
        e2.setRepsAtCap(250, now: WorkoutCapTests.editNow)
        XCTAssertEqual(e2.repsAtCap, 250)
        XCTAssertEqual(e2.capPositionText, "250 Run (R1)")
    }

    func testAmrapIsNeverForTimeCapped() throws {
        let r = try WorkoutResult.decode(from: try fixtureData("workout-amrap-2026-10-30", "json"))
        XCTAssertNil(r.forTimeCapSeconds)
        XCTAssertFalse(r.isCapped)
        XCTAssertNil(r.capPositionText)
    }
}
