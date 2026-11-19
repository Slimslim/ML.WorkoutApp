import Foundation
import XCTest
@testable import BarPathKit

/// ResultInsights (docs/RESULTS_INSIGHTS.md, W47) against the Python reference
/// (tools/barpath/result_insights.py). Fixtures/result_insights_cases.json is written by
/// tools/tests/result_insight_cases.py: invented workouts, each with the Python output.
final class ResultInsightsTests: XCTestCase {

    private func loadCases() throws -> [[String: Any]] {
        let url = try XCTUnwrap(fixtureURL("result_insights_cases", "json"), "result_insights_cases.json missing")
        let data: Data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    func testParityWithPython() throws {
        let cases = try loadCases()
        XCTAssertEqual(cases.count, 13)
        for c in cases {
            let name: String = c["name"] as? String ?? "?"
            let raw = try XCTUnwrap(c["result"] as? [String: Any], name)
            let data: Data = try JSONSerialization.data(withJSONObject: raw, options: [])
            let result: WorkoutResult = try WorkoutResult.decode(from: data)
            let expectedRaw = try XCTUnwrap(c["expected"] as? [[String: Any]], name)
            var expected: [ResultInsight] = []
            for e in expectedRaw {
                expected.append(ResultInsight(id: try XCTUnwrap(e["id"] as? String, name),
                                              text: try XCTUnwrap(e["text"] as? String, name),
                                              isCue: try XCTUnwrap(e["isCue"] as? Bool, name)))
            }
            let got: [ResultInsight] = ResultInsights.insights(result: result, definition: result.definition)
            XCTAssertEqual(got, expected, name)
        }
    }

    func testAmrapDriftTexts() throws {
        let cases = try loadCases()
        let c = try XCTUnwrap(cases.first(where: { ($0["name"] as? String) == "amrap_bike_drift" }))
        let data: Data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(c["result"]), options: [])
        let result: WorkoutResult = try WorkoutResult.decode(from: data)
        let got: [ResultInsight] = ResultInsights.insights(result: result, definition: result.definition)
        XCTAssertEqual(got.map({ $0.id }), ["A1", "A3", "A2", "CUE"])
        XCTAssertEqual(got[0].text, "Bike: 1:29 in round 1, then 1:48-1:51 (+23 %), 1:22 in total.")
        XCTAssertEqual(got[3], ResultInsight(id: "CUE", text: "Next time: hold the bike nearer 1:30.", isCue: true))
    }

    func testLimitsAndNeverShownWords() throws {
        let banned: [String] = ["pace", "speed", "calorie", "effort", "zone", "heart", "bpm", "fatigue", "tired",
                                "because"]
        for c in try loadCases() {
            let name: String = c["name"] as? String ?? "?"
            let data: Data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(c["result"]), options: [])
            let result: WorkoutResult = try WorkoutResult.decode(from: data)
            let got: [ResultInsight] = ResultInsights.insights(result: result, definition: result.definition)
            XCTAssertLessThanOrEqual(got.filter({ !$0.isCue }).count, 3, name)
            XCTAssertLessThanOrEqual(got.filter({ $0.isCue }).count, 1, name)
            if got.contains(where: { $0.isCue }) {
                XCTAssertTrue(got.last?.isCue ?? false, name)
            }
            for i in got {
                let low: String = i.text.lowercased()
                for word in banned {
                    XCTAssertFalse(low.contains(word), "\(name): \(i.text)")
                }
            }
        }
    }

    func testFormatting() {
        XCTAssertEqual(ResultInsights.timeText(89.4), "1:29")
        XCTAssertEqual(ResultInsights.timeText(89.5), "1:30")
        XCTAssertEqual(ResultInsights.timeText(-38), "0:38")
        XCTAssertEqual(ResultInsights.timeText(3725), "1:02:05")
        XCTAssertEqual(ResultInsights.percentText(0.2), "+20 %")
        XCTAssertEqual(ResultInsights.percentText(-0.06), "-6 %")
        XCTAssertEqual(ResultInsights.percentText(0.001), "+0 %")
        XCTAssertEqual(ResultInsights.roundHalfAway(2.5), 3)
        XCTAssertEqual(ResultInsights.roundHalfAway(-2.5), -3)
    }

    func testEmptyResultIsSilent() {
        let d = WorkoutDefinition(id: "t", name: "T", shortName: "T", format: .forTime, team: .solo,
                                  timeCapSeconds: nil, healthKitActivity: "crossTraining",
                                  segments: [WorkoutSegment(kind: .station, movement: "row", name: "Row",
                                                            target: SegmentTarget(500, .meters))])
        let r = WorkoutResult(definition: d, startDate: Date(timeIntervalSince1970: 0), finishDate: nil,
                              endDate: Date(timeIntervalSince1970: 60), totalSeconds: 0, segments: [], events: [])
        XCTAssertEqual(ResultInsights.insights(result: r, definition: d), [])
    }
}
