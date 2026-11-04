import SwiftUI

/// Everything used now and then: watch, account, privacy and the debug tools (story N8). Opened
/// from the avatar menu.
struct SettingsView: View {
    @EnvironmentObject private var link: PhoneLink
    @EnvironmentObject private var cloud: CloudAccount

    private static let privacyURL = URL(string: "https://github.com/Slimslim/ML.WorkoutApp/blob/main/PRIVACY.md")

    /// "1.0 (8)".
    private var versionText: String {
        let info: [String: Any] = Bundle.main.infoDictionary ?? [:]
        let version: String = info["CFBundleShortVersionString"] as? String ?? "?"
        let build: String = info["CFBundleVersion"] as? String ?? "?"
        return version + " (" + build + ")"
    }

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
            Section {
                LabeledContent("Version", value: versionText)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}
