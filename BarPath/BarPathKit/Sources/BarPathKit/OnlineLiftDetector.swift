import Foundation

/// Online detector parameters (spec §4). Defaults are shared with tools/barpath/detector.py.
public struct DetectorConfig: Equatable, Sendable {
    public var emaTau: Double           // s, smoothing for stillness
    public var stillRot: Double         // rad/s
    public var stillAcc: Double         // g
    public var armMinStill: Double      // s, stillness needed to arm
    public var armVerticalMin: Double   // |ghat.x| threshold
    public var rehomeStill: Double      // s, stillness that re-homes while armed
    public var startVelocity: Double    // m/s, upward velocity that confirms a pull
    public var startWindow: Double      // s, max motion time after homing to reach startVelocity
    public var anchorStill: Double      // s, stillness that counts as a zero-velocity anchor
    public var dropDistance: Double     // m, fall below the last anchor height => dropped
    public var returnHeight: Double     // m, |h| below this while still => returned
    public var returnStill: Double      // s
    public var noAnchorTimeout: Double  // s, lift with no anchor at all => end
    public var maxLiftDuration: Double  // s, hard cap
    public var cooldown: Double         // s, ignore input after an end
    public var armsUpMax: Double        // forearm counts as 'up' (turned over) when hang < this
    public var armsDownMin: Double      // ... and back 'down' (bar released) when hang > this

    public init(emaTau: Double = 0.08,
                stillRot: Double = 0.5,
                stillAcc: Double = 0.06,
                armMinStill: Double = 0.3,
                armVerticalMin: Double = 0.7,
                rehomeStill: Double = 0.15,
                startVelocity: Double = 0.5,
                startWindow: Double = 1.0,
                anchorStill: Double = 0.3,
                dropDistance: Double = 0.5,
                returnHeight: Double = 0.15,
                returnStill: Double = 0.5,
                noAnchorTimeout: Double = 8.0,
                maxLiftDuration: Double = 15.0,
                cooldown: Double = 1.5,
                armsUpMax: Double = 0.3,
                armsDownMin: Double = 0.8) {
        self.emaTau = emaTau
        self.stillRot = stillRot
        self.stillAcc = stillAcc
        self.armMinStill = armMinStill
        self.armVerticalMin = armVerticalMin
        self.rehomeStill = rehomeStill
        self.startVelocity = startVelocity
        self.startWindow = startWindow
        self.anchorStill = anchorStill
        self.dropDistance = dropDistance
        self.returnHeight = returnHeight
        self.returnStill = returnStill
        self.noAnchorTimeout = noAnchorTimeout
        self.maxLiftDuration = maxLiftDuration
        self.cooldown = cooldown
        self.armsUpMax = armsUpMax
        self.armsDownMin = armsDownMin
    }

    public static let `default`: DetectorConfig = DetectorConfig()
}

public enum DetectorState: String, Sendable {
    case idle, armed, lifting, cooldown
}

public enum DetectorEvent: Equatable, Sendable {
    case armed(homingTime: Double)
    case disarmed
    case liftStarted(homingTime: Double)
    case liftEnded(homingTime: Double, endTime: Double, reason: EndReason)
}

/// Live lift detector (spec §4). Feed every device-motion sample in time order.
/// Not thread-safe: use from a single actor/queue.
public final class OnlineLiftDetector {
    public let config: DetectorConfig
    public private(set) var state: DetectorState = .idle

    // Stillness tracking
    private var tPrev: Double? = nil
    private var rotEMA: Double = 0.0
    private var accEMA: Double = 0.0
    private var stillDur: Double = 0.0

    // Armed / lifting variables
    private var homingTime: Double = 0.0
    private var v: Double = 0.0
    private var motionTime: Double = 0.0
    private var h: Double = 0.0
    private var maxH: Double = 0.0
    private var hadAnchor: Bool = false
    private var anchorTime: Double = 0.0
    private var anchorH: Double = 0.0
    private var liftStart: Double = 0.0
    private var cooldownUntil: Double = 0.0
    private var hangSign: Double = 1.0
    private var homingHangSign: Double = 1.0
    private var armsUp: Bool = false

    public init(config: DetectorConfig = .default) {
        self.config = config
    }

