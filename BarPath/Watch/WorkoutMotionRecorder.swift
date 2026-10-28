import Foundation
import CoreMotion
import BarPathKit

/// Workout mode recorder (WORKOUT_SPEC §3): device motion at 100 Hz from `CMMotionManager`
/// straight into a `DebugCSVWriter`, plus the workout's comment lines (segments, HR,
/// pedometer, marks). No 800 Hz accel, no lift detector, no snippets.
///
/// Only used in Data mode. Main actor only: updates are delivered on `OperationQueue.main`
/// (same pattern as `MotionRecorder`'s 100 Hz fallback path).
@MainActor
final class WorkoutMotionRecorder {
    /// Samples per CSV write (1 s at 100 Hz): one write + fsync per second.
    static let batchSize = 100
    static let updateInterval: Double = 1.0 / 100.0

    var onError: (@MainActor (String) -> Void)?
    /// Called after each CSV batch write (for the data strip counters).
    var onBatchWritten: (@MainActor () -> Void)?

    private(set) var isRunning = false
    private(set) var motionAvailable = true
    private(set) var sampleCount = 0
    /// Wall-clock date of system boot; converts epoch seconds to the CSV's since-boot axis.
    private(set) var bootDate = Date()

    var csvBytes: Int { writer?.bytesWritten ?? lastBytes }
    var csvFileName: String? { writer?.fileName ?? lastFileName }

    private let manager = CMMotionManager()
    private var batch: [MotionSample] = []
    private var lastSampleTime: Double?
    private var writer: DebugCSVWriter?
    private var lastBytes = 0
    private var lastFileName: String?

    init() {}

    // MARK: - Start / stop

    func start(sessionId: UUID, definitionId: String) {
        guard !isRunning else { return }
        isRunning = true
        bootDate = Date(timeIntervalSinceNow: -ProcessInfo.processInfo.systemUptime)
        sampleCount = 0
        batch = []
        lastSampleTime = nil
        lastBytes = 0
        let w = DebugCSVWriter(sessionId: sessionId,
                               bootDate: bootDate,
                               liftType: .other,
                               headerTag: "workout=" + WorkoutMotionRecorder.clean(definitionId))
        writer = w
        lastFileName = w.fileName

        if manager.isDeviceMotionAvailable {
            motionAvailable = true
            manager.deviceMotionUpdateInterval = WorkoutMotionRecorder.updateInterval
            manager.startDeviceMotionUpdates(to: OperationQueue.main) { [weak self] motion, error in
                // Delivered on OperationQueue.main, so we really are on the main actor.
                if let error = error {
                    let message = error.localizedDescription
                    MainActor.assumeIsolated {
                        Log.motion.error("Workout device motion error: \(message, privacy: .public)")
                        self?.onError?("Motion error: \(message)")
                    }
                    return
                }
                guard let motion = motion else { return }
                let sample = MotionRecorder.makeSample(motion)
                MainActor.assumeIsolated {
                    self?.handle(sample)
                }
            }
        } else {
            motionAvailable = false
            Log.motion.error("Workout: no device motion available")
            onError?("Motion sensors unavailable")
        }
        Log.motion.info("Workout recorder started, motion \(self.motionAvailable)")
    }

    /// Stops motion, flushes, closes the CSV and returns its URL (in the outbox) if any.
    func stop() -> URL? {
        guard isRunning else { return nil }
        if motionAvailable {
            manager.stopDeviceMotionUpdates()
        }
        flush()
        isRunning = false
        var url: URL?
        if let w = writer {
            url = w.finish()
            lastBytes = w.bytesWritten
        }
        writer = nil
        Log.motion.info("Workout recorder stopped: \(self.sampleCount) samples")
        return url
    }

    // MARK: - Comment lines

    /// `description` is the part after `# event t=<s> `, e.g. `name=hr bpm=150`.
    func appendEvent(atUptime uptime: Double, description: String) {
        guard isRunning, let w = writer else { return }
        // Samples still in the batch are older than this event: write them first so the
        // file stays in time order.
        flush()
        w.appendEvent(atUptime: uptime, description: description)
    }

    /// Returns the mark number, or nil when not recording.
    func addMark(label: String) -> Int? {
        guard isRunning, let w = writer else { return nil }
        flush()
        w.appendMark(atUptime: ProcessInfo.processInfo.systemUptime, label: label)
        return w.marksWritten
    }

    /// Epoch seconds → seconds since boot (the CoreMotion / CSV time base).
    func uptime(forEpoch t: Double) -> Double {
        return t - bootDate.timeIntervalSince1970
    }

    // MARK: - Private

    private func handle(_ sample: MotionSample) {
        guard isRunning else { return }
        if let last = lastSampleTime, sample.t <= last { return }
        lastSampleTime = sample.t
        batch.append(sample)
        if batch.count >= WorkoutMotionRecorder.batchSize {
            flush()
            onBatchWritten?()
        }
    }

    private func flush() {
        guard !batch.isEmpty else { return }
        let samples = batch
        batch = []
        writer?.append(samples)
        sampleCount += samples.count
    }

    /// Header/comment values must not contain spaces or commas.
    static func clean(_ value: String) -> String {
        var s = value.replacingOccurrences(of: " ", with: "_")
        s = s.replacingOccurrences(of: ",", with: "_")
        s = s.replacingOccurrences(of: "\n", with: "_")
        return s
    }
}
