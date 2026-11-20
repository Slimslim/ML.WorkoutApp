import XCTest
@testable import BarPathKit

/// E2 (0.18): the workout engine switch, phone → watch on the `workoutEngine` context key.
final class WorkoutEngineTests: XCTestCase {

    func testDefaults() {
        XCTAssertEqual(WorkoutEngine.contextKey, "workoutEngine")
        XCTAssertEqual(WorkoutEngine.watchDefault, .legacy)
        XCTAssertEqual(WorkoutEngine.phoneDefault, .v2)
        XCTAssertEqual(WorkoutEngine.v2.rawValue, "v2")
        XCTAssertEqual(WorkoutEngine.legacy.rawValue, "legacy")
    }

    /// The watch runs legacy until the phone has sent a known engine.
    func testResolveFallsBackToLegacy() {
        XCTAssertEqual(WorkoutEngine.resolve(nil), .legacy)
        XCTAssertEqual(WorkoutEngine.resolve(""), .legacy)
        XCTAssertEqual(WorkoutEngine.resolve("v3"), .legacy)
        XCTAssertEqual(WorkoutEngine.resolve(2), .legacy)
        XCTAssertEqual(WorkoutEngine.resolve("v2"), .v2)
        XCTAssertEqual(WorkoutEngine.resolve("legacy"), .legacy)
    }

    func testReceivedIgnoresMissingOrUnknown() {
        XCTAssertNil(WorkoutEngine.received(in: [:]))
        XCTAssertNil(WorkoutEngine.received(in: ["weightUnit": "kg"]))
        XCTAssertNil(WorkoutEngine.received(in: ["workoutEngine": "v3"]))
        XCTAssertNil(WorkoutEngine.received(in: ["workoutEngine": 1]))
        XCTAssertEqual(WorkoutEngine.received(in: ["workoutEngine": "v2"]), .v2)
        XCTAssertEqual(WorkoutEngine.received(in: ["workoutEngine": "legacy"]), .legacy)
    }

    /// The phone adds the key and keeps every other key in the shared context.
    func testMergeKeepsOtherKeysAndRoundTrips() {
        let context: [String: Any] = [
            "type": "selectWorkout",
            "sentAt": 1_800_000_000.0,
            "liftSelection": ["liftType": "deadlift"],
            "weightUnit": "lb",
            "phoneDevice": ["model": "iPhone"]
        ]
        for engine in WorkoutEngine.allCases {
            guard let merged = WorkoutEngine.merged(context: context, engine: engine) else {
                XCTFail("nothing to send for \(engine)")
                continue
            }
            XCTAssertEqual(merged.count, context.count + 1)
            XCTAssertEqual(merged["type"] as? String, "selectWorkout")
            XCTAssertEqual(merged["sentAt"] as? Double, 1_800_000_000.0)
            XCTAssertEqual((merged["liftSelection"] as? [String: String])?["liftType"], "deadlift")
            XCTAssertEqual(merged["weightUnit"] as? String, "lb")
            XCTAssertEqual((merged["phoneDevice"] as? [String: String])?["model"], "iPhone")
            // Round trip: what the watch reads back is what the phone sent.
            XCTAssertEqual(WorkoutEngine.received(in: merged), engine)
            XCTAssertEqual(WorkoutEngine.resolve(merged[WorkoutEngine.contextKey]), engine)
            // Already there: nothing to send.
            XCTAssertNil(WorkoutEngine.merged(context: merged, engine: engine))
        }
        // A change replaces the value, still keeping the rest.
        let v2 = WorkoutEngine.merged(context: context, engine: .v2) ?? [:]
        let back = WorkoutEngine.merged(context: v2, engine: .legacy) ?? [:]
        XCTAssertEqual(WorkoutEngine.received(in: back), .legacy)
        XCTAssertEqual(back.count, context.count + 1)
    }

    /// What a recording and a result call the engine (QA): new / classic.
    func testRecordNames() {
        XCTAssertEqual(WorkoutEngine.v2.recordName, "new")
        XCTAssertEqual(WorkoutEngine.legacy.recordName, "classic")
        XCTAssertEqual(WorkoutEngine.v2.headerPair, "engine=new")
        XCTAssertEqual(WorkoutEngine.legacy.headerPair, "engine=classic")
        for engine in WorkoutEngine.allCases {
            XCTAssertEqual(WorkoutEngine.fromRecordName(engine.recordName), engine)
        }
        XCTAssertNil(WorkoutEngine.fromRecordName(nil))
        XCTAssertNil(WorkoutEngine.fromRecordName("v2"))
    }

    /// The result records the engine; older results (no key) still decode, and nil is not written.
    func testResultFieldIsOptional() throws {
        let start: Date = Date(timeIntervalSince1970: 1_793_846_845)
        var result = WorkoutResult(definition: WorkoutLibrary.quickTest, startDate: start,
                                   finishDate: start.addingTimeInterval(10),
                                   endDate: start.addingTimeInterval(10),
                                   totalSeconds: 10, segments: [], events: [])
        XCTAssertNil(result.engine)
        let plain = try result.encoded()
        let plainText = String(data: plain, encoding: .utf8) ?? ""
        XCTAssertFalse(plainText.contains("\"engine\""))
        XCTAssertNil(try WorkoutResult.decode(from: plain).engine)

        result.engine = WorkoutEngine.v2.recordName
        let data = try result.encoded()
        let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        XCTAssertEqual(json?["engine"] as? String, "new")
        let tagged = try WorkoutResult.decode(from: data)
        XCTAssertEqual(tagged.engine, "new")
        XCTAssertEqual(WorkoutEngine.fromRecordName(tagged.engine), .v2)
        XCTAssertEqual(tagged, result)
    }
}
