import XCTest
@testable import BarPathKit

/// #148: rest → Crown → next set. Parity with tools/tests/test_lift_cycle.py
/// (`lift_cycle_cases.json`, `rest_arm_cases.json`; invented signals, no real data).
final class LiftCycleTests: XCTestCase {

    /// A JSON boolean (Bool on Darwin, NSNumber or Bool on Linux).
    private func flag(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }

    func testCycleBasics() {
        var c = LiftCycle(startAt: 0)
        XCTAssertEqual(c.state, .armed)
        XCTAssertTrue(c.isListening)
        XCTAssertEqual(c.listeningFrom, 0)
        XCTAssertTrue(c.canShowEndPage)
        XCTAssertFalse(c.arm(at: 1))
        XCTAssertTrue(c.setStarted(at: 2))
        XCTAssertFalse(c.canShowEndPage)
        XCTAssertTrue(c.setEnded(at: 10))
        XCTAssertEqual(c.state, .resting)
        XCTAssertFalse(c.isListening)
        XCTAssertEqual(c.listeningFrom, Double.greatestFiniteMagnitude)
        XCTAssertFalse(c.setStarted(at: 12))
        XCTAssertEqual(c.state, .resting)
        XCTAssertTrue(c.arm(at: 100))
        XCTAssertEqual(c.lastRest ?? -1, 90, accuracy: 1e-9)
        XCTAssertEqual(c.listeningFrom, 100)
    }

    func testArmedTimeoutRule() {
        XCTAssertEqual(LiftCycle.armedTimeout, 180.0)
        var c = LiftCycle(startAt: 0)
        XCTAssertFalse(c.expireArmed(at: LiftCycle.armedTimeout - 0.1, busy: false))
        XCTAssertFalse(c.expireArmed(at: LiftCycle.armedTimeout + 5, busy: true))
        XCTAssertTrue(c.expireArmed(at: LiftCycle.armedTimeout, busy: false))
        XCTAssertEqual(c.state, .resting)
        XCTAssertEqual(c.since, 0)
        XCTAssertTrue(c.arm(at: 300))
        XCTAssertEqual(c.lastRest ?? -1, 300, accuracy: 1e-9)
        XCTAssertTrue(c.expireArmed(at: 480, busy: false))
        XCTAssertEqual(c.since, 0)
        XCTAssertFalse(c.expireArmed(at: 700, busy: false))
    }

    func testCycleCasesMatchPython() throws {
        XCTAssertNotNil(fixtureURL("lift_cycle_cases", "json"), "lift_cycle_cases.json missing")
        let fixture = try jsonObject(try fixtureData("lift_cycle_cases", "json"))
        let cases = fixture["cases"] as? [String: Any] ?? [:]
        XCTAssertEqual(cases.count, 5)
        for (name, value) in cases.sorted(by: { $0.key < $1.key }) {
            let c = value as? [String: Any] ?? [:]
            let ops = c["ops"] as? [[Any]] ?? []
            let expected = c["expected"] as? [[String: Any]] ?? []
            XCTAssertEqual(ops.count, expected.count, name)
            var cycle = LiftCycle(startAt: 0)
            for (op, want) in zip(ops, expected) {
                let kind = op.first as? String ?? ""
                let t = number(op.count > 1 ? op[1] : nil) ?? 0
                let ok: Bool
                switch kind {
                case "start":
                    cycle = LiftCycle(startAt: t)
                    ok = true
                case "arm": ok = cycle.arm(at: t)
                case "setStarted": ok = cycle.setStarted(at: t)
                case "setEnded": ok = cycle.setEnded(at: t)
                case "expire": ok = cycle.expireArmed(at: t, busy: flag(op.count > 2 ? op[2] : nil) ?? false)
                default:
                    XCTFail("unknown op \(kind)")
                    ok = false
                }
                let label = "\(name) \(kind) \(t)"
                XCTAssertEqual(ok, flag(want["ok"]), label)
                XCTAssertEqual(cycle.state.rawValue, want["state"] as? String, label)
                XCTAssertEqual(cycle.since, number(want["since"]) ?? -1, accuracy: 1e-9, label)
                XCTAssertEqual(cycle.armedAt, number(want["armedAt"]) ?? -1, accuracy: 1e-9, label)
                if let rest = number(want["lastRest"]) {
                    XCTAssertEqual(cycle.lastRest ?? -1, rest, accuracy: 1e-9, label)
                } else {
                    XCTAssertNil(cycle.lastRest, label)
                }
                XCTAssertEqual(cycle.isListening, flag(want["listening"]), label)
                XCTAssertEqual(cycle.canShowEndPage, flag(want["canShowEndPage"]), label)
            }
        }
    }

