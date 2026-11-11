import Foundation
import XCTest
@testable import BarPathKit

/// Which results belong to a workout; same cases as tools/tests/test_workout_history.py. The
/// library seed workouts come from the card parity fixture (they are the PitFIRE rows of Nov 2).
final class WorkoutHistoryTests: XCTestCase {

    private func libraryDefinition(_ id: String) throws -> WorkoutDefinition {
        let root: [String: Any] = try jsonObject(try fixtureData("workout_cards.expected", "json"))
        let cards: [[String: Any]] = (root["cards"] as? [[String: Any]]) ?? []
        for entry in cards {
            guard let defObject = entry["definition"] as? [String: Any],
                  let entryId = defObject["id"] as? String, entryId == id else { continue }
            let data: Data = try JSONSerialization.data(withJSONObject: defObject, options: [])
            return try JSONDecoder().decode(WorkoutDefinition.self, from: data)
        }
        throw XCTSkip("fixture has no " + id)
    }

    private func renamed(_ d: WorkoutDefinition, _ id: String) -> WorkoutDefinition {
        var out: WorkoutDefinition = d
        out.id = id
        return out
    }

    private func result(_ d: WorkoutDefinition, day: Int) -> WorkoutResult {
        var c = DateComponents()
        c.year = 2026
        c.month = 11
        c.day = day
        c.hour = 18
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
        let start: Date = calendar.date(from: c) ?? Date(timeIntervalSince1970: 0)
        let end: Date = start.addingTimeInterval(600)
        return WorkoutResult(definition: d, startDate: start, finishDate: end, endDate: end,
                             totalSeconds: 600, segments: [], events: [])
    }

    func testNormalizedName() {
        XCTAssertEqual(WorkoutHistory.normalizedName("Every 1:00 × 8: Power C&J"), "every 1 00 8 power c j")
        XCTAssertEqual(WorkoutHistory.normalizedName("  FREEDOM "), "freedom")
        XCTAssertEqual(WorkoutHistory.normalizedName("Café  “Game Over”"), "cafe game over")
        XCTAssertEqual(WorkoutHistory.normalizedName(""), "")
    }

    func testFreedomBuiltInIdMatchesLibraryRow() throws {
        let lib: WorkoutDefinition = try libraryDefinition("lib.pitfire.20261102.freedom")
        var old: WorkoutDefinition = renamed(lib, "wod.freedom")
        for i in 0..<old.segments.count where old.segments[i].load != nil {
            old.segments[i].load = SegmentLoad(85, SegmentLoad.Unit.kg)
        }
        XCTAssertTrue(WorkoutHistory.isSameWorkout(lib, old))
        XCTAssertTrue(WorkoutHistory.isSameWorkout(old, lib))
    }

    func testPcjEmomBuiltInIdMatchesLibraryRow() throws {
        let lib: WorkoutDefinition = try libraryDefinition("lib.pitfire.20261102.pcj-emom")
        XCTAssertTrue(WorkoutHistory.isSameWorkout(lib, renamed(lib, "wod.pcjEmom")))
    }

    func testSameNameOtherMovementsDoNotMatch() throws {
        let lib: WorkoutDefinition = try libraryDefinition("lib.pitfire.20261102.freedom")
        var other: WorkoutDefinition = renamed(lib, "wod.other")
        other.segments[1].movement = "thrusters"
        XCTAssertFalse(WorkoutHistory.isSameWorkout(lib, other))
        var shorter: WorkoutDefinition = renamed(lib, "wod.short")
        shorter.segments = Array(shorter.segments.dropLast(2))
        XCTAssertFalse(WorkoutHistory.isSameWorkout(lib, shorter))
    }

    func testSameMovementsOtherNameDoNotMatch() throws {
        let lib: WorkoutDefinition = try libraryDefinition("lib.pitfire.20261102.freedom")
        var other: WorkoutDefinition = renamed(lib, "wod.liberty")
        other.name = "Liberty"
        XCTAssertFalse(WorkoutHistory.isSameWorkout(lib, other))
    }

    func testSameIdAlwaysMatches() throws {
        guard let helen = WorkoutLibrary.definition(id: "wod.helen") else {
            throw XCTSkip("no Helen")
        }
        var edited: WorkoutDefinition = helen
        edited.name = "Helen (old)"
        XCTAssertTrue(WorkoutHistory.isSameWorkout(helen, edited))
    }

    func testMovementSequence() throws {
        let lib: WorkoutDefinition = try libraryDefinition("lib.pitfire.20261102.pcj-emom")
        XCTAssertEqual(Array(WorkoutHistory.movementSequence(lib).prefix(2)),
                       ["station:powerCleanAndJerk", "rest:rest"])
    }

    func testResultsNewestFirst() throws {
        let lib: WorkoutDefinition = try libraryDefinition("lib.pitfire.20261102.freedom")
        guard let helenDef = WorkoutLibrary.definition(id: "wod.helen") else {
            throw XCTSkip("no Helen")
        }
        let a: WorkoutResult = result(renamed(lib, "wod.freedom"), day: 2)
        let b: WorkoutResult = result(lib, day: 9)
        let helen: WorkoutResult = result(helenDef, day: 5)
        let all: [WorkoutResult] = [a, helen, b]
        XCTAssertEqual(WorkoutHistory.results(of: lib, in: all).map { $0.id }, [b.id, a.id])
        XCTAssertEqual(WorkoutHistory.latest(of: lib, in: all)?.id, b.id)
    }

    func testSegmentLinesQuantityFirst() throws {
        let pcj: WorkoutDefinition = try libraryDefinition("lib.pitfire.20261102.pcj-emom")
        XCTAssertEqual(pcj.segments.prefix(2).map { WorkoutCard.segmentLine($0).full }, ["2 Power C&J", "Rest"])
        guard let helen = WorkoutLibrary.definition(id: "wod.helen") else {
            throw XCTSkip("no Helen")
        }
        XCTAssertEqual(helen.segments.prefix(3).map { WorkoutCard.segmentLine($0).full },
                       ["400 m Run", "21 KB Swings", "12 Pull-ups"])
        let freedom: WorkoutDefinition = try libraryDefinition("lib.pitfire.20261102.freedom")
        XCTAssertEqual(freedom.segments.prefix(2).map { WorkoutCard.segmentLine($0).full },
                       ["40 Cal Row", "7 Power Cleans @155 lb"])
    }

    func testSameMovementsIgnoresTheName() {
        var renamed = WorkoutLibrary.helen
        renamed.id = "lib.x"
        renamed.name = "3 Rounds For Time"
        XCTAssertFalse(WorkoutHistory.isSameWorkout(renamed, WorkoutLibrary.helen))
        XCTAssertTrue(WorkoutHistory.sameMovements(renamed, WorkoutLibrary.helen))
        XCTAssertFalse(WorkoutHistory.sameMovements(WorkoutLibrary.amrap20, WorkoutLibrary.helen))
    }
}
