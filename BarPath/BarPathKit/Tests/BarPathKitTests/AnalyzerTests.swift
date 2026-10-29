import XCTest
@testable import BarPathKit

final class AnalyzerTests: XCTestCase {

    /// -90° about y: device +x (forearm, pointing up when the arm hangs) -> world +z,
    /// device +z (watch face) -> world -x.
    private let hangingArm = Quat(w: 0.5.squareRoot(), x: 0, y: -(0.5.squareRoot()), z: 0)

    /// set 1 s -> pull to 0.9 m (peak v ≈ 2.975) -> hold 1 s -> free fall 0.6 s -> 0.5 s.
    private func simplePull(attitude: Quat) -> SignalBuilder {
        var b = SignalBuilder(attitude: attitude)
        b.hold(1.0)
        b.phase(0.3, aUp: 10)
        b.phase(0.3, aUp: -10)
        b.hold(1.0)
        b.phase(0.6, aUp: -standardGravity)
        b.hold(0.5)
        return b
    }

    func testDefaultConfigMatchesSpec() {
        let c = AnalyzerConfig.default
        XCTAssertEqual(c.emaTau, 0.08)
        XCTAssertEqual(c.stillRot, 0.5)
        XCTAssertEqual(c.stillAcc, 0.06)
        XCTAssertEqual(c.homingMinStill, 0.2)
        XCTAssertEqual(c.startVelocity, 0.5)
        XCTAssertEqual(c.startWindow, 1.0)
        XCTAssertEqual(c.anchorMinStill, 0.25)
        XCTAssertEqual(c.dropDistance, 0.5)
        XCTAssertEqual(c.maxUncorrectedDuration, 3.0)
    }

    func testBackwardStillnessAndRelease() {
        // Forward EMA keeps saying "still" a few samples into motion; the backward pass does not.
        var t: [Double] = []
        var acc: [Double] = []
        for i in 0..<100 {
            t.append(Double(i) * 0.005)
            acc.append(i < 50 ? 0.0 : 1.0)
        }
        let rot = [Double](repeating: 0.0, count: 100)
        let fwd = LiftAnalyzer.stillnessMask(t: t, rotNorm: rot, accNorm: acc, config: .default, reverse: false)
        let bwd = LiftAnalyzer.stillnessMask(t: t, rotNorm: rot, accNorm: acc, config: .default, reverse: true)
        XCTAssertTrue(fwd[49])
        XCTAssertFalse(fwd[51])
        XCTAssertFalse(bwd[49])                      // backward EMA already saw the motion
        XCTAssertTrue(bwd[0])
        let run = LiftAnalyzer.StillRun(start: 0, end: 50)
        let r = LiftAnalyzer.releaseIndex(run, bwd)
        XCTAssertLessThan(r, 50)
        XCTAssertTrue(bwd[r])
        XCTAssertFalse(bwd[r + 1])
        XCTAssertEqual(LiftAnalyzer.releaseIndex(LiftAnalyzer.StillRun(start: 60, end: 70), bwd), 60)
    }

    func testStillRuns() {
        let runs = LiftAnalyzer.stillRuns([true, true, false, false, true, false, true, true, true])
        XCTAssertEqual(runs.map { $0.start }, [0, 4, 6])
        XCTAssertEqual(runs.map { $0.end }, [1, 4, 8])
        XCTAssertTrue(LiftAnalyzer.stillRuns([]).isEmpty)
        XCTAssertTrue(LiftAnalyzer.stillRuns([false, false]).isEmpty)
    }

