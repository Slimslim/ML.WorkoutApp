import Foundation
import XCTest
@testable import BarPathKit

/// WORKOUT_SPEC §5: result corrections and partial reps. Same cases as
/// tools/tests/test_workout.py (test_move_segment_start_*, test_set_partial_reps_*).
final class WorkoutResultEditingTests: XCTestCase {

    /// 2026-10-31T12:00:00Z
    private let editNow: Date = Date(timeIntervalSince1970: 1_793_448_000)

    /// Nightmare AMRAP 20 of 2026-10-30 (v2 with HR series; Crown mix-up in round 4).
    private func loadAmrap() throws -> WorkoutResult {
        let data: Data = try fixtureData("workout-amrap-2026-10-30", "json")
        return try WorkoutResult.decode(from: data)
    }

    /// The real corrected boundaries from data/raw/2026-10-30-amrap20/README.md.
    private func corrected() throws -> WorkoutResult {
        var r: WorkoutResult = try loadAmrap()
        let s0: Double = r.segments[0].start
        XCTAssertTrue(r.moveSegmentStart(index: 12, to: s0 + 556.94, now: editNow))
        XCTAssertTrue(r.moveSegmentStart(index: 13, to: s0 + 619.32, now: editNow))
        return r
    }

    // MARK: Fixture

    func testAmrapFixtureDecodesWithoutNewFields() throws {
        let r: WorkoutResult = try loadAmrap()
        XCTAssertEqual(r.version, 2)
        XCTAssertNil(r.partialReps)
        XCTAssertNil(r.editedAt)
        XCTAssertEqual(r.segments.count, 24)
        XCTAssertNotNil(r.heartRateSeries)
        XCTAssertEqual(r.partialRepsLimit, 31)      // last segment: Double Unders 31
    }

    // MARK: moveSegmentStart

    func testMoveSegmentStartFixesTheRound4MixUp() throws {
        let original: WorkoutResult = try loadAmrap()
        let r: WorkoutResult = try corrected()
        let s0: Double = r.segments[0].start
        let seg11: SegmentResult = r.segments[11]
        let seg12: SegmentResult = r.segments[12]
        let seg13: SegmentResult = r.segments[13]

        // Durations: 556.94 − 496.77 / 619.32 − 556.94 / 700.07 − 619.32.
        XCTAssertEqual(seg11.duration, 60.16783, accuracy: 1e-4)
        XCTAssertEqual(seg12.duration, 62.38, accuracy: 1e-4)
        XCTAssertEqual(seg13.duration, 80.75398, accuracy: 1e-4)
        XCTAssertEqual(seg12.start - s0, 556.94, accuracy: 1e-6)
        XCTAssertEqual(seg13.start - s0, 619.32, accuracy: 1e-6)
        XCTAssertEqual(seg11.end, seg12.start)
        XCTAssertEqual(seg12.end, seg13.start)
        XCTAssertEqual(seg11.start, original.segments[11].start)
        XCTAssertEqual(seg13.end, original.segments[13].end)

        // HR recomputed from the 5 s series (bucket centres inside the segment).
        XCTAssertEqual(seg11.heartRateAvg ?? -1, 169.16666666666666, accuracy: 1e-9)
        XCTAssertEqual(seg11.heartRateMax ?? -1, 173, accuracy: 1e-9)
        XCTAssertEqual(seg11.heartRateMin ?? -1, 167, accuracy: 1e-9)
        XCTAssertEqual(seg12.heartRateAvg ?? -1, 163.15384615384616, accuracy: 1e-9)
        XCTAssertEqual(seg12.heartRateMax ?? -1, 168, accuracy: 1e-9)
        XCTAssertEqual(seg12.heartRateMin ?? -1, 161, accuracy: 1e-9)
        XCTAssertEqual(seg13.heartRateAvg ?? -1, 160.8125, accuracy: 1e-9)
        XCTAssertEqual(seg13.heartRateMax ?? -1, 163, accuracy: 1e-9)
        XCTAssertEqual(seg13.heartRateMin ?? -1, 157, accuracy: 1e-9)

        // Steps and distance conserved over the three, shared by time; cadence recomputed.
        var stepsBefore: Double = 0
        var stepsAfter: Double = 0
        var distBefore: Double = 0
        var distAfter: Double = 0
        for i in 11...13 {
            stepsBefore += original.segments[i].steps ?? 0
            stepsAfter += r.segments[i].steps ?? 0
            distBefore += original.segments[i].distance ?? 0
            distAfter += r.segments[i].distance ?? 0
        }
        XCTAssertEqual(stepsAfter, stepsBefore, accuracy: 1e-9)
        XCTAssertEqual(distAfter, distBefore, accuracy: 1e-9)
        XCTAssertEqual(seg12.cadence ?? -1, (seg12.steps ?? 0) / seg12.duration * 60, accuracy: 1e-9)
        XCTAssertNil(seg12.paceSecondsPerKm)

        // Nothing else changes.
        XCTAssertEqual(r.totalSeconds, original.totalSeconds)
        XCTAssertEqual(r.events, original.events)
        for i in 0..<r.segments.count where i < 11 || i > 13 {
            XCTAssertEqual(r.segments[i], original.segments[i])
        }
        XCTAssertEqual(r.editedAt, editNow)
    }

