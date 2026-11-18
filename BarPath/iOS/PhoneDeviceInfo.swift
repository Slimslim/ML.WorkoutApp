import Foundation
import UIKit
import WatchConnectivity
import BarPathKit

/// W29: the phone's model, iOS version, app build and heart-rate zone source, sent to the watch
/// in the application context under `phoneDevice` (a new key; the other keys are kept). The
/// watch writes them into every workout recording's header, so the uploaded CSV says which
/// phone and phone build it went with (a watch/phone build mismatch is visible).
/// Nothing personal: no name, no birth year, no heart rate values.
enum PhoneDeviceInfo {
    /// Application context key (read by the watch's `WorkoutRecordingInfo`).
    static let contextKey = PhoneDeviceContext.key

    /// ["model": "iPhone16,1", "os": "18.1", "build": "16", "hrZoneSource": "custom|age|workouts"].
    /// Call on the main thread.
    static func dictionary() -> [String: String] {
        let build: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "unknown"
        let profile = AthleteProfile.shared
        let zones: String
        if profile.manualMaxHeartRate != nil {
            zones = "custom"
        } else if profile.birthYear != nil {
            zones = "age"
        } else {
            // No setting: the highest heart rate of the recorded workouts, when there is one.
            zones = "workouts"
        }
        return [
            "model": hardwareIdentifier(),
            "os": UIDevice.current.systemVersion,
            "build": build,
            "hrZoneSource": zones
        ]
    }

    /// Hardware identifier such as "iPhone16,1" (sysctl hw.machine), or "unknown".
    static func hardwareIdentifier() -> String {
        var size: Int = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        let bytes: [UInt8] = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        let name = String(decoding: bytes, as: UTF8.self)
        return name.isEmpty ? "unknown" : name
    }

    /// Puts `phoneDevice` in the application context, keeping every other key. Call on the main
    /// thread. `force` sends even when the phone's copy already has the same values: pass true on
    /// activation and watch-state changes, because the phone's `applicationContext` outlives
    /// launches and watch app reinstalls while the watch's received copy does not (#79).
    static func send(force: Bool = false) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        guard let context = PhoneDeviceContext.merged(context: session.applicationContext,
                                                      info: dictionary(),
                                                      now: Date(),
                                                      force: force) else { return }
        do {
            try session.updateApplicationContext(context)
        } catch {
            NSLog("BarPath: could not send the phone device info: %@", error.localizedDescription)
        }
    }
}
