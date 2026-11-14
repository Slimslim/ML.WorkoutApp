import Foundation
import UIKit
import BackgroundTasks
import BarPathKit

/// Uploads without the app on screen (story W28).
///
/// - The watch sends a `filesQueued` message at END and after each file it delivered; a watch
///   message wakes the iPhone app in the background. `run(_:)` then keeps the app awake (a
///   UIApplication background task, about 30 s) while the sign-in is restored, the recordings are
///   gzip-staged and handed to the background URLSession, which goes on with the phone locked.
/// - A background app refresh (`BGAppRefreshTask`) is the safety net: it is scheduled whenever
///   files are left to upload, and runs a sync with a fresh token (an upload that waited past the
///   token's hour fails with 401 and is queued again here).
///
/// `run` and `schedule` are callable from any thread.
enum BackgroundSync {
    static let refreshIdentifier = "com.slimslim.barpath.upload-refresh"

    /// Syncs now, holding a background task until the files are queued.
    static func run(_ reason: String) {
        Task { @MainActor in
            let activity = BackgroundActivity(name: "Rx Lab upload: " + reason)
            await CloudAccount.shared.syncAndWait()
            activity.end()
        }
    }

    // MARK: - Background app refresh

    /// Call before `didFinishLaunching` returns (iOS requires registration at launch).
    static func register() {
        let ok: Bool = BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshIdentifier,
                                                       using: nil) { task in
            handle(task)
        }
        if !ok {
            NSLog("BarPath: upload refresh task not registered (missing from Info.plist?)")
        }
    }

    /// Asks iOS for a background refresh while `waiting` files are not yet in the cloud; cancels
    /// the request when nothing is waiting. A newer request replaces the older one.
    static func schedule(waiting: Int) {
        guard let date = UploadRefreshPlan.nextRefresh(waiting: waiting, now: Date()) else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshIdentifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = date
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Simulator, Background App Refresh off in Settings, or too many requests: the next
            // wake or app open still uploads.
            NSLog("BarPath: could not schedule the upload refresh: %@", error.localizedDescription)
        }
    }

    private static func handle(_ task: BGTask) {
        let done = TaskOnce(task)
        let work = Task { @MainActor in
            await CloudAccount.shared.syncAndWait()
            done.complete(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            done.complete(success: false)
        }
    }
}

/// Completes a BGTask exactly once (the work and the expiration handler race).
private final class TaskOnce: @unchecked Sendable {
    private let task: BGTask
    private let lock = NSLock()
    private var completed = false

    init(_ task: BGTask) {
        self.task = task
    }

    func complete(success: Bool) {
        lock.lock()
        let first: Bool = !completed
        completed = true
        lock.unlock()
        if first {
            task.setTaskCompleted(success: success)
        }
    }
}

/// A UIApplication background task that ends once: when the work is done, or when iOS says
/// time is up (the expiration handler runs on the main thread).
@MainActor
final class BackgroundActivity {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        let id: UIBackgroundTaskIdentifier = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }
}
