import Foundation
import os
import BarPathKit

private let engineLog = Logger(subsystem: "BarPathWatch", category: "workoutEngine")

/// The watch session on the engine (docs/WORKOUT_MODEL_RFC.md §11 step 4): owns the engine
/// state, its clock and its crash checkpoint (`WorkoutEngineCheckpointFile`, a separate file from
/// the old path's `WorkoutCheckpoint`). Created by `WorkoutSessionModel` only for a definition
/// whose route is `.engine` (it carries a v2 structure); every other workout keeps the old path,
/// unchanged.
///
/// `WorkoutSessionModel` keeps HealthKit, sensors, the CSV file and the result, and asks this
/// model for every timing decision while it exists: Crown, undo, the 200 ms tick, the reps
/// question, End. The engine state is projected onto a `WorkoutProgress`
/// (`WorkoutEngineSession.progress`), so the existing workout views show the run unchanged.
///
/// Time: engine times are Int ms since START on a monotonic clock that keeps counting while the
/// watch sleeps (`CLOCK_MONOTONIC`, RFC §14.3 E3), never `Date()`. Wall time is used only for
/// the projection, the result and the CSV.
@MainActor
final class WorkoutEngineSessionModel {
    /// What one input changed, for `WorkoutSessionModel` to play and write.
    struct Update {
        var effects: [EngineEffect] = []
        /// CSV event lines (`description`, at a systemUptime), in order.
        var csv: [(uptime: Double, text: String)] = []
        /// The projected step changed (advance, undo, finish or unfinish).
        var stepChanged: Bool = false
        /// The change came from the clock, not from the athlete.
        var byClock: Bool = false
    }

    let raw: JSONValue
    let plan: WorkoutPlan
    let options: JSONValue
    private(set) var state: EngineState
    private(set) var progress: WorkoutProgress
    private(set) var startEpoch: Double = 0
    private var startUptime: Double = 0
    private var startMonoNs: UInt64 = 0
    private var written: [String: Int] = [:]
    private var projectedStarts: Int = 0
    /// The CSV time of the last engine line written (lines never go back in time).
    private var lastLineUptime: Double = 0
    private var projectedFinished: Bool = false

    private init(raw: JSONValue, plan: WorkoutPlan, options: JSONValue) {
        self.raw = raw
        self.plan = plan
        self.options = options
        self.state = WorkoutEngine.initial(plan)
        self.progress = WorkoutEngineSession.progress(raw, WorkoutEngineSession.project(WorkoutEngine.initial(plan)),
                                                      startEpoch: 0)
    }

    /// The engine model for a definition's raw JSON, or nil when it keeps the old path. A
    /// refused v2 definition also returns nil for now: the "Update the app / Run as stopwatch"
    /// screen waits for the owner's design approval, so until then the watch runs what it ran
    /// before this change (the old keys), and logs the refusal.
    static func make(rawDefinition data: Data?) -> WorkoutEngineSessionModel? {
        guard let data = data, let raw = try? JSONValue.parse(data) else {
            return nil
        }
        switch WorkoutEngineSession.route(raw) {
        case .engine:
            break
        case .legacy(let reason, let missing):
            if let reason = reason {
                engineLog.info("Engine refused (\(reason, privacy: .public) \(missing.joined(separator: ","), privacy: .public)); old keys are exact")
            }
            return nil
        case .refused(let reason, let missing):
            engineLog.error("Engine refused (\(reason, privacy: .public) \(missing.joined(separator: ","), privacy: .public)); running the old keys until the refusal screen is approved")
            return nil
        }
        guard let plan = try? WorkoutEngine.plan(raw) else {
            engineLog.error("Engine route but the plan failed; running the old keys")
            return nil
        }
        let options: JSONValue = WorkoutEngineSession.options(scale: nil, standard: "M", choices: [:])
        return WorkoutEngineSessionModel(raw: raw, plan: plan, options: options)
    }

    // MARK: Clock

    private static func monotonicNs() -> UInt64 {
        return clock_gettime_nsec_np(CLOCK_MONOTONIC)
    }

    /// ms since START on the monotonic clock, clamped to the engine's range (never traps).
    func nowMs() -> Int {
        let now: UInt64 = WorkoutEngineSessionModel.monotonicNs()
        guard now > startMonoNs else {
            return 0
        }
        let ms: UInt64 = (now - startMonoNs) / 1_000_000
        return ms >= UInt64(EngineEvent.maxMs) ? EngineEvent.maxMs : Int(ms)
    }

