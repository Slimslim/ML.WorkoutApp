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

    // MARK: - Synthetic sets (code review 2026-10-29), same as tools/tests/test_reps.py

    /// Arms hanging (ĝ = -x); bar pulled `rom` m in `up` s (half-sine velocity), held 0.4 s,
    /// lowered in `down` s, paused on the floor; one rep every `period` s.
    private func syntheticSet(reps: Int, period: Double, rom: Double = 0.6, up: Double = 1.0,
                              down: Double = 1.0, lead: Double = 8.0, tail: Double = 10.0) -> [MotionSample] {
        let fs = 200.0
        let n = Int(((lead + Double(reps) * period + tail) * fs).rounded(.down))
        var t = [Double](repeating: 0, count: n)
        var v = [Double](repeating: 0, count: n)
        let vu = Double.pi * rom / (2 * up)
        let vd = Double.pi * rom / (2 * down)
        for i in 0..<n {
            t[i] = Double(i) / fs
            for k in 0..<reps {
                let tr = t[i] - lead - Double(k) * period
                if tr >= 0 && tr < up {
                    v[i] += vu * sin(Double.pi * tr / up)
                }
                let td = tr - (up + 0.4)
                if td >= 0 && td < down {
                    v[i] -= vd * sin(Double.pi * td / down)
                }
            }
        }
        var out: [MotionSample] = []
        out.reserveCapacity(n)
        let g = Vec3(-1, 0, 0)
        for i in 0..<n {
            let lo = max(0, i - 1)
            let hi = min(n - 1, i + 1)
            let a = (v[hi] - v[lo]) / (t[hi] - t[lo])
            out.append(MotionSample(t: t[i], attitude: Quat.identity, userAccel: g * (a / standardGravity),
                                    gravity: g, rotationRate: Vec3.zero))
        }
        return out
    }

    private func replay(_ samples: [MotionSample], flushAfterSet: Bool = false)
        -> (sets: [[Rep]], live: [Int], duplicates: Int, firstStart: Double?) {
        var tracker = SetTracker()
        var sets: [[Rep]] = []
        var live: [Int] = []
        var duplicates = 0
        var firstStart: Double?
        func record(_ e: SetEvent) {
            switch e {
            case .repCounted(let n): live.append(n)
            case .setEnded(let start, _, _, _, let reps):
                sets.append(reps)
                if firstStart == nil { firstStart = start }
            }
        }
        var k = 0
        while k < samples.count {
            let end = min(samples.count, k + 200)
            let events = tracker.process(Array(samples[k..<end]))
            events.forEach(record)
            if flushAfterSet && events.contains(where: { if case .setEnded = $0 { return true } else { return false } }) {
                if tracker.flush() != nil { duplicates += 1 }
            }
            k = end
        }
        if let last = tracker.flush() { record(last) }
        return (sets, live, duplicates, firstStart)
    }

    func testSyntheticFastSetIsOneSet() {
        let r = replay(syntheticSet(reps: 6, period: 2.5))
        XCTAssertEqual(r.sets.map { $0.count }, [6])
        XCTAssertEqual(r.live, Array(1...6))
    }

    func testSlowDeadStopSetIsNotSplit() {
        let r = replay(syntheticSet(reps: 5, period: 5.0, up: 1.6, down: 1.4))
        XCTAssertEqual(r.sets.map { $0.count }, [5])
        XCTAssertEqual(r.live, Array(1...5))
    }

    func testFlushRightAfterSetEndDoesNotDuplicate() {
        let r = replay(syntheticSet(reps: 6, period: 2.5), flushAfterSet: true)
        XCTAssertEqual(r.sets.map { $0.count }, [6])
        XCTAssertEqual(r.duplicates, 0)
    }

    func testLongSetKeepsCounting() {
        let r = replay(syntheticSet(reps: 25, period: 4.5))
        XCTAssertEqual(r.sets.map { $0.count }, [25])
        XCTAssertEqual(r.live, Array(1...25))
        XCTAssertLessThan(r.firstStart ?? 99, 8.0)
    }
}
