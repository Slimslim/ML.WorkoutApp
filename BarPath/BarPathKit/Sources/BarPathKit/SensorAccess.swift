import Foundation

/// W23: which "access is off" banner the Workouts tab (phone) and the start screen (watch) show.
///
/// iOS never tells an app whether reading heart rate was refused, so heart rate follows what the
/// last session saw: any heart-rate sample means access is on; a session of at least
/// `minimumSessionSeconds` with none means it is off; a shorter session says nothing (the previous
/// answer stands). Motion's authorization status is readable, so the caller passes it in.
public enum SensorBanner: Equatable {
    case heartRate
    case motion
    case heartRateAndMotion
}

public enum SensorAccess {
    /// UserDefaults key (watch): whether the last practice or workout received heart rate.
    /// Written by `WorkoutPracticeModel` and `WorkoutSessionModel`; missing until a session decides.
    public static let receivedHeartRateKey: String = "lastSessionReceivedHeartRate.v1"

    /// A session this long without a heart-rate sample counts as "heart rate is off".
    public static let minimumSessionSeconds: Double = 120.0

    /// What a finished session says about heart-rate access: true when it got at least one
    /// sample, false when it ran at least `minimumSessionSeconds` with none, nil when it was too
    /// short to tell (keep the previous answer).
    public static func receivedHeartRate(sampleCount: Int, sessionSeconds: Double) -> Bool? {
        if sampleCount > 0 {
            return true
        }
        if sessionSeconds >= minimumSessionSeconds {
            return false
        }
        return nil
    }

    /// The same answer for a result the phone received from the watch.
    public static func receivedHeartRate(result: WorkoutResult) -> Bool? {
        var count: Int = 0
        if result.heartRateAvg != nil {
            count += 1
        }
        if let series = result.heartRateSeries {
            for bpm in series.bpm where bpm != nil {
                count += 1
            }
        }
        for segment in result.segments where segment.heartRateAvg != nil {
            count += 1
        }
        return receivedHeartRate(sampleCount: count, sessionSeconds: result.totalSeconds)
    }

    /// The first answer, newest result first (`results` sorted newest first); nil when no result
    /// tells (no workouts yet, or only short ones).
    public static func lastReceivedHeartRate(results: [WorkoutResult]) -> Bool? {
        for result in results {
            if let answer = receivedHeartRate(result: result) {
                return answer
            }
        }
        return nil
    }

    /// The banner to show, or nil. Unknown heart rate (nil: no session has told yet) shows nothing.
    public static func banner(lastSessionReceivedHeartRate: Bool?, motionDenied: Bool) -> SensorBanner? {
        let heartRateOff: Bool = lastSessionReceivedHeartRate == false
        if heartRateOff && motionDenied {
            return .heartRateAndMotion
        }
        if heartRateOff {
            return .heartRate
        }
        if motionDenied {
            return .motion
        }
        return nil
    }
}
