import Foundation
import XCTest
@testable import BarPathKit

final class WorkoutTests: XCTestCase {

    // MARK: Library

    func testLibraryHasNineUniqueDefinitionsInOrder() {
        let all = WorkoutLibrary.all
        XCTAssertEqual(all.count, 9)
        XCTAssertEqual(all.map { (d: WorkoutDefinition) -> String in d.id },
                       [WorkoutLibrary.hyroxSolo.id, WorkoutLibrary.hyroxDoubles.id, WorkoutLibrary.halfHyrox.id,
                        WorkoutLibrary.partnerWod1.id, WorkoutLibrary.partnerWod2.id, WorkoutLibrary.quickTest.id,
                        WorkoutLibrary.helen.id, WorkoutLibrary.rowThrusters.id, WorkoutLibrary.amrap20.id])
        let ids = Set(all.map { (d: WorkoutDefinition) -> String in d.id })
        XCTAssertEqual(ids.count, 9)
        for d in all {
            XCTAssertEqual(WorkoutLibrary.definition(id: d.id), d)
            XCTAssertLessThanOrEqual(d.shortName.count, 12)
        }
        XCTAssertNil(WorkoutLibrary.definition(id: "nope"))
    }

    func testClassWorkouts() {
        XCTAssertEqual(WorkoutLibrary.helen.segments.count, 9)
        XCTAssertEqual(WorkoutLibrary.helen.runCount, 3)
        XCTAssertEqual(WorkoutLibrary.helen.segments[1].title, "KB Swings 21")
        XCTAssertEqual(WorkoutLibrary.rowThrusters.segments.count, 17)
        XCTAssertEqual(WorkoutLibrary.rowThrusters.segments[0].title, "Row 15 cal")
        XCTAssertEqual(WorkoutLibrary.rowThrusters.segments[2].kind, SegmentKind.rest)
        XCTAssertEqual(WorkoutLibrary.rowThrusters.segments[2].title, "Rest")
        XCTAssertEqual(WorkoutLibrary.rowThrusters.segments.last?.movement, Movement.thrusters)
        XCTAssertEqual(WorkoutLibrary.amrap20.segments.count, 40)
    }

    func testHyroxSoloStructure() {
        let d = WorkoutLibrary.hyroxSolo
        XCTAssertEqual(d.segments.count, 16)
        XCTAssertEqual(d.runCount, 8)
        XCTAssertEqual(d.stationCount, 8)
        for (i, s) in d.segments.enumerated() {
            XCTAssertEqual(s.kind, i % 2 == 0 ? SegmentKind.run : SegmentKind.station)
            if s.kind == .run { XCTAssertEqual(s.title, "Run 1000 m") }
        }
        let stations = d.segments.filter { (s: WorkoutSegment) -> Bool in s.kind == .station }
        XCTAssertEqual(stations.map { (s: WorkoutSegment) -> String in s.movement },
                       [Movement.skiErg, Movement.sledPush, Movement.sledPull, Movement.burpeeBroadJumps,
                        Movement.row, Movement.farmersCarry, Movement.sandbagLunges, Movement.wallBalls])
        XCTAssertEqual(stations.map { (s: WorkoutSegment) -> String in s.title },
                       ["SkiErg 1000 m", "Sled Push 50 m", "Sled Pull 50 m", "Burpee Broad Jumps 80 m",
                        "Row 1000 m", "Farmers Carry 200 m", "Sandbag Lunges 100 m", "Wall Balls 100"])
        XCTAssertEqual(WorkoutLibrary.hyroxDoubles.segments, d.segments)
        XCTAssertEqual(WorkoutLibrary.hyroxDoubles.team, TeamFormat.doubles)
        XCTAssertEqual(WorkoutLibrary.halfHyrox.segments.count, 16)
        XCTAssertEqual(WorkoutLibrary.halfHyrox.segments[0].title, "Run 500 m")
        XCTAssertEqual(WorkoutLibrary.halfHyrox.segments[15].title, "Wall Balls 50")
    }