    public func reset() {
        state = .idle
        tPrev = nil
        rotEMA = 0.0
        accEMA = 0.0
        stillDur = 0.0
        homingTime = 0.0
        v = 0.0
        motionTime = 0.0
        h = 0.0
        maxH = 0.0
        hadAnchor = false
        anchorTime = 0.0
        anchorH = 0.0
        liftStart = 0.0
        cooldownUntil = 0.0
        hangSign = 1.0
        homingHangSign = 1.0
        armsUp = false
    }

    /// Feed every 200 Hz sample in order. Returns at most one event per sample.
    public func process(_ s: MotionSample) -> DetectorEvent? {
        let t = s.t
        var dt: Double = 0.0
        if let prev = tPrev {
            dt = clampValue(t - prev, 0.0, 0.05)
        }
        tPrev = t

        let ghat = s.gravity.normalized
        // CoreMotion: userAcceleration = -(physical acceleration)/G and ghat points down,
        // so userAccel·ghat = a_up/G (spec §4 sign convention).
        let aUp = s.userAccel.dot(ghat) * standardGravity
        let alpha: Double = config.emaTau > 0 ? min(1.0, dt / config.emaTau) : 1.0
        rotEMA += alpha * (s.rotationRate.norm - rotEMA)
        accEMA += alpha * (s.userAccel.norm - accEMA)
        let isStill = rotEMA < config.stillRot && accEMA < config.stillAcc
        stillDur = isStill ? stillDur + dt : 0.0
        let armVertical = abs(ghat.x) >= config.armVerticalMin

        switch state {
        case .idle:
            if stillDur >= config.armMinStill && armVertical {
                state = .armed
                homingTime = t
                homingHangSign = ghat.x >= 0 ? 1.0 : -1.0
                v = 0.0
                motionTime = 0.0
                return .armed(homingTime: t)
            }
            return nil

        case .armed:
            if stillDur >= config.rehomeStill {
                homingTime = t
                homingHangSign = ghat.x >= 0 ? 1.0 : -1.0
                v = 0.0
                motionTime = 0.0
                if !armVertical {
                    state = .idle
                    return .disarmed
                }
                return nil
            }
            v += aUp * dt
            motionTime += dt
            if v >= config.startVelocity {
                state = .lifting
                h = 0.0
                h += v * dt
                maxH = max(0.0, h)
                hadAnchor = false
                anchorTime = homingTime
                anchorH = 0.0
                liftStart = homingTime
                hangSign = homingHangSign
                armsUp = false
                return .liftStarted(homingTime: homingTime)
            } else if motionTime > config.startWindow {
                state = .idle
                return .disarmed
            }
            return nil

        case .lifting:
            v += aUp * dt
            h += v * dt
            maxH = max(maxH, h)
            if stillDur >= config.anchorStill {
                v = 0.0
                hadAnchor = true
                anchorTime = t
                anchorH = h
            }
            // Forearm orientation: hang ≈ +1 with the arm hanging (as at homing), ≈ -1 overhead.
            let hang = hangSign * ghat.x
            if hang < config.armsUpMax {
                armsUp = true
            }
            // End checks, in order.
            var endTime: Double? = nil
            var reason: EndReason = .timeout
            if armsUp && hang > config.armsDownMin {
                // Arms back down after the turnover: the bar was dropped or lowered.
                endTime = t
                reason = .drop
            } else if hadAnchor && anchorH - h > config.dropDistance {
                endTime = anchorTime
                reason = .drop
            } else if hadAnchor && stillDur >= config.returnStill && abs(h) < config.returnHeight
                        && t - liftStart > 1.0 {
                endTime = t
                reason = .returned
            } else if !hadAnchor && t - liftStart > config.noAnchorTimeout {
                endTime = t
                reason = .timeout
            } else if t - liftStart > config.maxLiftDuration {
                endTime = hadAnchor ? anchorTime : t
                reason = .timeout
            }
            if let end = endTime {
                state = .cooldown
                cooldownUntil = t + config.cooldown
                return .liftEnded(homingTime: homingTime, endTime: end, reason: reason)
            }
            return nil

        case .cooldown:
            if t >= cooldownUntil {
                state = .idle
                stillDur = 0.0
                v = 0.0
            }
            return nil
        }
    }
}
