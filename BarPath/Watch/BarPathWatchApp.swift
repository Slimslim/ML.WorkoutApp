import SwiftUI

@main
struct BarPathWatchApp: App {
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
            if model.phase == .idle {
                StartView()
            } else {
                SessionView()
            }
        }
    }
}
