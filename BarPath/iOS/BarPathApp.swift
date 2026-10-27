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
        PhoneLink.shared.activate()
        return true
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
    @StateObject private var link = PhoneLink.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(link)
                .tint(Theme.accent)
                .onAppear {
                    store.loadIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        openWatchAppSoon()
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

struct RootView: View {
    var body: some View {
        TabView {
            LiveView()
                .tabItem {
                    Label("Live", systemImage: "waveform.path.ecg")
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
