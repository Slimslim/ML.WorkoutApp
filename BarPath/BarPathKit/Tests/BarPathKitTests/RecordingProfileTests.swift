import XCTest
@testable import BarPathKit

final class RecordingProfileTests: XCTestCase {

    private func segments(_ raw: [[String: Any]]) throws -> [WorkoutSegment] {
        var out: [WorkoutSegment] = []
        for s in raw {
            let kindText: String = try XCTUnwrap(s["kind"] as? String)
            let kind: SegmentKind = try XCTUnwrap(SegmentKind(rawValue: kindText))
            let load: SegmentLoad? = (s["load"] as? Bool) == true ? SegmentLoad(20, .lb) : nil
            out.append(WorkoutSegment(kind: kind,
                                      movement: try XCTUnwrap(s["movement"] as? String),
                                      name: try XCTUnwrap(s["name"] as? String),
                                      target: nil, load: load))
        }
        return out
    }

    private func definition(_ segs: [WorkoutSegment]) -> WorkoutDefinition {
        return WorkoutDefinition(id: "t", name: "T", shortName: "T", format: .forTime, team: .solo,
                                 timeCapSeconds: nil, healthKitActivity: "crossTraining", segments: segs)
    }

    private func fixture() throws -> [String: Any] {
        let data: Data = try fixtureData("recording_profile_cases", "json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testSharedCases() throws {
        let cases = try XCTUnwrap(try fixture()["cases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 60)
        for c in cases {
            let name: String = c["name"] as? String ?? ""
            let segs = try segments(try XCTUnwrap(c["segments"] as? [[String: Any]]))
            let expected: String = c["profile"] as? String ?? ""
            XCTAssertEqual(RecordingProfile.profile(for: definition(segs)).rawValue, expected, name)
        }
    }

    func testBuiltInsAndSeedsArePinned() throws {
        let library = try XCTUnwrap(try fixture()["library"] as? [[String: Any]])
        var builtInIds: Set<String> = []
        for e in library {
            let id: String = e["id"] as? String ?? ""
            let expected: String = e["profile"] as? String ?? ""
            if (e["source"] as? String) == "builtin" {
                builtInIds.insert(id)
                let d = try XCTUnwrap(WorkoutLibrary.definition(id: id), id)
                XCTAssertEqual(RecordingProfile.profile(for: d).rawValue, expected, id)
            } else {
                let segs = try segments(try XCTUnwrap(e["segments"] as? [[String: Any]]))
                XCTAssertEqual(RecordingProfile.profile(for: definition(segs)).rawValue, expected, id)
            }
        }
        XCTAssertEqual(builtInIds, Set(WorkoutLibrary.known.map { (d: WorkoutDefinition) -> String in d.id }))
        XCTAssertEqual(RecordingProfile.profile(for: WorkoutLibrary.free), .standard)
    }

    func testWordsAndRates() {
        XCTAssertEqual(RecordingProfile.words("powerCleanAndJerk"), ["power", "clean", "and", "jerk"])
        XCTAssertEqual(RecordingProfile.words("Bent-over row"), ["bent", "over", "row"])
        XCTAssertEqual(RecordingProfile.words("DB C&J"), ["db", "c", "j"])
        XCTAssertEqual(RecordingProfile.high.sampleRateHz, 200)
        XCTAssertEqual(RecordingProfile.standard.sampleRateHz, 100)
    }
}