    // MARK: - The Crown gating the set tracker

    /// Same invented signal as `_signal` in tools/tests/test_lift_cycle.py. pulls: [t0, rom, up,
    /// down] (bar up, held 0.4 s, down); shakes: [t0, dur, rom, up] (a fast up/down wrist lobe
    /// with 5 Hz jitter: 1.0 g along the forearm, 0.8 g across). Arms hanging, ĝ = -x.
    private func signal(pulls: [[Double]], shakes: [[Double]], total: Double) -> [MotionSample] {
        let step = 1.0 / 200.0
        let n = Int((total / step).rounded(.up))
        var t = [Double](repeating: 0, count: n)
        var v = [Double](repeating: 0, count: n)
        for i in 0..<n {
            t[i] = Double(i) * step
        }
        func lobe(_ t0: Double, _ rom: Double, _ up: Double, _ down: Double) {
            let vu = Double.pi * rom / (2 * up)
            let vd = Double.pi * rom / (2 * down)
            for i in 0..<n {
                let tr = t[i] - t0
                if tr >= 0 && tr < up {
                    v[i] += vu * sin(Double.pi * tr / up)
                }
                let td = tr - (up + 0.4)
                if td >= 0 && td < down {
                    v[i] -= vd * sin(Double.pi * td / down)
                }
            }
        }
        for p in pulls where p.count == 4 {
            lobe(p[0], p[1], p[2], p[3])
        }
        for s in shakes where s.count == 4 {
            lobe(s[0], s[2], s[3], s[3])
        }
        var jx = [Double](repeating: 0, count: n)
        var jy = [Double](repeating: 0, count: n)
        for s in shakes where s.count == 4 {
            for i in 0..<n where t[i] >= s[0] && t[i] < s[0] + s[1] {
                let ph = 2 * Double.pi * 5.0 * (t[i] - s[0])
                jx[i] += -1.0 * sin(ph)
                jy[i] += 0.8 * sin(ph + 1.0)
            }
        }
        var out: [MotionSample] = []
        out.reserveCapacity(n)
        let g = Vec3(-1, 0, 0)
        for i in 0..<n {
            let lo = max(0, i - 1)
            let hi = min(n - 1, i + 1)
            let a = (v[hi] - v[lo]) / (t[hi] - t[lo])
            let ua = g * (a / standardGravity) + Vec3(jx[i], jy[i], 0)
            out.append(MotionSample(t: t[i], attitude: Quat.identity, userAccel: ua,
                                    gravity: g, rotationRate: Vec3.zero))
        }
        return out
    }

    private struct Replay {
        var sets: [(start: Double, reps: [Rep])] = []
        var live: [Int] = []
        var arms: [(Double, Bool)] = []
        var rest: Double?
        var expired: [Double] = []
    }

    /// Like MotionRecorder: 1 s batches; a Crown turn at `a` is applied before the first batch
    /// starting at or after it; the tracker counts reps only from `listeningFrom`.
    private func watchReplay(_ samples: [MotionSample], arms: [Double]) -> Replay {
        var out = Replay()
        guard let first = samples.first else { return out }
        var cycle = LiftCycle(startAt: first.t)
        var tracker = SetTracker()
        var todo = arms.sorted()
        func handle(_ e: SetEvent) {
            switch e {
            case .repCounted(let n):
                out.live.append(n)
                cycle.setStarted(at: 0)
            case .setEnded(let start, _, _, let lastRepEnd, let reps):
                out.sets.append((start, reps))
                cycle.setEnded(at: lastRepEnd)
            }
        }
        var k = 0
        while k < samples.count {
            while let a = todo.first, a <= samples[k].t {
                todo.removeFirst()
                out.arms.append((a, cycle.arm(at: a)))
            }
            tracker.armedFrom = cycle.listeningFrom
            let end = min(samples.count, k + 200)
            tracker.process(Array(samples[k..<end])).forEach(handle)
            let latest = samples[end - 1].t
            if cycle.expireArmed(at: latest, busy: tracker.detected) {
                out.expired.append(latest)
            }
            k = end
        }
        tracker.armedFrom = cycle.listeningFrom
        if let last = tracker.flush() {
            handle(last)
        }
        out.rest = cycle.lastRest
        return out
    }

