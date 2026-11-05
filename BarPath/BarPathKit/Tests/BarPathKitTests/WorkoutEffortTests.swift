import XCTest
@testable import BarPathKit

final class WorkoutEffortTests: XCTestCase {
    private func cleans(reps: Double = 7, load: SegmentLoad? = SegmentLoad(155, .lb)) -> WorkoutSegment {
        return WorkoutSegment(kind: .station, movement: "powerCleans", name: "Power Cleans",
                              target: SegmentTarget(reps, .reps), load: load)
    }

    private func result(_ planned: [WorkoutSegment], done: [(Int, SegmentKind)], finished: Bool = true,
                        series: HeartRateSeries? = nil, partial: Int? = nil,
                        start: Date = Date(timeIntervalSince1970: 1_793_667_600)) -> WorkoutResult {
        let definition = WorkoutDefinition(id: "t", name: "T", shortName: "T", format: .forTime, team: .solo,
                                           timeCapSeconds: nil, healthKitActivity: "crossTraining",
                                           segments: planned)
        let segments: [SegmentResult] = done.map { (item: (Int, SegmentKind)) -> SegmentResult in
            SegmentResult(index: item.0, kind: item.1, movement: "m", title: "t", start: 0, end: 1, duration: 1)
        }
        var r = WorkoutResult(definition: definition, startDate: start,
                              finishDate: finished ? start.addingTimeInterval(600) : nil,
                              endDate: start.addingTimeInterval(720), totalSeconds: 600,
                              segments: segments, events: [])
        r.heartRateSeries = series
        r.partialReps = partial
        return r
    }

    func testZones() {
        let bpm: [Double] = [99, 100, 120, 140, 160, 180, 200]
        XCTAssertEqual(bpm.map { WorkoutEffort.zone(bpm: $0, maxHeartRate: 200) }, [0, 1, 2, 3, 4, 5, 5])
        XCTAssertEqual(WorkoutEffort.zone(bpm: 150, maxHeartRate: 0), 0)
    }

    func testParityWithPython() throws {
        let data: Data = try fixtureData("effort_cases", "json")
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(cases.count, 6)
        for c in cases {
            let s = try XCTUnwrap(c["series"] as? [String: Any])
            let raw = try XCTUnwrap(s["bpm"] as? [Any])
            let series = HeartRateSeries(start: try XCTUnwrap(s["start"] as? Double),
                                         interval: try XCTUnwrap(s["interval"] as? Double),
                                         bpm: raw.map { $0 as? Double })
            let got: Double? = WorkoutEffort.effort(series: series, finish: try XCTUnwrap(c["finish"] as? Double),
                                                    maxHeartRate: try XCTUnwrap(c["maxHeartRate"] as? Double))
            if let expected = c["effort"] as? Double {
                XCTAssertEqual(try XCTUnwrap(got), expected, accuracy: 1e-9, c["name"] as? String ?? "")
            } else {
                XCTAssertNil(got, c["name"] as? String ?? "")
            }
        }
    }

    func testMaxComesFromTheStoredMaxWithoutASeries() {
        let series = HeartRateSeries(start: 0, interval: 5, bpm: [150])
        var onlyMax = result([], done: [])
        onlyMax.heartRateMax = 180
        XCTAssertEqual(WorkoutEffort.highestHeartRate([result([], done: [], series: series), onlyMax]), 180)
    }

    func testWeightLifted() {
        let lb: Double = 0.45359237
        XCTAssertEqual(result([cleans()], done: [(0, .station)]).weightLiftedKg, 7 * 155 * lb, accuracy: 1e-9)
        let pair = cleans(reps: 10, load: SegmentLoad(50, .lb, count: 2))
        XCTAssertEqual(result([pair], done: [(0, .station)]).weightLiftedKg, 10 * 100 * lb, accuracy: 1e-9)
    }

    func testWeightLiftedSkipsWhatItCannotKnow() {
        let row = WorkoutSegment(kind: .station, movement: "row", name: "Row",
                                 target: SegmentTarget(40, .calories), load: SegmentLoad(155, .lb))
        let r = result([row, cleans(load: nil)], done: [(0, .station), (1, .station)])
        XCTAssertEqual(r.weightLiftedKg, 0)
        XCTAssertEqual(result([], done: []).weightLiftedKg, 0)
    }

    func testWeightLiftedUnfinishedAndWrapped() {
        let r = result([cleans()], done: [(0, .station), (1, .station)], finished: false, partial: 3)
        XCTAssertEqual(r.weightLiftedKg, (7 + 3) * 155 * 0.45359237, accuracy: 1e-9)
    }

    func testDaysGroupByLocalDayAndKeepMissingHeartRate() throws {
        let start = Date(timeIntervalSince1970: 1_793_667_600) // 2026-11-03 01:00 UTC
        let series = HeartRateSeries(start: start.timeIntervalSince1970, interval: 60, bpm: [200, 200])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: -8 * 3600))
        let days = WorkoutEffort.days([result([], done: [], series: series),
                                       result([], done: [], start: start.addingTimeInterval(3600)),
                                       result([], done: [], start: start.addingTimeInterval(19 * 3600))],
                                      calendar: calendar)
        XCTAssertEqual(days.map { $0.day }, ["2026-11-02", "2026-11-03"])
        XCTAssertEqual(days[0].effort, 10)
        XCTAssertEqual(days[0].minutes, 20)
        XCTAssertNil(days[1].effort)
    }
}
