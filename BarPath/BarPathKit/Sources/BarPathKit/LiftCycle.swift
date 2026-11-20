import Foundation

/// Lifting block cycle on the watch (#148, stories L7–L9): armed → in set → resting →
/// (Crown turn) → armed. Mirrors tools/barpath/lift_cycle.py (parity fixture
/// `lift_cycle_cases.json`). Times are on the motion clock (s).
///
/// Detection listens only while armed or in a set. While resting nothing the athlete does can
/// start a set; when the Crown arms the next set only motion from that moment counts
/// (`listeningFrom`, fed to `SetTracker.armedFrom`; the lift detector is reset).
public struct LiftCycle: Equatable, Sendable {
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
        return true
    }
}
