import XCTest
@testable import BarPathKit

final class PhoneDeviceContextTests: XCTestCase {
    private let info: [String: String] = ["model": "iPhone16,1", "os": "18.1", "build": "16", "hrZoneSource": "age"]

    func testAddsEntryAndKeepsOtherKeys() {
        let context: [String: Any] = ["type": "selectWorkout", "liftSelection": ["lift": "snatch"], "weightUnit": "kg"]
        let out = PhoneDeviceContext.merged(context: context, info: info, now: Date(timeIntervalSince1970: 1000), force: false)
        XCTAssertNotNil(out)
        XCTAssertEqual(out?["type"] as? String, "selectWorkout")
        XCTAssertEqual(out?["weightUnit"] as? String, "kg")
        XCTAssertNotNil(out?["liftSelection"])
        let entry = out?[PhoneDeviceContext.key] as? [String: String]
        XCTAssertEqual(entry?["model"], "iPhone16,1")
        XCTAssertEqual(entry?["build"], "16")
        XCTAssertEqual(entry?["hrZoneSource"], "age")
        XCTAssertEqual(entry?[PhoneDeviceContext.sentAtField], "1000000")
    }

    /// #79: the phone's own context already holds the same values (sent before the watch app was
    /// reinstalled). A forced send (activation, watch-state change) must still go out, changed.
    func testForceSendsEvenWhenUnchanged() {
        var stored: [String: String] = info
        stored[PhoneDeviceContext.sentAtField] = "1000000"
        let context: [String: Any] = [PhoneDeviceContext.key: stored, "weightUnit": "lb"]
        let out = PhoneDeviceContext.merged(context: context, info: info, now: Date(timeIntervalSince1970: 2000), force: true)
        XCTAssertNotNil(out)
        let entry = out?[PhoneDeviceContext.key] as? [String: String]
        XCTAssertEqual(entry?[PhoneDeviceContext.sentAtField], "2000000")
        XCTAssertEqual(out?["weightUnit"] as? String, "lb")
    }

    func testUnforcedSkipsWhenSameValuesIgnoringSentAt() {
        var stored: [String: String] = info
        stored[PhoneDeviceContext.sentAtField] = "1000000"
        let context: [String: Any] = [PhoneDeviceContext.key: stored]
        XCTAssertNil(PhoneDeviceContext.merged(context: context, info: info, now: Date(timeIntervalSince1970: 2000), force: false))
        // Also skips the entry sendWorkout writes (no sentAt).
        XCTAssertNil(PhoneDeviceContext.merged(context: [PhoneDeviceContext.key: info], info: info, now: Date(), force: false))
    }

    func testUnforcedSendsWhenValuesChange() {
        let context: [String: Any] = [PhoneDeviceContext.key: info]
        var changed: [String: String] = info
        changed["hrZoneSource"] = "custom"
        let out = PhoneDeviceContext.merged(context: context, info: changed, now: Date(), force: false)
        XCTAssertEqual((out?[PhoneDeviceContext.key] as? [String: String])?["hrZoneSource"], "custom")
    }

    /// #82: a forced merge (activation, watch-state change, app becomes active) must leave the
    /// other areas' keys exactly as they were: the `selectWorkout` payload and `liftSelection`.
    func testForcedMergeKeepsSelectWorkoutAndLiftSelectionUnchanged() {
        let definition = Data([0x7B, 0x22, 0x61, 0x22, 0x3A, 0x31, 0x7D])
        let lift: [String: Any] = LiftSelection(liftType: .snatch, loadLb: 135, sentAt: 1234.5).dictionary
        var stored: [String: String] = info
        stored[PhoneDeviceContext.sentAtField] = "1000000"
        let context: [String: Any] = [
            "type": "selectWorkout",
            "workoutDefinition": definition,
            "sentAt": 999.25,
            LiftSelection.contextKey: lift,
            "weightUnit": "kg",
            PhoneDeviceContext.key: stored
        ]
        guard let out = PhoneDeviceContext.merged(context: context, info: info,
                                                  now: Date(timeIntervalSince1970: 2000), force: true) else {
            XCTFail("a forced merge must send")
            return
        }
        XCTAssertEqual(Set(out.keys), Set(context.keys))
        XCTAssertEqual(out["type"] as? String, "selectWorkout")
        XCTAssertEqual(out["workoutDefinition"] as? Data, definition)
        XCTAssertEqual(out["sentAt"] as? Double, 999.25)
        XCTAssertEqual(out["weightUnit"] as? String, "kg")
        let outLift = out[LiftSelection.contextKey] as? [String: Any]
        XCTAssertEqual(outLift?["liftType"] as? String, LiftType.snatch.rawValue)
        XCTAssertEqual(outLift?["loadLb"] as? Double, 135)
        XCTAssertEqual(outLift?["sentAt"] as? Double, 1234.5)
        XCTAssertEqual(outLift?.count, lift.count)
        XCTAssertEqual((out[PhoneDeviceContext.key] as? [String: String])?[PhoneDeviceContext.sentAtField], "2000000")
    }
}