    func testPartnerWods() {
        let w1 = WorkoutLibrary.partnerWod1
        XCTAssertEqual(w1.segments.count, 10)
        XCTAssertEqual(w1.segments.map { (s: WorkoutSegment) -> String in s.title },
                       ["Run 1000 m", "Wall Balls 100", "Run 800 m", "DB Walking Lunges 80", "Run 600 m",
                        "Burpees 60", "Run 400 m", "Med Ball Box Step-Overs 40", "Run 200 m", "Devil Press 20"])
        let w2 = WorkoutLibrary.partnerWod2
        XCTAssertEqual(w2.segments.count, 5)
        XCTAssertTrue(w2.segments.allSatisfy { (s: WorkoutSegment) -> Bool in s.kind == .station })
        XCTAssertEqual(w2.segments.map { (s: WorkoutSegment) -> String in s.title },
                       ["SkiErg 1000 m", "Sled Push 40 m", "Farmers Carry 100 m", "DB Over-Shoulder 40",
                        "SkiErg 1000 m"])
        XCTAssertEqual(WorkoutLibrary.quickTest.segments.count, 4)
    }

    func testTargetText() {
        XCTAssertEqual(SegmentTarget(1000, .meters).text, "1000 m")
        XCTAssertEqual(SegmentTarget(100, .reps).text, "100 reps")
        XCTAssertEqual(SegmentTarget(20, .calories).text, "20 cal")
        XCTAssertEqual(SegmentTarget(120, .seconds).text, "2:00")
        XCTAssertEqual(SegmentTarget(65, .seconds).text, "1:05")
        let s = WorkoutSegment(kind: .rest, movement: "rest", name: "Rest", target: nil)
        XCTAssertEqual(s.title, "Rest")
        XCTAssertEqual(Movement.displayName("mystery"), "mystery")
    }

    // MARK: Golden scenario

    private func goldenProgress() -> WorkoutProgress {
        var p = WorkoutProgress(definition: WorkoutLibrary.quickTest)
        p.start(at: 1000)
        XCTAssertTrue(p.advance(at: 1060, source: .crown))
        XCTAssertTrue(p.advance(at: 1100, source: .crown))
        XCTAssertTrue(p.undo(at: 1105, source: .button))
        XCTAssertTrue(p.advance(at: 1110, source: .crown))
        XCTAssertTrue(p.advance(at: 1170, source: .crown))
        XCTAssertTrue(p.advance(at: 1200, source: .crown))
        return p
    }

    func testGoldenSplitsAndEvents() {
        let p = goldenProgress()
        XCTAssertTrue(p.isFinished)
        XCTAssertEqual(p.finishTime, 1200)
        XCTAssertEqual(p.segmentStarts, [1000, 1060, 1110, 1170])
        let splits = p.splits(now: 5000)
        XCTAssertEqual(splits.map { (s: SegmentSplit) -> Double in s.start }, [1000, 1060, 1110, 1170])
        XCTAssertEqual(splits.map { (s: SegmentSplit) -> Double in s.end }, [1060, 1110, 1170, 1200])
        XCTAssertEqual(splits.map { (s: SegmentSplit) -> Double in s.duration }, [60, 50, 60, 30])
        XCTAssertEqual(p.totalElapsed(now: 5000), 200, accuracy: 1e-9)
        XCTAssertEqual(p.segmentElapsed(now: 5000), 30, accuracy: 1e-9)
        XCTAssertEqual(p.events.map { (e: WorkoutEvent) -> WorkoutEventKind in e.kind },
                       [.start, .advance, .advance, .undo, .advance, .advance, .finish])
        XCTAssertEqual(p.events.map { (e: WorkoutEvent) -> Int in e.segmentIndex }, [0, 1, 2, 1, 2, 3, 3])
        XCTAssertEqual(p.events[3].source, AdvanceSource.button)
        XCTAssertNil(p.nextSegment)
    }

