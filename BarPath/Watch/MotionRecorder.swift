import Foundation
import CoreMotion
import BarPathKit

/// Streams motion while the workout session runs, feeds the ring buffers, the online lift
/// detector and (in debug mode) the full-session CSV, and cuts/sends lift snippets (spec §4, §7).
///
/// Everything runs on the main actor: 200 Hz device motion + 800 Hz accel arrive in ~1 s
/// batches, which is cheap to process; this avoids any data races on the buffers.
///
/// Order per motion batch (data safety first): CSV → ring buffer → detector → snippets.
/// The CSV never depends on the detector.
@MainActor
final class MotionRecorder {
    enum Mode: Equatable {
        case batched          // CMBatchedSensorManager: 200 Hz motion + 800 Hz accel
        case fallback100Hz    // CMMotionManager device motion at 100 Hz, no accel
        case unavailable
    }

    static let preRoll: Double = 2.0
    static let postRoll: Double = 1.0
    /// How long (motion time) to wait for the accel stream to catch up before cutting anyway.
    static let maxAccelWait: Double = 2.0
    /// Fallback mode: samples are grouped into batches of this size (0.5 s at 100 Hz).
    static let fallbackBatchSize = 50

    // MARK: Callbacks (all on the main actor)

    var onDetectorStateChange: (@MainActor (DetectorState) -> Void)?
    var onDetectorEvent: (@MainActor (DetectorEvent) -> Void)?
    /// Lift snippet written to disk and queued for transfer (lift index).
    var onLiftSaved: (@MainActor (Int) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    /// Called after each processed motion batch (for the "data is flowing" counters).
    var onBatchProcessed: (@MainActor () -> Void)?

    // MARK: Settings for the next lift

    var liftType: LiftType = .snatch
    var loadKg: Double?

    // MARK: State

    private(set) var isRunning = false
    private(set) var mode: Mode = .batched
    private(set) var liftCount = 0
    private(set) var savedLiftCount = 0
    private(set) var motionSampleCount = 0
    private(set) var accelSampleCount = 0
    var csvBytes: Int { csvWriter?.bytesWritten ?? lastCSVBytes }
    var csvSamples: Int { csvWriter?.samplesWritten ?? lastCSVSamples }
    var isRecordingCSV: Bool { csvWriter != nil }
    var detectorState: DetectorState { detector.state }

    private let batchedManager = CMBatchedSensorManager()
    private let fallbackManager = CMMotionManager()
    private var motionTask: Task<Void, Never>?
    private var accelTask: Task<Void, Never>?
    private var accelActive = false
    private var fallbackBatch: [MotionSample] = []

    private var motionBuffer = MotionRingBuffer(capacity: 6000)    // 30 s @ 200 Hz
    private var accelBuffer = AccelRingBuffer(capacity: 24000)     // 30 s @ 800 Hz
    private let detector = OnlineLiftDetector()
    private var lastPublishedState: DetectorState = .idle

    private var sessionId = UUID()
    private var bootDate = Date()
    private var csvWriter: DebugCSVWriter?
    private var lastCSVBytes = 0
    private var lastCSVSamples = 0

    private struct LiftContext {
        let homingTime: Double
        let liftType: LiftType
        let loadKg: Double?
    }

    private struct PendingSnippet {
        let index: Int
        let liftType: LiftType
        let loadKg: Double?
        let homingTime: Double
        let endTime: Double
        let reason: EndReason
    }

    private var currentLift: LiftContext?
    private var pending: [PendingSnippet] = []

    init() {}

    // MARK: - Start / stop

    /// Call only once the HKWorkoutSession is running (CMBatchedSensorManager requires it).
    /// `sessionId` groups lifts on the phone (one per workout); `csvId` names this block's
    /// debug CSV (a new one after each "Change"); lift numbers continue from `liftIndexOffset`.
    func start(sessionId: UUID, csvId: UUID, recordDebugCSV: Bool, liftIndexOffset: Int = 0) {
        guard !isRunning else { return }
        isRunning = true
        self.sessionId = sessionId
        bootDate = Date(timeIntervalSinceNow: -ProcessInfo.processInfo.systemUptime)   // spec §2

        motionBuffer.removeAll()
        accelBuffer.removeAll()
        detector.reset()
        lastPublishedState = detector.state
        pending = []
        currentLift = nil
        liftCount = liftIndexOffset
        savedLiftCount = liftIndexOffset
        motionSampleCount = 0
        accelSampleCount = 0
        fallbackBatch = []
        lastCSVBytes = 0
        lastCSVSamples = 0
        csvWriter = recordDebugCSV ? DebugCSVWriter(sessionId: csvId, bootDate: bootDate, liftType: liftType) : nil

        if CMBatchedSensorManager.isDeviceMotionSupported {
            mode = .batched
            startBatched()
        } else if fallbackManager.isDeviceMotionAvailable {
            mode = .fallback100Hz
            startFallback()
        } else {
            mode = .unavailable
            Log.motion.error("No device motion available")
            onError?("Motion sensors unavailable on this device")
        }
        Log.motion.info("Recorder started, mode \(String(describing: self.mode), privacy: .public), csv \(recordDebugCSV)")
    }

    /// Stops the sensors, flushes pending snippets (an in-progress lift is saved with
    /// `.sessionEnd`), closes the debug CSV and returns its URL (in the outbox) if any.
    func stop() -> URL? {
        guard isRunning else { return nil }

        // Stop the streams first so nothing else arrives.
        motionTask?.cancel()
        accelTask?.cancel()
        motionTask = nil
        accelTask = nil
        if mode == .batched {
            batchedManager.stopDeviceMotionUpdates()
            if accelActive { batchedManager.stopAccelerometerUpdates() }
        } else if mode == .fallback100Hz {
            fallbackManager.stopDeviceMotionUpdates()
            if !fallbackBatch.isEmpty {
                let rest = fallbackBatch
                fallbackBatch = []
                ingestMotion(rest)
            }
        }
        accelActive = false

        // A lift still in progress is saved with what we have.
        if detector.state == .lifting, let lift = currentLift, let latest = motionBuffer.latestTime {
            liftCount += 1
            pending.append(PendingSnippet(index: liftCount, liftType: lift.liftType, loadKg: lift.loadKg,
                                          homingTime: lift.homingTime, endTime: latest, reason: .sessionEnd))
            csvWriter?.appendEvent(atUptime: latest, description: String(format: "name=liftEnded homing=%.3f end=%.3f reason=sessionEnd", lift.homingTime - (csvWriter?.t0 ?? 0), latest - (csvWriter?.t0 ?? 0)))
            currentLift = nil
        }
        processPending(force: true)
        isRunning = false

        var csvURL: URL?
        if let writer = csvWriter {
            csvURL = writer.finish()
            lastCSVBytes = writer.bytesWritten
            lastCSVSamples = writer.samplesWritten
        }
        csvWriter = nil
        Log.motion.info("Recorder stopped: \(self.motionSampleCount) motion, \(self.accelSampleCount) accel samples, \(self.liftCount) lifts")
        return csvURL
    }

    /// Appends a user marker to the debug CSV (no-op when not recording a CSV).
    /// Returns the marker number, or nil.
    func addMark(label: String) -> Int? {
        guard isRunning, let writer = csvWriter else { return nil }
        writer.appendMark(atUptime: ProcessInfo.processInfo.systemUptime, label: label)
        return writer.marksWritten
    }

    // MARK: - Sensor streams

    private func startBatched() {
        let manager = batchedManager
        motionTask = Task { @MainActor [weak self] in
            do {
                for try await batch in manager.deviceMotionUpdates() {
                    if Task.isCancelled { break }
                    guard let self = self else { break }
                    self.handleDeviceMotionBatch(batch)
                }
            } catch {
                if !Task.isCancelled {
                    Log.motion.error("Device motion stream failed: \(error.localizedDescription, privacy: .public)")
                    self?.onError?("Motion stream stopped: \(error.localizedDescription)")
                }
            }
        }

        if CMBatchedSensorManager.isAccelerometerSupported {
            accelActive = true
            accelTask = Task { @MainActor [weak self] in
                do {
                    for try await batch in manager.accelerometerUpdates() {
                        if Task.isCancelled { break }
                        guard let self = self else { break }
                        self.handleAccelBatch(batch)
                    }
                } catch {
                    if !Task.isCancelled {
                        Log.motion.error("Accelerometer stream failed: \(error.localizedDescription, privacy: .public)")
                        // Device motion (and the CSV) keep going; snippets just lose 800 Hz accel.
                        self?.accelActive = false
                    }
                }
            }
        } else {
            accelActive = false
        }
    }

    private func startFallback() {
        accelActive = false
        fallbackManager.deviceMotionUpdateInterval = 1.0 / 100.0
        fallbackManager.startDeviceMotionUpdates(to: OperationQueue.main) { [weak self] motion, error in
            // Delivered on OperationQueue.main, so we really are on the main actor.
            if let error = error {
                let message = error.localizedDescription
                MainActor.assumeIsolated {
                    Log.motion.error("Fallback device motion error: \(message, privacy: .public)")
                    self?.onError?("Motion error: \(message)")
                }
                return
            }
            guard let motion = motion else { return }
            let sample = MotionRecorder.makeSample(motion)
            MainActor.assumeIsolated {
                self?.handleFallbackSample(sample)
            }
        }
    }

    private func handleFallbackSample(_ sample: MotionSample) {
        guard isRunning else { return }
        fallbackBatch.append(sample)
        if fallbackBatch.count >= MotionRecorder.fallbackBatchSize {
            let batch = fallbackBatch
            fallbackBatch = []
            ingestMotion(batch)
        }
    }

    private func handleDeviceMotionBatch(_ batch: [CMDeviceMotion]) {
        guard isRunning else { return }
        var samples: [MotionSample] = []
        samples.reserveCapacity(batch.count)
        for m in batch {
            samples.append(MotionRecorder.makeSample(m))
        }
        ingestMotion(samples)
    }

    private func handleAccelBatch(_ batch: [CMAccelerometerData]) {
        guard isRunning else { return }
        for a in batch {
            let t = a.timestamp
            if let last = accelBuffer.latestTime, t <= last { continue }
            accelBuffer.append(AccelSample(t: t, accel: Vec3(a.acceleration.x, a.acceleration.y, a.acceleration.z)))
            accelSampleCount += 1
        }
        processPending(force: false)
    }

    nonisolated static func makeSample(_ m: CMDeviceMotion) -> MotionSample {
        let q = m.attitude.quaternion
        return MotionSample(t: m.timestamp,
                            attitude: Quat(w: q.w, x: q.x, y: q.y, z: q.z),
                            userAccel: Vec3(m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z),
                            gravity: Vec3(m.gravity.x, m.gravity.y, m.gravity.z),
                            rotationRate: Vec3(m.rotationRate.x, m.rotationRate.y, m.rotationRate.z))
    }

    // MARK: - Processing

    private func ingestMotion(_ samples: [MotionSample]) {
        // Drop duplicates / out-of-order samples (keeps every downstream consumer monotonic).
        var accepted: [MotionSample] = []
        accepted.reserveCapacity(samples.count)
        var last = motionBuffer.latestTime
        for s in samples {
            if let l = last, s.t <= l { continue }
            accepted.append(s)
            last = s.t
        }
        guard !accepted.isEmpty else { return }

        // 1. Debug CSV first: independent of the detector.
        csvWriter?.append(accepted)
        motionSampleCount += accepted.count

        // 2. Ring buffer + detector.
        for s in accepted {
            motionBuffer.append(s)
            if let event = detector.process(s) {
                handle(event, sample: s)
            }
        }

        let state = detector.state
        if state != lastPublishedState {
            lastPublishedState = state
            onDetectorStateChange?(state)
        }

        // 3. Snippets whose post-roll has arrived.
        processPending(force: false)
        onBatchProcessed?()
    }

    private func handle(_ event: DetectorEvent, sample: MotionSample) {
        let t0 = csvWriter?.t0 ?? 0
        switch event {
        case .armed(let homingTime):
            csvWriter?.appendEvent(atUptime: sample.t,
                                   description: String(format: "name=armed homing=%.3f", homingTime - t0))
        case .disarmed:
            csvWriter?.appendEvent(atUptime: sample.t, description: "name=disarmed")
        case .liftStarted(let homingTime):
            currentLift = LiftContext(homingTime: homingTime, liftType: liftType, loadKg: loadKg)
            csvWriter?.appendEvent(atUptime: sample.t,
                                   description: String(format: "name=liftStarted homing=%.3f", homingTime - t0))
        case .liftEnded(let homingTime, let endTime, let reason):
            liftCount += 1
            let snippetType: LiftType
            let snippetLoad: Double?
            if let lift = currentLift {
                snippetType = lift.liftType
                snippetLoad = lift.loadKg
            } else {
                snippetType = liftType
                snippetLoad = loadKg
            }
            pending.append(PendingSnippet(index: liftCount, liftType: snippetType, loadKg: snippetLoad,
                                          homingTime: homingTime, endTime: endTime, reason: reason))
            currentLift = nil
            csvWriter?.appendEvent(atUptime: sample.t,
                                   description: String(format: "name=liftEnded homing=%.3f end=%.3f reason=",
                                                       homingTime - t0, endTime - t0) + reason.rawValue)
        }
        onDetectorEvent?(event)
    }

    private func processPending(force: Bool) {
        guard !pending.isEmpty else { return }
        guard let latestMotion = motionBuffer.latestTime else { return }
        var remaining: [PendingSnippet] = []
        for p in pending {
            let needed = p.endTime + MotionRecorder.postRoll
            let motionReady = latestMotion >= needed
            var accelReady = true
            if accelActive {
                let latestAccel = accelBuffer.latestTime ?? -Double.greatestFiniteMagnitude
                accelReady = latestAccel >= needed || latestMotion >= needed + MotionRecorder.maxAccelWait
            }
            if force || (motionReady && accelReady) {
                emit(p)
            } else {
                remaining.append(p)
            }
        }
        pending = remaining
    }

    private func emit(_ p: PendingSnippet) {
        let start = p.homingTime - MotionRecorder.preRoll
        let end = p.endTime + MotionRecorder.postRoll
        let motion = motionBuffer.samples(from: start, to: end)
        guard !motion.isEmpty else {
            Log.motion.error("Lift \(p.index) has no motion samples in [\(start), \(end)]")
            onError?("Lift \(p.index) could not be saved (no data)")
            return
        }
        let accel = accelBuffer.samples(from: start, to: end)
        let recording = SnippetBuilder.makeRecording(sessionId: sessionId,
                                                     index: p.index,
                                                     liftType: p.liftType,
                                                     loadKg: p.loadKg,
                                                     bootDate: bootDate,
                                                     motion: motion,
                                                     accel: accel,
                                                     homingTime: p.homingTime,
                                                     endTime: p.endTime,
                                                     endReason: p.reason)
        let index = p.index
        let directory = WatchFiles.outbox
        Log.motion.info("Lift \(index): \(motion.count) motion, \(accel.count) accel samples")

        // JSON encoding of ~2 MB takes a moment; do it off the main actor.
        Task.detached(priority: .utility) { [weak self] in
            var failure: String?
            do {
                let data = try recording.encoded()
                let url = directory.appendingPathComponent("\(recording.id.uuidString).json")
                try data.write(to: url, options: .atomic)
                PhoneLink.shared.sendFile(url, metadata: PhoneLink.liftMetadata(id: recording.id.uuidString))
            } catch {
                Log.files.error("Could not write lift \(index): \(error.localizedDescription, privacy: .public)")
                failure = error.localizedDescription
            }
            let failureMessage = failure
            await self?.snippetFinished(index: index, failure: failureMessage)
        }
    }

    private func snippetFinished(index: Int, failure: String?) {
        if let failure = failure {
            onError?("Lift \(index) not saved: \(failure)")
        } else {
            savedLiftCount += 1
            onLiftSaved?(index)
        }
    }
}