    /// The CSV time (systemUptime) of engine time `ms`. `CLOCK_MONOTONIC` counts sleep and
    /// `systemUptime` (every other CSV line) does not, so the sleep measured so far is taken off:
    /// engine lines stay in step with the HR, segment and sensor lines after the watch slept.
    /// This is exact for a line written as its event happens (every 200 ms tick). A line whose
    /// event came before a sleep but is written after it (a bell due during the sleep, reps
    /// entered later, a late Crown) has the whole sleep taken off and can come out too early;
    /// `stamp` keeps it from going before START or before a line already written.
    private func uptime(_ ms: Int) -> Double {
        let elapsedUptime: Double = ProcessInfo.processInfo.systemUptime - startUptime
        let sleep: Double = max(0, Double(nowMs()) / 1000 - elapsedUptime)
        return startUptime + Double(ms) / 1000 - sleep
    }

    // MARK: Inputs

    /// START (the tap, RFC §14.3 E1): the clock starts now, not when HealthKit is ready. Writes
    /// the plan and bell lines (RFC §9).
    func start(epoch: Double, uptime: Double) -> Update {
        startEpoch = epoch
        startUptime = uptime
        startMonoNs = WorkoutEngineSessionModel.monotonicNs()
        lastLineUptime = uptime
        var u = Update()
        let epochMs = Int64((epoch * 1000).rounded())
        let uptimeMs = Int64((uptime * 1000).rounded())
        for line in WorkoutEngineCSV.planLines(plan, startEpochMs: epochMs, startUptimeMs: uptimeMs) {
            u.csv.append((uptime: uptime, text: line))
        }
        apply(EngineEvent(kind: "start", t: 0), into: &u)
        return u
    }

    /// A Crown turn (or long press, or the Next button). `began` is when the turn began; until
    /// the view stamps the gesture start, it is the time the model received it.
    func crown(began: Int? = nil) -> Update {
        var u = Update()
        let t: Int = nowMs()
        apply(EngineEvent(kind: "crown", t: t, began: began ?? t), into: &u)
        return u
    }

    func undo() -> Update {
        var u = Update()
        apply(EngineEvent(kind: "undo", t: nowMs()), into: &u)
        return u
    }

    /// The 200 ms loop: bells, 3-2-1, the time cap.
    func tick() -> Update {
        var u = Update()
        apply(EngineEvent(kind: "tick", t: nowMs()), into: &u)
        u.byClock = true
        return u
    }

    func reps(step: String, value: Int) -> Update {
        var u = Update()
        apply(EngineEvent(kind: "reps", t: nowMs(), step: step, value: .int(value)), into: &u)
        return u
    }

    /// End pressed: closes the run (a step still running ends there, RFC §4.2).
    func end() -> Update {
        var u = Update()
        if !state.done {
            apply(EngineEvent(kind: "end", t: nowMs()), into: &u)
        }
        return u
    }

    private func apply(_ event: EngineEvent, into u: inout Update) {
        let r = WorkoutEngine.reduce(state, event)
        state = r.0
        u.effects.append(contentsOf: r.1)
        refresh(into: &u, byClock: event.kind == "tick")
    }

    /// `uptime(ms)`, never before START nor before the last line written (#113 review F1).
    private func stamp(_ ms: Int) -> Double {
        let v: Double = max(uptime(ms), startUptime, lastLineUptime)
        lastLineUptime = v
        return v
    }

