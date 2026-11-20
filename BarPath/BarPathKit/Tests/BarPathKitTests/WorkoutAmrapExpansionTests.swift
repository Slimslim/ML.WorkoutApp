import Foundation
import XCTest
@testable import BarPathKit

/// #138: an AMRAP is expanded at workout start so the list never runs out before the cap.
/// Cases shared with tools/tests/test_amrap_expand.py (Fixtures/amrap_expand_cases.json).
final class WorkoutAmrapExpansionTests: XCTestCase {

    struct CaseInput: Decodable {
        let id: String
        let name: String
        let shortName: String
        let format: WorkoutFormat
        let team: TeamFormat
        let healthKitActivity: String
        let timeCapSeconds: Double?
        let roundSize: Int?
    }

    struct Case: Decodable {
        let name: String
        let input: CaseInput
        let pattern: [WorkoutSegment]
        let times: Int
        let unchanged: Bool
        let segmentCount: Int
        let roundSize: Int?
        let blockStart: Int?

        var definition: WorkoutDefinition {
            var segments: [WorkoutSegment] = []
            for _ in 0..<times {
                segments.append(contentsOf: pattern)
            }
            return WorkoutDefinition(id: input.id, name: input.name, shortName: input.shortName,
                                     format: input.format, team: input.team,
                                     timeCapSeconds: input.timeCapSeconds,
                                     healthKitActivity: input.healthKitActivity,
                                     segments: segments, intervalSeconds: nil,
                                     roundSize: input.roundSize)
        }
    }

    struct Fixture: Decodable {
        let cases: [Case]
    }

    private func loadCases() throws -> [Case] {
        let data: Data = try fixtureData("amrap_expand_cases", "json")
        return try JSONDecoder().decode(Fixture.self, from: data).cases
    }

    func testFixtureCases() throws {
        let cases: [Case] = try loadCases()
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for c in cases {
            let before: WorkoutDefinition = c.definition
            let after: WorkoutDefinition = before.expandedForAmrap()
            if c.unchanged {
                XCTAssertEqual(after, before, c.name)
                continue
            }
            XCTAssertEqual(after.segments.count, c.segmentCount, c.name)
            XCTAssertEqual(after.roundSize, c.roundSize, c.name)
            guard let r = c.roundSize, let start = c.blockStart else {
                XCTFail("missing roundSize/blockStart: \(c.name)")
                continue
            }
            let n: Int = before.segments.count
            XCTAssertEqual(Array(after.segments.prefix(n)), before.segments, c.name)
            if after.segments.count > n {
                for i in n..<after.segments.count {
                    XCTAssertEqual(after.segments[i], before.segments[start + (i - n) % r], "\(c.name) \(i)")
                }
            }
            XCTAssertEqual(after.id, before.id, c.name)
            XCTAssertEqual(after.timeCapSeconds, before.timeCapSeconds, c.name)
        }
    }

    func testIdempotent() throws {
        for c in try loadCases() {
            let once: WorkoutDefinition = c.definition.expandedForAmrap()
            XCTAssertEqual(once.expandedForAmrap(), once, c.name)
        }
    }

    /// The #138 scenario: six Crown advances finished a one-pass AMRAP; expanded, it moves on to
    /// round 2 and only the cap (or End) finishes it.
    func testOnePassAmrapKeepsGoingAfterTheLastListedPart() throws {
        let cases: [Case] = try loadCases()
        let d: WorkoutDefinition = cases[0].definition.expandedForAmrap()
        var p = WorkoutProgress(definition: d)
        let t0: Double = 1_800_000_000
        p.start(at: t0)
        for k in 1...6 {
            XCTAssertTrue(p.advance(at: t0 + Double(k * 100), source: .crown))
        }
        XCTAssertFalse(p.isFinished)
        XCTAssertEqual(p.currentIndex, 6)
        XCTAssertTrue(p.finish(at: t0 + 1440, source: .auto))
        XCTAssertTrue(p.isFinished)
    }

    /// The crash checkpoint stores WorkoutProgress, which carries the definition: a restored
    /// workout keeps the expanded list (and expanding it again changes nothing).
    func testCheckpointKeepsTheExpandedDefinition() throws {
        let cases: [Case] = try loadCases()
        let d: WorkoutDefinition = cases[0].definition.expandedForAmrap()
        var p = WorkoutProgress(definition: d)
        let t0: Double = 1_800_000_000
        p.start(at: t0)
        XCTAssertTrue(p.advance(at: t0 + 100, source: .crown))
        let data: Data = try JSONEncoder().encode(p)
        let restored: WorkoutProgress = try JSONDecoder().decode(WorkoutProgress.self, from: data)
        XCTAssertEqual(restored, p)
        XCTAssertEqual(restored.definition.segments.count, d.segments.count)
        XCTAssertEqual(restored.definition.expandedForAmrap(), restored.definition)
    }

    func testBuiltInsOnlyAmrapsChange() {
        for d in WorkoutLibrary.all {
            let after: WorkoutDefinition = d.expandedForAmrap()
            if d.format != .amrap {
                XCTAssertEqual(after, d, d.id)
            } else {
                XCTAssertGreaterThanOrEqual(after.segments.count, d.segments.count, d.id)
                XCTAssertEqual(Array(after.segments.prefix(d.segments.count)), d.segments, d.id)
            }
        }
    }
}
