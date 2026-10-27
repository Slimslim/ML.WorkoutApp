import Foundation

// MARK: - Public types

/// Offline analyzer parameters (spec §5).
public struct AnalyzerConfig: Equatable, Sendable {
    public var emaTau: Double                  // s
    public var stillRot: Double                // rad/s
    public var stillAcc: Double                // g
    public var homingMinStill: Double          // s
    public var startVelocity: Double           // m/s
    public var startWindow: Double             // s
    public var anchorMinStill: Double          // s
    public var dropDistance: Double            // m
    public var maxUncorrectedDuration: Double  // s
    public var armsUpMax: Double               // forearm 'up' (turned over) when hang < this
    public var armsDownMin: Double             // forearm back 'down' (bar released) when hang > this
    public var pseudoAnchorWindow: Double      // s, search window before arms-down
    public var pseudoAnchorSmooth: Double      // s, moving-average width of the calmness score

    public init(emaTau: Double = 0.08,
                stillRot: Double = 0.5,
                stillAcc: Double = 0.06,
                homingMinStill: Double = 0.2,
                startVelocity: Double = 0.5,
                startWindow: Double = 1.0,
                anchorMinStill: Double = 0.25,
                dropDistance: Double = 0.5,
                maxUncorrectedDuration: Double = 3.0,
                armsUpMax: Double = 0.3,
                armsDownMin: Double = 0.8,
                pseudoAnchorWindow: Double = 1.0,
                pseudoAnchorSmooth: Double = 0.1) {
        self.emaTau = emaTau
        self.stillRot = stillRot
        self.stillAcc = stillAcc
        self.homingMinStill = homingMinStill
        self.startVelocity = startVelocity
        self.startWindow = startWindow
        self.anchorMinStill = anchorMinStill
        self.dropDistance = dropDistance
        self.maxUncorrectedDuration = maxUncorrectedDuration
        self.armsUpMax = armsUpMax
        self.armsDownMin = armsDownMin
        self.pseudoAnchorWindow = pseudoAnchorWindow
        self.pseudoAnchorSmooth = pseudoAnchorSmooth
    }

    public static let `default`: AnalyzerConfig = AnalyzerConfig()
}

public struct PathSample: Equatable, Sendable {
    public var t: Double          // seconds since homing
    public var forward: Double    // m, + = away from the lifter
    public var lateral: Double    // m
    public var vertical: Double   // m, + = up, 0 at homing
    public var vForward: Double   // m/s
    public var vVertical: Double  // m/s
    public var speed: Double      // m/s, |v| (3-D)

    public init(t: Double, forward: Double, lateral: Double, vertical: Double,
                vForward: Double, vVertical: Double, speed: Double) {
        self.t = t
        self.forward = forward
        self.lateral = lateral
        self.vertical = vertical
        self.vForward = vForward
        self.vVertical = vVertical
        self.speed = speed
    }
}

/// Motion between two zero-velocity anchors.
public struct LiftSegment: Equatable, Sendable {
    public var startIndex: Int            // into LiftAnalysis.path
    public var endIndex: Int
    public var duration: Double
    public var peakVerticalVelocity: Double
    public var heightGain: Double          // vertical(end) - vertical(start)
    public var maxHeight: Double
    public var minHeight: Double
    public var driftCorrection: Double     // |velocity error| removed at the closing anchor, m/s

    public init(startIndex: Int, endIndex: Int, duration: Double, peakVerticalVelocity: Double,
                heightGain: Double, maxHeight: Double, minHeight: Double, driftCorrection: Double) {
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.duration = duration
        self.peakVerticalVelocity = peakVerticalVelocity
        self.heightGain = heightGain
        self.maxHeight = maxHeight
        self.minHeight = minHeight
        self.driftCorrection = driftCorrection
    }
}

public enum Confidence: String, Sendable {
    case high, medium, low
}

