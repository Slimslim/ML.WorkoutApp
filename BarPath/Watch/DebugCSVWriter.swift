import Foundation
import BarPathKit

/// Full-session debug recording (spec §2.1).
///
/// Every accepted device-motion sample is written as one CSV row. Rows are written and the
/// FileHandle is synchronized once per batch (≈1 s), so a crash loses at most about one
/// batch. The file lives in `WatchFiles.recording` while open and is moved to the outbox by
/// `finish()`.
///
/// Extra comment lines (all start with `#`, so any parser that skips the header comment
/// handles them; pandas: `comment="#"`):
///   `# mark t=<sec> n=<k> label=<text>`        user tapped "Mark" (t on the CSV time axis)
///   `# event t=<sec> name=<event> ...`         online detector events, for tuning
///
/// Not thread-safe: used only from the main actor (MotionRecorder).
final class DebugCSVWriter {
    let sessionId: UUID
    private let bootDate: Date
    private let liftType: LiftType
    /// Replaces `liftType=<raw>` in the header line when set (workout mode: `workout=<id>`).
    private let headerTag: String?
    private let recordingURL: URL
    private var handle: FileHandle?
    private var failed = false

    /// Since-boot time of the first sample: CSV t = 0.
    private(set) var t0: Double?
    private(set) var samplesWritten = 0
    private(set) var bytesWritten = 0
    private(set) var marksWritten = 0
    /// Comment lines that arrived before the first sample (written right after the header,
    /// once t0 is known).
    private var pendingComments: [(time: Double, makeLine: (Double) -> String)] = []

    var fileName: String { "session-\(sessionId.uuidString).csv" }

    init(sessionId: UUID, bootDate: Date, liftType: LiftType, headerTag: String? = nil) {
        self.sessionId = sessionId
        self.bootDate = bootDate
        self.liftType = liftType
        self.headerTag = headerTag
        self.recordingURL = WatchFiles.recording.appendingPathComponent("session-\(sessionId.uuidString).csv")
    }

    // MARK: - Writing

    func append(_ samples: [MotionSample]) {
        guard !failed, !samples.isEmpty else { return }
        if handle == nil {
            open(startTime: samples[0].t, startDate: bootDate.addingTimeInterval(samples[0].t))
        }
        guard let t0 = t0 else { return }
        var text = ""
        text.reserveCapacity(samples.count * 110)
        for s in samples {
            text += String(format: "%.6f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f\n",
                           s.t - t0,
                           s.attitude.w, s.attitude.x, s.attitude.y, s.attitude.z,
                           s.userAccel.x, s.userAccel.y, s.userAccel.z,
                           s.gravity.x, s.gravity.y, s.gravity.z,
                           s.rotationRate.x, s.rotationRate.y, s.rotationRate.z)
        }
        if write(text) {
            samplesWritten += samples.count
        }
    }

    /// `time` is seconds since boot (same base as CoreMotion timestamps).
    func appendMark(atUptime time: Double, label: String) {
        marksWritten += 1
        let n = marksWritten
        let clean = label.replacingOccurrences(of: "\n", with: " ")
        appendComment(atUptime: time) { rel in
            String(format: "# mark t=%.6f n=%ld label=", rel, n) + clean
        }
    }

    func appendEvent(atUptime time: Double, description: String) {
        appendComment(atUptime: time) { rel in
            String(format: "# event t=%.6f ", rel) + description
        }
    }

    private func appendComment(atUptime time: Double, makeLine: @escaping (Double) -> String) {
        guard !failed else { return }
        if let t0 = t0 {
            _ = write(makeLine(time - t0) + "\n")
        } else {
            // No sample yet (first second of a session): keep it until t0 is known.
            pendingComments.append((time: time, makeLine: makeLine))
        }
    }

    // MARK: - Finish

    /// Flushes, closes and moves the file to the outbox. Always returns a file when possible,
    /// even with zero samples (header only), so the user can see the session was recorded.
    func finish() -> URL? {
        if handle == nil && !failed {
            open(startTime: nil, startDate: Date())
        }
        if let handle = handle {
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                Log.files.error("CSV close failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        handle = nil
        let fm = FileManager.default
        guard fm.fileExists(atPath: recordingURL.path) else {
            Log.files.error("CSV file missing at finish")
            return nil
        }
        let destination = WatchFiles.outbox.appendingPathComponent(fileName)
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: recordingURL, to: destination)
            Log.files.info("CSV finished: \(self.samplesWritten) samples, \(self.bytesWritten) bytes")
            return destination
        } catch {
            Log.files.error("Could not move CSV to outbox: \(error.localizedDescription, privacy: .public)")
            // Still try to send it from where it is.
            return recordingURL
        }
    }

    // MARK: - Private

    private func open(startTime: Double?, startDate: Date) {
        t0 = startTime
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let tag: String = headerTag ?? "liftType=\(liftType.rawValue)"
        var header = "# barpath-session v1, sessionId=\(sessionId.uuidString), startDate=\(formatter.string(from: startDate)), \(tag)\n"
        header += "t,qw,qx,qy,qz,ax,ay,az,gx,gy,gz,rx,ry,rz\n"
        for comment in pendingComments {
            if let t0 = startTime {
                header += comment.makeLine(comment.time - t0) + "\n"
            } else {
                // Session without any sample: keep since-boot time and say so.
                header += comment.makeLine(comment.time) + " (t since boot: no samples)\n"
            }
        }
        pendingComments = []
        let fm = FileManager.default
        guard fm.createFile(atPath: recordingURL.path, contents: Data(header.utf8)) else {
            Log.files.error("Could not create CSV at \(self.recordingURL.path, privacy: .public)")
            failed = true
            return
        }
        bytesWritten = header.utf8.count
        do {
            let h = try FileHandle(forWritingTo: recordingURL)
            _ = try h.seekToEnd()
            handle = h
        } catch {
            Log.files.error("Could not open CSV: \(error.localizedDescription, privacy: .public)")
            failed = true
        }
    }

    /// Writes and syncs to disk. Returns false (and stops writing) on error.
    private func write(_ text: String) -> Bool {
        guard let handle = handle, !failed else { return false }
        let data = Data(text.utf8)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            bytesWritten += data.count
            return true
        } catch {
            Log.files.error("CSV write failed: \(error.localizedDescription, privacy: .public)")
            failed = true
            return false
        }
    }
}
