import Foundation
import Combine
import WatchConnectivity
import HealthKit
import BarPathKit

/// The single WCSessionDelegate of the iPhone app (one shared instance).
///
/// WatchConnectivity calls the delegate on a background queue. Published state is only
/// mutated on the main queue. Incoming files are moved synchronously inside
/// `session(_:didReceive:)`, because the system deletes them when that call returns.
/// Live rep count of the set in progress, from the watch's status messages.
struct LiveSetStatus: Equatable {
    let setNumber: Int
    let repCount: Int
    let liftName: String
    let loadLb: Double?

    /// Nil unless the watch is running a strength block with at least one rep in this set.
    init?(message: [String: Any]) {
        guard (message["phase"] as? String) == "running",
              let reps = (message["repCount"] as? NSNumber)?.intValue, reps > 0 else { return nil }
        repCount = reps
        setNumber = ((message["liftCount"] as? NSNumber)?.intValue ?? 0) + 1
        let raw = message["liftType"] as? String
        liftName = raw.flatMap { LiftType(rawValue: $0)?.displayName } ?? "Set"
        loadLb = (message["loadLb"] as? NSNumber)?.doubleValue
    }
}

final class PhoneLink: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = PhoneLink()

    @Published private(set) var activationState: WCSessionActivationState = .notActivated
    @Published private(set) var isPaired = false
    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var isReachable = false
    @Published private(set) var lastFileReceivedAt: Date?
    @Published private(set) var lastStatusText: String?
    /// Strength-mode set in progress on the watch (live rep count), nil between sets.
    @Published private(set) var liveSet: LiveSetStatus?
    @Published private(set) var lastError: String?
    /// True while a "open the watch app" request (HKHealthStore.startWatchApp) is in flight.
    @Published private(set) var isLaunchingWatchApp = false
    @Published private(set) var watchLaunchError: String?

    private let healthStore = HKHealthStore()

    private override init() {
        super.init()
    }

    /// Call once at launch.
    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Opens BarPath on the paired watch (it comes to the foreground on the start screen).
    /// Uses HKHealthStore.startWatchApp, which works even when the watch app isn't running.
    func launchWatchApp() {
        guard activationState == .activated, isPaired, isWatchAppInstalled else { return }
        guard !isLaunchingWatchApp else { return }
        isLaunchingWatchApp = true
        watchLaunchError = nil
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor
        healthStore.startWatchApp(with: configuration) { success, error in
            DispatchQueue.main.async {
                self.isLaunchingWatchApp = false
                if !success {
                    self.watchLaunchError = error?.localizedDescription ?? "Couldn't open the watch app"
                }
            }
        }
    }

    var activationDescription: String {
        switch activationState {
        case .activated: return "Activated"
        case .inactive: return "Inactive"
        case .notActivated: return "Not activated"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - State

    private func publishState(_ session: WCSession) {
        let state = session.activationState
        let activated = state == .activated
        let paired = activated ? session.isPaired : false
        let installed = activated ? session.isWatchAppInstalled : false
        let reachable = activated ? session.isReachable : false
        DispatchQueue.main.async {
            self.activationState = state
            self.isPaired = paired
            self.isWatchAppInstalled = installed
            self.isReachable = reachable
            if !reachable {
                self.liveSet = nil
            }
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error = error {
            let text = "Activation failed: \(error.localizedDescription)"
            DispatchQueue.main.async {
                self.lastError = text
            }
        }
        publishState(session)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        publishState(session)
    }

    func sessionDidDeactivate(_ session: WCSession) {
        // Happens when the user switches to another watch: re-activate for the new one.
        WCSession.default.activate()
        publishState(session)
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        publishState(session)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        publishState(session)
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata ?? [:]
        let type = (metadata["type"] as? String)?.lowercased() ?? ""
        let source = file.fileURL
        let name = source.lastPathComponent.lowercased()
        let isCSV = source.pathExtension.lowercased() == "csv"

        let isMarks = type == "marks" || name.hasSuffix("-marks.csv")
        let isSessionCSV = !isMarks && (type == "session" || type == "sessioncsv" || (type != "lift" && isCSV))

        do {
            if isMarks || isSessionCSV {
                // Synchronous move: the system deletes `source` when this method returns.
                _ = try LiftFiles.storeIncomingDebugFile(from: source,
                                                         isMarks: isMarks,
                                                         metadataSessionId: metadata["sessionId"] as? String)
                notifyReceived()
                Task { @MainActor in
                    LiftStore.shared.reloadDebugFiles()
                }
            } else {
                let destination = try LiftFiles.storeIncomingLift(from: source,
                                                                  metadataId: metadata["id"] as? String)
                notifyReceived()
                Task { @MainActor in
                    LiftStore.shared.ingestLift(at: destination)
                }
            }
        } catch {
            let text = "Could not store \(source.lastPathComponent): \(error.localizedDescription)"
            NSLog("BarPath: %@", text)
            DispatchQueue.main.async {
                self.lastError = text
            }
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleMessage(message)
    }

    func session(_ session: WCSession,
                 didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        handleMessage(message)
        replyHandler([:])
    }

    // MARK: - Private

    private func notifyReceived() {
        let now = Date()
        DispatchQueue.main.async {
            self.lastFileReceivedAt = now
        }
    }

    /// Optional live status from the watch (`["type": "status", ...]`), shown as plain text.
    private func handleMessage(_ message: [String: Any]) {
        guard (message["type"] as? String) == "status" else { return }
        let parts = message.keys.sorted().compactMap { key -> String? in
            if key == "type" { return nil }
            guard let value = message[key] else { return nil }
            return "\(key): \(value)"
        }
        let text = parts.joined(separator: " · ")
        let live = LiveSetStatus(message: message)
        DispatchQueue.main.async {
            self.lastStatusText = text.isEmpty ? nil : text
            self.liveSet = live
        }
    }
}