public struct LiftMetrics: Equatable, Sendable {
    public var peakVerticalVelocity: Double
    public var timeToPeakVelocity: Double  // s since homing
    public var maxHeight: Double           // highest point before the first catch anchor
    public var catchHeight: Double?        // lowest point between maxHeight and the first anchor after it
    public var dropUnderBar: Double?       // maxHeight - catchHeight
    public var finalHeight: Double         // height at path end (lockout/recovery)
    public var maxForward: Double          // max of forward (>= 0 normally)
    public var maxBackward: Double         // min of forward (<= 0 normally)
    public var duration: Double            // homing -> path end

    public init(peakVerticalVelocity: Double, timeToPeakVelocity: Double, maxHeight: Double,
                catchHeight: Double?, dropUnderBar: Double?, finalHeight: Double,
                maxForward: Double, maxBackward: Double, duration: Double) {
        self.peakVerticalVelocity = peakVerticalVelocity
        self.timeToPeakVelocity = timeToPeakVelocity
        self.maxHeight = maxHeight
        self.catchHeight = catchHeight
        self.dropUnderBar = dropUnderBar
        self.finalHeight = finalHeight
        self.maxForward = maxForward
        self.maxBackward = maxBackward
        self.duration = duration
    }
}

public struct LiftAnalysis: Equatable, Sendable {
    public var recordingId: UUID
    public var homingIndex: Int            // into recording.motion
    public var endIndex: Int               // into recording.motion
    public var path: [PathSample]          // homingIndex...endIndex
    public var segments: [LiftSegment]
    public var metrics: LiftMetrics
    public var confidence: Confidence
    public var notes: [String]             // human-readable caveats

    public init(recordingId: UUID, homingIndex: Int, endIndex: Int, path: [PathSample],
                segments: [LiftSegment], metrics: LiftMetrics, confidence: Confidence, notes: [String]) {
        self.recordingId = recordingId
        self.homingIndex = homingIndex
        self.endIndex = endIndex
        self.path = path
        self.segments = segments
        self.metrics = metrics
        self.confidence = confidence
        self.notes = notes
    }
}

public enum AnalysisError: Error, Equatable {
    case tooShort, noHomingFound
}

// MARK: - Analyzer

/// Offline analyzer (spec §5 incl. Revision A). Mirrors tools/barpath/analyzer.py.
public enum LiftAnalyzer {

    /// Human-readable notes (exact strings shared with the Python reference).
    public static let noteGravityOnly: String = "Orientation unavailable: vertical only"
    public static let noteNoAnchor: String = "No still recovery found: path uncorrected"
    public static let notePseudoAnchor: String = "No still hold at the finish: end estimated at the calmest point before the drop"
    public static let noteForwardEstimated: String = "Forward direction estimated"
    public static let noteHomingFromWatch: String = "Homing taken from the watch estimate"

    /// Inclusive range of sample indices where the forward isStill mask is true.
    struct StillRun {
        var start: Int
        var end: Int
    }

    /// Anchor run: velocity is forced to 0 on [start, release]; motion resumes after `release`.
    struct Anchor {
        var start: Int
        var release: Int
        var end: Int
    }

    private enum FrameMode {
        case direct, conjugate, gravityOnly
    }

