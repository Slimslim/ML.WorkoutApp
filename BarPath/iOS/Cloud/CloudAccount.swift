import Foundation
import UIKit
import BarPathKit
import Supabase

/// Sign in with Apple (through Supabase Auth) and upload of every stored file to the user's
/// folder in Supabase Storage, with one row per file in the `uploads` table.
///
/// The files on the phone stay the source of truth; the cloud is a copy. A file is uploaded
/// again when its size or modification date changes (e.g. after "Fix splits").
///
/// Motion recordings (.csv) are big text files: a gzip copy is staged in Caches and uploaded
/// as "<path>.csv.gz"; the manifest still records the local .csv. A file the server refuses for
/// its size (bucket limit 50 MB) is remembered as skipped and not queued again until it changes.
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
    private var stagingCleaned = false
    /// Immediate re-queues after a refused token, per file version (W28).
    private var authRetries = UploadRetryBudget()
    /// The next sync gets a new access token even if the current one looks valid (after a refusal).
    private var forceTokenRefresh = false
    /// Files waiting that are still worth a background refresh (see `UploadFailureLog`).
    private var refreshWaiting = 0
    private static let failureLogKey = "uploadFailures.v1"

    /// Bucket limit per file (see supabase/migrations/20261102000000_uploads.sql).
    private static let maxUploadBytes: Int = 52_428_800

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
            let folder: String = userId.uuidString.lowercased()
            // Files are found by listing the folder (also those without an `uploads` row), plus the
            // rows' paths. A second listing catches an upload that finished during the first pass.
            let known: [String] = try await uploadRowPaths(userId: userId)
            let first: [String] = try await listObjects(folder: folder)
            try await removeObjects(known + first)
            let late: [String] = try await listObjects(folder: folder)
            try await removeObjects(late)
            try await client.rpc("delete_user").execute()
            UploadManifest.clear(userId: userId)
            PendingRows.clear(userId: userId)
            DownloadManifest.clear(userId: userId)
            SkippedFiles.clear(userId: userId)
            try? await client.auth.signOut()
            apply(nil)
            isSyncing = false
        } catch {
            lastError = "Could not delete the account: \(error.localizedDescription)"
        }
    }

    /// Paths of all the user's `uploads` rows, read page by page (the API caps one answer).
    private func uploadRowPaths(userId: UUID) async throws -> [String] {
        guard let client else { return [] }
        var paths: [String] = []
        let pageSize: Int = 1000
        while true {
            let rows: [UploadPath] = try await client.from("uploads")
                .select("path")
                .eq("user_id", value: userId)
                .order("path")
                .range(from: paths.count, to: paths.count + pageSize - 1)
                .execute()
                .value
            paths += rows.map { $0.path }
            if rows.count < pageSize { break }
        }
        return paths
    }

    /// Every object under `folder` in the bucket, subfolders included, page by page.
    /// A folder entry has no `id`; a file has one.
    private func listObjects(folder: String) async throws -> [String] {
        guard let client else { return [] }
        let bucket = client.storage.from(CloudConfig.bucket)
        let pageSize: Int = 100
        var files: [String] = []
        var pending: [String] = [folder]
        while let current = pending.popLast() {
            var offset: Int = 0
            while true {
                let page: [FileObject] = try await bucket.list(
                    path: current,
                    options: SearchOptions(limit: pageSize, offset: offset))   // sorted by name by default
                for entry in page {
                    let full: String = CloudPaths.join(folder: current, name: entry.name)
                    if entry.id == nil {
                        pending.append(full)
                    } else {
                        files.append(full)
                    }
                }
                offset += page.count
                if page.count < pageSize { break }
            }
        }
        return files
    }

    /// Deletes objects in batches of 100 (a path that is already gone is not an error).
    private func removeObjects(_ paths: [String]) async throws {
        guard let client else { return }
        for batch in CloudPaths.batches(paths, size: 100) {
            _ = try await client.storage.from(CloudConfig.bucket).remove(paths: batch)
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
            // In the background the few seconds iOS gives go to the uploads; corrections from
            // the cloud are checked at the next app open.
            if UIApplication.shared.applicationState != .background {
                await downloadCorrections(userId: userId)
            }
            if !stagingCleaned {
                stagingCleaned = true
                await BackgroundUploads.shared.cleanStaging()
            }
            let manifest = UploadManifest.load(userId: userId)
            let everything: [LocalFile] = LocalFiles.all()
            // Forget skipped versions that no longer exist (the file changed or was removed).
            var skipped: [String: String] = SkippedFiles.load(userId: userId)
            let currentVersions: [String: String] = Dictionary(everything.map { ($0.path, $0.version) },
                                                               uniquingKeysWith: { first, _ in first })
            let stillSkipped: [String: String] = skipped.filter { currentVersions[$0.key] == $0.value }
            if stillSkipped.count != skipped.count {
                skipped = stillSkipped
                SkippedFiles.save(skipped, userId: userId)
            }
            let files = everything.filter { manifest[$0.path] != $0.version && skipped[$0.path] != $0.version }
            pendingCount = files.count
            var failures: UploadFailureLog = CloudAccount.loadFailures()
            let waitingKeys = Set(files.map { UploadRetryBudget.key(path: $0.path, version: $0.version) })
            failures.keepOnly(waitingKeys)
            CloudAccount.saveFailures(failures)
            refreshWaiting = waitingKeys.filter { failures.keepsRefreshing($0) }.count
            guard !files.isEmpty else {
                isSyncing = false
                if lastError == nil { lastSync = Date() }
                continue
            }
            let token: String
            do {
                if forceTokenRefresh {
                    // The server refused the last token: the client may still think it is valid
                    // (clock skew), so ask for a new one.
                    forceTokenRefresh = false
                    token = try await client.auth.refreshSession().accessToken
                } else {
                    token = try await client.auth.session.accessToken
                }
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
                var objectPath: String = userId.uuidString.lowercased() + "/" + file.path
                var uploadURL: URL = file.url
                var contentType: String = file.contentType
                var bytes: Int = Int(file.size)
                var stagedName: String? = nil
                if file.url.pathExtension.lowercased() == "csv" {
                    let source: URL = file.url
                    let staged: StagedFile? = await Task.detached(priority: .utility) { () -> StagedFile? in
                        return try? BackgroundUploads.stageGzip(of: source)
                    }.value
                    guard let staged else {
                        lastError = "Upload failed for \(file.path): could not compress it"
                        continue
                    }
                    if self.userId != userId {
                        BackgroundUploads.removeStaged(staged.name)
                        return
                    }
                    objectPath += ".gz"
                    uploadURL = staged.url
                    contentType = "application/gzip"
                    bytes = staged.size
                    stagedName = staged.name
                }
                if bytes > CloudAccount.maxUploadBytes {
                    // Even compressed it can never upload: remember it and stop trying.
                    BackgroundUploads.removeStaged(stagedName)
                    noteTooLarge(file.path, version: file.version, userId: userId)
                    continue
                }
                let job = UploadJob(userId: userId,
                                    path: file.path,
                                    version: file.version,
                                    objectPath: objectPath,
                                    kind: file.kind,
                                    bytes: bytes,
                                    modified: file.modified,
                                    stagedFile: stagedName)
                if await uploadNowIfBackground(job, file: uploadURL, contentType: contentType, token: token) {
                    continue
                }
                BackgroundUploads.shared.enqueue(job, file: uploadURL,
                                                 contentType: contentType, accessToken: token)
            }
            if await BackgroundUploads.shared.inFlight().isEmpty {
                // Everything left was skipped: no upload will report back.
                isSyncing = false
            }
        } while syncAgain
    }

    /// One sync for a background wake (watch message, received file, app refresh): waits for the
    /// saved sign-in to be restored, queues everything, and returns once the files are handed to
    /// the background URLSession. Then asks for a background refresh if anything is left.
    func syncAndWait() async {
        guard let client else { return }
        // Launched in the background: the auth listener may not have restored the session yet.
        var waited: Int = 0
        while isRestoring && waited < 100 && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        // Restored as signed out while the keychain was not readable yet (before the first
        // unlock since boot): read it again now.
        if userId == nil, let session = client.auth.currentSession {
            apply(session)
        }
        guard isSignedIn else { return }
        await sync()
        // A sync already running took this request over (`syncAgain`): wait for it to finish.
        waited = 0
        while isQueueing && waited < 600 && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        BackgroundSync.schedule(waiting: refreshWaiting)
    }

    /// Largest file sent directly during a background wake; bigger ones go to the background session.
    private static let directUploadMaxBytes: Int = 5_000_000

    /// In the background, iOS starts background-session uploads at its own discretion (it may wait
    /// for Wi-Fi and power). So while the app is awake in the background (watch wake, refresh),
    /// files are sent right away with a normal request, while time remains. Returns true when the
    /// upload ended (uploaded or refused for good); false to hand the file to the background session.
    private func uploadNowIfBackground(_ job: UploadJob, file: URL, contentType: String, token: String) async -> Bool {
        let app = UIApplication.shared
        guard app.applicationState == .background,
              job.bytes <= CloudAccount.directUploadMaxBytes,
              app.backgroundTimeRemaining > 15,
              !Task.isCancelled else { return false }
        let result: (UploadOutcome, String?) = await BackgroundUploads.uploadDirect(
            job, file: file, contentType: contentType, accessToken: token,
            timeout: min(20, app.backgroundTimeRemaining - 8))
        if result.0 == .retryLater {
            // Timed out or no network: the background session keeps trying (staged copy kept).
            return false
        }
        await uploadFinished(job, outcome: result.0, failure: result.1)
        return true
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
            // The build is part of the date: a file this build could not read is tried again by the next.
            let stamp: String = object.updatedAt.map { CloudAccount.appBuild + ":" + String($0.timeIntervalSince1970) } ?? ""
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

    private static let appBuild: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""

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
    func uploadFinished(_ job: UploadJob, outcome: UploadOutcome, failure: String?) async {
        BackgroundUploads.removeStaged(job.stagedFile)
        let retryKey: String = UploadRetryBudget.key(path: job.path, version: job.version)
        switch outcome {
        case .tooLarge:
            noteTooLarge(job.path, version: job.version, userId: job.userId)
        case .authRejected:
            lastError = "Upload failed for \(job.path): \(failure ?? "sign-in refused")"
            // The token expired while the upload waited: queue it again now with a fresh one
            // (a few times per file version), else at the next background refresh.
            // `userId` is still nil when iOS relaunched the app for these events and the saved
            // sign-in is not restored yet; `syncAndWait` waits for it and checks the user.
            if (userId == nil || job.userId == userId) && authRetries.take(retryKey) {
                forceTokenRefresh = true
                BackgroundSync.run("token refresh")
            } else {
                BackgroundSync.schedule(waiting: 1)
            }
        case .retryLater:
            lastError = "Upload failed for \(job.path): \(failure ?? "unknown error")"
            var failures: UploadFailureLog = CloudAccount.loadFailures()
            failures.recordFailure(retryKey)
            CloudAccount.saveFailures(failures)
            if failures.keepsRefreshing(retryKey) {
                BackgroundSync.schedule(waiting: 1)
            }
        case .uploaded:
            authRetries.reset(retryKey)
            var failures: UploadFailureLog = CloudAccount.loadFailures()
            failures.recordSuccess(retryKey)
            CloudAccount.saveFailures(failures)
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

    private static func loadFailures() -> UploadFailureLog {
        let raw = UserDefaults.standard.dictionary(forKey: failureLogKey) as? [String: Int] ?? [:]
        return UploadFailureLog(counts: raw)
    }

    private static func saveFailures(_ log: UploadFailureLog) {
        if log.counts.isEmpty {
            UserDefaults.standard.removeObject(forKey: failureLogKey)
        } else {
            UserDefaults.standard.set(log.counts, forKey: failureLogKey)
        }
    }

    /// Remembers a file version the server can never take, and says so in `lastError`
    /// (cleared by the next sync, which no longer queues the file).
    private func noteTooLarge(_ path: String, version: String, userId: UUID) {
        var skipped: [String: String] = SkippedFiles.load(userId: userId)
        skipped[path] = version
        SkippedFiles.save(skipped, userId: userId)
        if userId == self.userId { pendingCount = max(0, pendingCount - 1) }
        lastError = skipped.count == 1 ? "1 file too large to upload"
                                       : "\(skipped.count) files too large to upload"
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
    /// Every regular file under Documents/Lifts, Documents/Workouts, Documents/Debug and
    /// Documents/Profile (the athlete's unit and body details, kind "profile").
    static func all() -> [LocalFile] {
        AthleteProfile.shared.writeProfileFile()
        let documents = LiftFiles.documentsURL.standardizedFileURL
        let roots = [LiftFiles.liftsURL, WorkoutFiles.workoutsURL, LiftFiles.debugURL,
                     AthleteProfile.profileFolderURL]
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

/// Cloud workout files already checked for corrections (name → build:cloud updated time), per user:
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

/// File versions the server refused for their size (path → version, same key as the upload
/// manifest), per user: Application Support/cloud-<user>-skipped.json. Not queued again.
private enum SkippedFiles {
    private static func url(userId: UUID) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("cloud-\(userId.uuidString.lowercased())-skipped.json")
    }

    static func load(userId: UUID) -> [String: String] {
        guard let data = try? Data(contentsOf: url(userId: userId)),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    static func save(_ map: [String: String], userId: UUID) {
        if map.isEmpty {
            clear(userId: userId)
        } else if let data = try? JSONEncoder().encode(map) {
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