    func testMoveSegmentStartClampsAndRejects() throws {
        var r: WorkoutResult = try loadAmrap()
        let aStart: Double = r.segments[4].start
        XCTAssertTrue(r.moveSegmentStart(index: 5, to: aStart - 100, now: editNow))
        XCTAssertEqual(r.segments[5].start, aStart + 1, accuracy: 1e-9)
        XCTAssertEqual(r.segments[4].duration, 1, accuracy: 1e-9)
        let end5: Double = r.segments[5].end
        XCTAssertTrue(r.moveSegmentStart(index: 5, to: end5 + 100, now: editNow))
        XCTAssertEqual(r.segments[5].start, end5 - 1, accuracy: 1e-9)
        XCTAssertEqual(r.segments[5].duration, 1, accuracy: 1e-9)

        var fresh: WorkoutResult = try loadAmrap()
        let s0: Double = fresh.segments[0].start
        for bad in [0, -1, 24, 99] {
            XCTAssertFalse(fresh.moveSegmentStart(index: bad, to: s0 + 10, now: editNow))
        }
        XCTAssertNil(fresh.editedAt)
        XCTAssertEqual(fresh, try loadAmrap())

        let before: [SegmentResult] = r.segments
        XCTAssertFalse(r.moveSegmentStart(index: 3, to: Double.nan, now: editNow))
        XCTAssertEqual(r.segments, before)
    }

    // MARK: Partial reps

    func testSetPartialRepsClamps() throws {
        var r: WorkoutResult = try loadAmrap()
        r.setPartialReps(99, now: editNow)
        XCTAssertEqual(r.partialReps, 31)
        r.setPartialReps(-4, now: editNow)
        XCTAssertEqual(r.partialReps, 0)
        r.setPartialReps(nil, now: editNow)
        XCTAssertNil(r.partialReps)
        XCTAssertEqual(r.editedAt, editNow)
        r.setPartialReps(13, now: editNow)
        XCTAssertEqual(r.partialReps, 13)

        // Without a reps target (Run 200 m) only the lower bound applies.
        let seg: SegmentResult = SegmentResult(index: 0, kind: .run, movement: Movement.run, title: "Run 200 m",
                                               start: 1000, end: 1060, duration: 60)
        var q: WorkoutResult = WorkoutResult(definition: WorkoutLibrary.quickTest,
                                             startDate: Date(timeIntervalSince1970: 1000), finishDate: nil,
                                             endDate: Date(timeIntervalSince1970: 1060), totalSeconds: 60,
                                             segments: [seg], events: [])
        XCTAssertNil(q.partialRepsLimit)
        q.setPartialReps(500, now: editNow)
        XCTAssertEqual(q.partialReps, 500)
    }

    // MARK: JSON

    func testPartialRepsAndEditedAtRoundTrip() throws {
        var r: WorkoutResult = try corrected()
        r.setPartialReps(13, now: editNow)
        let data: Data = try r.encoded()
        let obj: [String: Any] = try jsonObject(data)
        XCTAssertEqual(number(obj["partialReps"]), 13)
        XCTAssertEqual(obj["editedAt"] as? String, "2026-10-31T12:00:00.000Z")
        let back: WorkoutResult = try WorkoutResult.decode(from: data)
        XCTAssertEqual(back.partialReps, 13)
        XCTAssertEqual(back.editedAt, editNow)
        XCTAssertEqual(back, r)

        // Whole-second dates (as Python writes them) decode too.
        let json: String = """
        {"version":2,"id":"11111111-2222-3333-4444-555555555555",
         "definition":{"id":"quick.test","name":"Quick Test","shortName":"Test","format":"forTime","team":"solo",
           "healthKitActivity":"crossTraining",
           "segments":[{"kind":"run","movement":"run","name":"Run","target":{"value":200,"unit":"meters"}}]},
         "startDate":"2026-10-31T09:00:00Z","endDate":"2026-10-31T09:01:00Z","totalSeconds":60,
         "segments":[],"events":[],"partialReps":7,"editedAt":"2026-10-31T12:00:00Z"}
        """
        let p: WorkoutResult = try WorkoutResult.decode(from: Data(json.utf8))
        XCTAssertEqual(p.partialReps, 7)
        XCTAssertEqual(p.editedAt, editNow)
    }