    /// Re-projects the state and writes the CSV lines for what changed: today's `segment`,
    /// `finish` and `undo` lines (index = the projected flat list), then the engine's `step` and
    /// `input` lines not written yet.
    private func refresh(into u: inout Update, byClock: Bool) {
        let pr = WorkoutEngineSession.project(state)
        progress = WorkoutEngineSession.progress(raw, pr, startEpoch: startEpoch)

        let n: Int = pr.starts.count
        let finished: Bool = pr.finish != nil
        if n < projectedStarts || (projectedFinished && !finished) {
            let name: String = projectedFinished && !finished ? "unfinish" : "undo"
            // Stamped only when the line is written, so a tick that writes nothing doesn't move
            // the clamp forward (#116 review follow-up 1).
            u.csv.append((uptime: stamp(state.now ?? 0), text: "name=\(name) index=\(max(0, n - 1)) source=crown"))
            u.stepChanged = true
        }
        if n > projectedStarts {
            for i in projectedStarts..<n {
                let kind: String = pr.segments.indices.contains(i) ? (pr.segments[i]["kind"]?.string ?? "station") : "station"
                var source: String = "start"
                if i > 0 {
                    source = (i - 1 < pr.sources.count && pr.sources[i - 1] == "crown") ? "crown" : "auto"
                }
                u.csv.append((uptime: stamp(pr.starts[i]), text: "name=segment index=\(i) kind=\(kind) source=\(source)"))
            }
            u.stepChanged = true
        }
        if finished && !projectedFinished, let f = pr.finish {
            u.csv.append((uptime: stamp(f), text: "name=finish index=\(max(0, n - 1)) source=\(pr.finishSource ?? "auto")"))
            u.stepChanged = true
        }
        if u.stepChanged && byClock {
            u.byClock = true
        }
        projectedStarts = n
        projectedFinished = finished
        for line in WorkoutEngineSession.newLines(state, written: &written) {
            u.csv.append((uptime: stamp(line.t), text: line.text))
        }
    }

    // MARK: What the views ask

    /// The clock that ends what the athlete is doing now, as `WorkoutSessionModel.nextClockEvent`
    /// gives it (seconds since 1970): the timer counts down to it unless it finishes the workout.
    var nextClockEvent: (time: Double, isFinish: Bool)? {
        guard let b = WorkoutEngineSession.nextBell(state) else {
            return nil
        }
        return (time: startEpoch + Double(b.t) / 1000, isFinish: b.finish)
    }

    /// The step of the one reps question the done screen asks (the latest), or nil.
    var askedStep: EngineStep? {
        guard let id = WorkoutEngineSession.latestAsk(state) else {
            return nil
        }
        return state.step(id: id)
    }

    /// The asked step as the old segment the reps picker shows.
    var askedSegment: WorkoutSegment? {
        guard let s = askedStep else {
            return nil
        }
        return WorkoutEngineSession.segment(WorkoutEngineSession.legacySegment(s))
    }

    /// The clock ended the workout (AMRAP end, last window, a hard cap).
    var finishedByClock: Bool {
        return state.done && state.endedBy == "clock"
    }

    // MARK: Checkpoint

    /// The checkpoint bytes (canonical JSON), `watch` carrying the HR series and the rest.
    func checkpointData(watch: JSONValue) -> Data {
        let cp: JSONValue = WorkoutEngineSession.makeCheckpoint(
            definition: raw, plan: plan, state: state,
            startEpochMs: Int64((startEpoch * 1000).rounded()), savedAtMs: nowMs(),
            options: options, watch: watch)
        return WorkoutEngineSession.checkpointData(cp)
    }
}

/// The engine's crash checkpoint file (`Checkpoint/engine-checkpoint.json`), separate from the
/// old path's `workout-checkpoint.json`. Canonical JSON written atomically off the main thread.
/// A file that can't be recovered is moved aside (`engine-checkpoint-<time>.aside.json`), never
/// deleted (RFC §8).
enum WorkoutEngineCheckpointFile {
    private static let log = Logger(subsystem: "BarPathWatch", category: "engineCheckpoint")
    private static let queue = DispatchQueue(label: "barpath.engineCheckpoint", qos: .utility)

    private static var directoryURL: URL {
        let base: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Checkpoint", isDirectory: true)
    }

    private static var fileURL: URL {
        return directoryURL.appendingPathComponent("engine-checkpoint.json")
    }

    static func save(_ data: Data) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                log.error("Could not write engine checkpoint: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func load() -> Data? {
        return queue.sync { () -> Data? in
            let url: URL = fileURL
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try? Data(contentsOf: url)
        }
    }

    static func clear() {
        queue.async {
            let url: URL = fileURL
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Keeps an unrecoverable checkpoint for the debug tools instead of deleting it.
    static func moveAside(reason: String) {
        queue.async {
            let url: URL = fileURL
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let stamp: Int64 = Int64(Date().timeIntervalSince1970)
            let aside: URL = directoryURL.appendingPathComponent("engine-checkpoint-\(stamp).aside.json")
            do {
                try FileManager.default.moveItem(at: url, to: aside)
                log.error("Engine checkpoint moved aside (\(reason, privacy: .public))")
            } catch {
                log.error("Could not move engine checkpoint aside: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
