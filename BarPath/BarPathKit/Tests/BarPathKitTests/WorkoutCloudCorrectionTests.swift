import Foundation
import XCTest
@testable import BarPathKit

/// Story W17: which cloud copy of a result replaces the phone's copy.
final class WorkoutCloudCorrectionTests: XCTestCase {

    private func result(id: UUID, editedAt: Date?) -> WorkoutResult {
        let start: Date = Date(timeIntervalSince1970: 1_793_846_845)
        let seg: SegmentResult = SegmentResult(index: 0, kind: .station, movement: "pullUps",
                                               title: "Strict Pull-ups 2",
                                               start: start.timeIntervalSince1970,
                                               end: start.timeIntervalSince1970 + 10, duration: 10)
        return WorkoutResult(id: id, definition: WorkoutLibrary.quickTest, startDate: start,
                             finishDate: start.addingTimeInterval(10), endDate: start.addingTimeInterval(10),
                             totalSeconds: 10, segments: [seg], events: [], editedAt: editedAt)
    }

    private let id: UUID = UUID(uuidString: "0556F540-5796-49A7-806E-324F7B241F02")!
    private let t1: Date = Date(timeIntervalSince1970: 1_793_850_000)
    private let t2: Date = Date(timeIntervalSince1970: 1_793_860_000)

    func testCloudEditReplacesUneditedPhoneCopy() {
        XCTAssertTrue(WorkoutCloudCorrection.shouldReplace(local: result(id: id, editedAt: nil),
                                                           with: result(id: id, editedAt: t1)))
    }

    func testLaterCloudEditReplacesEarlierPhoneEdit() {
        XCTAssertTrue(WorkoutCloudCorrection.shouldReplace(local: result(id: id, editedAt: t1),
                                                           with: result(id: id, editedAt: t2)))
    }

    func testLaterPhoneEditIsKept() {
        XCTAssertFalse(WorkoutCloudCorrection.shouldReplace(local: result(id: id, editedAt: t2),
                                                            with: result(id: id, editedAt: t1)))
    }

    func testSameEditIsNotTakenAgain() {
        XCTAssertFalse(WorkoutCloudCorrection.shouldReplace(local: result(id: id, editedAt: t1),
                                                            with: result(id: id, editedAt: t1)))
    }

    func testUneditedCloudCopyIsIgnored() {
        XCTAssertFalse(WorkoutCloudCorrection.shouldReplace(local: result(id: id, editedAt: nil),
                                                            with: result(id: id, editedAt: nil)))
    }

    func testDifferentResultIsIgnored() {
        XCTAssertFalse(WorkoutCloudCorrection.shouldReplace(local: result(id: id, editedAt: nil),
                                                            with: result(id: UUID(), editedAt: t1)))
    }

    func testFileNames() {
        XCTAssertEqual(WorkoutCloudCorrection.resultId(fileName: "0556F540-5796-49A7-806E-324F7B241F02.json"), id)
        XCTAssertNil(WorkoutCloudCorrection.resultId(fileName: "0556F540-5796-49A7-806E-324F7B241F02.original.json"))
        XCTAssertNil(WorkoutCloudCorrection.resultId(fileName: "session-0556F540.csv"))
        XCTAssertNil(WorkoutCloudCorrection.resultId(fileName: "notes.json"))
    }

    /// A corrected file carries keys this build does not know yet (e.g. `rx`, W19): it still
    /// decodes, and its editedAt (fractional seconds) is read.
    func testCorrectionWithUnknownKeysDecodes() throws {
        var r: WorkoutResult = result(id: id, editedAt: t1)
        r.totalSeconds = 12
        let data: Data = try r.encoded()
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("not an object")
        }
        object["rx"] = true
        object["editedAt"] = "2026-11-05T05:12:10.000Z"
        let patched: Data = try JSONSerialization.data(withJSONObject: object)
        let decoded: WorkoutResult = try WorkoutResult.decode(from: patched)
        XCTAssertEqual(decoded.id, id)
        XCTAssertNotNil(decoded.editedAt)
        XCTAssertTrue(WorkoutCloudCorrection.shouldReplace(local: result(id: id, editedAt: nil), with: decoded))
    }
}
