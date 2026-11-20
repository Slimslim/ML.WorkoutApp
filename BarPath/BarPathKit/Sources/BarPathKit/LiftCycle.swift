import Foundation

/// Lifting block cycle on the watch (#148, stories L7–L9): armed → in set → resting →
/// (Crown turn) → armed. Mirrors tools/barpath/lift_cycle.py (parity fixture
/// `lift_cycle_cases.json`). Times are on the motion clock (s).
///
/// Detection listens only while armed or in a set. While resting nothing the athlete does can
/// start a set; when the Crown arms the next set only motion from that moment counts
/// (`listeningFrom`, fed to `SetTracker.armedFrom`; the lift detector is reset).
///
/// Armed time-out (owner, 20 Nov): armed with no set for `armedTimeout` s goes back to resting,
/// unless a rep / lift is under way; the rest keeps counting from where it started.
/// Forgotten-Crown reminder (owner, 20 Nov): `remindAtRest()` is true at most once per rest; the
/// caller buzzes and shows "Turn the Crown?". It never counts or records anything.
public struct LiftCycle: Equatable, Sendable {
    /// Armed with no set for this long (s) goes back to Rest.
    public static let armedTimeout: Double = 180.0

    public enum State: String, Equatable, Sendable {
        case armed
        case inSet
        case resting
    }

    public private(set) var state: State
    /// Armed / in set: the arm time. Resting: the rest start (last rep's top or the lift's end).
    public private(set) var since: Double
    public private(set) var armedAt: Double
    /// The rest before the current set (rest start → Crown turn), nil before the first rest.
    public private(set) var lastRest: Double?
    /// The "Turn the Crown?" reminder already fired in this rest.
    public private(set) var reminded: Bool = false
    /// Where the rest started before the last Crown turn (an armed time-out resumes it).
    private var restStartBeforeArm: Double?

    /// The block starts armed: the athlete starts the watch at the bar.
    public init(startAt t: Double) {
        state = .armed
        since = t
        armedAt = t
        lastRest = nil
    }

    public var isListening: Bool { return state != .resting }

    /// Reps / lifts that start before this are not counted (+∞ while resting).
    public var listeningFrom: Double {
        return isListening ? armedAt : Double.greatestFiniteMagnitude
    }

    /// The End page (swipe left) is offered except in a set.
    public var canShowEndPage: Bool { return state != .inSet }

    /// A Crown turn: arms the next set, only while resting. True if it did.
    @discardableResult
    public mutating func arm(at t: Double) -> Bool {
        guard state == .resting else { return false }
        lastRest = max(0.0, t - since)
        restStartBeforeArm = since
        state = .armed
        since = t
        armedAt = t
        return true
    }

    /// First rep counted / lift started: armed → in set. Ignored otherwise.
    @discardableResult
    public mutating func setStarted(at t: Double) -> Bool {
        guard state == .armed else { return false }
        state = .inSet
        return true
    }

    /// Set saved / lift ended at `t` (the last rep's top or the lift's end): → resting since `t`.
    @discardableResult
    public mutating func setEnded(at t: Double) -> Bool {
        guard state != .resting else { return false }
        state = .resting
        since = t
        restStartBeforeArm = nil
        reminded = false
        return true
    }

    /// Armed for `armedTimeout` with no set (and nothing under way, `busy`): back to resting,
    /// the rest counting from where it started. True if it did.
    @discardableResult
    public mutating func expireArmed(at t: Double, busy: Bool) -> Bool {
        guard state == .armed, !busy, t - armedAt >= LiftCycle.armedTimeout else { return false }
        state = .resting
        since = restStartBeforeArm ?? armedAt
        restStartBeforeArm = nil
        reminded = false
        return true
    }

    /// Set-like motion while resting: true the first time in this rest (buzz and show
    /// "Turn the Crown?"), false otherwise.
    public mutating func remindAtRest() -> Bool {
        guard state == .resting, !reminded else { return false }
        reminded = true
        return true
    }
}
