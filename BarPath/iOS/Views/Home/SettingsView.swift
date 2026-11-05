import SwiftUI

/// Everything used now and then: watch, account, privacy and the debug tools (story N8). Opened
/// from the avatar menu.
struct SettingsView: View {
    @EnvironmentObject private var link: PhoneLink
    @EnvironmentObject private var cloud: CloudAccount

    private static let privacyURL = URL(string: "https://github.com/Slimslim/ML.WorkoutApp/blob/main/PRIVACY.md")

    var body: some View {
        List {
            Section("Watch") {
                LabeledContent("Apple Watch", value: link.watchStatusText)
            }
            if cloud.isSignedIn {
                AccountSection()
            }
            if let url = SettingsView.privacyURL {
                Section {
                    Link("Privacy", destination: url)
                }
            }
            Section("For testing") {
                NavigationLink("Debug tools") {
                    DebugView()
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}
