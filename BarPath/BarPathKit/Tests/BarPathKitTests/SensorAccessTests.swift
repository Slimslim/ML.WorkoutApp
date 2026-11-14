import Foundation
import XCTest
@testable import BarPathKit

/// W23: the "Heart rate is off" / "Motion is off" banner rule.
final class SensorAccessTests: XCTestCase {

    private func result(totalSeconds: Double, start: Double = 1_000_000,
                        avg: Double? = nil, series: HeartRateSeries? = nil,
                        segmentAvg: Double? = nil) -> WorkoutResult {
        var segments: [SegmentResult] = []
        if let s = segmentAvg {
            segments.append(SegmentResult(index: 0, kind: .run, movement: "run", title: "Run",
                                          start: start, end: start + totalSeconds, duration: totalSeconds,
                                          heartRateAvg: s))
        }
        return WorkoutResult(definition: WorkoutLibrary.quickTest,
                             startDate: Date(timeIntervalSince1970: start),
                             finishDate: Date(timeIntervalSince1970: start + totalSeconds),
                             endDate: Date(timeIntervalSince1970: start + totalSeconds),
                             totalSeconds: totalSeconds, segments: segments, events: [],
                             heartRateAvg: avg, heartRateSeries: series)
    }

    func testSessionFlag() {
        XCTAssertEqual(SensorAccess.receivedHeartRate(sampleCount: 1, sessionSeconds: 5), true)
        XCTAssertEqual(SensorAccess.receivedHeartRate(sampleCount: 0, sessionSeconds: 120), false)
        XCTAssertEqual(SensorAccess.receivedHeartRate(sampleCount: 0, sessionSeconds: 600), false)
        XCTAssertNil(SensorAccess.receivedHeartRate(sampleCount: 0, sessionSeconds: 119.9))
    }

    func testKeyMatchesPractice() {
        XCTAssertEqual(SensorAccess.receivedHeartRateKey, "lastSessionReceivedHeartRate.v1")
    }

    func testResultFlag() {
        XCTAssertEqual(SensorAccess.receivedHeartRate(result: result(totalSeconds: 600)), false)
        XCTAssertEqual(SensorAccess.receivedHeartRate(result: result(totalSeconds: 600, avg: 140)), true)
        XCTAssertEqual(SensorAccess.receivedHeartRate(result: result(totalSeconds: 600, segmentAvg: 150)), true)
        let series = HeartRateSeries(start: 0, interval: 5, bpm: [nil, 120, nil])
        XCTAssertEqual(SensorAccess.receivedHeartRate(result: result(totalSeconds: 600, series: series)), true)
        let empty = HeartRateSeries(start: 0, interval: 5, bpm: [nil, nil])
        XCTAssertEqual(SensorAccess.receivedHeartRate(result: result(totalSeconds: 600, series: empty)), false)
        XCTAssertNil(SensorAccess.receivedHeartRate(result: result(totalSeconds: 60)))
    }

    func testLastResultSkipsShortOnes() {
        // Newest first: a 1-minute test without HR says nothing, the 10-minute one with HR decides.
        let list = [result(totalSeconds: 60), result(totalSeconds: 600, avg: 130), result(totalSeconds: 600)]
        XCTAssertEqual(SensorAccess.lastReceivedHeartRate(results: list), true)
        XCTAssertEqual(SensorAccess.lastReceivedHeartRate(results: [result(totalSeconds: 600)]), false)
        XCTAssertNil(SensorAccess.lastReceivedHeartRate(results: []))
        XCTAssertNil(SensorAccess.lastReceivedHeartRate(results: [result(totalSeconds: 30)]))
    }

    func testBanner() {
        XCTAssertNil(SensorAccess.banner(lastSessionReceivedHeartRate: nil, motionDenied: false))
        XCTAssertNil(SensorAccess.banner(lastSessionReceivedHeartRate: true, motionDenied: false))
        XCTAssertEqual(SensorAccess.banner(lastSessionReceivedHeartRate: false, motionDenied: false), .heartRate)
        XCTAssertEqual(SensorAccess.banner(lastSessionReceivedHeartRate: nil, motionDenied: true), .motion)
        XCTAssertEqual(SensorAccess.banner(lastSessionReceivedHeartRate: true, motionDenied: true), .motion)
        XCTAssertEqual(SensorAccess.banner(lastSessionReceivedHeartRate: false, motionDenied: true), .heartRateAndMotion)
    }
}
