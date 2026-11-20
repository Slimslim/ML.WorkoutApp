import Foundation
import XCTest
@testable import BarPathKit

/// WorkoutProgress in block mode (WORKOUT_SPEC 5c): replays the scripts of
/// Fixtures/repeat_block_progress_cases.json (written by tools/make_repeat_block_progress_cases.py
/// from the Python reference) and requires the same events. The clock driver mirrors
/// `repeat_block.tick` / `run_script`.
final class RepeatBlockProgressTests: XCTestCase {

    /// [t, action] and [t, kind, step, source]: mixed types, decoded by hand.
    struct Action: Decodable {
        let t: Double
        let action: String

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            t = try c.decode(Double.self)
            action = try c.decode(String.self)
        }
    }

    struct Event: Decodable, Equatable, CustomStringConvertible {
        let t: Double
        let kind: String
        let step: Int
        let source: String?

        init(t: Double, kind: String, step: Int, source: String?) {
            self.t = t
            self.kind = kind
            self.step = step
            self.source = source
        }

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            t = try c.decode(Double.self)
            kind = try c.decode(String.self)
            step = try c.decode(Int.self)
            source = try c.decodeIfPresent(String.self)
        }

        var description: String { return "[\(t), \(kind), \(step), \(source ?? "nil")]" }
    }

    struct Case: Decodable {
        let name: String
        let definition: WorkoutDefinition
        let script: [Action]
        let events: [Event]
        let finished: Bool
        let finishTime: Double?
        let currentStep: Int
        let steps: Int
    }

    struct Fixture: Decodable {
        let cases: [Case]
    }

    /// What the watch's undo suppresses (WorkoutSessionModel.undo): an auto change whose time has
    /// already passed (per step start) and a cap already passed.
    struct Suppress {
        var autoStart: Double? = nil
        var cap: Bool = false
    }

    /// The clock up to `now`: the cap first on a tie, then the segment changes (repeat_block.tick),
    /// skipping what an undo suppressed (WorkoutSessionModel.nextClockEvent).
    static func tick(_ p: inout WorkoutProgress, now: Double, suppress: Suppress) {
        var guardCount: Int = 0
        while guardCount < 10_000 {
            guardCount += 1
            guard p.isStarted, !p.isFinished, let last = p.segmentStarts.last else { return }
            let cap: Double? = suppress.cap ? nil : p.capTime
            var auto: Double? = p.autoAdvanceTime()
            if auto != nil, let s = suppress.autoStart, last == s {
                auto = nil
            }
            if let c = cap, c <= now, auto == nil || c <= auto! {
                p.finish(at: Swift.max(c, last), source: .auto)
                return
            }
            guard let a = auto, a <= now else { return }
            if !p.autoAdvance(at: a) { return }
        }
        XCTFail("clock loop did not settle")
    }

    static func run(_ p: inout WorkoutProgress, script: [Action]) -> [Event] {
        var suppress = Suppress()
        for a in script {
            tick(&p, now: a.t, suppress: suppress)
            switch a.action {
            case "start": p.start(at: a.t)
            case "crown": p.advance(at: a.t, source: .crown)
            case "undo":
                if p.undo(at: a.t, source: .crown) {
                    if let auto = p.autoAdvanceTime(), auto <= a.t {
                        suppress.autoStart = p.segmentStarts.last
                    }
                    if let cap = p.capTime, cap <= a.t {
                        suppress.cap = true
                    }
                }
            case "end": p.finish(at: a.t, source: .button)
            default: break
            }
        }
        return p.events.map { (e: WorkoutEvent) -> Event in
            Event(t: e.t, kind: e.kind.rawValue, step: e.segmentIndex, source: e.source?.rawValue)
        }
    }

    func testProgressCases() throws {
        let data: Data = try fixtureData("repeat_block_progress_cases", "json")
        let cases: [Case] = try JSONDecoder().decode(Fixture.self, from: data).cases
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for c in cases {
            guard let plan = RepeatBlock.enginePlan(for: c.definition, engineOn: true) else {
                XCTFail("\(c.name): no block plan")
                continue
            }
            var p = WorkoutProgress(definition: c.definition, block: plan)
            let events: [Event] = RepeatBlockProgressTests.run(&p, script: c.script)
            XCTAssertEqual(events, c.events, c.name)
            XCTAssertEqual(p.isFinished, c.finished, c.name)
            XCTAssertEqual(p.finishTime, c.finishTime, c.name)
            XCTAssertEqual(p.currentIndex, c.currentStep, c.name)
            XCTAssertEqual(p.segmentStarts.count, c.steps, c.name)
        }
    }

    /// A checkpoint keeps the plan; an older checkpoint (no "block" key) decodes as today's path.
    func testCheckpointRoundTripKeepsTheBlock() throws {
        let data: Data = try fixtureData("repeat_block_progress_cases", "json")
        let c: Case = try JSONDecoder().decode(Fixture.self, from: data).cases[0]
        var p = WorkoutProgress(definition: c.definition, block: RepeatBlock.enginePlan(for: c.definition, engineOn: true))
        p.start(at: 0)
        p.advance(at: 40, source: .crown)
        let saved: Data = try JSONEncoder().encode(p)
        let back: WorkoutProgress = try JSONDecoder().decode(WorkoutProgress.self, from: saved)
        XCTAssertEqual(back, p)
        XCTAssertNotNil(back.block)

        var legacy = WorkoutProgress(definition: WorkoutLibrary.helen)
        legacy.start(at: 0)
        let legacyJSON: String = String(data: try JSONEncoder().encode(legacy), encoding: .utf8) ?? ""
        XCTAssertFalse(legacyJSON.contains("\"block\""))
        let old: WorkoutProgress = try JSONDecoder().decode(WorkoutProgress.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(old.block)
        XCTAssertEqual(old, legacy)
    }

    func testCrownInTheWindowWaitIsIgnored() throws {
        let data: Data = try fixtureData("repeat_block_progress_cases", "json")
        let cases: [Case] = try JSONDecoder().decode(Fixture.self, from: data).cases
        guard let c = cases.first(where: { (c: Case) -> Bool in c.definition.id == "p.tabata" }) else {
            XCTFail("no tabata case")
            return
        }
        var p = WorkoutProgress(definition: c.definition, block: RepeatBlock.enginePlan(for: c.definition, engineOn: true))
        p.start(at: 0)
        XCTAssertTrue(p.advance(at: 15, source: .crown))
        XCTAssertTrue(p.isWaitingForWindow)
        XCTAssertFalse(p.advance(at: 20, source: .crown))
        XCTAssertEqual(p.currentIndex, 1)
        XCTAssertTrue(p.advance(at: 30, source: .auto))
        XCTAssertFalse(p.isWaitingForWindow)
        XCTAssertEqual(p.position(ofStep: p.currentIndex)?.pass, 1)
        XCTAssertEqual(p.position(ofStep: p.currentIndex)?.part, 0)
    }
}
