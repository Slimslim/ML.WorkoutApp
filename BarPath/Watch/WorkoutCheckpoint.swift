import Foundation
import os
import BarPathKit

/// Everything needed to rebuild a workout's result if the app dies mid-session (crash,
/// memory kill, reboot, dead battery). Written to a file in Application Support while a
/// workout runs and deleted once the result is safely written. At the next launch a checkpoint
/// that is still there is turned into a result ("saved after interruption"); see
/// `WorkoutSessionModel.recoverInterruptedWorkout()`.
struct WorkoutCheckpoint: Codable {
    static let currentVersion: Int = 1

    var version: Int = WorkoutCheckpoint.currentVersion
    var workoutId: UUID
    var progress: WorkoutProgress
    var heartRates: [TimedValue]
    var pedometer: [PedometerSnapshot]
    var partialReps: Int?
    /// A debug CSV (`session-<workoutId>.csv`) was being recorded.
    var recordedCSV: Bool
    /// Seconds since 1970 when this checkpoint was written; the end time of a recovered result.
    var savedAt: Double

    // MARK: Storage

    private static let log = Logger(subsystem: "BarPathWatch", category: "workoutCheckpoint")
    /// One serial queue: encoding and writing happen off the main thread, in order, and a
    /// load or clear never overtakes an earlier save.
    private static let queue = DispatchQueue(label: "barpath.workoutCheckpoint", qos: .utility)

    private static var directoryURL: URL {
        let base: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Checkpoint", isDirectory: true)
    }

    private static var fileURL: URL {
        return directoryURL.appendingPathComponent("workout-checkpoint.json")
    }

    /// Encodes and writes `checkpoint` atomically, off the calling thread. Errors are logged only.
    static func save(_ checkpoint: WorkoutCheckpoint) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                let data: Data = try JSONEncoder().encode(checkpoint)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                log.error("Could not write checkpoint: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The stored checkpoint, or nil when there is none. A file that cannot be decoded is
    /// logged and deleted.
    static func load() -> WorkoutCheckpoint? {
        return queue.sync { () -> WorkoutCheckpoint? in
            let url: URL = fileURL
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do {
                let data: Data = try Data(contentsOf: url)
                return try JSONDecoder().decode(WorkoutCheckpoint.self, from: data)
            } catch {
                log.error("Checkpoint unreadable, deleting it: \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: url)
                return nil
            }
        }
    }

    /// Deletes the stored checkpoint (if any), in order after earlier saves.
    static func clear() {
        queue.async {
            let url: URL = fileURL
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                log.error("Could not delete checkpoint: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