    func testRestArmCasesMatchPython() throws {
        XCTAssertNotNil(fixtureURL("rest_arm_cases", "json"), "rest_arm_cases.json missing")
        let fixture = try jsonObject(try fixtureData("rest_arm_cases", "json"))
        let tol = number(fixture["tolerance"]) ?? 0.006
        let cases = fixture["cases"] as? [String: Any] ?? [:]
        XCTAssertEqual(cases.count, 7)
        func rows(_ x: Any?) -> [[Double]] {
            return (x as? [Any] ?? []).map { row in (row as? [Any] ?? []).compactMap { number($0) } }
        }
        for (name, value) in cases.sorted(by: { $0.key < $1.key }) {
            let c = value as? [String: Any] ?? [:]
            let input = c["input"] as? [String: Any] ?? [:]
            let expected = c["expected"] as? [String: Any] ?? [:]
            let samples = signal(pulls: rows(input["pulls"]), shakes: rows(input["shakes"]),
                                 total: number(input["total"]) ?? 0)
            let arms = (input["arms"] as? [Any] ?? []).compactMap { number($0) }
            let r = watchReplay(samples, arms: arms)

            let wantSets = expected["sets"] as? [[String: Any]] ?? []
            XCTAssertEqual(r.sets.map { $0.reps.count }, wantSets.map { rows($0["reps"]).count }, name)
            for (got, want) in zip(r.sets, wantSets) {
                XCTAssertEqual(got.start, number(want["start"]) ?? -1, accuracy: tol, name)
                for (rep, w) in zip(got.reps, rows(want["reps"])) where w.count == 2 {
                    XCTAssertEqual(rep.start, w[0], accuracy: tol, name)
                    XCTAssertEqual(rep.end, w[1], accuracy: tol, name)
                }
            }
            let wantLive = (expected["live"] as? [Any] ?? []).compactMap { number($0) }.map { Int($0) }
            XCTAssertEqual(r.live, wantLive, name)
            let wantArms = expected["arms"] as? [[Any]] ?? []
            XCTAssertEqual(r.arms.count, wantArms.count, name)
            for (got, want) in zip(r.arms, wantArms) where want.count == 2 {
                XCTAssertEqual(got.0, number(want[0]) ?? -1, accuracy: 1e-9, name)
                XCTAssertEqual(got.1, flag(want[1]), name)
            }
            let wantExpired = (expected["expired"] as? [Any] ?? []).compactMap { number($0) }
            XCTAssertEqual(r.expired.count, wantExpired.count, name)
            for (got, want) in zip(r.expired, wantExpired) {
                XCTAssertEqual(got, want, accuracy: tol, name)
            }
            if let rest = number(expected["rest"]) {
                XCTAssertEqual(r.rest ?? -1, rest, accuracy: tol, name)
            } else {
                XCTAssertNil(r.rest, name)
            }
        }
    }

    /// While resting (armedFrom = +∞) a whole set of real-looking pulls counts nothing.
    func testRestingTrackerCountsNothing() {
        var pulls: [[Double]] = []
        for k in 0..<6 {
            pulls.append([8.0 + Double(k) * 2.5, 0.6, 1.0, 1.0])
        }
        let samples = signal(pulls: pulls, shakes: [], total: 35.0)
        var tracker = SetTracker()
        tracker.armedFrom = Double.greatestFiniteMagnitude
        var events: [SetEvent] = []
        var k = 0
        while k < samples.count {
            let end = min(samples.count, k + 200)
            events += tracker.process(Array(samples[k..<end]))
            k = end
        }
        XCTAssertTrue(events.isEmpty, "events \(events)")
        XCTAssertNil(tracker.flush())
    }
}
