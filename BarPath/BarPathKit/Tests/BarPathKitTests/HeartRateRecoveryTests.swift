import Foundation
import XCTest
@testable import BarPathKit

/// HeartRateRecovery (WORKOUT_SPEC §6). Same cases as tools/tests/test_workout.py.
final class HeartRateRecoveryTests: XCTestCase {

    // MARK: Helpers

    /// Partner WOD 1, 2026-10-31: the watch's HR samples from 1374.7 s to End (seconds since the
    /// start, rounded to 0.1 s). Finish at 1389.3 s, End at 1610.5 s.
    private static let realTail: [(Double, Double)] = [
        (1374.7, 159), (1380.2, 159), (1384.7, 161), (1390.3, 162), (1394.7, 161), (1399.7, 160),
        (1404.7, 162), (1409.7, 160), (1414.7, 155), (1419.8, 154), (1424.7, 151), (1430.2, 151),
        (1434.8, 150), (1439.8, 150), (1444.7, 147), (1450.2, 143), (1454.7, 142), (1459.7, 142),
        (1464.7, 139), (1469.7, 138), (1474.8, 136), (1479.8, 132), (1484.7, 129), (1490.3, 125),
        (1494.7, 124), (1500.2, 124), (1505.4, 123), (1510.2, 123), (1514.8, 122), (1520.3, 115),
        (1524.8, 113), (1529.7, 112), (1534.8, 115), (1540.3, 117), (1544.8, 117), (1550.2, 109),
        (1554.7, 107), (1559.7, 104), (1564.7, 101), (1570.2, 107), (1574.8, 114), (1579.8, 119),
        (1585.3, 107), (1589.7, 105), (1594.7, 104), (1599.8, 104), (1605.3, 114), (1609.8, 113)]
    private static let realFinish: Double = 1389.3
    private static let realEnd: Double = 1610.5

    private func tailSamples(offset: Double = 0) -> [TimedValue] {
        return HeartRateRecoveryTests.realTail.map({ (p: (Double, Double)) -> TimedValue in
            TimedValue(t: offset + p.0, value: p.1)
        })
    }

    private func tailSeries(end: Double = HeartRateRecoveryTests.realEnd, offset: Double = 0) -> HeartRateSeries {
        return HeartRateSeries.make(samples: tailSamples(offset: offset), start: offset, end: offset + end)
    }

    private func result(series: HeartRateSeries?, start: Double, finish: Double?, end: Double) -> WorkoutResult {
        return WorkoutResult(definition: WorkoutLibrary.quickTest,
                             startDate: Date(timeIntervalSince1970: start),
                             finishDate: finish.map({ (f: Double) -> Date in Date(timeIntervalSince1970: f) }),
                             endDate: Date(timeIntervalSince1970: end),
                             totalSeconds: (finish ?? end) - start, segments: [], events: [],
                             heartRateSeries: series)
    }

    // MARK: Recovery

    func testRecoveryFromRealTail() throws {
        let rec = try XCTUnwrap(HeartRateRecovery.make(series: tailSeries(),
                                                       finish: HeartRateRecoveryTests.realFinish,
                                                       end: HeartRateRecoveryTests.realEnd))
        XCTAssertEqual(rec.heartRateAtFinish, 161.5, accuracy: 1e-9)
        XCTAssertEqual(rec.coveredSeconds, 221.2, accuracy: 1e-9)
        XCTAssertEqual(rec.marks.map({ (m: HeartRateRecovery.Mark) -> Double in m.seconds }), [60, 120, 180])
        XCTAssertEqual(rec.marks.map({ (m: HeartRateRecovery.Mark) -> Int in m.minutes }), [1, 2, 3])
        XCTAssertEqual(rec.mark(minutes: 1)?.heartRate ?? -1, (147 + 145 + 142.5) / 3, accuracy: 1e-9)
        XCTAssertEqual(rec.mark(minutes: 2)?.heartRate ?? -1, (124 + 123 + 122.5) / 3, accuracy: 1e-9)
        XCTAssertEqual(rec.mark(minutes: 3)?.heartRate ?? -1, (101 + 104.1 + 110.5) / 3, accuracy: 1e-9)
        XCTAssertEqual(rec.drop1 ?? -1, 161.5 - 144.8333333, accuracy: 1e-6)
        XCTAssertEqual(rec.drop2 ?? -1, 161.5 - 123.1666667, accuracy: 1e-6)
        XCTAssertEqual(rec.drop3 ?? -1, 161.5 - 105.2, accuracy: 1e-6)
    }

    func testRecoveryNeedsAMinuteAndReportsOnlyCoveredMarks() throws {
        let finish: Double = HeartRateRecoveryTests.realFinish
        // Ended 59 s after the finish: nothing.
        XCTAssertNil(HeartRateRecovery.make(series: tailSeries(), finish: finish, end: finish + 59))
        // Series stops at the finish (files before 2026-11-01), End later: nothing.
        XCTAssertNil(HeartRateRecovery.make(series: tailSeries(end: finish), finish: finish,
                                            end: HeartRateRecoveryTests.realEnd))
        // 90 s after the finish: only the 1-minute mark.
        let short = try XCTUnwrap(HeartRateRecovery.make(series: tailSeries(end: finish + 90), finish: finish,
                                                         end: finish + 90))
        XCTAssertEqual(short.marks.map({ (m: HeartRateRecovery.Mark) -> Int in m.minutes }), [1])
        XCTAssertNil(short.drop2)
        XCTAssertNil(short.drop3)
        // No HR around the finish: nothing.
        let noFinish = HeartRateSeries(start: 0, interval: 5,
                                       bpm: [Double?](repeating: nil, count: 30) + [Double?](repeating: 120, count: 30))
        XCTAssertNil(HeartRateRecovery.make(series: noFinish, finish: 140, end: 300))
        // A gap at +60 s but values later: the 2- and 3-minute marks.
        let gap = HeartRateSeries(start: 0, interval: 5,
                                  bpm: [Double?](repeating: 150, count: 4) + [Double?](repeating: nil, count: 20)
                                      + [Double?](repeating: 110, count: 30))
        let rec = try XCTUnwrap(HeartRateRecovery.make(series: gap, finish: 20, end: 270))
        XCTAssertEqual(rec.marks.map({ (m: HeartRateRecovery.Mark) -> Int in m.minutes }), [2, 3])
        XCTAssertEqual(rec.drop2 ?? -1, 40, accuracy: 1e-9)
    }

