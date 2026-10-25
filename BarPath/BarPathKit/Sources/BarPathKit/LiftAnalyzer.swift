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

    public init(emaTau: Double = 0.08,
                stillRot: Double = 0.5,
                stillAcc: Double = 0.06,
                homingMinStill: Double = 0.2,
                startVelocity: Double = 0.5,
                startWindow: Double = 1.0,
                anchorMinStill: Double = 0.25,
                dropDistance: Double = 0.5,
                maxUncorrectedDuration: Double = 3.0) {
        self.emaTau = emaTau
        self.stillRot = stillRot
        self.stillAcc = stillAcc
        self.homingMinStill = homingMinStill
        self.startVelocity = startVelocity
        self.startWindow = startWindow
        self.anchorMinStill = anchorMinStill
        self.dropDistance = dropDistance
        self.maxUncorrectedDuration = maxUncorrectedDuration
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

public enum LiftAnalyzer {

    /// Human-readable notes (exact strings from the spec).
    public static let noteGravityOnly: String = "Orientation unavailable: vertical only"
    public static let noteNoAnchor: String = "No still recovery found: path uncorrected"
    public static let noteForwardEstimated: String = "Forward direction estimated"
    public static let noteHomingFromWatch: String = "Homing taken from the watch's estimate"

    /// Inclusive range of sample indices where isStill is true.
    struct StillRun {
        var start: Int
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

        var quats: [Quat] = []
        var aDev: [Vec3] = []
        var grav: [Vec3] = []
        var rotNorm: [Double] = []
        var accNorm: [Double] = []
        quats.reserveCapacity(n)
        aDev.reserveCapacity(n)
        grav.reserveCapacity(n)
        rotNorm.reserveCapacity(n)
        accNorm.reserveCapacity(n)
        for i in 0..<n {
            let q = Quat(w: motion.qw[i], x: motion.qx[i], y: motion.qy[i], z: motion.qz[i])
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
        let mode: FrameMode
        if zA >= -0.8 && zB >= -0.8 {
            mode = .gravityOnly
            notes.append(noteGravityOnly)
        } else if abs(zA + 1.0) <= abs(zB + 1.0) {
            mode = .direct
        } else {
            mode = .conjugate
        }

        var rot: [Quat] = []     // effective device -> world rotation
        rot.reserveCapacity(n)
        var aW: [Vec3] = []
        aW.reserveCapacity(n)
        for i in 0..<n {
            switch mode {
            case .direct:
                rot.append(quats[i])
                aW.append(quats[i].rotate(aDev[i]))
            case .conjugate:
                let qc = quats[i].conjugate
                rot.append(qc)
                aW.append(qc.rotate(aDev[i]))
            case .gravityOnly:
                rot.append(Quat.identity)
                let ghat = grav[i].normalized
                aW.append(Vec3(0.0, 0.0, -(aDev[i].dot(ghat))))
            }
        }

        // 2. Stillness mask (same EMA formulas as the online detector, forward pass).
        var still: [Bool] = [Bool](repeating: false, count: n)
        var rotEMA: Double = 0.0
        var accEMA: Double = 0.0
        for i in 0..<n {
            let dt: Double = i == 0 ? 0.0 : clampValue(t[i] - t[i - 1], 0.0, 0.05)
            let alpha: Double = config.emaTau > 0 ? min(1.0, dt / config.emaTau) : 1.0
            rotEMA += alpha * (rotNorm[i] - rotEMA)
            accEMA += alpha * (accNorm[i] - accEMA)
            still[i] = rotEMA < config.stillRot && accEMA < config.stillAcc
        }
        let runs = stillRuns(still)

        // 3. Homing.
        var homingIndex: Int = -1
        var homingRun = StillRun(start: 0, end: 0)
        for run in runs {
            if t[run.end] - t[run.start] < config.homingMinStill { continue }
            let s = run.end
            var vz: Double = 0.0
            var k = s + 1
            var found = false
            while k < n && t[k] - t[s] <= config.startWindow {
                let dt = t[k] - t[k - 1]
                vz += 0.5 * (aW[k].z + aW[k - 1].z) * dt
                if vz >= config.startVelocity {
                    found = true
                    break
                }
                k += 1
            }
            if found {
                homingIndex = s
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
            }
            notes.append(noteHomingFromWatch)
        }
        let h0 = homingIndex
        if t[n - 1] - t[h0] < 0.5 { throw AnalysisError.tooShort }

        // 4. Anchors: still runs after homing, long enough.
        var anchors: [StillRun] = []
        for run in runs where run.start > h0 && t[run.end] - t[run.start] >= config.anchorMinStill {
            anchors.append(run)
        }

        // 5./6. Velocity and position.
        var v: [Vec3] = [Vec3](repeating: Vec3.zero, count: n)
        var p: [Vec3] = [Vec3](repeating: Vec3.zero, count: n)
        var segBounds: [(s: Int, e: Int, drift: Double)] = []
        var endIndex: Int = h0
        var noAnchor = false

        if anchors.isEmpty {
            noAnchor = true
            notes.append(noteNoAnchor)
            var e = h0
            while e + 1 < n && t[e + 1] - t[h0] <= config.maxUncorrectedDuration {
                e += 1
            }
            if e == h0 { e = min(h0 + 1, n - 1) }
            endIndex = e
            if e > h0 {
                for i in (h0 + 1)...e {
                    let dt = t[i] - t[i - 1]
                    v[i] = v[i - 1] + (aW[i] + aW[i - 1]) * (0.5 * dt)
                }
            }
            segBounds.append((s: h0, e: e, drift: 0.0))
        } else {
            // Corrected velocity for every motion segment up to the last anchor.
            var allBounds: [(s: Int, e: Int, drift: Double)] = []
            var s = h0
            for a in anchors {
                let e = a.start
                var vRaw: [Vec3] = [Vec3](repeating: Vec3.zero, count: e - s + 1)
                if e > s {
                    for i in (s + 1)...e {
                        let dt = t[i] - t[i - 1]
                        vRaw[i - s] = vRaw[i - s - 1] + (aW[i] + aW[i - 1]) * (0.5 * dt)
                    }
                }
                let drift = vRaw[e - s]
                let span = t[e] - t[s]
                for i in s...e {
                    let frac: Double = span > 0 ? (t[i] - t[s]) / span : 1.0
                    v[i] = vRaw[i - s] - drift * frac
                }
                // Inside the anchor run velocity is forced to 0.
                for i in a.start...a.end {
                    v[i] = Vec3.zero
                }
                allBounds.append((s: s, e: e, drift: drift.norm))
                s = a.end
            }
            let lastAnchorEnd = anchors[anchors.count - 1].end
            if lastAnchorEnd > h0 {
                for i in (h0 + 1)...lastAnchorEnd {
                    let dt = t[i] - t[i - 1]
                    p[i] = p[i - 1] + (v[i] + v[i - 1]) * (0.5 * dt)
                }
            }

            // Path end: first anchor whose open-ended tail falls more than dropDistance below it.
            endIndex = lastAnchorEnd
            var usedAnchors = anchors.count
            for j in 0..<anchors.count {
                let a = anchors[j]
                let tailEnd: Int = j + 1 < anchors.count ? anchors[j + 1].start : n - 1
                let anchorH = p[a.end].z
                var tv: Double = 0.0
                var tz: Double = anchorH
                var dropped = false
                if tailEnd > a.end {
                    for k in (a.end + 1)...tailEnd {
                        let dt = t[k] - t[k - 1]
                        let tvNew = tv + 0.5 * (aW[k].z + aW[k - 1].z) * dt
                        tz += 0.5 * (tv + tvNew) * dt
                        tv = tvNew
                        if anchorH - tz > config.dropDistance {
                            dropped = true
                            break
                        }
                    }
                }
                if dropped {
                    endIndex = a.end
                    usedAnchors = j + 1
                    break
                }
            }
            for j in 0..<usedAnchors {
                segBounds.append(allBounds[j])
            }
        }

        // Positions for the no-anchor path (anchor case was integrated above).
        if noAnchor && endIndex > h0 {
            for i in (h0 + 1)...endIndex {
                let dt = t[i] - t[i - 1]
                p[i] = p[i - 1] + (v[i] + v[i - 1]) * (0.5 * dt)
            }
        }

        // 7. Horizontal axes.
        var forwardAxis = Vec3(1.0, 0.0, 0.0)
        if mode != .gravityOnly {
            var fSum = Vec3.zero
            let runStart = min(homingRun.start, h0)
            let runEnd = max(homingRun.end, h0)
            for k in runStart...runEnd {
                fSum = fSum + rot[k].rotate(Vec3(0.0, 0.0, 1.0))
            }
            let f = fSum / Double(runEnd - runStart + 1)
            let fh = Vec3(f.x, f.y, 0.0)
            if fh.norm >= 0.3 {
                forwardAxis = fh.normalized
            } else {
                forwardAxis = pcaForward(p: p, from: h0, to: endIndex)
                notes.append(noteForwardEstimated)
            }
        }
        let up = Vec3(0.0, 0.0, 1.0)
        let lateralAxis = up.cross(forwardAxis)

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

        // 9. Segments.
        var segments: [LiftSegment] = []
        for b in segBounds {
            var segPeakV = -Double.infinity
            var segMaxZ = -Double.infinity
            var segMinZ = Double.infinity
            for i in b.s...b.e {
                segPeakV = max(segPeakV, v[i].z)
                segMaxZ = max(segMaxZ, p[i].z)
                segMinZ = min(segMinZ, p[i].z)
            }
            segments.append(LiftSegment(startIndex: b.s - h0,
                                        endIndex: b.e - h0,
                                        duration: t[b.e] - t[b.s],
                                        peakVerticalVelocity: segPeakV,
                                        heightGain: p[b.e].z - p[b.s].z,
                                        maxHeight: segMaxZ,
                                        minHeight: segMinZ,
                                        driftCorrection: b.drift))
        }

        // 8. Metrics.
        var peakIdx = 0
        for i in 0..<path.count where path[i].vVertical > path[peakIdx].vVertical {
            peakIdx = i
        }
        let peakV = path[peakIdx].vVertical
        let timeToPeak = path[peakIdx].t
        let peakTimeAbs = t[h0 + peakIdx]

        var catchAnchor: StillRun? = nil
        if !noAnchor {
            for a in anchors where a.start <= endIndex && t[a.start] > peakTimeAbs {
                catchAnchor = a
                break
            }
        }
        let limit: Int = catchAnchor != nil ? catchAnchor!.start - h0 : path.count - 1
        var maxIdx = 0
        for i in 0...limit where path[i].vertical > path[maxIdx].vertical {
            maxIdx = i
        }
        let maxHeight = path[maxIdx].vertical
        var catchHeight: Double? = nil
        var dropUnderBar: Double? = nil
        if catchAnchor != nil {
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

    /// Principal axis of the horizontal positions over [from, to]; sign chosen so that
    /// max(forward) >= |min(forward)|.
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
        if abs(sxy) > 1e-15 {
            let half = 0.5 * (sxx - syy)
            let lambda = 0.5 * (sxx + syy) + (half * half + sxy * sxy).squareRoot()
            axis = Vec3(lambda - syy, sxy, 0.0).normalized
        } else if sxx >= syy {
            axis = Vec3(1.0, 0.0, 0.0)
        } else {
            axis = Vec3(0.0, 1.0, 0.0)
        }
        if axis.norm < 1e-12 { axis = Vec3(1.0, 0.0, 0.0) }
        var fMax = -Double.infinity
        var fMin = Double.infinity
        for i in from...to {
            let f = p[i].dot(axis)
            fMax = max(fMax, f)
            fMin = min(fMin, f)
        }
        if fMax < abs(fMin) {
            axis = -axis
        }
        return axis
    }
}
