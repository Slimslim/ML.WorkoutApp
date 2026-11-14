import Foundation
import Combine
import WatchConnectivity
import BarPathKit

/// Where the watch keeps files.
///
/// - `Outbox`: finished files waiting for (or in) a WatchConnectivity transfer. A file is
///   deleted only after `didFinish fileTransfer` reports success; anything left here at
///   launch is re-sent, so a crash or a failed transfer never silently drops a lift.
/// - `Recording`: the debug CSV while it is still being written. Moved to `Outbox` at End.
enum WatchFiles {
    static var outbox: URL { directory("Outbox") }
    static var recording: URL { directory("Recording") }

    private static func directory(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                Log.files.error("Could not create \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return url
    }
}

/// The single WCSessionDelegate of the watch app (one shared instance).
///
/// Thread-safety: WatchConnectivity calls the delegate on a background queue. All mutable
/// state of this class is only touched on the main queue (`DispatchQueue.main.async`).
/// The class is intentionally not actor-isolated so it can be called from anywhere.
final class PhoneLink: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = PhoneLink()

    /// Number of file transfers still queued/in flight.
    @Published private(set) var pendingTransfers = 0
    @Published private(set) var isReachable = false
    /// Workout picked on the iPhone ("selectWorkout" application context / message).
    @Published private(set) var phoneWorkout: WorkoutDefinition?
    /// Lift + load picked on the iPhone's Lifts tab (`liftSelection` in context / message).
    @Published private(set) var phoneLift: LiftSelection?
    /// Weight unit for lift loads: the phone's choice (`weightUnit` in context / message), kept on
    /// the watch so it works with the phone out of reach. Until the phone sends one, the watch's
    /// own region decides.
    @Published private(set) var weightUnit: WeightUnit = PhoneLink.storedWeightUnit()

    private struct QueuedFile {
        let url: URL
        let metadata: [String: Any]
    }

    // Main-queue only.
    private var queuedUntilActivated: [QueuedFile] = []
    private var retryCounts: [String: Int] = [:]
    private var activated = false
    private static let maxRetries = 3
    /// Upload wake for the phone (W28): owed after a file is queued or delivered, sent as soon as
    /// the phone is reachable, at most once per `wakeInterval` (a later one carries the news).
    private var wakeOwed = false
    private var wakeScheduled = false
    private var lastWakeAt: Date = .distantPast
    private static let wakeInterval: TimeInterval = 5
    /// Message `type` of the upload wake (message only, never in the application context).
    static let filesQueuedType = "filesQueued"
    /// `sentAt` of the last applied phone workout, persisted so an old application context
    /// re-delivered at launch doesn't override a later choice made on the watch.
    private static let phoneWorkoutSentAtKey = "phoneWorkoutSentAt.v1"
    private static let phoneLiftSentAtKey = "phoneLiftSentAt.v1"
    /// UserDefaults key and application context key of the weight unit ("kg" or "lb").
    static let weightUnitKey = "weightUnit"

    static func storedWeightUnit() -> WeightUnit {
        if let raw = UserDefaults.standard.string(forKey: weightUnitKey), let unit = WeightUnit(rawValue: raw) {
            return unit
        }
        return WeightUnit.defaultUnit(metric: Locale.current.measurementSystem == .metric)
    }

    /// Whether the last phone choice was a lift (Lifting page) rather than a workout.
    var lastPhoneChoiceWasLift: Bool {
        let defaults = UserDefaults.standard
        return defaults.double(forKey: PhoneLink.phoneLiftSentAtKey)
            > defaults.double(forKey: PhoneLink.phoneWorkoutSentAtKey)
    }

    private override init() {
        super.init()
    }

