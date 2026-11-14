import Foundation
import XCTest
@testable import BarPathKit

/// The pieces of the watch's crash checkpoint that live in the kit: WorkoutProgress and
/// TimedValue survive JSON, and a progress that was cut short (no finish) turns into the
/// segments an early End would give.
final class WorkoutCheckpointPayloadTests: XCTestCase {
    static let t0: Double = 1_800_000_000

    private func cutShortProgress() -> WorkoutProgress {
        let t0: Double = WorkoutCheckpointPayloadTests.t0
        var p = WorkoutProgress(definition: WorkoutLibrary.helen)
        p.start(at: t0)
        XCTAssertTrue(p.advance(at: t0 + 100, source: .crown))
        XCTAssertTrue(p.advance(at: t0 + 230, source: .crown))
        return p
    }

    func testProgressAndHeartRatesRoundTripThroughJSON() throws {
        let p: WorkoutProgress = cutShortProgress()
        let hr: [TimedValue] = [TimedValue(t: WorkoutCheckpointPayloadTests.t0 + 5, value: 120),
                                TimedValue(t: WorkoutCheckpointPayloadTests.t0 + 10, value: 128)]
        let encoder = JSONEncoder()
        let decodedProgress: WorkoutProgress = try JSONDecoder().decode(WorkoutProgress.self,
                                                                         from: try encoder.encode(p))
        let decodedHR: [TimedValue] = try JSONDecoder().decode([TimedValue].self, from: try encoder.encode(hr))
        XCTAssertEqual(decodedProgress, p)
        XCTAssertEqual(decodedHR, hr)
        XCTAssertTrue(decodedProgress.isStarted)
        XCTAssertFalse(decodedProgress.isFinished)
    }

    func testRecoveredProgressWithoutFinishGivesSegmentsUpToTheEnd() throws {
        let t0: Double = WorkoutCheckpointPayloadTests.t0
        let saved: WorkoutProgress = cutShortProgress()
        var recovered: WorkoutProgress = try JSONDecoder().decode(WorkoutProgress.self,
                                                                  from: try JSONEncoder().encode(saved))
        let endT: Double = t0 + 300
        recovered.recordEnd(at: endT)
        XCTAssertNil(recovered.finishTime)
        let segments: [SegmentResult] = SplitStats.compute(progress: recovered, now: endT,
                                                           heartRates: [], pedometer: [])
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].start, t0, accuracy: 0.001)
        XCTAssertEqual(segments[2].start, t0 + 230, accuracy: 0.001)
        XCTAssertEqual(segments[2].end, endT, accuracy: 0.001)
        XCTAssertEqual(segments[2].duration, 70, accuracy: 0.001)
    }
}
