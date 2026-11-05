import Foundation
import BarPathKit
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
    private var isQueueing = false
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
        await BackgroundUploads.shared.cancelAll()
        try? await client.auth.signOut()
        apply(nil)
        isSyncing = false
    }

    /// Removes every uploaded file, the `uploads` rows and the account itself.
    /// The files on this phone are kept.
    func deleteAccount() async {
        guard let client, let userId else { return }
        lastError = nil
        await BackgroundUploads.shared.cancelAll()
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
            PendingRows.clear(userId: userId)
            DownloadManifest.clear(userId: userId)
            try? await client.auth.signOut()
            apply(nil)
            isSyncing = false
        } catch {
            lastError = "Could not delete the account: \(error.localizedDescription)"
        }
    }

    // MARK: - Upload

    /// Queues new and changed files for upload. Safe to call often: calls during a run are merged.
    func syncSoon() {
        guard client != nil, isSignedIn else { return }
        if isQueueing {
            syncAgain = true
            return
        }
        Task { await sync() }
    }

    /// Hands every file not yet uploaded to `BackgroundUploads`, which keeps going while the app
    /// is suspended; `uploadFinished` records each one. Also retries rows that could not be written.
    private func sync() async {
        guard let client, let userId else { return }
        if isQueueing {
            syncAgain = true
            return
        }
        isQueueing = true
        defer { isQueueing = false }
        repeat {
            syncAgain = false
            await writePendingRows(userId: userId)
            await downloadCorrections(userId: userId)
            let manifest = UploadManifest.load(userId: userId)
            let files = LocalFiles.all().filter { manifest[$0.path] != $0.version }
            pendingCount = files.count
            guard !files.isEmpty else {
                isSyncing = false
                if lastError == nil { lastSync = Date() }
                continue
            }
            let token: String
            do {
                token = try await client.auth.session.accessToken
            } catch {
                lastError = "Upload paused: \(error.localizedDescription)"
                return
            }
            let busy = Set(await BackgroundUploads.shared.inFlight()
                .filter { $0.userId == userId }
                .map { $0.path })
            lastError = nil
            isSyncing = true
            for file in files where !busy.contains(file.path) {
                let job = UploadJob(userId: userId,
                                    path: file.path,
                                    version: file.version,
                                    objectPath: userId.uuidString.lowercased() + "/" + file.path,
                                    kind: file.kind,
                                    bytes: Int(file.size),
                                    modified: file.modified)
                BackgroundUploads.shared.enqueue(job, file: file.url,
                                                 contentType: file.contentType, accessToken: token)
            }
        } while syncAgain
    }

    /// Pull to refresh in the Log: one sync now (downloads corrections, queues uploads).
    func refreshNow() async {
        guard client != nil, isSignedIn else { return }
        await sync()
    }

    // MARK: - Corrections from the cloud (story W17)

    /// Prefix of the errors set by `downloadCorrections` (cleared at its next run).
    private static let correctionErrorPrefix = "Corrected workouts: "

    /// Replaces a workout result on the phone with the copy in the user's Storage folder when
    /// that copy is a later correction (`WorkoutCloudCorrection.shouldReplace`). The phone's
    /// previous copy is kept as <id>.original.json (Restore original), and the written files are
    /// marked as uploaded so they are not sent back. Only results already on the phone and with
    /// nothing waiting to upload are considered (a phone change not yet in the cloud always
    /// wins); files whose cloud date has not changed since the last check are skipped.
    private func downloadCorrections(userId: UUID) async {
        guard let client else { return }
        if let error = lastError, error.hasPrefix(CloudAccount.correctionErrorPrefix) {
            lastError = nil
        }
        let folder: String = userId.uuidString.lowercased() + "/" + WorkoutFiles.workoutsURL.lastPathComponent
        let bucket = client.storage.from(CloudConfig.bucket)
        var objects: [FileObject] = []
        let pageSize: Int = 500
        do {
            while true {
                let page: [FileObject] = try await bucket.list(
                    path: folder, options: SearchOptions(limit: pageSize, offset: objects.count))
                objects += page
                if page.count < pageSize { break }
            }
        } catch {
            lastError = CloudAccount.correctionErrorPrefix + "could not check: \(error.localizedDescription)"
            return
        }
        let store: WorkoutStore = WorkoutStore.shared
        store.loadIfNeeded()
        let uploaded: [String: String] = UploadManifest.load(userId: userId)
        let busy = Set(await BackgroundUploads.shared.inFlight()
            .filter { $0.userId == userId }
            .map { $0.path })
        var seen: [String: String] = DownloadManifest.load(userId: userId)
        for object in objects {
            guard let id = WorkoutCloudCorrection.resultId(fileName: object.name),
                  store.result(id: id) != nil else { continue }
            let url: URL = WorkoutFiles.fileURL(id: id)
            // A phone change not yet uploaded (or uploading) wins: check again after it is sent.
            guard let path = CloudAccount.relativePath(url), !busy.contains(path),
                  let version = CloudAccount.localVersion(url), uploaded[path] == version else { continue }
            let stamp: String = object.updatedAt.map { String($0.timeIntervalSince1970) } ?? ""
            if !stamp.isEmpty && seen[object.name] == stamp { continue }
            let cloud: WorkoutResult
            do {
                let data: Data = try await bucket.download(path: folder + "/" + object.name)
                cloud = try WorkoutResult.decode(from: data)
            } catch is DecodingError {
                // Not a result this build can read: don't download it again until it changes.
                seen[object.name] = stamp
                lastError = CloudAccount.correctionErrorPrefix + "\(object.name) is not readable"
                continue
            } catch {
                lastError = CloudAccount.correctionErrorPrefix + "\(object.name): \(error.localizedDescription)"
                continue
            }
            // Read the phone's copy again: it may have been edited during the download.
            guard let local = store.result(id: id) else { continue }
            if WorkoutCloudCorrection.shouldReplace(local: local, with: cloud) {
                let hadOriginal: Bool = WorkoutFiles.hasOriginal(id: id)
                guard store.saveEdited(cloud) else { continue }   // retried at the next sync
                markUploaded(url: url, userId: userId)
                if !hadOriginal {
                    // Keep the cloud's <id>.original.json (the watch copy) as it is.
                    markUploaded(url: WorkoutFiles.originalURL(id: id), userId: userId)
                }
            }
            seen[object.name] = stamp
        }
        DownloadManifest.save(seen, userId: userId)
    }

    /// Path relative to Documents ("Workouts/<id>.json"), as `LocalFile.path`.
    private static func relativePath(_ url: URL) -> String? {
        let documents = LiftFiles.documentsURL.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(documents + "/") else { return nil }
        return String(full.dropFirst(documents.count + 1))
    }

    /// The file's current version string, as `LocalFile.version`; nil when it does not exist.
    private static func localVersion(_ url: URL) -> String? {
        var fresh: URL = url
        fresh.removeAllCachedResourceValues()   // the file may have just been rewritten
        guard let values = try? fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return nil
        }
        return "\(Int64(values.fileSize ?? 0))-\(Int((values.contentModificationDate ?? Date()).timeIntervalSince1970))"
    }

    /// Records a file just written from the cloud as already uploaded, so the next sync does not
    /// send it back.
    private func markUploaded(url: URL, userId: UUID) {
        guard let path = CloudAccount.relativePath(url), let version = CloudAccount.localVersion(url) else { return }
        var manifest = UploadManifest.load(userId: userId)
        manifest[path] = version
        UploadManifest.save(manifest, userId: userId)
    }

    /// Called for each file iOS finished sending (also after a background relaunch).
    func uploadFinished(_ job: UploadJob, failure: String?) async {
        if let failure {
            lastError = "Upload failed for \(job.path): \(failure)"
        } else {
            var manifest = UploadManifest.load(userId: job.userId)
            manifest[job.path] = job.version
            UploadManifest.save(manifest, userId: job.userId)
            var rows = PendingRows.load(userId: job.userId)
            rows[job.objectPath] = UploadRow(user_id: job.userId,
                                             path: job.objectPath,
                                             kind: job.kind,
                                             bytes: job.bytes,
                                             file_modified_at: job.modified)
            PendingRows.save(rows, userId: job.userId)
            if job.userId == userId { pendingCount = max(0, pendingCount - 1) }
            await writePendingRows(userId: job.userId)
        }
        if await BackgroundUploads.shared.inFlight().isEmpty {
            isSyncing = false
            if lastError == nil { lastSync = Date() }
        }
    }

    /// Writes the `uploads` rows of files already in Storage. A row that fails (e.g. no network
    /// in the background) stays queued for the next sync; the file itself is not sent again.
    private func writePendingRows(userId: UUID) async {
        guard let client else { return }
        var rows = PendingRows.load(userId: userId)
        guard !rows.isEmpty else { return }
        do {
            try await client.from("uploads")
                .upsert(Array(rows.values), onConflict: "user_id,path")
                .execute()
            rows.removeAll()
        } catch {
            lastError = "Could not record uploads: \(error.localizedDescription)"
        }
        PendingRows.save(rows, userId: userId)
    }
}

