import Foundation

/// Rep counting for strength lifts where the hands hold the bar (deadlift first).
/// Mirrors tools/barpath/reps.py exactly (centred moving averages, no IIR state):
/// 1. a_up = +(userAccel·ĝ)·G; 2. low-pass by a centred moving average, integrate (trapezoid);
/// 3. high-pass by subtracting a centred moving average of the velocity; 4. velocity peaks
/// ≥ minPeakVelocity, picked greedily by height ≥ minRepInterval apart; 5. concentric phase
/// between the zero crossings around each peak, ROM = ∫v; keep reps with ROM ≥ minRange and
/// the forearm hanging (|ĝ.x| ≥ armHangMin) at the top.
public struct RepConfig: Equatable, Sendable {
    public var smooth: Double = 0.15          // s
    public var detrend: Double = 3.0          // s
    public var minPeakVelocity: Double = 0.2  // m/s
    public var minRepInterval: Double = 1.2   // s
    public var minRange: Double = 0.30        // m
    public var armHangMin: Double = 0.8

    public init() {}
}

public struct Rep: Codable, Equatable, Sendable {
    public var start: Double         // s, start of the concentric phase
    public var peak: Double          // s, peak upward velocity
    public var end: Double           // s, top of the rep
    public var range: Double         // m
    public var meanVelocity: Double  // m/s
    public var peakVelocity: Double  // m/s

    public init(start: Double, peak: Double, end: Double, range: Double, meanVelocity: Double, peakVelocity: Double) {
        self.start = start
        self.peak = peak
        self.end = end
        self.range = range
        self.meanVelocity = meanVelocity
        self.peakVelocity = peakVelocity
    }
}

public struct RepAnalysis: Codable, Equatable, Sendable {
    public var reps: [Rep] = []
    public var rejected: [Rep] = []

    public init() {}

    public var count: Int { return reps.count }

    /// Fractional drop in mean concentric velocity from the faster of the first two reps to
    /// the last rep (0.25 = the last rep was 25 % slower).
    public var velocityLoss: Double {
        guard reps.count >= 2 else { return 0.0 }
        let best = max(reps[0].meanVelocity, reps[1].meanVelocity)
        return best > 0 ? (best - reps[reps.count - 1].meanVelocity) / best : 0.0
    }
}

public enum RepCounter {

    /// Centred moving average; the window shrinks at the edges (mean of what exists).
    public static func movingAverage(_ x: [Double], width: Int) -> [Double] {
        let n = x.count
        guard n > 0 else { return [] }
        let h = max(1, width) / 2
        var c = [Double](repeating: 0.0, count: n + 1)
        for i in 0..<n {
            c[i + 1] = c[i] + x[i]
        }
        var out = [Double](repeating: 0.0, count: n)
        for i in 0..<n {
            let lo = max(0, i - h)
            let hi = min(n, i + h + 1)
            out[i] = (c[hi] - c[lo]) / Double(hi - lo)
        }
        return out
    }

    public static func count(_ motion: MotionSeries, config: RepConfig = RepConfig()) -> RepAnalysis {
        var out = RepAnalysis()
        let n = motion.count
        guard n >= 50 else { return out }
        let t = motion.t

        var dts: [Double] = []
        dts.reserveCapacity(n - 1)
        for i in 1..<n {
            dts.append(t[i] - t[i - 1])
        }
        let fs = 1.0 / median(dts)

        var aUp = [Double](repeating: 0.0, count: n)
        var gx = [Double](repeating: 0.0, count: n)
        for i in 0..<n {
            let g = Vec3(motion.gx[i], motion.gy[i], motion.gz[i])
            let gn = g.norm
            let gh = gn > 0 ? g / gn : Vec3.zero
            aUp[i] = Vec3(motion.ax[i], motion.ay[i], motion.az[i]).dot(gh) * standardGravity
            gx[i] = gh.x
        }
        let aLp = movingAverage(aUp, width: Int((config.smooth * fs).rounded()))
        var v = [Double](repeating: 0.0, count: n)
        for i in 1..<n {
            v[i] = v[i - 1] + 0.5 * (aLp[i] + aLp[i - 1]) * (t[i] - t[i - 1])
        }
        let trend = movingAverage(v, width: Int((config.detrend * fs).rounded()))
        for i in 0..<n {
            v[i] -= trend[i]
        }

        var cand: [Int] = []
        for i in 1..<(n - 1) where v[i] >= config.minPeakVelocity && v[i] >= v[i - 1] && v[i] > v[i + 1] {
            cand.append(i)
        }
        cand.sort { a, b in v[a] != v[b] ? v[a] > v[b] : a < b }
        let minGap = Int((config.minRepInterval * fs).rounded())
        var picked: [Int] = []
        for i in cand where picked.allSatisfy({ abs(i - $0) >= minGap }) {
            picked.append(i)
        }
        picked.sort()

        for i in picked {
            var s = i
            while s > 0 && v[s - 1] > 0 {
                s -= 1
            }
            var e = i
            while e < n - 1 && v[e + 1] > 0 {
                e += 1
            }
            guard e > s else { continue }
            var rom = 0.0
            for k in s..<e {
                rom += 0.5 * (v[k + 1] + v[k]) * (t[k + 1] - t[k])
            }
            let dur = t[e] - t[s]
            let rep = Rep(start: t[s], peak: t[i], end: t[e], range: rom,
                          meanVelocity: dur > 0 ? rom / dur : 0.0, peakVelocity: v[i])
            if rom >= config.minRange && abs(gx[e]) >= config.armHangMin {
                out.reps.append(rep)
            } else {
                out.rejected.append(rep)
            }
        }
        return out
    }

    private static func median(_ x: [Double]) -> Double {
        let s = x.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : 0.5 * (s[m - 1] + s[m])
    }
}
