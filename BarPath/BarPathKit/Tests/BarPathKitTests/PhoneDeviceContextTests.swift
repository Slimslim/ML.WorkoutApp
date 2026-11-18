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
}
