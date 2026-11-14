import SwiftUI
import UIKit
import BarPathKit

/// W23: top of the Workouts tab, above Today (mockup docs/concepts/first-workout.html, approved
/// 13 Nov). Shown until access is back on: one line saying what is lost, one button to fix it.
///
/// Heart rate: iOS does not say whether reading heart rate was refused, so it follows the newest
/// workout the phone received from the watch (`SensorAccess.lastReceivedHeartRate`): one of 2 min or
/// more with no heart rate turns it on, any heart rate turns it off. It clears only when the next
/// such workout arrives (a watch practice sends nothing). Motion is not shown on the phone: steps
/// and reps use the watch's Motion permission, which only the watch can read (its start screen
/// shows it), and the phone app never asks for Motion itself.
struct WorkoutSensorBannerView: View {
    let banner: SensorBanner

    /// Mockup colours, with dark-mode values so the box stays readable in both.
    private static let fill = Color(uiColor: UIColor { (t: UITraitCollection) -> UIColor in
        t.userInterfaceStyle == .dark ? UIColor(red: 0.20, green: 0.13, blue: 0.08, alpha: 1)
            : UIColor(red: 1.0, green: 0.953, blue: 0.918, alpha: 1)               // #FFF3EA
    })
    private static let border = Color(uiColor: UIColor { (t: UITraitCollection) -> UIColor in
        t.userInterfaceStyle == .dark ? UIColor(red: 0.36, green: 0.22, blue: 0.13, alpha: 1)
            : UIColor(red: 0.957, green: 0.824, blue: 0.737, alpha: 1)             // #F4D2BC
    })
    private static let buttonFill = Color(red: 0.851, green: 0.412, blue: 0.180)   // #D9692E

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(WorkoutSensorBannerView.title(banner))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Text(WorkoutSensorBannerView.detail(banner))
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if banner != .motion {
                    actionButton("Turn on in Health") {
                        WorkoutSensorBannerView.openHealth()
                    }
                }
                if banner != .heartRate {
                    actionButton(banner == .motion ? "Open Settings" : "Motion settings") {
                        WorkoutSensorBannerView.openSettings()
                    }
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(WorkoutSensorBannerView.fill))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(WorkoutSensorBannerView.border, lineWidth: 1))
    }

    private func actionButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(WorkoutSensorBannerView.buttonFill))
        }
        .buttonStyle(.borderless)
    }

    static func title(_ banner: SensorBanner) -> String {
        switch banner {
        case .heartRate: return "Heart rate is off"
        case .motion: return "Motion is off"
        case .heartRateAndMotion: return "Heart rate and Motion are off"
        }
    }

    static func detail(_ banner: SensorBanner) -> String {
        switch banner {
        case .heartRate:
            return "Your workouts record time and splits, but no heart rate, calories or recovery. "
                + "In Health: Sharing → Apps → Rx Lab. Clears after your next workout."
        case .motion:
            return "No steps, distance or rep data. Turn on Motion & Fitness for Rx Lab."
        case .heartRateAndMotion:
            return "Your workouts record time and splits only: no heart rate, calories, recovery, "
                + "steps or reps. In Health: Sharing → Apps → Rx Lab. Clears after your next workout."
        }
    }

    /// The Health app (an app cannot open its own Sharing page there); Settings if it can't.
    static func openHealth() {
        guard let url = URL(string: "x-apple-health://") else {
            openSettings()
            return
        }
        UIApplication.shared.open(url, options: [:]) { (opened: Bool) in
            if !opened {
                openSettings()
            }
        }
    }

    /// This app's page in Settings (its Motion & Fitness switch is there once it was asked).
    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    /// Current banner for the phone (see the type comment).
    static func current(results: [WorkoutResult]) -> SensorBanner? {
        let received: Bool? = SensorAccess.lastReceivedHeartRate(results: results)
        return SensorAccess.banner(lastSessionReceivedHeartRate: received, motionDenied: false)
    }
}
