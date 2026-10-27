import XCTest
@testable import BarPathKit

final class DetectorTests: XCTestCase {

    private func homing(_ e: DetectorEvent) -> Double? {
        switch e {
        case .armed(let h): return h
        case .liftStarted(let h): return h
        case .liftEnded(let h, _, _): return h
        case .disarmed: return nil
        }
    }

    func testDefaultConfigMatchesSpec() {
        let c = DetectorConfig.default
        XCTAssertEqual(c.emaTau, 0.08)
        XCTAssertEqual(c.stillRot, 0.5)
        XCTAssertEqual(c.stillAcc, 0.06)
        XCTAssertEqual(c.armMinStill, 0.3)
        XCTAssertEqual(c.armVerticalMin, 0.7)
        XCTAssertEqual(c.rehomeStill, 0.15)
        XCTAssertEqual(c.startVelocity, 0.5)
        XCTAssertEqual(c.startWindow, 1.0)
        XCTAssertEqual(c.anchorStill, 0.3)
        XCTAssertEqual(c.dropDistance, 0.5)
        XCTAssertEqual(c.returnHeight, 0.15)
        XCTAssertEqual(c.returnStill, 0.5)
        XCTAssertEqual(c.noAnchorTimeout, 8.0)
        XCTAssertEqual(c.maxLiftDuration, 15.0)
        XCTAssertEqual(c.cooldown, 1.5)
    }

    /// set -> pull up 0.9 m -> hold overhead -> free fall: ends with .drop at the hold.
    func testArmLiftDropThenRearm() {
        var b = SignalBuilder()
        b.hold(1.0)
        b.phase(0.3, aUp: 10)
        b.phase(0.3, aUp: -10)
        b.hold(1.0)                      // overhead hold: samples t = 1.6 ... 2.595
        b.phase(0.6, aUp: -standardGravity)
        b.hold(2.0)

        let det = OnlineLiftDetector()
        XCTAssertEqual(det.state, .idle)
        let events = replay(b.samples, detector: det)
        XCTAssertEqual(events.count, 4, "\(events)")
        guard events.count == 4 else { return }

        guard case .armed(let armT) = events[0].event else { return XCTFail("expected .armed, got \(events[0])") }
        XCTAssertEqual(armT, 0.30, accuracy: 0.011)

        guard case .liftStarted(let h1) = events[1].event else { return XCTFail("expected .liftStarted") }
        XCTAssertEqual(h1, 0.995, accuracy: 1e-6)          // last still sample before the pull
        XCTAssertEqual(events[1].t, 1.05, accuracy: 0.011)

        guard case .liftEnded(let h2, let end, let reason) = events[2].event else {
            return XCTFail("expected .liftEnded")
        }
        XCTAssertEqual(reason, .drop)
        XCTAssertEqual(h2, 0.995, accuracy: 1e-6)
        XCTAssertEqual(end, 2.595, accuracy: 1e-6)        // last still sample of the overhead hold
        XCTAssertEqual(events[2].t, 2.915, accuracy: 0.011)

        // Cooldown 1.5 s, then 0.3 s of stillness re-arms.
        guard case .armed(let rearm) = events[3].event else { return XCTFail("expected re-arm") }
        XCTAssertEqual(rearm, 4.72, accuracy: 0.011)
        XCTAssertEqual(det.state, .armed)
    }

    func testStateTransitionsStepByStep() {
        var b = SignalBuilder()
        b.hold(1.0)
        b.phase(0.3, aUp: 10)
        b.phase(0.3, aUp: -10)
        b.hold(1.0)
        b.phase(0.6, aUp: -standardGravity)
        let det = OnlineLiftDetector()
        var states: [DetectorState] = [det.state]
        for s in b.samples {
            _ = det.process(s)
            if states.last != det.state { states.append(det.state) }
        }
        XCTAssertEqual(states, [.idle, .armed, .lifting, .cooldown])
    }

