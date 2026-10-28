import SwiftUI
import WatchKit
import HealthKit
import Combine
import BarPathKit

/// Receives the iPhone's "open the watch app" request (HKHealthStore.startWatchApp).
/// The app is brought to the foreground on the start screen; the athlete picks the lift
/// and taps Start, so no workout is started automatically.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Log.link.info("Opened from iPhone")
        // The phone opens us with a non-strength configuration when it sent a workout:
        // show the Workouts page (RootView reads this through @AppStorage).
        if workoutConfiguration.activityType != .traditionalStrengthTraining {
            UserDefaults.standard.set(1, forKey: "rootPage.v1")
        }
    }
}

@main
struct BarPathWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @StateObject private var model = SessionModel()
    @StateObject private var workoutModel = WorkoutSessionModel()

    init() {
        // The single WCSessionDelegate; activate as early as possible so queued/orphaned
        // files are sent and incoming state is ready.
        PhoneLink.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(workoutModel)
        }
    }
}

/// Lifting session → SessionView; workout session → WorkoutSessionView; otherwise two
/// horizontal pages: Lifting (StartView) and Workouts (WorkoutStartView). The last page is
/// remembered.
struct RootView: View {
    @EnvironmentObject var model: SessionModel
    @EnvironmentObject var workoutModel: WorkoutSessionModel
    @AppStorage("rootPage.v1") private var rootPage: Int = 0

    var body: some View {
        Group {
            if model.phase != .idle {
                SessionView()
            } else if workoutModel.phase != .idle {
                WorkoutSessionView()
            } else {
                TabView(selection: $rootPage) {
                    StartView()
                        .tag(0)
                    WorkoutStartView()
                        .tag(1)
                }
                .tabViewStyle(.page)
            }
        }
        .onReceive(PhoneLink.shared.$phoneWorkout) { (definition: WorkoutDefinition?) in
            guard let definition = definition else { return }
            workoutModel.selectFromPhone(definition)
            if model.phase == .idle && workoutModel.phase == .idle {
                rootPage = 1
                WKInterfaceDevice.current().play(.click)
            }
        }
    }
}
