import SwiftUI
import UIKit
import HealthKit

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    private let healthStore = HKHealthStore()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Scan stored lifts first, then start WatchConnectivity so queued transfers are
        // delivered into a ready store.
        LiftStore.shared.loadIfNeeded()
        WorkoutStore.shared.loadIfNeeded()
        PhoneLink.shared.activate()
        CloudAccount.shared.start()
        // Reconnect to uploads iOS kept running while the app was not.
        _ = BackgroundUploads.shared.session
        return true
    }

    /// iOS relaunched the app in the background because uploads finished.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploads.identifier else {
            completionHandler()
            return
        }
        BackgroundUploads.shared.eventsCompletion = completionHandler
        _ = BackgroundUploads.shared.session
    }

    /// The watch app requests HealthKit authorization; the user approves it on the phone.
    func applicationShouldRequestHealthAuthorization(_ application: UIApplication) {
        healthStore.handleAuthorizationForExtension { _, _ in }
    }
}

@main
struct BarPathApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LiftStore.shared
    @StateObject private var workoutStore = WorkoutStore.shared
    @StateObject private var link = PhoneLink.shared
    @StateObject private var cloud = CloudAccount.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            GateView()
                .environmentObject(store)
                .environmentObject(workoutStore)
                .environmentObject(link)
                .environmentObject(cloud)
                .tint(Theme.accent)
                .onAppear {
                    store.loadIfNeeded()
                    workoutStore.loadIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        openWatchAppSoon()
                        cloud.syncSoon()
                    }
                }
        }
    }

    /// When the phone app comes to the foreground, bring BarPath up on the watch too.
    /// WatchConnectivity needs a moment after launch to report pairing/installation.
    private func openWatchAppSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let watch = PhoneLink.shared
            if !watch.isReachable {
                watch.launchWatchApp()
            }
        }
    }
}

/// Sign-in screen for testers when the cloud is configured; the app itself otherwise.
struct GateView: View {
    @EnvironmentObject private var cloud: CloudAccount

    var body: some View {
        if !CloudConfig.isConfigured || cloud.isSignedIn {
            RootView()
        } else if cloud.isRestoring {
            ProgressView()
        } else {
            SignInView()
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            LiveView()
                .tabItem {
                    Label("Live", systemImage: "waveform.path.ecg")
                }
            LiftChooserView()
                .tabItem {
                    Label("Lifts", systemImage: "figure.strengthtraining.traditional")
                }
            WorkoutListView()
                .tabItem {
                    Label("Workouts", systemImage: "figure.run")
                }
            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
            DebugView()
                .tabItem {
                    Label("Debug", systemImage: "ladybug")
                }
        }
    }
}
