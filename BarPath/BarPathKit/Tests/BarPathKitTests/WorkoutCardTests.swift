import Foundation
import XCTest
@testable import BarPathKit

/// Parity with tools/barpath/workout_card.py: the fixture holds each definition (built-ins and the
/// library seed workouts) and the card the Python reference makes from it.
final class WorkoutCardTests: XCTestCase {

    private func expectedCards() throws -> [[String: Any]] {
        let root: [String: Any] = try jsonObject(try fixtureData("workout_cards.expected", "json"))
        guard let cards = root["cards"] as? [[String: Any]] else {
            XCTFail("fixture has no cards")
            return []
        }
        return cards
    }

    private func optionalString(_ value: Any?) -> String? {
        guard let v = value, !(v is NSNull) else { return nil }
        return v as? String
    }

    private func check(_ card: WorkoutCard, _ expected: [String: Any], _ id: String) {
        XCTAssertEqual(card.name, optionalString(expected["name"]), id)
        XCTAssertEqual(card.nameIsFormat, (expected["nameIsFormat"] as? Bool) ?? false, id)
        XCTAssertEqual(card.typeTag?.label, optionalString(expected["typeTag"]), id)
        XCTAssertEqual(card.blockTag?.label, optionalString(expected["blockTag"]), id)
        XCTAssertEqual(card.timeDomainLine, optionalString(expected["timeDomainLine"]), id)
        XCTAssertEqual(card.repSchemeLine, optionalString(expected["repSchemeLine"]), id)
        XCTAssertEqual(card.capLine, optionalString(expected["capLine"]), id)
        XCTAssertEqual(card.summaryLine, optionalString(expected["summaryLine"]), id)
        let lines: [[String: Any]] = (expected["lines"] as? [[String: Any]]) ?? []
        XCTAssertEqual(card.lines.count, lines.count, id)
        for (i, line) in lines.enumerated() where i < card.lines.count {
            XCTAssertEqual(card.lines[i].text, optionalString(line["text"]), id + " line \(i)")
            XCTAssertEqual(card.lines[i].load, optionalString(line["load"]), id + " line \(i)")
        }
        let visible = card.visibleLines()
        XCTAssertEqual(visible.lines.count, (expected["visibleLineCount"] as? Int) ?? -1, id)
        XCTAssertEqual(visible.hidden, (expected["hiddenLineCount"] as? Int) ?? -1, id)
    }

    func testParityWithPythonReference() throws {
        let cards: [[String: Any]] = try expectedCards()
        XCTAssertEqual(cards.count, WorkoutLibrary.known.count + 2)
        for entry in cards {
            guard let defObject = entry["definition"], let expected = entry["card"] as? [String: Any] else {
                XCTFail("bad fixture entry")
                continue
            }
            let data: Data = try JSONSerialization.data(withJSONObject: defObject, options: [])
            let definition: WorkoutDefinition = try JSONDecoder().decode(WorkoutDefinition.self, from: data)
            check(WorkoutCard.make(definition: definition), expected, definition.id)
            // The built-ins in Swift are the same workouts as in Python.
            if let builtIn = WorkoutLibrary.definition(id: definition.id) {
                XCTAssertEqual(builtIn, definition, definition.id)
                check(WorkoutCard.make(definition: builtIn), expected, definition.id + " (built-in)")
            }
        }
    }

    func testHelen() {
        let c = WorkoutCard.make(definition: WorkoutLibrary.helen)
        XCTAssertEqual(c.name, "Helen")
        XCTAssertEqual(c.typeTag, WorkoutCard.TypeTag.rft)
        XCTAssertEqual(c.blockTag, WorkoutCard.BlockTag.metcon)
        XCTAssertEqual(c.timeDomainLine, "3 rounds")
        XCTAssertEqual(c.lines.map { (l: WorkoutCard.Line) -> String in l.full },
                       ["400 m Run", "21 KB Swings", "12 Pull-ups"])
        XCTAssertEqual(c.capLine, "16 min cap")
    }

    func testAmrapWithRestAndEmom() {
        let a = WorkoutCard.make(definition: WorkoutLibrary.amrap40)
        XCTAssertEqual(a.name, "AMRAP 40")
        XCTAssertTrue(a.nameIsFormat)
        XCTAssertEqual(a.timeDomainLine, "40 min AMRAP · rest 1 min between rounds")
        XCTAssertNil(a.capLine)
        let e = WorkoutCard.make(definition: WorkoutLibrary.rowThrusters)
        XCTAssertEqual(e.name, "Row + Thrusters")
        XCTAssertEqual(e.typeTag, WorkoutCard.TypeTag.emom)
        XCTAssertEqual(e.timeDomainLine, "Every 3:00 × 6")
        XCTAssertEqual(e.lines.map { (l: WorkoutCard.Line) -> String in l.full }, ["15 Cal Row", "12 Thrusters"])
    }

    func testMixedSchemeAndNoName() {
        var segs: [WorkoutSegment] = []
        for v in [40.0, 30.0, 20.0, 30.0, 40.0] {
            segs.append(WorkoutSegment(kind: .station, movement: "row", name: "Row",
                                       target: SegmentTarget(v, .calories)))
            segs.append(WorkoutSegment(kind: .station, movement: "powerCleans", name: "Power Cleans",
                                       target: SegmentTarget(7, .reps), load: SegmentLoad(155, .lb)))
        }
        let d = WorkoutDefinition(id: "t", name: "  ", shortName: "", format: .forTime, team: .solo,
                                  timeCapSeconds: 1200, healthKitActivity: "crossTraining",
                                  segments: segs, roundSize: 2)
        let c = WorkoutCard.make(definition: d)
        XCTAssertEqual(c.repSchemeLine, "40-30-20-30-40")
        XCTAssertEqual(c.lines.map { (l: WorkoutCard.Line) -> String in l.full }, ["Cal Row", "7 Power Cleans @155 lb"])
        XCTAssertEqual(c.name, "5 rounds")
        XCTAssertTrue(c.nameIsFormat)
        XCTAssertEqual(c.capLine, "20 min cap")
        XCTAssertEqual(c.summaryLine, "40-30-20-30-40 Cal Row · 7 Power Cleans @155 lb")
    }

    func testFreeWorkoutAndShortNames() {
        let f = WorkoutCard.make(definition: WorkoutLibrary.free)
        XCTAssertEqual(f.name, "Free Workout")
        XCTAssertNil(f.typeTag)
        XCTAssertNil(f.blockTag)
        XCTAssertEqual(f.lines.first?.text, "Turn the Crown at each change")
        XCTAssertEqual(Movement.shortName(Movement.dumbbellSnatch, plural: true), "ALT DB Snatches")
        XCTAssertEqual(Movement.shortName(Movement.pullUps, plural: false), "Pull-up")
        XCTAssertNil(Movement.shortName("nope", plural: false))
        XCTAssertTrue(WorkoutCard.isGenericName("E3MOM 12"))
        XCTAssertFalse(WorkoutCard.isGenericName("Eva"))
    }
}
