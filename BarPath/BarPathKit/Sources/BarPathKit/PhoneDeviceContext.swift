import Foundation

/// W29 (#79): how the phone puts its device info (`phoneDevice`) into the WatchConnectivity
/// application context. Pure logic, so it can be tested without a watch.
///
/// The phone's `WCSession.applicationContext` is what the phone last *sent*, and it outlives
/// app launches and watch app reinstalls. A reinstalled watch app starts with an empty received
/// context, so "skip when the phone's copy already has the same values" never re-sends it.
/// `force` sends anyway (on activation and watch-state changes), and every send carries a fresh
/// `sentAt`, so WatchConnectivity sees a changed dictionary and delivers it.
public enum PhoneDeviceContext {
    /// Application context key (read by the watch's `WorkoutRecordingInfo`).
    public static let key = "phoneDevice"
    /// Field inside the `phoneDevice` entry: milliseconds since 1970 when it was sent, as a string.
    /// The watch ignores it; it only makes each send a new dictionary.
    public static let sentAtField = "sentAt"

    /// The application context to send, with every other key kept, or nil when nothing needs
    /// sending (`force` is false and the context already has the same values, `sentAt` ignored).
    public static func merged(context: [String: Any],
                              info: [String: String],
                              now: Date,
                              force: Bool) -> [String: Any]? {
        if !force, let current = context[key] as? [String: String] {
            var previous: [String: String] = current
            previous[sentAtField] = nil
            if previous == info { return nil }
        }
        var entry: [String: String] = info
        let millis: Int64 = Int64((now.timeIntervalSince1970 * 1000.0).rounded())
        entry[sentAtField] = String(millis)
        var out: [String: Any] = context
        out[key] = entry
        return out
    }
}
