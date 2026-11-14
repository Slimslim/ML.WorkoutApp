import Foundation
import BarPathKit

/// One file handed to iOS for upload. Stored in the task's `taskDescription`, so a finished
/// upload can be recorded even when the app was relaunched in the background.
struct UploadJob: Codable {
    let userId: UUID
    /// Path relative to Documents, e.g. "Lifts/<session>/<id>.json".
    let path: String
    let version: String
    /// "<user id>/<path>" in the bucket.
    let objectPath: String
    let kind: String
    /// Size of the file actually sent (the gzip copy for recordings).
    let bytes: Int
    let modified: Date
    /// Name of the gzip copy in `BackgroundUploads.stagingURL`, deleted when the upload ends.
    /// Absent in jobs queued by older builds.
    var stagedFile: String? = nil
}

/// A gzip copy of a recording, waiting in the staging directory.
struct StagedFile {
    let url: URL
    let name: String
    let size: Int
}

/// Uploads through a background URLSession: iOS keeps sending the files while the app is
/// suspended or the phone is locked, and relaunches the app in the background when they finish.
/// Files go straight to the Storage REST endpoint with the user's access token; a token that
/// expires before iOS gets to a file makes that upload fail, and the next sync queues it again.
final class BackgroundUploads: NSObject, URLSessionDataDelegate {
    static let shared = BackgroundUploads()
    static let identifier = "com.slimslim.barpath.uploads"

    /// Set by the app delegate when iOS relaunches the app for this session's events.
    var eventsCompletion: (() -> Void)?

    private(set) lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // MARK: - Staging (gzip copies of recordings)

    /// Caches/UploadStaging: not the temp directory, which the system may purge while a
    /// background upload is still waiting for its file.
    static var stagingURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("UploadStaging", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a standard gzip copy of `source` to the staging directory. Slow for big files:
    /// call it off the main thread. The source file is not changed.
    static func stageGzip(of source: URL) throws -> StagedFile {
        let data: Data = try Data(contentsOf: source, options: .mappedIfSafe)
        let deflated: Data
        if data.isEmpty {
            deflated = Gzip.emptyDeflate
        } else {
            deflated = try (data as NSData).compressed(using: .zlib) as Data
        }
        let gz: Data = Gzip.wrap(deflated: deflated, of: data)
        let name: String = UUID().uuidString + ".csv.gz"
        let url: URL = stagingURL.appendingPathComponent(name)
        // Readable after the first unlock: the background upload reads it with the phone locked.
        try gz.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return StagedFile(url: url, name: name, size: gz.count)
    }

    /// Makes a file readable while the phone is locked (after the first unlock since boot), so a
    /// background sync can stage and upload it. Files moved in from WatchConnectivity keep the
    /// protection they had in its inbox; this sets the app's usual class explicitly.
    static func keepReadableWhenLocked(_ url: URL) {
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path)
        } catch {
            NSLog("BarPath: could not set file protection on %@: %@",
                  url.lastPathComponent, error.localizedDescription)
        }
    }

    static func removeStaged(_ name: String?) {
        guard let name, !name.isEmpty, !name.contains("/") else { return }
        try? FileManager.default.removeItem(at: stagingURL.appendingPathComponent(name))
    }

    /// Deletes staged files no running task refers to (leftovers of a crash or a sign-out).
    func cleanStaging() async {
        let tasks = await session.allTasks
        var keep = Set<String>()
        for task in tasks where task.state != .canceling && task.state != .completed {
            if let name = Self.job(of: task)?.stagedFile { keep.insert(name) }
        }
        let dir = Self.stagingURL
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where !keep.contains(name) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Jobs iOS is still working on.
    func inFlight() async -> [UploadJob] {
        let tasks = await session.allTasks
        return tasks.compactMap { task in
            guard task.state != .canceling && task.state != .completed else { return nil }
            return Self.job(of: task)
        }
    }

    func enqueue(_ job: UploadJob, file: URL, contentType: String, accessToken: String) {
        guard let request = Self.makeRequest(job, contentType: contentType, accessToken: accessToken),
              let description = try? String(data: JSONEncoder().encode(job), encoding: .utf8) else { return }
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = description
        task.resume()
    }

    /// Sends one file now with a normal request (not the background session), for a background
    /// wake where the background session would wait (W28). The caller records the outcome.
    static func uploadDirect(_ job: UploadJob, file: URL, contentType: String, accessToken: String,
                             timeout: TimeInterval) async -> (UploadOutcome, String?) {
        guard let request = makeRequest(job, contentType: contentType, accessToken: accessToken) else {
            return (.retryLater, "bad upload address")
        }
        var timed: URLRequest = request
        timed.timeoutInterval = timeout
        do {
            let (body, response) = try await URLSession.shared.upload(for: timed, fromFile: file)
            let status: Int = (response as? HTTPURLResponse)?.statusCode ?? 0
            let outcome: UploadOutcome = UploadOutcome.classify(status: status, body: body.prefix(2048), failed: false)
            return (outcome, outcome == .uploaded ? nil : "HTTP \(status)")
        } catch {
            return (.retryLater, error.localizedDescription)
        }
    }

    private static func makeRequest(_ job: UploadJob, contentType: String, accessToken: String) -> URLRequest? {
        let encoded = job.objectPath
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? job.objectPath
        guard let url = URL(string: "\(CloudConfig.url)/storage/v1/object/\(CloudConfig.bucket)/\(encoded)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(CloudConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        return request
    }

    func cancelAll() async {
        for task in await session.allTasks { task.cancel() }
    }

    private static func job(of task: URLSessionTask) -> UploadJob? {
        guard let data = task.taskDescription?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(UploadJob.self, from: data)
    }

    // MARK: - URLSessionDelegate

    /// First bytes of each response body, by task (an error answer is a small JSON text).
    /// Delegate calls arrive on the session's serial queue.
    private var bodies: [Int: Data] = [:]

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var body = bodies[dataTask.taskIdentifier] ?? Data()
        if body.count < 2048 { body.append(data) }
        bodies[dataTask.taskIdentifier] = body
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let body: Data = bodies.removeValue(forKey: task.taskIdentifier) ?? Data()
        guard let job = Self.job(of: task) else { return }
        if (error as? URLError)?.code == .cancelled {
            Self.removeStaged(job.stagedFile)
            return
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let outcome: UploadOutcome = UploadOutcome.classify(status: status, body: body, failed: error != nil)
        let failure: String?
        if let error {
            failure = error.localizedDescription
        } else if outcome != .uploaded {
            failure = "HTTP \(status)"
        } else {
            failure = nil
        }
        Task { @MainActor in
            await CloudAccount.shared.uploadFinished(job, outcome: outcome, failure: failure)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Give the row writes started above a moment before iOS suspends the app again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let completion = self.eventsCompletion
            self.eventsCompletion = nil
            completion?()
        }
    }
}
