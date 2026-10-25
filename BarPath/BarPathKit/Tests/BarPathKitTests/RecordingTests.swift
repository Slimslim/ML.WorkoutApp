import XCTest
@testable import BarPathKit

final class RecordingTests: XCTestCase {

    private func sample(_ t: Double, _ k: Double) -> MotionSample {
        return MotionSample(t: t,
                            attitude: Quat(w: 0.5, x: 0.5 + k, y: -0.5, z: 0.25),
                            userAccel: Vec3(0.01 * k, -0.02, 0.125),
                            gravity: Vec3(-0.75, 0.5, -0.25),
                            rotationRate: Vec3(1.5, -2.25, k))
    }

    private func makeRecording(loadKg: Double? = 80.5) -> LiftRecording {
        var motion = MotionSeries()
        for i in 0..<5 {
            motion.append(sample(Double(i) * 0.005, Double(i)))
        }
        let accel = AccelSeries([AccelSample(t: -0.00125, accel: Vec3(0.5, -1.0, 0.25)),
                                 AccelSample(t: 0.0, accel: Vec3(0.75, -0.5, 0.125))])
        return LiftRecording(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                             sessionId: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                             index: 3,
                             liftType: .cleanAndJerk,
                             loadKg: loadKg,
                             startDate: Date(timeIntervalSince1970: 1_792_951_391.25),
                             homingTime: 2.0,
                             endTime: 7.4,
                             endReason: .drop,
                             motion: motion,
                             accel: accel)
    }

    // MARK: Series

    func testMotionSeriesColumnsAndSubscript() {
        let samples = [sample(0, 1), sample(0.005, 2), sample(0.01, 3)]
        let series = MotionSeries(samples)
        XCTAssertEqual(series.count, 3)
        XCTAssertEqual(series.t, [0, 0.005, 0.01])
        XCTAssertEqual(series.rz, [1, 2, 3])
        XCTAssertEqual(series[1], samples[1])
        XCTAssertEqual(series.samples, samples)
        XCTAssertEqual(MotionSeries().count, 0)
    }