    public static func analyze(_ recording: LiftRecording, config: AnalyzerConfig = .default) throws -> LiftAnalysis {
        let motion = recording.motion
        let n = motion.count
        if n < 2 { throw AnalysisError.tooShort }

        let t: [Double] = motion.t
        let G = standardGravity
        var notes: [String] = []

        var quats: [Quat] = []      // normalized attitude quaternions
        var aDev: [Vec3] = []       // userAccel * G (m/s²; = -physical acceleration)
        var grav: [Vec3] = []
        var rotNorm: [Double] = []
        var accNorm: [Double] = []
        quats.reserveCapacity(n)
        aDev.reserveCapacity(n)
        grav.reserveCapacity(n)
        rotNorm.reserveCapacity(n)
        accNorm.reserveCapacity(n)
        for i in 0..<n {
            let q = normalizedQuat(Quat(w: motion.qw[i], x: motion.qx[i], y: motion.qy[i], z: motion.qz[i]))
            let ua = Vec3(motion.ax[i], motion.ay[i], motion.az[i])
            let g = Vec3(motion.gx[i], motion.gy[i], motion.gz[i])
            let rr = Vec3(motion.rx[i], motion.ry[i], motion.rz[i])
            quats.append(q)
            aDev.append(ua * G)
            grav.append(g)
            rotNorm.append(rr.norm)
            accNorm.append(ua.norm)
        }

        // 1. World frame with auto-detected quaternion convention.
        var zAvals: [Double] = []
        var zBvals: [Double] = []
        zAvals.reserveCapacity(n)
        zBvals.reserveCapacity(n)
        for i in 0..<n {
            zAvals.append(quats[i].rotate(grav[i]).z)
            zBvals.append(quats[i].conjugate.rotate(grav[i]).z)
        }
        let zA = medianOf(zAvals)
        let zB = medianOf(zBvals)
        let bestZ: Double
        let candidate: FrameMode
        if abs(zA + 1.0) <= abs(zB + 1.0) {
            bestZ = zA
            candidate = .direct
        } else {
            bestZ = zB
            candidate = .conjugate
        }
        let mode: FrameMode
        if bestZ < -0.8 {
            mode = candidate
        } else {
            mode = .gravityOnly
            notes.append(noteGravityOnly)
        }

        // userAccel = -(physical acceleration)/G, so aW = -rot(userAccel)·G (world z up).
        var rot: [Quat] = []     // effective device -> world rotation
        rot.reserveCapacity(n)
        var aW: [Vec3] = []
        aW.reserveCapacity(n)
        for i in 0..<n {
            switch mode {
            case .direct:
                rot.append(quats[i])
                aW.append(-(quats[i].rotate(aDev[i])))
            case .conjugate:
                let qc = quats[i].conjugate
                rot.append(qc)
                aW.append(-(qc.rotate(aDev[i])))
            case .gravityOnly:
                rot.append(Quat.identity)
                let ghat = grav[i].normalized
                aW.append(Vec3(0.0, 0.0, aDev[i].dot(ghat)))
            }
        }

        // 2. Stillness: forward mask (runs, durations) + backward mask (release index).
        let still = stillnessMask(t: t, rotNorm: rotNorm, accNorm: accNorm, config: config, reverse: false)
        let stillB = stillnessMask(t: t, rotNorm: rotNorm, accNorm: accNorm, config: config, reverse: true)
        let runs = stillRuns(still)

        // 3. Homing.
        var homingIndex: Int = -1
        var homingRun = StillRun(start: 0, end: 0)
        for run in runs {
            if t[run.end] - t[run.start] < config.homingMinStill { continue }
            let s0 = releaseIndex(run, stillB)
            let tLimit = t[s0] + config.startWindow
            if s0 + 1 >= n || t[s0 + 1] > tLimit { continue }   // fewer than 2 samples in the window
            var found = config.startVelocity <= 0.0
            var vz: Double = 0.0
            var k = s0 + 1
            while !found && k < n && t[k] <= tLimit {
                let dt = t[k] - t[k - 1]
                vz += 0.5 * (aW[k].z + aW[k - 1].z) * dt
                if vz >= config.startVelocity {
                    found = true
                }
                k += 1
            }
            if found {
                homingIndex = s0
                homingRun = run
                break
            }
        }
        if homingIndex < 0 {
            guard let ht = recording.homingTime else { throw AnalysisError.noHomingFound }
            var best = 0
            var bestDist = Double.infinity
            for i in 0..<n {
                let d = abs(t[i] - ht)
                if d < bestDist {
                    bestDist = d
                    best = i
                }
            }
            homingIndex = best
            homingRun = StillRun(start: best, end: best)
            for run in runs where run.start <= best && best <= run.end {
                homingRun = run
                break
            }
            notes.append(noteHomingFromWatch)
        }
        let h0 = homingIndex
        if t[n - 1] - t[h0] < 0.5 { throw AnalysisError.tooShort }

        // 4. Anchors: forward still runs starting after the homing run, long enough.
        var anchors: [Anchor] = []
        for run in runs where run.start > homingRun.end && t[run.end] - t[run.start] >= config.anchorMinStill {
            anchors.append(Anchor(start: run.start, release: releaseIndex(run, stillB), end: run.end))
        }

        // 4b. Arms-down: after the turnover the forearm points up; when it points down again the
        // bar has been dropped or lowered. Nothing after that is part of the lift.
        var armsDownIndex: Int? = nil
        var hangMean: Double = 0.0
        for k in homingRun.start...homingRun.end {
            hangMean += grav[k].normalized.x
        }
        let hangSign: Double = hangMean >= 0 ? 1.0 : -1.0
        var upIndex: Int? = nil
        for i in h0..<n where hangSign * grav[i].normalized.x < config.armsUpMax {
            upIndex = i
            break
        }
        if let up = upIndex {
            for i in up..<n where hangSign * grav[i].normalized.x > config.armsDownMin {
                armsDownIndex = i
                break
            }
        }
        if let down = armsDownIndex, let up = upIndex {
            anchors = anchors.filter { $0.start < down }
            let hasFinishAnchor = anchors.contains { $0.start > up }
            if !hasFinishAnchor {
                // No still hold at the finish: the lifter is (nearly) at rest just before the
                // drop, so use the calmest point of the last second before arms-down.
                var calm: [Double] = []
                calm.reserveCapacity(n)
                for i in 0..<n {
                    calm.append(accNorm[i] + 0.05 * rotNorm[i])
                }
                var diffs: [Double] = []
                diffs.reserveCapacity(max(0, n - 1))
                for i in 1..<n {
                    diffs.append(t[i] - t[i - 1])
                }
                let dtMed: Double = diffs.isEmpty ? 0.005 : medianOf(diffs)
                let w: Int = dtMed > 0 ? max(1, Int((config.pseudoAnchorSmooth / dtMed).rounded())) : 1
                let half = (w - 1) / 2
                // j0 = first index with t >= t[down] - window (like numpy searchsorted), at least up.
                let tStart = t[down] - config.pseudoAnchorWindow
                var j0 = 0
                while j0 < n && t[j0] < tStart {
                    j0 += 1
                }
                j0 = max(up, j0)
                let j1 = down
                if j1 > j0 {
                    var best = j0
                    var bestScore = Double.infinity
                    for i in j0..<j1 {
                        // numpy convolve(mode: "same") with a box of width w
                        let lo = max(0, i + half - (w - 1))
                        let hi = min(n - 1, i + half)
                        var sum: Double = 0.0
                        for k in lo...hi {
                            sum += calm[k]
                        }
                        let score = sum / Double(w)
                        if score < bestScore {
                            bestScore = score
                            best = i
                        }
                    }
                    if best > h0 + 1 {
                        anchors.append(Anchor(start: best, release: best, end: best))
                        notes.append(notePseudoAnchor)
                    }
                }
            }
        }

        // 5. Velocity: piecewise ZUPT between still runs.
        var v: [Vec3] = [Vec3](repeating: Vec3.zero, count: n)
        var p: [Vec3] = [Vec3](repeating: Vec3.zero, count: n)
        var segBounds: [(s: Int, e: Int, drift: Double)] = []
        var s = h0
        for a in anchors {
            let e = a.start
            var vRaw: [Vec3] = [Vec3](repeating: Vec3.zero, count: e - s + 1)
            if e > s {
                for i in (s + 1)...e {
                    let dt = t[i] - t[i - 1]
                    vRaw[i - s] = vRaw[i - s - 1] + ((aW[i] + aW[i - 1]) * 0.5) * dt
                }
            }
            let drift = vRaw[e - s]
            let span = t[e] - t[s]
            for i in s...e {
                let frac: Double = span > 0 ? (t[i] - t[s]) / span : 0.0
                v[i] = vRaw[i - s] - drift * frac
            }
            segBounds.append((s: s, e: e, drift: drift.norm))
            for i in a.start...a.release {
                v[i] = Vec3.zero
            }
            s = a.release
        }

        // Positions (0 at homing) over the corrected region.
        let lastCorr: Int = anchors.isEmpty ? h0 : anchors[anchors.count - 1].release
        if lastCorr > h0 {
            for i in (h0 + 1)...lastCorr {
                let dt = t[i] - t[i - 1]
                p[i] = p[i - 1] + ((v[i] + v[i - 1]) * 0.5) * dt
            }
        }

        // 6. Path end.
        let noAnchor = anchors.isEmpty
        var endIndex: Int
        if noAnchor {
            let tLimit = t[h0] + config.maxUncorrectedDuration
            var e = h0
            while e + 1 < n && t[e + 1] <= tLimit {
                e += 1
            }
            endIndex = max(min(e, n - 1), h0 + 1)
            for i in (h0 + 1)...endIndex {
                let dt = t[i] - t[i - 1]
                v[i] = v[i - 1] + ((aW[i] + aW[i - 1]) * 0.5) * dt
            }
            for i in (h0 + 1)...endIndex {
                let dt = t[i] - t[i - 1]
                p[i] = p[i - 1] + ((v[i] + v[i - 1]) * 0.5) * dt
            }
            segBounds = [(s: h0, e: endIndex, drift: 0.0)]
            notes.append(noteNoAnchor)
        } else if armsDownIndex != nil {
            endIndex = anchors[anchors.count - 1].release
            let endLimit = endIndex
            segBounds = segBounds.filter { $0.e <= endLimit }
        } else {
            endIndex = anchors[anchors.count - 1].release
            for k in 0..<anchors.count {
                let ar = anchors[k].release
                let tailEnd: Int = k + 1 < anchors.count ? anchors[k + 1].start : n - 1
                if tailEnd <= ar { continue }
                let anchorZ = p[ar].z
                var tv: Double = 0.0
                var cumZ: Double = 0.0
                var dropped = false
                for j in (ar + 1)...tailEnd {
                    let dt = t[j] - t[j - 1]
                    let tvNew = tv + 0.5 * (aW[j].z + aW[j - 1].z) * dt
                    cumZ += 0.5 * (tvNew + tv) * dt
                    tv = tvNew
                    if anchorZ + cumZ < anchorZ - config.dropDistance {
                        dropped = true
                        break
                    }
                }
                if dropped {
                    endIndex = ar
                    break
                }
            }
            let endLimit = endIndex
            segBounds = segBounds.filter { $0.e <= endLimit }
        }

        // 7. Horizontal axes.
        var forwardAxis = Vec3(1.0, 0.0, 0.0)
        var lateralAxis = Vec3(0.0, 1.0, 0.0)
        if mode != .gravityOnly {
            var fSum = Vec3.zero
            for k in homingRun.start...homingRun.end {
                fSum = fSum + rot[k].rotate(Vec3(0.0, 0.0, 1.0))
            }
            let f = fSum / Double(homingRun.end - homingRun.start + 1)
            let fh = Vec3(f.x, f.y, 0.0)
            if fh.norm >= 0.3 {
                forwardAxis = fh / fh.norm
            } else {
                forwardAxis = pcaForward(p: p, from: h0, to: endIndex)
                notes.append(noteForwardEstimated)
            }
            lateralAxis = Vec3(0.0, 0.0, 1.0).cross(forwardAxis)
        }

        // Path samples.
        var path: [PathSample] = []
        path.reserveCapacity(endIndex - h0 + 1)
        for i in h0...endIndex {
            path.append(PathSample(t: t[i] - t[h0],
                                   forward: p[i].dot(forwardAxis),
                                   lateral: p[i].dot(lateralAxis),
                                   vertical: p[i].z,
                                   vForward: v[i].dot(forwardAxis),
                                   vVertical: v[i].z,
                                   speed: v[i].norm))
        }

        // 8. Metrics.
        var peakIdx = 0
        for i in 0..<path.count where path[i].vVertical > path[peakIdx].vVertical {
            peakIdx = i
        }
        let peakV = path[peakIdx].vVertical
        let timeToPeak = path[peakIdx].t

        var catchStart: Int? = nil
        for a in anchors where a.start <= endIndex && t[a.start] - t[h0] > timeToPeak {
            catchStart = a.start
            break
        }
        let limit: Int = (catchStart ?? endIndex) - h0
        var maxIdx = 0
        for i in 0...limit where path[i].vertical > path[maxIdx].vertical {
            maxIdx = i
        }
        let maxHeight = path[maxIdx].vertical
        var catchHeight: Double? = nil
        var dropUnderBar: Double? = nil
        if catchStart != nil {
            var lowest = Double.infinity
            for i in maxIdx...limit {
                lowest = min(lowest, path[i].vertical)
            }
            catchHeight = lowest
            dropUnderBar = maxHeight - lowest
        }
        var maxForward = -Double.infinity
        var maxBackward = Double.infinity
        for ps in path {
            maxForward = max(maxForward, ps.forward)
            maxBackward = min(maxBackward, ps.forward)
        }
        let lastPath = path[path.count - 1]
        let metrics = LiftMetrics(peakVerticalVelocity: peakV,
                                  timeToPeakVelocity: timeToPeak,
                                  maxHeight: maxHeight,
                                  catchHeight: catchHeight,
                                  dropUnderBar: dropUnderBar,
                                  finalHeight: lastPath.vertical,
                                  maxForward: maxForward,
                                  maxBackward: maxBackward,
                                  duration: lastPath.t)

        // 9. Segments.
        var segments: [LiftSegment] = []
        for b in segBounds {
            let i0 = b.s - h0
            let i1 = b.e - h0
            var segPeakV = -Double.infinity
            var segMaxZ = -Double.infinity
            var segMinZ = Double.infinity
            for i in i0...i1 {
                segPeakV = max(segPeakV, path[i].vVertical)
                segMaxZ = max(segMaxZ, path[i].vertical)
                segMinZ = min(segMinZ, path[i].vertical)
            }
            segments.append(LiftSegment(startIndex: i0,
                                        endIndex: i1,
                                        duration: t[b.e] - t[b.s],
                                        peakVerticalVelocity: segPeakV,
                                        heightGain: path[i1].vertical - path[i0].vertical,
                                        maxHeight: segMaxZ,
                                        minHeight: segMinZ,
                                        driftCorrection: b.drift))
        }

        // 10. Confidence.
        var maxDrift: Double = 0.0
        for sgm in segments {
            maxDrift = max(maxDrift, sgm.driftCorrection)
        }
        var confidence: Confidence
        if maxDrift < 0.25 {
            confidence = .high
        } else if maxDrift < 0.6 {
            confidence = .medium
        } else {
            confidence = .low
        }
        if mode == .gravityOnly && confidence == .high {
            confidence = .medium
        }
        if noAnchor {
            confidence = .low
        }

        return LiftAnalysis(recordingId: recording.id,
                            homingIndex: h0,
                            endIndex: endIndex,
                            path: path,
                            segments: segments,
                            metrics: metrics,
                            confidence: confidence,
                            notes: notes)
    }

