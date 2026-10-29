import XCTest
@testable import BarPathKit

final class RepCounterTests: XCTestCase {

    func testMovingAverageEdges() {
        let x: [Double] = [0, 1, 2, 3, 4]
        let m = RepCounter.movingAverage(x, width: 3)
        let expected: [Double] = [0.5, 1, 2, 3, 3.5]
        for (a, b) in zip(m, expected) {
            XCTAssertEqual(a, b, accuracy: 1e-12)
        }
        XCTAssertEqual(RepCounter.movingAverage(x, width: 1), x)
    }

    /// 300 lb × 6 deadlift set from 2026-10-29 (filmed, 6 reps); expectations from reps.py.
    func testRealDeadliftSetMatchesPython() throws {
        let input = try jsonObject(try fixtureData("real_deadlift_set", "json"))
        let expected = try jsonObject(try fixtureData("real_deadlift_set.python", "json"))
        func col(_ k: String) -> [Double] {
            return (input[k] as? [Any] ?? []).compactMap { number($0) }
        }
        var m = MotionSeries()
        m.t = col("t")
        m.ax = col("ax"); m.ay = col("ay"); m.az = col("az")
        m.gx = col("gx"); m.gy = col("gy"); m.gz = col("gz")
        let zeros = [Double](repeating: 0.0, count: m.t.count)
        m.qw = [Double](repeating: 1.0, count: m.t.count)
        m.qx = zeros; m.qy = zeros; m.qz = zeros
        m.rx = zeros; m.ry = zeros; m.rz = zeros

        try checkSetTracker(m.samples, expectedReps: Int(number(expected["count"]) ?? -1))

        let a = RepCounter.count(m)
        let tol = number(expected["tolerance"]) ?? 0.002
        XCTAssertEqual(Double(a.count), number(expected["count"]) ?? -1, "reps \(a.reps)")
        XCTAssertEqual(a.velocityLoss, number(expected["velocityLoss"]) ?? -1, accuracy: tol)
        let reps = expected["reps"] as? [[String: Any]] ?? []
        for (got, want) in zip(a.reps, reps) {
            XCTAssertEqual(got.start, number(want["start"]) ?? -1, accuracy: tol)
            XCTAssertEqual(got.end, number(want["end"]) ?? -1, accuracy: tol)
            XCTAssertEqual(got.range, number(want["range"]) ?? -1, accuracy: tol)
            XCTAssertEqual(got.meanVelocity, number(want["meanVelocity"]) ?? -1, accuracy: tol)
            XCTAssertEqual(got.peakVelocity, number(want["peakVelocity"]) ?? -1, accuracy: tol)
        }
    }

    /// Replays the set in 1 s batches like the watch: one set, live count 1, 2, ... in order.
    private func checkSetTracker(_ samples: [MotionSample], expectedReps: Int) throws {
        var tracker = SetTracker()
        var events: [SetEvent] = []
        var k = 0
        while k < samples.count {
            let end = min(samples.count, k + 200)
            events += tracker.process(Array(samples[k..<end]))
            k = end
        }
        if let last = tracker.flush() {
            events.append(last)
        }
        var live: [Int] = []
        var sets: [[Rep]] = []
        for e in events {
            switch e {
            case .repCounted(let n): live.append(n)
            case .setEnded(_, _, _, _, let reps): sets.append(reps)
            }
        }
        XCTAssertEqual(sets.count, 1, "events \(events)")
        XCTAssertEqual(sets.first?.count, expectedReps)
        XCTAssertEqual(live, Array(1...expectedReps))
    }
}