    func testSimplePullDirectConvention() throws {
        let rec = simplePull(attitude: hangingArm).recording()
        let a = try LiftAnalyzer.analyze(rec, config: .wristReference)
        XCTAssertEqual(a.recordingId, rec.id)
        // Release index (Revision A): the backward EMA flags the set as still only up to
        // sample 156 (it lags symmetrically to the forward EMA), and the overhead-hold anchor
        // run [363, 519] releases at 476. Values cross-checked with tools/barpath/analyzer.py.
        XCTAssertEqual(a.homingIndex, 156)
        XCTAssertEqual(a.endIndex, 476)              // release of the overhead hold (drop follows)
        XCTAssertEqual(a.path.count, 476 - 156 + 1)
        XCTAssertEqual(a.path[0].t, 0)
        XCTAssertEqual(a.path[0].vertical, 0)
        XCTAssertEqual(a.metrics.peakVerticalVelocity, 2.975, accuracy: 1e-6)
        XCTAssertEqual(a.metrics.timeToPeakVelocity, 0.515, accuracy: 1e-6)
        XCTAssertEqual(a.metrics.maxHeight, 0.9, accuracy: 1e-6)
        XCTAssertEqual(a.metrics.catchHeight ?? -1, 0.9, accuracy: 1e-6)
        XCTAssertEqual(a.metrics.dropUnderBar ?? -1, 0.0, accuracy: 1e-6)
        XCTAssertEqual(a.metrics.finalHeight, 0.9, accuracy: 1e-6)
        XCTAssertEqual(a.metrics.duration, 1.6, accuracy: 1e-6)
        XCTAssertEqual(a.metrics.maxForward, 0, accuracy: 1e-9)
        XCTAssertEqual(a.metrics.maxBackward, 0, accuracy: 1e-9)
        XCTAssertEqual(a.segments.count, 1)
        XCTAssertEqual(a.segments[0].startIndex, 0)
        XCTAssertEqual(a.segments[0].endIndex, 363 - 156)
        XCTAssertEqual(a.segments[0].duration, 1.035, accuracy: 1e-9)
        XCTAssertEqual(a.segments[0].driftCorrection, 0, accuracy: 1e-9)
        XCTAssertEqual(a.segments[0].heightGain, 0.9, accuracy: 1e-6)
        XCTAssertEqual(a.confidence, .high)
        XCTAssertEqual(a.notes, [])
    }

    func testConjugateConventionAutoDetected() throws {
        let direct = try LiftAnalyzer.analyze(simplePull(attitude: hangingArm).recording(), config: .wristReference)
        let conj = try LiftAnalyzer.analyze(simplePull(attitude: hangingArm.conjugate).recording(), config: .wristReference)
        XCTAssertEqual(conj.homingIndex, direct.homingIndex)
        XCTAssertEqual(conj.endIndex, direct.endIndex)
        XCTAssertEqual(conj.metrics.peakVerticalVelocity, direct.metrics.peakVerticalVelocity, accuracy: 1e-9)
        XCTAssertEqual(conj.metrics.maxHeight, direct.metrics.maxHeight, accuracy: 1e-9)
        XCTAssertEqual(conj.metrics.finalHeight, direct.metrics.finalHeight, accuracy: 1e-9)
        XCTAssertEqual(conj.confidence, .high)
        XCTAssertFalse(conj.notes.contains(LiftAnalyzer.noteGravityOnly))
    }

    func testGravityOnlyFallback() throws {
        // Identity attitude with gravity along device -x: neither convention puts gravity down.
        let a = try LiftAnalyzer.analyze(simplePull(attitude: Quat.identity).recording(), config: .wristReference)
        XCTAssertTrue(a.notes.contains("Orientation unavailable: vertical only"))
        XCTAssertEqual(a.metrics.peakVerticalVelocity, 2.975, accuracy: 1e-6)
        XCTAssertEqual(a.metrics.maxHeight, 0.9, accuracy: 1e-6)
        XCTAssertEqual(a.metrics.maxForward, 0)
        XCTAssertEqual(a.metrics.maxBackward, 0)
        XCTAssertEqual(a.confidence, .medium)        // capped
    }

    func testSnatchLikeCatchAndRecovery() throws {
        var b = SignalBuilder(attitude: hangingArm)
        b.hold(1.0)
        b.phase(0.3, aUp: 10)        // pull: up 0.9 m
        b.phase(0.3, aUp: -10)
        b.phase(0.2, aUp: -5)        // drop under the bar: down 0.2 m
        b.phase(0.2, aUp: 5)
        b.hold(0.8)                  // catch (anchor)
        b.phase(0.4, aUp: 5)         // recovery: up 0.8 m
        b.phase(0.4, aUp: -5)
        b.hold(1.0)                  // overhead hold (anchor)
        b.phase(0.6, aUp: -standardGravity)
        b.hold(0.5)
        let a = try LiftAnalyzer.analyze(b.recording(), config: .wristReference)
        XCTAssertEqual(a.homingIndex, 156)
        XCTAssertEqual(a.endIndex, 876)
        XCTAssertEqual(a.segments.count, 2)
        XCTAssertEqual(a.metrics.peakVerticalVelocity, 2.975, accuracy: 1e-6)
        XCTAssertEqual(a.metrics.maxHeight, 0.9, accuracy: 1e-3)
        XCTAssertEqual(a.metrics.catchHeight ?? -1, 0.7, accuracy: 1e-3)
        XCTAssertEqual(a.metrics.dropUnderBar ?? -1, 0.2, accuracy: 2e-3)
        XCTAssertEqual(a.metrics.finalHeight, 1.5, accuracy: 1e-6)
        XCTAssertEqual(a.metrics.duration, 3.6, accuracy: 1e-6)
        XCTAssertEqual(a.confidence, .high)
        // Segment indices are into the path and chain anchor to anchor.
        XCTAssertEqual(a.segments[0].startIndex, 0)
        XCTAssertEqual(a.segments[0].endIndex, 433 - 156)
        XCTAssertEqual(a.segments[1].startIndex, 526 - 156)   // release of the catch anchor
        XCTAssertEqual(a.segments[1].endIndex, 753 - 156)
        XCTAssertLessThan(a.segments[0].endIndex, a.segments[1].startIndex)
        XCTAssertLessThanOrEqual(a.segments[1].endIndex, a.path.count - 1)
    }

