import Foundation

/// Builds a LiftRecording snippet out of absolute (since-boot) sample times.
public enum SnippetBuilder {
    /// Re-bases times so the first motion sample is t = 0; homing/end times re-based too.
    /// `startDate = bootDate + first motion timestamp`. If `motion` is empty, the first accel
    /// timestamp (or 0) is used as the time origin.
    public static func makeRecording(sessionId: UUID, index: Int, liftType: LiftType, loadKg: Double?,
                                     bootDate: Date, motion: [MotionSample], accel: [AccelSample],
                                     homingTime: Double?, endTime: Double?, endReason: EndReason?) -> LiftRecording {
        let t0: Double
        if let first = motion.first {
            t0 = first.t
        } else if let firstA = accel.first {
            t0 = firstA.t
        } else {
            t0 = 0.0
        }

        var m = MotionSeries()
        for s in motion {
            var r = s
            r.t = s.t - t0
            m.append(r)
        }

        var a = AccelSeries()
        for s in accel {
            a.append(AccelSample(t: s.t - t0, accel: s.accel))
        }

        let homing: Double? = homingTime.map { $0 - t0 }
        let end: Double? = endTime.map { $0 - t0 }

        return LiftRecording(sessionId: sessionId,
                             index: index,
                             liftType: liftType,
                             loadKg: loadKg,
                             startDate: bootDate.addingTimeInterval(t0),
                             homingTime: homing,
                             endTime: end,
                             endReason: endReason,
                             motion: m,
                             accel: a)
    }
}
