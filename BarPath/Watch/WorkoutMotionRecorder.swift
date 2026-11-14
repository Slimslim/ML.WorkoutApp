import Foundation
import CoreMotion
import BarPathKit

/// Workout mode recorder (WORKOUT_SPEC §3): device motion straight into a `DebugCSVWriter`, plus
/// the workout's comment lines (segments, HR, pedometer, marks). No 800 Hz accel (the session CSV
/// has no accel columns), no lift detector, no snippets.
///
/// The rate is chosen once at start for the whole session (docs/RECORDING_PLAN.md, build 15):
/// - 200 Hz through `CMBatchedSensorManager` when the planned workout's `RecordingProfile` is
///   `.high`, the HealthKit session is running (the batched manager delivers nothing without
///   one) and the watch supports it;
/// - otherwise 100 Hz through `CMMotionManager`, unchanged. If the batched stream delivers no
///   sample within `batchedWatchdog` seconds, the recorder falls back to 100 Hz (nothing is
///   written to the header before the first sample, so `sampleRate` stays true).
///
/// Only used in Data mode. Main actor only: 100 Hz updates are delivered on `OperationQueue.main`
/// (same pattern as `MotionRecorder`'s 100 Hz fallback path); the batched stream is consumed in a
/// main-actor Task (same pattern as `MotionRecorder.startBatched`).
@MainActor
final class WorkoutMotionRecorder {
    /// Samples per CSV write (1 s at the nominal rate): one write + fsync per second.
    static let standardRateHz = 100
    static let highRateHz = 200
    /// Seconds to wait for the first batched sample before falling back to 100 Hz.
    static let batchedWatchdog: Double = 2.5

    enum Mode: Equatable {
        case standard100Hz
        case batched200Hz
        case unavailable
    }

    var onError: (@MainActor (String) -> Void)?
    /// Called after each CSV batch write (for the data strip counters).
    var onBatchWritten: (@MainActor () -> Void)?

    private(set) var isRunning = false
    private(set) var motionAvailable = true
    private(set) var mode: Mode = .standard100Hz
    /// Nominal rate of this session (what the header says), 100 or 200.
    private(set) var sampleRateHz = WorkoutMotionRecorder.standardRateHz
    private(set) var sampleCount = 0
    /// Wall-clock date of system boot; converts epoch seconds to the CSV's since-boot axis.
    private(set) var bootDate = Date()

    var csvBytes: Int { writer?.bytesWritten ?? lastBytes }
    var csvFileName: String? { writer?.fileName ?? lastFileName }

    private let manager = CMMotionManager()
    private let batchedManager = CMBatchedSensorManager()
    private var batchedTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var batchSize = WorkoutMotionRecorder.standardRateHz
    private var batch: [MotionSample] = []
    private var lastSampleTime: Double?
    private var writer: DebugCSVWriter?
    private var lastBytes = 0
    private var lastFileName: String?

    init() {}

    // MARK: - Start / stop

    /// `planned` is the rule's verdict for the workout (written to the header as `planProfile`);
    /// `healthKitRunning` says whether the HealthKit workout session is running right now;
    /// `gpsOn` whether location updates were actually started (header `gps=on|off`).
    /// Never blocks: the sensors are started and the call returns.
    func start(sessionId: UUID, definitionId: String, planned: RecordingProfile = .standard,
               healthKitRunning: Bool = false, gpsOn: Bool = false) {
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
        w.planProfile = planned.rawValue
        w.gpsOn = gpsOn
        writer = w
        lastFileName = w.fileName

        let useBatched: Bool = planned == .high && healthKitRunning && CMBatchedSensorManager.isDeviceMotionSupported
        if useBatched {
            mode = .batched200Hz
            motionAvailable = true
            setRate(WorkoutMotionRecorder.highRateHz)
            startBatched()
        } else if !startStandard() {
            // 100 Hz as before this build; only when even that is missing:
            mode = .unavailable
        }
        Log.motion.info("Workout recorder started, mode \(String(describing: self.mode), privacy: .public), planned \(planned.rawValue, privacy: .public), HK \(healthKitRunning)")
    }

    private func setRate(_ hz: Int) {
        sampleRateHz = hz
        batchSize = hz
        writer?.sampleRateHz = hz
    }

    /// The 100 Hz `CMMotionManager` path (unchanged). Returns false when there is no device motion.
    @discardableResult
    private func startStandard() -> Bool {
        mode = .standard100Hz
        setRate(WorkoutMotionRecorder.standardRateHz)
        if manager.isDeviceMotionAvailable {
            motionAvailable = true
            manager.deviceMotionUpdateInterval = 1.0 / Double(WorkoutMotionRecorder.standardRateHz)
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
            return true
        }
        motionAvailable = false
        Log.motion.error("Workout: no device motion available")
        onError?("Motion sensors unavailable")
        return false
    }

    /// 200 Hz through `CMBatchedSensorManager` (needs the running HKWorkoutSession).
    private func startBatched() {
        let bm = batchedManager
        batchedTask = Task { @MainActor [weak self] in
            do {
                for try await chunk in bm.deviceMotionUpdates() {
                    if Task.isCancelled { break }
                    guard let self = self else { break }
                    self.handleBatched(chunk)
                }
            } catch {
                if !Task.isCancelled {
                    Log.motion.error("Workout batched motion stream failed: \(error.localizedDescription, privacy: .public)")
                    self?.batchedFailed()
                }
            }
        }
        watchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(WorkoutMotionRecorder.batchedWatchdog * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self = self, self.isRunning, self.mode == .batched200Hz else { return }
            if self.sampleCount == 0 && self.batch.isEmpty {
                Log.motion.error("No batched motion within the watchdog time; falling back to 100 Hz")
                self.batchedFailed()
            }
        }
    }

    /// The batched stream gave nothing or stopped: continue at 100 Hz so the file is not empty.
    /// Before the first sample the header is not written yet, so it still says the true rate;
    /// after samples were written the header keeps 200 and a `rateFallback` event marks the change.
    private func batchedFailed() {
        guard isRunning, mode == .batched200Hz else { return }
        batchedTask?.cancel()
        batchedTask = nil
        batchedManager.stopDeviceMotionUpdates()
        let hadSamples: Bool = sampleCount > 0 || !batch.isEmpty
        if hadSamples {
            flush()
        }
        if startStandard() {
            if hadSamples {
                writer?.appendEvent(atUptime: ProcessInfo.processInfo.systemUptime,
                                    description: "name=rateFallback hz=100")
            }
        } else {
            mode = .unavailable
        }
    }

    /// Stops motion, flushes, closes the CSV and returns its URL (in the outbox) if any.
    func stop() -> URL? {
        guard isRunning else { return nil }
        watchdogTask?.cancel()
        watchdogTask = nil
        batchedTask?.cancel()
        batchedTask = nil
        if mode == .batched200Hz {
            batchedManager.stopDeviceMotionUpdates()
        }
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

    private func handleBatched(_ chunk: [CMDeviceMotion]) {
        guard isRunning, mode == .batched200Hz else { return }
        for m in chunk {
            handle(MotionRecorder.makeSample(m))
        }
    }

    private func handle(_ sample: MotionSample) {
        guard isRunning else { return }
        if let last = lastSampleTime, sample.t <= last { return }
        lastSampleTime = sample.t
        batch.append(sample)
        if batch.count >= batchSize {
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
