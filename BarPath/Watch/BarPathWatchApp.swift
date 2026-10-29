import SwiftUI
import WatchKit
import HealthKit

/// Receives the iPhone's "open the watch app" request (HKHealthStore.startWatchApp).
/// The app is brought to the foreground on the start screen; the athlete picks the lift
/// and taps Start, so no workout is started automatically.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Log.link.info("Opened from iPhone")
    }
}

@main
struct BarPathWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @StateObject private var model = SessionModel()

    init() {
        // The single WCSessionDelegate; activate as early as possible so queued/orphaned
        // files are sent and incoming state is ready.
        PhoneLink.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: SessionModel

    var body: some View {
        Group {
            if model.phase == .idle || model.phase == .paused {
                StartView()
            } else {
                SessionView()
            }
        }
    }
}