    // MARK: Helpers

    /// §4 EMA stillness, run forward or (reverse = true) backward in time with
    /// dt_i = clamp(t[i+1] - t[i], 0, 0.05). EMAs start at 0; the first processed sample has dt = 0.
    static func stillnessMask(t: [Double], rotNorm: [Double], accNorm: [Double],
                              config: AnalyzerConfig, reverse: Bool) -> [Bool] {
        let n = t.count
        var mask: [Bool] = [Bool](repeating: false, count: n)
        var rotEMA: Double = 0.0
        var accEMA: Double = 0.0
        var prev: Int = -1
        for step in 0..<n {
            let i = reverse ? n - 1 - step : step
            var dt: Double = 0.0
            if prev >= 0 {
                let raw: Double = reverse ? t[prev] - t[i] : t[i] - t[prev]
                dt = clampValue(raw, 0.0, 0.05)
            }
            prev = i
            let alpha: Double = config.emaTau > 0 ? min(1.0, dt / config.emaTau) : 1.0
            rotEMA += alpha * (rotNorm[i] - rotEMA)
            accEMA += alpha * (accNorm[i] - accEMA)
            mask[i] = rotEMA < config.stillRot && accEMA < config.stillAcc
        }
        return mask
    }

    /// Last index of the run that the backward mask also calls still, or the run's first index.
    static func releaseIndex(_ run: StillRun, _ stillB: [Bool]) -> Int {
        var i = run.end
        while i >= run.start {
            if stillB[i] { return i }
            i -= 1
        }
        return run.start
    }