    func testResultRecoveryAndOldFiles() throws {
        // The AMRAP fixture's series stops at the finish: no recovery, and its JSON is unchanged.
        let amrap = try WorkoutResult.decode(from: try fixtureData("workout-amrap-2026-10-30", "json"))
        XCTAssertNil(amrap.heartRateRecovery)

        let t0: Double = 1_800_000_000
        let finished = result(series: tailSeries(offset: t0), start: t0,
                              finish: t0 + HeartRateRecoveryTests.realFinish, end: t0 + HeartRateRecoveryTests.realEnd)
        XCTAssertEqual(finished.heartRateRecovery?.heartRateAtFinish ?? -1, 161.5, accuracy: 1e-9)
        XCTAssertFalse(finished.needsHeartRateBackfill)
        // Ended without finishing: no recovery.
        let unfinished = result(series: tailSeries(offset: t0), start: t0, finish: nil,
                                end: t0 + HeartRateRecoveryTests.realEnd)
        XCTAssertNil(unfinished.heartRateRecovery)
        // Version 1 (no series): nothing, no backfill.
        let v1 = result(series: nil, start: t0, finish: t0 + 100, end: t0 + 400)
        XCTAssertNil(v1.heartRateRecovery)
        XCTAssertFalse(v1.needsHeartRateBackfill)
    }

    // MARK: Backfill from the session CSV

    func testSessionCSVHeartRateSamples() throws {
        let text: String = """
        # barpath-session v1, sessionId=X, startDate=2026-10-31T16:36:02.684Z, workout=partner.wod1
        t,qw,qx,qy,qz,ax,ay,az,gx,gy,gz,rx,ry,rz
        # event t=-0.015398 name=segment index=0 kind=run source=start
        0.0,1,0,0,0,0,0,0,0,0,-1,0,0,0
        # event t=29.845809 name=hr bpm=108
        # event t=30.1 name=pedometer steps=2 distance=0.5 cadence=-1.0 pace=-1.0
        # mark t=31 n=1 label=mark
        # event t=1390.279843 name=hr bpm=162
        """
        let hr: [TimedValue] = SessionCSV.heartRateSamples(text)
        let origin: Double = try XCTUnwrap(BarPathJSON.parseDate("2026-10-31T16:36:02.684Z")).timeIntervalSince1970
        XCTAssertEqual(hr.count, 2)
        XCTAssertEqual(hr[0].t - origin, 29.845809, accuracy: 1e-5)
        XCTAssertEqual(hr[0].value, 108)
        XCTAssertEqual(hr[1].t - origin, 1390.279843, accuracy: 1e-5)
        XCTAssertEqual(hr[1].value, 162)
        // No header startDate: nothing (times can't be placed).
        let noHeader: String = text.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
        XCTAssertTrue(SessionCSV.heartRateSamples(noHeader).isEmpty)
    }

    func testBackfillExtendsTheSeriesToEndOnce() throws {
        let t0: Double = 1_800_000_000
        let finish: Double = t0 + HeartRateRecoveryTests.realFinish
        let end: Double = t0 + HeartRateRecoveryTests.realEnd
        // What the watch wrote before 2026-11-01: the series stops at the finish.
        let cut: HeartRateSeries = HeartRateSeries.make(samples: tailSamples(offset: t0), start: t0, end: finish)
        let old = result(series: cut, start: t0, finish: finish, end: end)
        XCTAssertEqual(cut.bpm.count, 278)
        XCTAssertTrue(old.needsHeartRateBackfill)
        XCTAssertNil(old.heartRateRecovery)

        let filled = try XCTUnwrap(old.backfillingHeartRate(samples: tailSamples(offset: t0)))
        let bpm: [Double?] = filled.heartRateSeries?.bpm ?? []
        XCTAssertEqual(bpm.count, 323)
        XCTAssertEqual(Array(bpm[0..<278]), cut.bpm)            // the watch's buckets are kept
        XCTAssertFalse(filled.needsHeartRateBackfill)
        XCTAssertNil(filled.editedAt)
        let rec = try XCTUnwrap(filled.heartRateRecovery)
        XCTAssertEqual(rec.heartRateAtFinish, 161, accuracy: 1e-9)  // last watch bucket before the finish
        XCTAssertEqual(rec.marks.map({ (m: HeartRateRecovery.Mark) -> Int in Int(m.heartRate.rounded()) }),
                       [145, 123, 105])
        XCTAssertEqual(rec.marks.map({ (m: HeartRateRecovery.Mark) -> Int in Int(m.drop.rounded()) }), [16, 38, 56])
        XCTAssertNil(filled.backfillingHeartRate(samples: tailSamples(offset: t0)))   // once only
        // No samples after the finish: nothing to add.
        XCTAssertNil(old.backfillingHeartRate(samples: []))
        // Round trip keeps the tail.
        let back = try WorkoutResult.decode(from: try filled.encoded())
        XCTAssertEqual(back.heartRateSeries, filled.heartRateSeries)
    }
}