    func testDisarmWhenForearmNotVertical() {
        var b = SignalBuilder()
        b.hold(1.0)
        b.gravity = Vec3(0, 0, -1)        // forearm horizontal, still
        b.hold(0.5)
        let det = OnlineLiftDetector()
        let events = replay(b.samples, detector: det)
        XCTAssertEqual(events.count, 2, "\(events)")
        guard events.count == 2 else { return }
        guard case .armed = events[0].event else { return XCTFail("expected .armed, got \(events[0])") }
        XCTAssertEqual(homing(events[0].event) ?? -1, 0.30, accuracy: 0.011)
        XCTAssertEqual(events[1].event, DetectorEvent.disarmed)
        XCTAssertEqual(events[1].t, 1.0, accuracy: 1e-9)
        XCTAssertEqual(det.state, .idle)
    }

    func testNotArmedWhenForearmHorizontal() {
        var b = SignalBuilder(gravity: Vec3(0, 0, -1), side: Vec3(1, 0, 0))
        b.hold(2.0)
        let events = replay(b.samples, detector: OnlineLiftDetector())
        XCTAssertTrue(events.isEmpty)
    }

    func testStartWindowExpiresWithoutPull() {
        var b = SignalBuilder()
        b.hold(1.0)
        b.phase(1.5, aUp: 0, lateral: 0.3 * standardGravity)   // moving sideways, no upward velocity
        let det = OnlineLiftDetector()
        let events = replay(b.samples, detector: det)
        XCTAssertEqual(events.count, 2, "\(events)")
        guard events.count == 2 else { return }
        XCTAssertEqual(events[1].event, .disarmed)
        XCTAssertEqual(events[1].t, 2.01, accuracy: 0.011)
        XCTAssertEqual(det.state, .idle)
    }

    func testNoAnchorTimeout() {
        var b = SignalBuilder()
        b.hold(1.0)
        b.phase(0.1, aUp: 10)                                  // v = 1 m/s => lift starts
        b.phase(9.0, aUp: 0, lateral: 0.3 * standardGravity)   // never still again
        let det = OnlineLiftDetector()
        let events = replay(b.samples, detector: det)
        XCTAssertEqual(events.count, 3, "\(events)")
        guard events.count == 3 else { return }
        guard case .liftEnded(let h, let end, let reason) = events[2].event else { return XCTFail() }
        XCTAssertEqual(reason, .timeout)
        XCTAssertEqual(h, 0.995, accuracy: 1e-6)
        XCTAssertEqual(end - h, 8.0, accuracy: 0.011)
        XCTAssertEqual(det.state, .cooldown)
    }

    func testReturnedToStart() {
        var b = SignalBuilder()
        b.hold(1.0)
        b.phase(0.25, aUp: 4)        // up 0.25 m
        b.phase(0.25, aUp: -4)
        b.hold(1.0)
        b.phase(0.25, aUp: -4)       // back down
        b.phase(0.25, aUp: 4)
        b.hold(2.0)
        let det = OnlineLiftDetector()
        let events = replay(b.samples, detector: det)
        XCTAssertEqual(events.count, 3, "\(events)")
        guard events.count == 3 else { return }
        guard case .liftEnded(let h, let end, let reason) = events[2].event else { return XCTFail() }
        XCTAssertEqual(reason, .returned)
        XCTAssertEqual(h, 1.005, accuracy: 0.011)
        XCTAssertEqual(end, 3.64, accuracy: 0.011)
    }

    func testResetReturnsToIdle() {
        var b = SignalBuilder()
        b.hold(1.0)
        let det = OnlineLiftDetector()
        _ = replay(b.samples, detector: det)
        XCTAssertEqual(det.state, .armed)
        det.reset()
        XCTAssertEqual(det.state, .idle)
        // After reset the stillness has to build up again from scratch.
        let again = replay(b.samples, detector: det)
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(again.first?.t ?? -1, 0.30, accuracy: 0.011)
    }
}
