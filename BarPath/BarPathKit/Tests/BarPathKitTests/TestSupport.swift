import Foundation
import XCTest
@testable import BarPathKit

/// Builds synthetic 200 Hz device-motion streams out of simple phases.
/// "up" is the device-frame direction opposite to gravity; accelerations are given in m/s².
struct SignalBuilder {
    var samples: [MotionSample] = []
    let dt: Double = 0.005
    var t0: Double = 0.0
    var attitude: Quat
    var gravity: Vec3          // device frame, g
    var side: Vec3             // device-frame unit vector perpendicular to gravity

    init(attitude: Quat = Quat.identity,
         gravity: Vec3 = Vec3(-1.0, 0.0, 0.0),
         side: Vec3 = Vec3(0.0, 1.0, 0.0),
         t0: Double = 0.0) {
        self.attitude = attitude
        self.gravity = gravity
        self.side = side
        self.t0 = t0
    }

    var up: Vec3 { return -(gravity.normalized) }

    /// Time the next sample will get.
    var nextTime: Double { return t0 + Double(samples.count) * dt }

    mutating func hold(_ duration: Double) {
        phase(duration, aUp: 0.0, lateral: 0.0)
    }

    mutating func phase(_ duration: Double, aUp: Double, lateral: Double = 0.0) {
        let count = Int((duration / dt).rounded())
        let ua = up * (aUp / standardGravity) + side * (lateral / standardGravity)
        for _ in 0..<count {
            samples.append(MotionSample(t: nextTime,
                                        attitude: attitude,
                                        userAccel: ua,
                                        gravity: gravity,
                                        rotationRate: Vec3.zero))
        }
    }

    func recording(homingTime: Double? = nil) -> LiftRecording {
        return LiftRecording(sessionId: UUID(),
                             index: 1,
                             liftType: .snatch,
                             startDate: Date(timeIntervalSince1970: 1_792_951_391.25),
                             homingTime: homingTime,
                             endTime: nil,
                             endReason: nil,
                             motion: MotionSeries(samples),
                             accel: AccelSeries())
    }
}

/// Replays samples through a detector and returns (sample time, event) pairs.
func replay(_ samples: [MotionSample], detector: OnlineLiftDetector) -> [(t: Double, event: DetectorEvent)] {
    var out: [(t: Double, event: DetectorEvent)] = []
    for s in samples {
        if let e = detector.process(s) {
            out.append((t: s.t, event: e))
        }
    }
    return out
}

/// Loads a fixture file from the test bundle's Fixtures folder, or nil if it is not there.
func fixtureURL(_ name: String, _ ext: String) -> URL? {
    if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") {
        return url
    }
    return Bundle.module.url(forResource: name, withExtension: ext)
}

func fixtureData(_ name: String, _ ext: String) throws -> Data {
    guard let url = fixtureURL(name, ext) else {
        throw XCTSkip("Fixture \(name).\(ext) not present (generate with tools/make_fixtures.py)")
    }
    return try Data(contentsOf: url)
}

func jsonObject(_ data: Data) throws -> [String: Any] {
    let obj = try JSONSerialization.jsonObject(with: data, options: [])
    guard let dict = obj as? [String: Any] else {
        throw NSError(domain: "BarPathKitTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "expected a JSON object"])
    }
    return dict
}

func number(_ value: Any?) -> Double? {
    guard let v = value else { return nil }
    if v is NSNull { return nil }
    if let d = v as? Double { return d }
    if let n = v as? NSNumber { return n.doubleValue }
    return nil
}