    func testGoldenStats() {
        let p = goldenProgress()
        var hr: [TimedValue] = []
        var t: Double = 1000
        while t <= 1200 {
            hr.append(TimedValue(t: t, value: 100 + (t - 1000) / 10))
            t += 10
        }
        let ped: [PedometerSample] = [
            PedometerSample(t: 1030, steps: 90, distance: 100),
            PedometerSample(t: 1060, steps: 180, distance: 200),
            PedometerSample(t: 1200, steps: 400, distance: 500)
        ]
        let r = SplitStats.compute(progress: p, now: 1300, heartRates: hr, pedometer: ped)
        XCTAssertEqual(r.count, 4)
        XCTAssertEqual(r[0].heartRateAvg ?? -1, 102.5, accuracy: 1e-9)
        XCTAssertEqual(r[0].heartRateMax ?? -1, 105, accuracy: 1e-9)
        XCTAssertEqual(r[0].steps ?? -1, 180, accuracy: 1e-9)
        XCTAssertEqual(r[0].distance ?? -1, 200, accuracy: 1e-9)
        XCTAssertEqual(r[0].cadence ?? -1, 180, accuracy: 1e-9)
        XCTAssertEqual(r[0].paceSecondsPerKm ?? -1, 300, accuracy: 1e-9)
        XCTAssertEqual(r[0].title, "Run 200 m")
        // Station segments never get a pace.
        XCTAssertNil(r[1].paceSecondsPerKm)
        XCTAssertNotNil(r[1].cadence)
        // Segment 3 ends exactly at finish; HR window is [start, end).
        XCTAssertEqual(r[3].heartRateMax ?? -1, 119, accuracy: 1e-9)
        // No data -> nil stats.
        let empty = SplitStats.compute(progress: p, now: 1300, heartRates: [], pedometer: [])
        XCTAssertNil(empty[0].heartRateAvg)
        XCTAssertNil(empty[0].steps)
        XCTAssertNil(empty[0].paceSecondsPerKm)
    }

    // MARK: Edge cases

    func testUndoAtSegmentZeroAndBeforeStart() {
        var p = WorkoutProgress(definition: WorkoutLibrary.quickTest)
        XCTAssertFalse(p.undo(at: 1, source: .button))
        XCTAssertFalse(p.advance(at: 1, source: .crown))
        XCTAssertEqual(p.segmentElapsed(now: 10), 0)
        XCTAssertNil(p.currentSegment)
        p.start(at: 1000)
        p.start(at: 2000)  // no-op
        XCTAssertEqual(p.startTime, 1000)
        XCTAssertEqual(p.events.count, 1)
        XCTAssertFalse(p.undo(at: 1001, source: .button))
        XCTAssertEqual(p.events.count, 1)
        XCTAssertEqual(p.currentSegment?.title, "Run 200 m")
        XCTAssertEqual(p.nextSegment?.title, "Air Squats 20")
        XCTAssertFalse(p.advance(at: 999, source: .crown))
    }

    func testAdvanceAfterFinishAndUnfinish() {
        var p = goldenProgress()
        XCTAssertFalse(p.advance(at: 1300, source: .crown))
        XCTAssertEqual(p.events.count, 7)
        XCTAssertTrue(p.undo(at: 1210, source: .button))
        XCTAssertFalse(p.isFinished)
        XCTAssertEqual(p.currentIndex, 3)
        XCTAssertEqual(p.events.last?.kind, WorkoutEventKind.unfinish)
        XCTAssertEqual(p.events.last?.segmentIndex, 3)
        XCTAssertEqual(p.segmentElapsed(now: 1250), 80, accuracy: 1e-9)
        XCTAssertTrue(p.advance(at: 1260, source: .press))
        XCTAssertEqual(p.finishTime, 1260)
        p.recordEnd(at: 1270)
        XCTAssertEqual(p.events.last?.kind, WorkoutEventKind.end)
    }

