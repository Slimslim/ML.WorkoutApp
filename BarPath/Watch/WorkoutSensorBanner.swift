import SwiftUI
import CoreMotion
import BarPathKit

/// W23: "Heart rate is off" / "Motion is off" above the workout tile on the start screen
/// (mockup docs/concepts/first-workout.html, approved 13 Nov). One line saying what is lost and
/// where to fix it; START still works. The watch cannot open Settings or Health itself, so the
/// box says where to go instead of offering a button.
struct WorkoutSensorBanner: View {
    let banner: SensorBanner

    /// The mockup's watch warning colours.
    static let warn = Color(red: 1.0, green: 0.722, blue: 0.420)       // #FFB86B
    static let box = Color(red: 0.165, green: 0.129, blue: 0.086)      // #2A2116

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(WorkoutSensorBanner.title(banner))
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundColor(WorkoutSensorBanner.warn)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(WorkoutSensorBanner.detail(banner))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 10).fill(WorkoutSensorBanner.box))
        .accessibilityElement(children: .combine)
    }

    static func title(_ banner: SensorBanner) -> String {
        switch banner {
        case .heartRate: return "♥ Heart rate is off"
        case .motion: return "Motion is off"
        case .heartRateAndMotion: return "♥ Heart rate, Motion off"
        }
    }

    static func detail(_ banner: SensorBanner) -> String {
        switch banner {
        case .heartRate: return "No HR · iPhone → Health"
        case .motion: return "No steps · Settings → Privacy"
        case .heartRateAndMotion: return "No HR or steps · Settings"
        }
    }

    /// Current banner: heart rate from the last practice or workout (`SensorAccess` rule),
    /// Motion from its readable authorization status.
    static func current() -> SensorBanner? {
        let received: Bool? = UserDefaults.standard.object(forKey: SensorAccess.receivedHeartRateKey) as? Bool
        let status: CMAuthorizationStatus = CMMotionActivityManager.authorizationStatus()
        let motionDenied: Bool = status == .denied || status == .restricted
        return SensorAccess.banner(lastSessionReceivedHeartRate: received, motionDenied: motionDenied)
    }
}