    func testOldFilesWithoutTheFieldsDecodeAndEncodeWithoutThem() throws {
        // Version 2 (the AMRAP fixture) and version 1 (Helen).
        let v2: WorkoutResult = try loadAmrap()
        XCTAssertNil(v2.partialReps)
        XCTAssertNil(v2.editedAt)
        let obj: [String: Any] = try jsonObject(try v2.encoded())
        XCTAssertNil(obj["partialReps"])
        XCTAssertNil(obj["editedAt"])

        let v1: WorkoutResult = try WorkoutResult.decode(from: try fixtureData("workout-helen-2026-10-29", "json"))
        XCTAssertEqual(v1.version, 1)
        XCTAssertNil(v1.partialReps)
        XCTAssertNil(v1.editedAt)
    }

    // MARK: Summary

    func testSummaryWithoutCorrectionsScoresFiveRoundsPlus51() throws {
        let r: WorkoutResult = try loadAmrap()
        let s: WorkoutSummary = WorkoutSummary.make(result: r, previous: nil, maxHeartRate: nil)
        XCTAssertEqual(s.headline.scoreText, "5 + 51")
        XCTAssertEqual(s.headline.rounds, 5)
        XCTAssertEqual(s.headline.extraReps, 51)
        XCTAssertNil(s.headline.partialReps)
        XCTAssertFalse(s.dataNote.isEdited)
        XCTAssertFalse(s.dataNote.text.contains("edited"))
        XCTAssertFalse(s.headline.contextText.contains("+"))
    }

    func testSummaryWithPartialRepsAndEditedSplits() throws {
        var r: WorkoutResult = try corrected()
        r.setPartialReps(13, now: editNow)
        let s: WorkoutSummary = WorkoutSummary.make(result: r, previous: nil, maxHeartRate: nil)

        XCTAssertEqual(s.headline.format, .amrap)
        XCTAssertEqual(s.headline.rounds, 5)
        XCTAssertEqual(s.headline.extraReps, 64)              // 10 + 31 + 10 + 13
        XCTAssertEqual(s.headline.partialReps, 13)
        XCTAssertEqual(s.headline.scoreText, "5 + 64")
        XCTAssertEqual(s.headline.stoppedIn, "Double Unders")
        XCTAssertTrue(s.headline.contextText.hasPrefix("Stopped in Double Unders, "))
        XCTAssertTrue(s.headline.contextText.contains("at the 20:00 cap"))
        XCTAssertTrue(s.headline.contextText.hasSuffix(" · +13 Double Unders"))

        guard case .amrapClock(let a) = s.story else {
            return XCTFail("expected amrapClock, got \(s.story)")
        }
        XCTAssertEqual(a.completedRounds, 5)
        XCTAssertEqual(a.extraReps, 64)
        XCTAssertEqual(a.stoppedIn?.partialReps, 13)
        XCTAssertEqual(a.stoppedIn?.segmentIndex, 23)

        // The corrected round 4 (segments 12…15) in the rows.
        XCTAssertEqual(s.rows[12].duration, 62.38, accuracy: 1e-4)
        XCTAssertEqual(s.rows[13].duration, 80.75398, accuracy: 1e-4)

        XCTAssertTrue(s.dataNote.isEdited)
        XCTAssertTrue(s.dataNote.text.hasSuffix(" · edited"))
    }

    func testPartialRepsZeroAddsNothing() throws {
        var r: WorkoutResult = try loadAmrap()
        r.partialReps = 0
        let s: WorkoutSummary = WorkoutSummary.make(result: r, previous: nil, maxHeartRate: nil)
        XCTAssertEqual(s.headline.scoreText, "5 + 51")
        XCTAssertFalse(s.headline.contextText.contains("+0"))
        XCTAssertFalse(s.dataNote.isEdited)                   // set on the watch: not an edit
    }
}