    func testAccelSeries() {
        var a = AccelSeries()
        a.append(AccelSample(t: 1, accel: Vec3(1, 2, 3)))
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0], AccelSample(t: 1, accel: Vec3(1, 2, 3)))
        XCTAssertEqual(AccelSeries([AccelSample(t: 1, accel: Vec3(1, 2, 3))]), a)
    }

    // MARK: JSON

    func testJSONRoundTrip() throws {
        let rec = makeRecording()
        let data = try rec.encoded()
        let back = try LiftRecording.decode(from: data)
        XCTAssertEqual(back.version, 1)
        XCTAssertEqual(back.id, rec.id)
        XCTAssertEqual(back.sessionId, rec.sessionId)
        XCTAssertEqual(back.index, 3)
        XCTAssertEqual(back.kind, "lift")
        XCTAssertEqual(back.liftType, .cleanAndJerk)
        XCTAssertEqual(back.loadKg, 80.5)
        XCTAssertEqual(back.startDate.timeIntervalSince1970, rec.startDate.timeIntervalSince1970, accuracy: 1e-3)
        XCTAssertEqual(back.homingTime, 2.0)
        XCTAssertEqual(back.endTime, 7.4)
        XCTAssertEqual(back.endReason, .drop)
        XCTAssertEqual(back.motion, rec.motion)
        XCTAssertEqual(back.accel, rec.accel)

        var nilRec = makeRecording(loadKg: nil)
        nilRec.homingTime = nil
        nilRec.endTime = nil
        nilRec.endReason = nil
        let back2 = try LiftRecording.decode(from: try nilRec.encoded())
        XCTAssertNil(back2.loadKg)
        XCTAssertNil(back2.homingTime)
        XCTAssertNil(back2.endTime)
        XCTAssertNil(back2.endReason)
    }

    func testJSONKeysMatchSpec() throws {
        let data = try makeRecording(loadKg: nil).encoded()
        let dict = try jsonObject(data)
        XCTAssertEqual(Set(dict.keys), Set(["version", "id", "sessionId", "index", "kind", "liftType", "loadKg",
                                            "startDate", "homingTime", "endTime", "endReason", "motion", "accel"]))
        XCTAssertTrue(dict["loadKg"] is NSNull)
        XCTAssertEqual(dict["liftType"] as? String, "cleanAndJerk")
        XCTAssertEqual(dict["endReason"] as? String, "drop")
        XCTAssertEqual(dict["kind"] as? String, "lift")
        XCTAssertEqual(dict["startDate"] as? String, "2026-10-25T18:03:11.250Z")
        let motion = try XCTUnwrap(dict["motion"] as? [String: Any])
        XCTAssertEqual(Set(motion.keys), Set(["t", "qw", "qx", "qy", "qz", "ax", "ay", "az",
                                              "gx", "gy", "gz", "rx", "ry", "rz"]))
        XCTAssertEqual((motion["t"] as? [Any])?.count, 5)
        let accel = try XCTUnwrap(dict["accel"] as? [String: Any])
        XCTAssertEqual(Set(accel.keys), Set(["t", "x", "y", "z"]))
    }

    func testDecodesPythonStyleJSON() throws {
        let withFraction = """
        {"version": 1, "id": "0f8fad5b-d9cb-469f-a165-70867728950e",
         "sessionId": "7c9e6679-7425-40de-944b-e07fc1f90ae7", "index": 2, "kind": "lift",
         "liftType": "snatch", "loadKg": null, "startDate": "2026-10-25T18:03:11.250Z",
         "homingTime": 2.0, "endTime": null, "endReason": "returned",
         "motion": {"t": [0.0, 0.005], "qw": [1, 1], "qx": [0, 0], "qy": [0, 0], "qz": [0, 0],
                    "ax": [0, 0], "ay": [0, 0], "az": [0, 0], "gx": [-1, -1], "gy": [0, 0], "gz": [0, 0],
                    "rx": [0, 0], "ry": [0, 0], "rz": [0, 0]},
         "accel": {"t": [], "x": [], "y": [], "z": []}}
        """
        let rec = try LiftRecording.decode(from: Data(withFraction.utf8))
        XCTAssertEqual(rec.id, UUID(uuidString: "0F8FAD5B-D9CB-469F-A165-70867728950E"))
        XCTAssertEqual(rec.liftType, .snatch)
        XCTAssertNil(rec.loadKg)
        XCTAssertNil(rec.endTime)
        XCTAssertEqual(rec.endReason, .returned)
        XCTAssertEqual(rec.motion.count, 2)
        XCTAssertEqual(rec.accel.count, 0)
        XCTAssertEqual(rec.startDate.timeIntervalSince1970, 1_792_951_391.25, accuracy: 1e-6)

        let noFraction = withFraction.replacingOccurrences(of: "18:03:11.250Z", with: "18:03:11Z")
        let rec2 = try LiftRecording.decode(from: Data(noFraction.utf8))
        XCTAssertEqual(rec2.startDate.timeIntervalSince1970, 1_792_951_391.0, accuracy: 1e-6)
    }

    func testDecodeRejectsUnequalMotionColumns() {
        let bad = """
        {"version": 1, "id": "0f8fad5b-d9cb-469f-a165-70867728950e",
         "sessionId": "7c9e6679-7425-40de-944b-e07fc1f90ae7", "index": 1, "kind": "lift",
         "liftType": "snatch", "loadKg": null, "startDate": "2026-10-25T18:03:11Z",
         "homingTime": null, "endTime": null, "endReason": null,
         "motion": {"t": [0.0, 0.005], "qw": [1], "qx": [0, 0], "qy": [0, 0], "qz": [0, 0],
                    "ax": [0, 0], "ay": [0, 0], "az": [0, 0], "gx": [-1, -1], "gy": [0, 0], "gz": [0, 0],
                    "rx": [0, 0], "ry": [0, 0], "rz": [0, 0]},
         "accel": {"t": [], "x": [], "y": [], "z": []}}
        """
        XCTAssertThrowsError(try LiftRecording.decode(from: Data(bad.utf8)))
    }

    func testDateHelpers() {
        let d = Date(timeIntervalSince1970: 1_792_951_391.25)
        XCTAssertEqual(BarPathJSON.formatDate(d), "2026-10-25T18:03:11.250Z")
        let parsed = BarPathJSON.parseDate("2026-10-25T18:03:11Z")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.timeIntervalSince1970 ?? 0, 1_792_951_391.0, accuracy: 1e-6)
        XCTAssertNil(BarPathJSON.parseDate("not a date"))
    }

    func testLiftTypeDisplayNames() {
        XCTAssertEqual(LiftType.snatch.displayName, "Snatch")
        XCTAssertEqual(LiftType.cleanAndJerk.displayName, "Clean & Jerk")
        XCTAssertEqual(LiftType.powerSnatch.displayName, "Power Snatch")
        XCTAssertEqual(LiftType.cleanAndJerk.id, "cleanAndJerk")
        XCTAssertEqual(LiftType.allCases.count, 9)
    }

    // MARK: SnippetBuilder

    func testSnippetBuilderRebasesTimes() {
        let boot = Date(timeIntervalSince1970: 1_000_000)
        var motion: [MotionSample] = []
        for i in 0..<10 {
            motion.append(sample(1000.0 + Double(i) * 0.005, Double(i)))
        }
        let accel = [AccelSample(t: 999.999, accel: Vec3(0, 0, -1)),
                     AccelSample(t: 1000.00025, accel: Vec3(0, 0, -1))]
        let rec = SnippetBuilder.makeRecording(sessionId: UUID(), index: 2, liftType: .powerClean, loadKg: 60,
                                               bootDate: boot, motion: motion, accel: accel,
                                               homingTime: 1000.02, endTime: 1000.04, endReason: .returned)
        XCTAssertEqual(rec.version, 1)
        XCTAssertEqual(rec.kind, "lift")
        XCTAssertEqual(rec.index, 2)
        XCTAssertEqual(rec.liftType, .powerClean)
        XCTAssertEqual(rec.loadKg, 60)
        XCTAssertEqual(rec.endReason, .returned)
        XCTAssertEqual(rec.motion.count, 10)
        XCTAssertEqual(rec.motion.t[0], 0)
        XCTAssertEqual(rec.motion.t[9], 0.045, accuracy: 1e-9)
        XCTAssertEqual(rec.motion.rz, (0..<10).map { Double($0) })
        XCTAssertEqual(rec.accel.count, 2)
        XCTAssertEqual(rec.accel.t[0], -0.001, accuracy: 1e-9)
        XCTAssertEqual(rec.accel.t[1], 0.00025, accuracy: 1e-9)
        XCTAssertEqual(rec.homingTime ?? -1, 0.02, accuracy: 1e-9)
        XCTAssertEqual(rec.endTime ?? -1, 0.04, accuracy: 1e-9)
        XCTAssertEqual(rec.startDate.timeIntervalSince1970, 1_001_000, accuracy: 1e-6)
    }

    func testSnippetBuilderNilTimes() {
        let rec = SnippetBuilder.makeRecording(sessionId: UUID(), index: 1, liftType: .snatch, loadKg: nil,
                                               bootDate: Date(timeIntervalSince1970: 0),
                                               motion: [sample(5, 0)], accel: [],
                                               homingTime: nil, endTime: nil, endReason: nil)
        XCTAssertNil(rec.homingTime)
        XCTAssertNil(rec.endTime)
        XCTAssertEqual(rec.motion.t, [0])
        XCTAssertEqual(rec.accel.count, 0)
        XCTAssertEqual(rec.startDate.timeIntervalSince1970, 5, accuracy: 1e-9)
    }

    // MARK: SessionCSV

    func testSessionCSVParse() throws {
        let text = "# barpath-session v1, sessionId=7C9E6679-7425-40DE-944B-E07FC1F90AE7, "
            + "startDate=2026-10-25T18:03:11.250Z, liftType=snatch\r\n"
            + "t,qw,qx,qy,qz,ax,ay,az,gx,gy,gz,rx,ry,rz\r\n"
            + "0.000000,1.00000,0.00000,0.00000,0.00000,0.01000,0.02000,0.03000,-1.00000,0.00000,0.00000,0.10000,0.20000,0.30000\r\n"
            + "0.005000,0.70711,0.00000,-0.70711,0.00000,0.00000,0.00000,0.00000,-0.99000,0.10000,0.00000,0.00000,0.00000,-0.50000\r\n"
        let parsed = try SessionCSV.parse(text)
        XCTAssertEqual(parsed.header["sessionId"], "7C9E6679-7425-40DE-944B-E07FC1F90AE7")
        XCTAssertEqual(parsed.header["startDate"], "2026-10-25T18:03:11.250Z")
        XCTAssertEqual(parsed.header["liftType"], "snatch")
        XCTAssertEqual(parsed.header["format"], "barpath-session v1")
        XCTAssertEqual(parsed.samples.count, 2)
        let s0 = parsed.samples[0]
        XCTAssertEqual(s0.t, 0)
        XCTAssertEqual(s0.attitude, Quat(w: 1, x: 0, y: 0, z: 0))
        XCTAssertEqual(s0.userAccel, Vec3(0.01, 0.02, 0.03))
        XCTAssertEqual(s0.gravity, Vec3(-1, 0, 0))
        XCTAssertEqual(s0.rotationRate, Vec3(0.1, 0.2, 0.3))
        let s1 = parsed.samples[1]
        XCTAssertEqual(s1.t, 0.005)
        XCTAssertEqual(s1.attitude.y, -0.70711)
        XCTAssertEqual(s1.rotationRate.z, -0.5)
    }

    func testSessionCSVErrors() {
        XCTAssertThrowsError(try SessionCSV.parse("# only a comment\n"))
        XCTAssertThrowsError(try SessionCSV.parse("t,qw\n0,1\n"))
        let badRow = "t,qw,qx,qy,qz,ax,ay,az,gx,gy,gz,rx,ry,rz\n0,1,0,0,0,0,0,0,-1,0,0,0,0\n"
        XCTAssertThrowsError(try SessionCSV.parse(badRow)) { error in
            XCTAssertEqual(error as? SessionCSVError, SessionCSVError.malformedRow(line: 2))
        }
    }
}