// MARK: - Rows

private struct UploadRow: Codable {
    let user_id: UUID
    let path: String
    let kind: String
    let bytes: Int
    let file_modified_at: Date
}

/// Rows of uploaded files not yet written to the `uploads` table, by object path.
private enum PendingRows {
    private static func url(userId: UUID) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("cloud-\(userId.uuidString.lowercased())-rows.json")
    }

    static func load(userId: UUID) -> [String: UploadRow] {
        guard let data = try? Data(contentsOf: url(userId: userId)),
              let rows = try? JSONDecoder().decode([String: UploadRow].self, from: data) else { return [:] }
        return rows
    }

    static func save(_ rows: [String: UploadRow], userId: UUID) {
        if rows.isEmpty {
            clear(userId: userId)
        } else if let data = try? JSONEncoder().encode(rows) {
            try? data.write(to: url(userId: userId), options: .atomic)
        }
    }

    static func clear(userId: UUID) {
        try? FileManager.default.removeItem(at: url(userId: userId))
    }
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

/// Cloud workout files already checked for corrections (name → cloud updated time), per user:
/// Application Support/cloud-<user>-downloads.json.
private enum DownloadManifest {
    private static func url(userId: UUID) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("cloud-\(userId.uuidString.lowercased())-downloads.json")
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