    func testProgressCodableRoundTrip() throws {
        let p = goldenProgress()
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(WorkoutProgress.self, from: data)
        XCTAssertEqual(back, p)
    }

    // MARK: Result JSON

    func testWorkoutResultRoundTrip() throws {
        let p = goldenProgress()
        let segs = SplitStats.compute(progress: p, now: 1300, heartRates: [], pedometer: [])
        let start = Date(timeIntervalSince1970: 1_792_951_391.25)
        let result = WorkoutResult(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                                   definition: WorkoutLibrary.quickTest,
                                   startDate: start,
                                   finishDate: start.addingTimeInterval(200),
                                   endDate: start.addingTimeInterval(210),
                                   totalSeconds: 200,
                                   segments: segs,
                                   events: p.events,
                                   heartRateAvg: 110,
                                   heartRateMax: 120,
                                   recordingFileName: "session-abc.csv")
        let data = try result.encoded()
        let back = try WorkoutResult.decode(from: data)
        XCTAssertEqual(back, result)
        XCTAssertEqual(back.version, 1)
        XCTAssertEqual(back.runSeconds, 120, accuracy: 1e-9)
        XCTAssertEqual(back.stationSeconds, 80, accuracy: 1e-9)
        let obj = try jsonObject(data)
        XCTAssertTrue(obj["startDate"] is String)
    }

    // MARK: Timed segments

    func testIntervalRestEndsOnTheClock() {
        var p = WorkoutProgress(definition: WorkoutLibrary.rowThrusters)
        p.start(at: 1000)
        XCTAssertNil(p.autoAdvanceTime())
        p.advance(at: 1060, source: .crown)
        XCTAssertNil(p.autoAdvanceTime())
        p.advance(at: 1100, source: .crown)
        XCTAssertEqual(p.autoAdvanceTime(), 1180)
        p.advance(at: 1180, source: .auto)
        p.advance(at: 1250, source: .crown)
        p.advance(at: 1370, source: .crown)
        XCTAssertEqual(p.autoAdvanceTime(), 1540)
    }

    func testFixedRestAndAmrapCap() {
        let d = WorkoutDefinition(
            id: "t.rest", name: "Rest test", shortName: "Rest", format: .forTime, team: .solo,
            timeCapSeconds: nil, healthKitActivity: "crossTraining",
            segments: [
                WorkoutSegment(kind: .station, movement: Movement.burpees, name: "Burpees", target: SegmentTarget(10, .reps)),
                WorkoutSegment(kind: .rest, movement: Movement.rest, name: "Rest", target: SegmentTarget(60, .seconds)),
                WorkoutSegment(kind: .station, movement: Movement.burpees, name: "Burpees", target: SegmentTarget(10, .reps))
            ])
        var p = WorkoutProgress(definition: d)
        p.start(at: 0)
        p.advance(at: 42, source: .crown)
        XCTAssertEqual(p.autoAdvanceTime(), 102)
        XCTAssertNil(p.capTime)

        var a = WorkoutProgress(definition: WorkoutLibrary.amrap20)
        a.start(at: 500)
        XCTAssertEqual(a.capTime, 1700)
        XCTAssertTrue(a.finish(at: 1700, source: .auto))
        XCTAssertTrue(a.isFinished)
        XCTAssertEqual(a.events.last?.kind, WorkoutEventKind.finish)
    }

    func testDefinitionWithoutIntervalDecodes() throws {
        let json = "{\"id\":\"x\",\"name\":\"X\",\"shortName\":\"X\",\"format\":\"forTime\",\"team\":\"solo\",\"healthKitActivity\":\"crossTraining\",\"segments\":[]}"
        let d = try JSONDecoder().decode(WorkoutDefinition.self, from: Data(json.utf8))
        XCTAssertNil(d.intervalSeconds)
    }
}
