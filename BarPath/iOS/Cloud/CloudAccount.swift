import Foundation
import Supabase

/// Sign in with Apple (through Supabase Auth) and upload of every stored file to the user's
/// folder in Supabase Storage, with one row per file in the `uploads` table.
///
/// The files on the phone stay the source of truth; the cloud is a copy. A file is uploaded
/// again when its size or modification date changes (e.g. after "Fix splits").
@MainActor
final class CloudAccount: ObservableObject {
    static let shared = CloudAccount()

    @Published private(set) var userId: UUID?
    @Published private(set) var email: String?
    /// True until the stored session has been checked at launch (avoids flashing the sign-in screen).
    @Published private(set) var isRestoring = true
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastError: String?

    let client: SupabaseClient?
    private var syncAgain = false

    var isSignedIn: Bool { return userId != nil }

    private init() {
        if CloudConfig.isConfigured, let url = URL(string: CloudConfig.url) {
            client = SupabaseClient(supabaseURL: url, supabaseKey: CloudConfig.anonKey)
        } else {
            client = nil
            isRestoring = false
        }
    }

    // MARK: - Session

    /// Restores the saved session and follows sign-in / sign-out events.
    func start() {
        guard let client else { return }
        Task {
            for await (_, session) in client.auth.authStateChanges {
                apply(session)
                isRestoring = false
                if session != nil { syncSoon() }
            }
        }
    }

    private func apply(_ session: Session?) {
        if let session {
            userId = session.user.id
            email = session.user.email
        } else {
            userId = nil
            email = nil
        }
    }

    /// `idToken` and the raw `nonce` come from the Sign in with Apple button.
    func signInWithApple(idToken: String, nonce: String, fullName: PersonNameComponents?) async {
        guard let client else { return }
        lastError = nil
        do {
            let session = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce))
            apply(session)
            // Apple sends the name only on the very first sign-in: keep it.
            if let fullName {
                let name = PersonNameComponentsFormatter().string(from: fullName)
                if !name.isEmpty {
                    _ = try? await client.auth.update(user: UserAttributes(data: ["full_name": .string(name)]))
                }
            }
            syncSoon()
        } catch {
            lastError = "Sign in failed: \(error.localizedDescription)"
        }
    }

    func signOut() async {
        guard let client else { return }
        try? await client.auth.signOut()
        apply(nil)
    }

    /// Removes every uploaded file, the `uploads` rows and the account itself.
    /// The files on this phone are kept.
    func deleteAccount() async {
        guard let client, let userId else { return }
        lastError = nil
        do {
            let rows: [UploadPath] = try await client.from("uploads")
                .select("path")
                .eq("user_id", value: userId)
                .execute()
                .value
            let paths = rows.map { $0.path }
            var start = 0
            while start < paths.count {
                let batch = Array(paths[start..<min(start + 100, paths.count)])
                _ = try await client.storage.from(CloudConfig.bucket).remove(paths: batch)
                start += 100
            }
            try await client.rpc("delete_user").execute()
            UploadManifest.clear(userId: userId)
            try? await client.auth.signOut()
            apply(nil)
        } catch {
            lastError = "Could not delete the account: \(error.localizedDescription)"
        }
    }

    // MARK: - Upload

    /// Uploads new and changed files. Safe to call often: calls during a run are merged.
    func syncSoon() {
        guard client != nil, isSignedIn else { return }
        if isSyncing {
            syncAgain = true
            return
        }
        Task { await sync() }
    }

    private func sync() async {
        guard let client, let userId else { return }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            syncAgain = false
            var manifest = UploadManifest.load(userId: userId)
            let files = LocalFiles.all().filter { manifest[$0.path] != $0.version }
            pendingCount = files.count
            var failures = 0
            for file in files {
                do {
                    try await upload(file, userId: userId, client: client)
                    manifest[file.path] = file.version
                    UploadManifest.save(manifest, userId: userId)
                } catch {
                    failures += 1
                    lastError = "Upload failed for \(file.path): \(error.localizedDescription)"
                }
                pendingCount -= 1
            }
            if failures == 0 {
                lastError = nil
                lastSync = Date()
            }
        } while syncAgain
    }

    private func upload(_ file: LocalFile, userId: UUID, client: SupabaseClient) async throws {
        let data = try Data(contentsOf: file.url)
        let objectPath = userId.uuidString.lowercased() + "/" + file.path
        _ = try await client.storage.from(CloudConfig.bucket).upload(
            objectPath,
            data: data,
            options: FileOptions(contentType: file.contentType, upsert: true))
        let row = UploadRow(user_id: userId,
                            path: objectPath,
                            kind: file.kind,
                            bytes: data.count,
                            file_modified_at: file.modified)
        try await client.from("uploads")
            .upsert(row, onConflict: "user_id,path")
            .execute()
    }
}

// MARK: - Rows

private struct UploadRow: Encodable {
    let user_id: UUID
    let path: String
    let kind: String
    let bytes: Int
    let file_modified_at: Date
}

private struct UploadPath: Decodable {
    let path: String
}

// MARK: - Local files

private struct LocalFile {
    let url: URL
    /// Path relative to Documents, e.g. "Lifts/<session>/<id>.json".
    let path: String
    let kind: String
    let modified: Date
    let size: Int64

    var version: String { return "\(size)-\(Int(modified.timeIntervalSince1970))" }

    var contentType: String {
        switch url.pathExtension.lowercased() {
        case "json": return "application/json"
        case "csv": return "text/csv"
        default: return "application/octet-stream"
        }
    }
}

private enum LocalFiles {
    /// Every regular file under Documents/Lifts, Documents/Workouts and Documents/Debug.
    static func all() -> [LocalFile] {
        let documents = LiftFiles.documentsURL.standardizedFileURL
        let roots = [LiftFiles.liftsURL, WorkoutFiles.workoutsURL, LiftFiles.debugURL]
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        var found: [LocalFile] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root,
                                                                  includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else { continue }
                let full = url.standardizedFileURL.path
                guard full.hasPrefix(documents.path + "/") else { continue }
                let relative = String(full.dropFirst(documents.path.count + 1))
                let kind = relative.split(separator: "/").first.map { $0.lowercased() } ?? "other"
                found.append(LocalFile(url: url,
                                       path: relative,
                                       kind: kind,
                                       modified: values.contentModificationDate ?? Date(),
                                       size: Int64(values.fileSize ?? 0)))
            }
        }
        return found
    }
}

/// Which file versions are already uploaded, per user: Application Support/cloud-<user>.json.
private enum UploadManifest {
    private static func url(userId: UUID) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("cloud-\(userId.uuidString.lowercased()).json")
    }

    static func load(userId: UUID) -> [String: String] {
        guard let data = try? Data(contentsOf: url(userId: userId)),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    static func save(_ map: [String: String], userId: UUID) {
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: url(userId: userId), options: .atomic)
        }
    }

    static func clear(userId: UUID) {
        try? FileManager.default.removeItem(at: url(userId: userId))
    }
}