    /// Unit quaternion (zero quaternion if the norm is below 1e-12, like geometry.normalize).
    static func normalizedQuat(_ q: Quat) -> Quat {
        let nrm = (q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z).squareRoot()
        if nrm < 1e-12 { return Quat(w: 0.0, x: 0.0, y: 0.0, z: 0.0) }
        return Quat(w: q.w / nrm, x: q.x / nrm, y: q.y / nrm, z: q.z / nrm)
    }

    /// Maximal runs of consecutive `true` values.
    static func stillRuns(_ mask: [Bool]) -> [StillRun] {
        var runs: [StillRun] = []
        var start: Int = -1
        for i in 0..<mask.count {
            if mask[i] {
                if start < 0 { start = i }
            } else if start >= 0 {
                runs.append(StillRun(start: start, end: i - 1))
                start = -1
            }
        }
        if start >= 0 {
            runs.append(StillRun(start: start, end: mask.count - 1))
        }
        return runs
    }

    /// Principal axis of the horizontal positions over [from, to] (population covariance,
    /// eigenvector (lambda - syy, sxy); if sxy ~ 0 the axis with the larger variance); sign chosen
    /// so that max(forward) >= |min(forward)|.
    static func pcaForward(p: [Vec3], from: Int, to: Int) -> Vec3 {
        let m = Double(to - from + 1)
        var mx: Double = 0.0
        var my: Double = 0.0
        for i in from...to {
            mx += p[i].x
            my += p[i].y
        }
        mx /= m
        my /= m
        var sxx: Double = 0.0
        var sxy: Double = 0.0
        var syy: Double = 0.0
        for i in from...to {
            let dx = p[i].x - mx
            let dy = p[i].y - my
            sxx += dx * dx
            sxy += dx * dy
            syy += dy * dy
        }
        sxx /= m
        sxy /= m
        syy /= m
        var axis: Vec3
        if abs(sxy) < 1e-12 {
            axis = sxx >= syy ? Vec3(1.0, 0.0, 0.0) : Vec3(0.0, 1.0, 0.0)
        } else {
            let lambda = 0.5 * (sxx + syy) + (0.25 * (sxx - syy) * (sxx - syy) + sxy * sxy).squareRoot()
            let ex = lambda - syy
            let ey = sxy
            let en = (ex * ex + ey * ey).squareRoot()
            axis = Vec3(ex / en, ey / en, 0.0)
        }
        var fMax = -Double.infinity
        var fMin = Double.infinity
        for i in from...to {
            let f = p[i].x * axis.x + p[i].y * axis.y
            fMax = max(fMax, f)
            fMin = min(fMin, f)
        }
        if fMax < abs(fMin) {
            axis = -axis
        }
        return axis
    }
}
