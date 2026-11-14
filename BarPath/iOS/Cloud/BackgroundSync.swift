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

    /// Syncs now, holding a background task until the files are queued. The background task
    /// begins before this returns, so iOS cannot suspend the app between a WatchConnectivity
    /// callback and the sync.
    ///
    /// `awaitingFiles`: the watch's `pending` count from a `filesQueued` message. Its wake reaches
    /// the phone before the files, and a file that lands while the app is suspended is only
    /// delivered at the next wake. So in the background the sync first waits for those files
    /// (each one also starts its own run), while background time remains, at most 25 s.
    static func run(_ reason: String, awaitingFiles: Int = 0) {
        let activity = BackgroundActivity(name: "Rx Lab upload: " + reason)
        let arrivedBefore: Int = FileArrivals.count
        Task { @MainActor in
            let inBackground: Bool = UIApplication.shared.applicationState == .background
            if inBackground && awaitingFiles > 0 {
                await waitForFiles(awaitingFiles, arrivedBefore: arrivedBefore)
            }
            await CloudAccount.shared.syncAndWait()
            if inBackground && FileArrivals.count - arrivedBefore < awaitingFiles {
                // Files still on their way: ask for a refresh to pick them up.
                schedule(waiting: 1)
            }
            activity.end()
        }
    }

    /// Call from `session(_:didReceive:)` once a file is stored.
    static func noteFileReceived() {
        FileArrivals.increment()
    }

    @MainActor
    private static func waitForFiles(_ count: Int, arrivedBefore: Int) async {
        let app = UIApplication.shared
        var waited: Int = 0
        while FileArrivals.count - arrivedBefore < count && waited < 250 && !Task.isCancelled {
            // Keep enough time for the sync itself (sign-in, gzip, queueing).
            if app.backgroundTimeRemaining < 10 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
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

/// Files received from the watch since launch (any thread).
private enum FileArrivals {
    private static let lock = NSLock()
    private static var value: Int = 0

    static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    static func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

/// A UIApplication background task that begins in `init` (on any thread, synchronously) and
/// ends once: when the work is done, or when iOS says time is up.
final class BackgroundActivity: @unchecked Sendable {
    private static let invalidRaw: Int = UIBackgroundTaskIdentifier.invalid.rawValue
    private let lock = NSLock()
    private var rawId: Int = BackgroundActivity.invalidRaw
    private var ended = false

    init(name: String) {
        let begin: () -> Int = {
            MainActor.assumeIsolated {
                UIApplication.shared.beginBackgroundTask(withName: name) {
                    self.end()
                }.rawValue
            }
        }
        let raw: Int = Thread.isMainThread ? begin() : DispatchQueue.main.sync(execute: begin)
        lock.lock()
        let alreadyEnded: Bool = ended
        if !alreadyEnded { rawId = raw }
        lock.unlock()
        if alreadyEnded {
            // Expired before begin returned (practically never): end it now.
            BackgroundActivity.finish(raw)
        }
    }

    func end() {
        lock.lock()
        let first: Bool = !ended
        ended = true
        let raw: Int = rawId
        rawId = BackgroundActivity.invalidRaw
        lock.unlock()
        if first {
            BackgroundActivity.finish(raw)
        }
    }

    private static func finish(_ raw: Int) {
        guard raw != invalidRaw else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: raw))
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: raw))
                }
            }
        }
    }
}