    /// Call once at launch.
    func activate() {
        // A debug CSV left in Recording means the app died mid-session: move it to the
        // outbox (it was flushed per batch) so it gets sent like any other file.
        moveStaleRecordingsToOutbox()
        guard WCSession.isSupported() else {
            Log.link.error("WCSession not supported")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Queue a file for transfer to the phone. The file must stay where it is until the
    /// transfer finishes; PhoneLink deletes it then. Never gated on reachability:
    /// transferFile queues and delivers later.
    func sendFile(_ url: URL, metadata: [String: Any]) {
        DispatchQueue.main.async {
            self.enqueue(QueuedFile(url: url, metadata: metadata))
        }
    }

    /// Optional live status for the phone; dropped silently if the phone app isn't reachable.
    func sendStatus(_ message: [String: Any]) {
        DispatchQueue.main.async {
            let session = WCSession.default
            guard self.activated, session.activationState == .activated, session.isReachable else { return }
            session.sendMessage(message, replyHandler: nil) { error in
                Log.link.debug("status message failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Private (main queue)

    private func enqueue(_ file: QueuedFile) {
        guard FileManager.default.fileExists(atPath: file.url.path) else {
            Log.link.error("File to send does not exist: \(file.url.lastPathComponent, privacy: .public)")
            return
        }
        let session = WCSession.default
        guard activated, session.activationState == .activated else {
            Log.link.info("Session not activated yet, queueing \(file.url.lastPathComponent, privacy: .public)")
            queuedUntilActivated.append(file)
            pendingTransfers = queuedUntilActivated.count
            return
        }
        session.transferFile(file.url, metadata: file.metadata)
        Log.link.info("transferFile \(file.url.lastPathComponent, privacy: .public)")
        refreshPendingCount()
        // Wake the phone app now too: an activated session on the phone receives the transfer
        // as soon as it lands, instead of waiting for the next launch.
        wakePhone()
    }

    /// Tells the phone app files are on their way or arrived (W28). A watch message wakes the
    /// iPhone app in the background even when it is closed and the phone is locked; it then
    /// uploads to the cloud without being opened. Needs the phone reachable (watch app in front or
    /// in a workout); otherwise it goes out when the phone becomes reachable.
    private func wakePhone() {
        wakeOwed = true
        // On the next main-queue turn: END queues the result and the recording in separate
        // main-queue blocks, so the wake goes out after both with `pending` counting both.
        DispatchQueue.main.async {
            self.sendWakeIfPossible()
        }
    }

    private func sendWakeIfPossible() {
        guard wakeOwed, !wakeScheduled else { return }
        let session = WCSession.default
        guard activated, session.activationState == .activated, session.isReachable else { return }
        let elapsed: TimeInterval = Date().timeIntervalSince(lastWakeAt)
        if elapsed < PhoneLink.wakeInterval {
            wakeScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (PhoneLink.wakeInterval - elapsed)) {
                self.wakeScheduled = false
                self.sendWakeIfPossible()
            }
            return
        }
        wakeOwed = false
        lastWakeAt = Date()
        let message: [String: Any] = [
            "type": PhoneLink.filesQueuedType,
            "pending": pendingTransfers,
            "sentAt": Date().timeIntervalSince1970
        ]
        session.sendMessage(message, replyHandler: nil) { error in
            Log.link.info("filesQueued message failed: \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async {
                // Try again at the next file event or when the phone is reachable again.
                self.wakeOwed = true
            }
        }
        Log.link.info("filesQueued sent (pending \(self.pendingTransfers))")
    }

    private func refreshPendingCount() {
        let session = WCSession.default
        let outstanding = session.activationState == .activated ? session.outstandingFileTransfers.count : 0
        pendingTransfers = outstanding + queuedUntilActivated.count
    }

    private func didActivate(_ session: WCSession) {
        activated = true
        handleWorkoutSelection(session.receivedApplicationContext)
        handleLiftSelection(session.receivedApplicationContext)
        handleWeightUnit(session.receivedApplicationContext)
        isReachable = session.isReachable
        let queued = queuedUntilActivated
        queuedUntilActivated = []
        let queuedNames = Set(queued.map { $0.url.lastPathComponent })
        for file in queued {
            enqueue(file)
        }
        resendOrphans(excluding: queuedNames)
        refreshPendingCount()
    }

    /// Re-sends files sitting in the outbox that the system no longer knows about
    /// (e.g. the app was killed, or a transfer failed too often in a previous run).
    private func resendOrphans(excluding names: Set<String>) {
        let session = WCSession.default
        let outstanding = Set(session.outstandingFileTransfers.map { $0.file.fileURL.lastPathComponent })
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: WatchFiles.outbox,
                                                                includingPropertiesForKeys: nil)
        } catch {
            Log.files.error("Could not list outbox: \(error.localizedDescription, privacy: .public)")
            return
        }
        for url in files {
            let name = url.lastPathComponent
            if outstanding.contains(name) || names.contains(name) { continue }
            guard let metadata = PhoneLink.metadata(forFileNamed: name) else { continue }
            Log.link.info("Re-sending orphaned \(name, privacy: .public)")
            enqueue(QueuedFile(url: url, metadata: metadata))
        }
    }

    private func moveStaleRecordingsToOutbox() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: WatchFiles.recording, includingPropertiesForKeys: nil) else {
            return
        }
        for url in files where url.pathExtension == "csv" {
            let destination = WatchFiles.outbox.appendingPathComponent(url.lastPathComponent)
            do {
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.moveItem(at: url, to: destination)
                Log.files.info("Recovered stale recording \(url.lastPathComponent, privacy: .public)")
            } catch {
                Log.files.error("Could not recover \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Metadata reconstructed from the file name (used for re-sends).
    /// `workout-<uuid>.json` → workout result, `<uuid>.json` → lift,
    /// `session-<uuid>.csv` → debug session CSV.
    static func metadata(forFileNamed name: String) -> [String: Any]? {
        // Workout results first: they also end in ".json".
        if name.hasPrefix("workout-") && name.hasSuffix(".json") {
            let id = String(name.dropFirst(8).dropLast(5))
            guard UUID(uuidString: id) != nil else { return nil }
            return workoutResultMetadata(id: id)
        }
        if name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            guard UUID(uuidString: id) != nil else { return nil }
            return liftMetadata(id: id)
        }
        if name.hasPrefix("session-") && name.hasSuffix(".csv") {
            let id = String(name.dropFirst(8).dropLast(4))
            return sessionCSVMetadata(sessionId: id)
        }
        return nil
    }

    static func liftMetadata(id: String) -> [String: Any] {
        return ["type": "lift", "id": id]
    }

    static func workoutResultMetadata(id: String) -> [String: Any] {
        return ["type": "workoutResult", "id": id]
    }

    static func sessionCSVMetadata(sessionId: String) -> [String: Any] {
        return ["type": "sessionCSV", "sessionId": sessionId]
    }

    private func handleFinished(_ fileTransfer: WCSessionFileTransfer, error: Error?) {
        let url = fileTransfer.file.fileURL
        let name = url.lastPathComponent
        if let error = error {
            let attempts = (retryCounts[name] ?? 0) + 1
            retryCounts[name] = attempts
            Log.link.error("Transfer of \(name, privacy: .public) failed (attempt \(attempts)): \(error.localizedDescription, privacy: .public)")
            if attempts <= PhoneLink.maxRetries {
                let metadata = fileTransfer.file.metadata ?? PhoneLink.metadata(forFileNamed: name) ?? [:]
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    self.enqueue(QueuedFile(url: url, metadata: metadata))
                }
            } else {
                Log.link.error("Giving up on \(name, privacy: .public) for now; it stays in the outbox and is re-sent on next launch")
            }
        } else {
            retryCounts[name] = nil
            do {
                try FileManager.default.removeItem(at: url)
                Log.link.info("Delivered and deleted \(name, privacy: .public)")
            } catch {
                Log.files.error("Delivered but could not delete \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        refreshPendingCount()
        if error == nil {
            // The file is on the phone now: wake the app so it uploads it.
            wakePhone()
        }
    }

    // MARK: - WCSessionDelegate (watchOS)

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error = error {
            Log.link.error("WCSession activation failed: \(error.localizedDescription, privacy: .public)")
        }
        Log.link.info("WCSession activation state: \(activationState.rawValue)")
        guard activationState == .activated else { return }
        DispatchQueue.main.async {
            self.didActivate(session)
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        DispatchQueue.main.async {
            self.isReachable = reachable
            if reachable {
                self.sendWakeIfPossible()
            }
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        DispatchQueue.main.async {
            self.handleFinished(fileTransfer, error: error)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async {
            self.handleWorkoutSelection(message)
            self.handleLiftSelection(message)
            self.handleWeightUnit(message)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async {
            self.handleWorkoutSelection(applicationContext)
            self.handleLiftSelection(applicationContext)
            self.handleWeightUnit(applicationContext)
        }
    }

    // MARK: - Weight unit from the phone (main queue)

    private func handleWeightUnit(_ payload: [String: Any]) {
        guard let raw = payload[PhoneLink.weightUnitKey] as? String,
              let unit = WeightUnit(rawValue: raw) else { return }
        UserDefaults.standard.set(raw, forKey: PhoneLink.weightUnitKey)
        if unit != weightUnit {
            weightUnit = unit
        }
    }

    // MARK: - Lift selection from the phone (main queue)

    private func handleLiftSelection(_ payload: [String: Any]) {
        guard let d = payload[LiftSelection.contextKey] as? [String: Any],
              let selection = LiftSelection(dictionary: d) else { return }
        let defaults = UserDefaults.standard
        let lastSentAt = defaults.double(forKey: PhoneLink.phoneLiftSentAtKey)
        if selection.sentAt > 0 && selection.sentAt <= lastSentAt { return }
        defaults.set(selection.sentAt, forKey: PhoneLink.phoneLiftSentAtKey)
        Log.link.info("Lift from phone: \(selection.liftType.rawValue, privacy: .public)")
        phoneLift = selection
    }

    // MARK: - Workout selection from the phone (main queue)

    /// `["type": "selectWorkout", "workoutDefinition": <JSON Data>, "sentAt": <seconds since 1970>]`.
    /// The phone sends the same payload as application context and, when reachable, as a
    /// message; the `sentAt` check applies it once.
    private func handleWorkoutSelection(_ payload: [String: Any]) {
        guard (payload["type"] as? String) == "selectWorkout",
              let data = payload["workoutDefinition"] as? Data else { return }
        let sentAt = (payload["sentAt"] as? Double) ?? 0
        let defaults = UserDefaults.standard
        let lastSentAt = defaults.double(forKey: PhoneLink.phoneWorkoutSentAtKey)
        if sentAt > 0 && sentAt <= lastSentAt { return }
        let definition: WorkoutDefinition
        do {
            definition = try JSONDecoder().decode(WorkoutDefinition.self, from: data)
        } catch {
            Log.link.error("Could not decode workout from phone: \(error.localizedDescription, privacy: .public)")
            return
        }
        defaults.set(sentAt, forKey: PhoneLink.phoneWorkoutSentAtKey)
        Log.link.info("Workout from phone: \(definition.id, privacy: .public)")
        phoneWorkout = definition
    }
}
