import XCTest
@testable import BarPathKit

final class UploadRetryTests: XCTestCase {
    private func body(_ text: String) -> Data { Data(text.utf8) }

    func testSuccessIsUploaded() {
        XCTAssertEqual(UploadOutcome.classify(status: 200, body: Data(), failed: false), .uploaded)
        XCTAssertEqual(UploadOutcome.classify(status: 201, body: Data(), failed: false), .uploaded)
    }

    func testTransportErrorIsRetriedLater() {
        XCTAssertEqual(UploadOutcome.classify(status: 0, body: Data(), failed: true), .retryLater)
        // Even a status-looking response is ignored when the task failed.
        XCTAssertEqual(UploadOutcome.classify(status: 401, body: Data(), failed: true), .retryLater)
    }

    func testTooLarge() {
        XCTAssertEqual(UploadOutcome.classify(status: 413, body: Data(), failed: false), .tooLarge)
        let text = #"{"statusCode":"413","error":"Payload too large","message":"The object exceeded the maximum allowed size"}"#
        XCTAssertEqual(UploadOutcome.classify(status: 400, body: body(text), failed: false), .tooLarge)
        XCTAssertTrue(UploadOutcome.isTooLarge(status: 400, body: body(text)))
        XCTAssertFalse(UploadOutcome.isTooLarge(status: 400, body: Data()))
    }

    func testExpiredTokenIsAuthRejected() {
        XCTAssertEqual(UploadOutcome.classify(status: 401, body: Data(), failed: false), .authRejected)
        XCTAssertEqual(UploadOutcome.classify(status: 403, body: Data(), failed: false), .authRejected)
        let jwt = #"{"statusCode":"403","error":"Unauthorized","message":"jwt expired"}"#
        XCTAssertEqual(UploadOutcome.classify(status: 400, body: body(jwt), failed: false), .authRejected)
    }

    func testOtherErrorsAreRetriedLater() {
        XCTAssertEqual(UploadOutcome.classify(status: 500, body: Data(), failed: false), .retryLater)
        XCTAssertEqual(UploadOutcome.classify(status: 503, body: body("busy"), failed: false), .retryLater)
        XCTAssertEqual(UploadOutcome.classify(status: 400, body: Data(), failed: false), .retryLater)
    }

    func testRetryBudgetIsPerFileVersion() {
        var budget = UploadRetryBudget(maxImmediateRetries: 2)
        let a = UploadRetryBudget.key(path: "Workouts/a.json", version: "10-1")
        let b = UploadRetryBudget.key(path: "Workouts/a.json", version: "12-2")
        XCTAssertTrue(budget.take(a))
        XCTAssertTrue(budget.take(a))
        XCTAssertFalse(budget.take(a))
        XCTAssertTrue(budget.take(b))
        budget.reset(a)
        XCTAssertTrue(budget.take(a))
    }

    func testRefreshOnlyWhenSomethingIsWaiting() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(UploadRefreshPlan.nextRefresh(waiting: 0, now: now))
        XCTAssertEqual(UploadRefreshPlan.nextRefresh(waiting: 3, now: now),
                       now.addingTimeInterval(15 * 60))
    }
}