    func testNoAnchorIsUncorrectedAndLowConfidence() throws {
        var b = SignalBuilder(attitude: hangingArm)
        b.hold(1.0)
        b.phase(0.3, aUp: 10)
        b.phase(0.3, aUp: -10)
        b.phase(4.0, aUp: 0, lateral: 0.3 * standardGravity)   // never still again
        let a = try LiftAnalyzer.analyze(b.recording(), config: .wristReference)
        XCTAssertEqual(a.confidence, .low)
        XCTAssertTrue(a.notes.contains("No still recovery found: path uncorrected"))
        XCTAssertEqual(a.metrics.duration, 3.0, accuracy: 1e-6)
        // Revision D: the catch comes from vVertical, so it exists even without anchors.
        XCTAssertEqual(a.metrics.catchHeight ?? -1, 0.9, accuracy: 1e-6)
        XCTAssertEqual(a.metrics.dropUnderBar ?? -1, 0.0, accuracy: 1e-6)
        XCTAssertTrue(a.notes.contains(LiftAnalyzer.noteLateral))
        XCTAssertEqual(a.metrics.maxHeight, 0.9, accuracy: 1e-6)
    }

    func testHomingFallsBackToRecordingEstimate() throws {
        var b = SignalBuilder(attitude: hangingArm)
        b.hold(2.0)
        let a = try LiftAnalyzer.analyze(b.recording(homingTime: 0.5), config: .wristReference)
        XCTAssertEqual(a.homingIndex, 100)
        XCTAssertEqual(a.confidence, .low)
        XCTAssertEqual(a.notes, ["Homing taken from the watch estimate", "No still recovery found: path uncorrected"])
    }

    func testNoHomingFound() {
        var b = SignalBuilder(attitude: hangingArm)
        b.hold(2.0)
        XCTAssertThrowsError(try LiftAnalyzer.analyze(b.recording(), config: .wristReference)) { error in
            XCTAssertEqual(error as? AnalysisError, AnalysisError.noHomingFound)
        }
    }

    func testTooShort() {
        var b = SignalBuilder(attitude: hangingArm)
        b.hold(0.2)
        XCTAssertThrowsError(try LiftAnalyzer.analyze(b.recording(homingTime: 0.1), config: .wristReference)) { error in
            XCTAssertEqual(error as? AnalysisError, AnalysisError.tooShort)
        }
        let empty = SignalBuilder().recording()
        XCTAssertThrowsError(try LiftAnalyzer.analyze(empty, config: .wristReference)) { error in
            XCTAssertEqual(error as? AnalysisError, AnalysisError.tooShort)
        }
    }

    func testPCAForwardSign() {
        // Horizontal positions mostly along -y with a larger excursion towards -y than +y.
        var p: [Vec3] = []
        for i in 0..<21 {
            let s = Double(i) / 20.0
            p.append(Vec3(0.01 * s, -0.2 * s, 0))
        }
        p.append(Vec3(0, 0.05, 0))
        let axis = LiftAnalyzer.pcaForward(p: p, from: 0, to: p.count - 1)
        XCTAssertEqual(axis.z, 0)
        XCTAssertEqual(axis.norm, 1, accuracy: 1e-9)
        XCTAssertLessThan(axis.y, -0.9)          // points to where the biggest excursion is
    }
}
