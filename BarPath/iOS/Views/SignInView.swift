import SwiftUI
import AuthenticationServices
import CryptoKit

/// First screen for testers: what the app collects, then Sign in with Apple.
struct SignInView: View {
    @EnvironmentObject private var cloud: CloudAccount
    @State private var nonce = ""
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Text("Rx Lab")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                Text("A second opinion on every workout.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                Label("Your lifts, workouts and watch recordings are saved to your account, so they are safe and can be shown back to you.",
                      systemImage: "icloud.and.arrow.up")
                Label("This test version also helps improve lift detection: the owner of Rx Lab can see the uploaded recordings and heart rate.",
                      systemImage: "waveform.path.ecg")
                Label("Never used for ads. Delete your account and all uploaded data at any time in the app.",
                      systemImage: "trash")
            }
            .font(.subheadline)
            Spacer()
            if let error = cloud.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Color.red)
            }
            SignInWithAppleButton(.continue) { request in
                nonce = Self.randomNonce()
                request.requestedScopes = [.fullName, .email]
                request.nonce = Self.sha256(nonce)
            } onCompletion: { result in
                handle(result)
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 50)
            .disabled(isWorking)
            .overlay {
                if isWorking { ProgressView() }
            }
            Text("By continuing you agree that your training data is stored as described above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .preferredColorScheme(.dark)
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else { return }
            isWorking = true
            Task {
                await cloud.signInWithApple(idToken: idToken, nonce: nonce, fullName: credential.fullName)
                isWorking = false
            }
        case .failure:
            // Cancelled or failed in Apple's sheet; the sheet already told the user.
            break
        }
    }

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in charset.randomElement(using: &generator)! })
    }

    private static func sha256(_ text: String) -> String {
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Account and upload status, in Settings.
struct AccountSection: View {
    @EnvironmentObject private var cloud: CloudAccount
    @State private var confirmDelete = false

    var body: some View {
        Section {
            LabeledContent("Signed in", value: cloud.email ?? "Apple ID")
            LabeledContent("Upload") {
                if cloud.isSyncing {
                    Text("\(cloud.pendingCount) left…")
                } else if let date = cloud.lastSync {
                    Text("Up to date · \(date.formatted(date: .omitted, time: .shortened))")
                } else {
                    Text("Waiting")
                }
            }
            if let error = cloud.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.orange)
            }
            Button("Upload now") { cloud.syncSoon() }
                .disabled(cloud.isSyncing)
            Button("Sign out") {
                Task { await cloud.signOut() }
            }
            Button("Delete account and uploaded data", role: .destructive) {
                confirmDelete = true
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Every lift, workout and recording is uploaded to your Rx Lab account. Files on this phone are kept.")
        }
        .confirmationDialog("Delete your account and everything uploaded? Files on this phone stay.",
                            isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete account", role: .destructive) {
                Task { await cloud.deleteAccount() }
            }
        }
    }
}
