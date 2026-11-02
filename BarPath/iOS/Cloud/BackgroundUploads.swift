import Foundation

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
    let bytes: Int
    let modified: Date
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

    /// Jobs iOS is still working on.
    func inFlight() async -> [UploadJob] {
        let tasks = await session.allTasks
        return tasks.compactMap { task in
            guard task.state != .canceling && task.state != .completed else { return nil }
            return Self.job(of: task)
        }
    }

    func enqueue(_ job: UploadJob, file: URL, contentType: String, accessToken: String) {
        let encoded = job.objectPath
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? job.objectPath
        guard let url = URL(string: "\(CloudConfig.url)/storage/v1/object/\(CloudConfig.bucket)/\(encoded)"),
              let description = try? String(data: JSONEncoder().encode(job), encoding: .utf8) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(CloudConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = description
        task.resume()
    }

    func cancelAll() async {
        for task in await session.allTasks { task.cancel() }
    }

    private static func job(of task: URLSessionTask) -> UploadJob? {
        guard let data = task.taskDescription?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(UploadJob.self, from: data)
    }

    // MARK: - URLSessionDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let job = Self.job(of: task) else { return }
        if (error as? URLError)?.code == .cancelled { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let failure: String?
        if let error {
            failure = error.localizedDescription
        } else if !(200..<300).contains(status) {
            failure = "HTTP \(status)"
        } else {
            failure = nil
        }
        Task { @MainActor in
            await CloudAccount.shared.uploadFinished(job, failure: failure)
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
