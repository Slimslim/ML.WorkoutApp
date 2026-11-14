import Foundation
import CoreLocation

/// GPS for workouts whose plan contains a run (docs/RECORDING_PLAN.md, build 15). Self-contained:
/// owns a `CLLocationManager`, filters fixes, and hands them on as
/// - `onFix`: one plain `Fix` per accepted location (distance since the start, speed, accuracy,
///   relative altitude: no coordinates), for the session CSV;
/// - `onRoute`: the accepted `CLLocation`s in small batches, for the Health route builder.
///
/// Privacy: coordinates leave this class only through `onRoute` (Apple Health). Nothing here
/// writes a file.
///
/// Never blocks and never raises an error on screen: without authorization, or when location is
/// unavailable, `start` logs once and returns false, and the workout runs exactly as before.
/// Location permission is asked in the practice workout, not here.
///
/// Main actor only. The manager is created on the main thread, so Core Location delivers its
/// callbacks there.
@MainActor
final class WorkoutLocationRecorder: NSObject, CLLocationManagerDelegate {
    /// One accepted fix, without coordinates.
    struct Fix {
        /// Epoch seconds of the fix.
        let t: Double
        /// Cumulative meters since the first accepted fix (sum between consecutive accepted fixes).
        let distance: Double
        /// m/s, nil when Core Location reports a negative (unknown) speed.
        let speed: Double?
        /// Horizontal accuracy in m.
        let accuracy: Double
        /// Altitude change since the first fix in m (relative; 0 until an altitude is valid).
        let altitudeDelta: Double
    }

    /// A fix with a worse horizontal accuracy than this (m) is dropped.
    static let maxAccuracy: Double = 30.0
    /// Locations per route batch, or this many seconds, whichever comes first.
    static let routeBatchCount: Int = 10
    static let routeBatchSeconds: Double = 10.0

    var onFix: ((Fix) -> Void)?
    var onRoute: (([CLLocation]) -> Void)?

    private(set) var isRunning = false
    private(set) var acceptedCount = 0

    private var manager: CLLocationManager?
    private var startEpoch: Double = 0
    private var lastLocation: CLLocation?
    private var cumulativeDistance: Double = 0
    private var altitudeBase: Double?
    private var lastAltitudeDelta: Double = 0
    private var pending: [CLLocation] = []
    private var lastFlushEpoch: Double = 0
    private var loggedFailure = false

    // MARK: - Start / stop

    /// Starts location updates. Fixes with a timestamp before `date` are dropped (cached fixes).
    /// Returns false (after one log line) when location is not authorized or not available.
    @discardableResult
    func start(from date: Date) -> Bool {
        guard !isRunning else { return true }
        let m = CLLocationManager()
        let status: CLAuthorizationStatus = m.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            Log.workout.error("Location not used: authorization status \(status.rawValue)")
            return false
        }
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyBest
        m.activityType = .fitness
        // Apple: apps that receive location updates in the background must declare the
        // `location` value under UIBackgroundModes in Info.plist; setting this property without it
        // is a fatal error. So it is set only when that is declared, and (we are authorized, see
        // the guard above) before `startUpdatingLocation`.
        if WorkoutLocationRecorder.declaresLocationBackgroundMode() {
            m.allowsBackgroundLocationUpdates = true
        }
        manager = m
        isRunning = true
        startEpoch = date.timeIntervalSince1970
        lastLocation = nil
        cumulativeDistance = 0
        altitudeBase = nil
        lastAltitudeDelta = 0
        pending = []
        acceptedCount = 0
        loggedFailure = false
        lastFlushEpoch = Date().timeIntervalSince1970
        m.startUpdatingLocation()
        Log.workout.info("Location updates started")
        return true
    }

    /// Stops updates and hands the last route batch on. Safe to call any number of times.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        manager?.stopUpdatingLocation()
        manager?.delegate = nil
        manager = nil
        flushRoute()
        Log.workout.info("Location updates stopped, \(self.acceptedCount) fixes accepted")
    }

    private static func declaresLocationBackgroundMode() -> Bool {
        for key in ["UIBackgroundModes", "WKBackgroundModes"] {
            if let modes = Bundle.main.object(forInfoDictionaryKey: key) as? [String], modes.contains("location") {
                return true
            }
        }
        return false
    }

    // MARK: - Fixes

    private func received(_ locations: [CLLocation]) {
        guard isRunning else { return }
        for loc in locations {
            accept(loc)
        }
        let now: Double = Date().timeIntervalSince1970
        if pending.count >= WorkoutLocationRecorder.routeBatchCount
            || (!pending.isEmpty && now - lastFlushEpoch >= WorkoutLocationRecorder.routeBatchSeconds) {
            flushRoute()
        }
    }

    private func accept(_ loc: CLLocation) {
        let accuracy: Double = loc.horizontalAccuracy
        guard accuracy >= 0, accuracy <= WorkoutLocationRecorder.maxAccuracy else { return }
        let t: Double = loc.timestamp.timeIntervalSince1970
        guard t > startEpoch else { return }
        if let last = lastLocation {
            guard loc.timestamp > last.timestamp else { return }
            cumulativeDistance += loc.distance(from: last)
        }
        lastLocation = loc
        if loc.verticalAccuracy >= 0 {
            if let base = altitudeBase {
                lastAltitudeDelta = loc.altitude - base
            } else {
                altitudeBase = loc.altitude
                lastAltitudeDelta = 0
            }
        }
        acceptedCount += 1
        pending.append(loc)
        let speed: Double? = loc.speed >= 0 ? loc.speed : nil
        onFix?(Fix(t: t, distance: cumulativeDistance, speed: speed, accuracy: accuracy,
                   altitudeDelta: lastAltitudeDelta))
    }

    private func flushRoute() {
        lastFlushEpoch = Date().timeIntervalSince1970
        guard !pending.isEmpty else { return }
        let batch: [CLLocation] = pending
        pending = []
        onRoute?(batch)
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.received(locations)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message: String = error.localizedDescription
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // No fix indoors is normal (kCLErrorLocationUnknown); log once, keep waiting.
                if !self.loggedFailure {
                    self.loggedFailure = true
                    Log.workout.error("Location error: \(message, privacy: .public)")
                }
            }
        }
    }
}

/// Asks for when-in-use location access once (the practice workout does it, after Health and
/// Motion), so the prompt never appears in the middle of a real workout. `completion` runs on
/// the main actor exactly once: at once when the question was answered before (or location is
/// restricted), after the answer, or after `timeoutSeconds` if nothing came back. It does not say
/// whether access was granted.
@MainActor
final class LocationPermissionRequest: NSObject, CLLocationManagerDelegate {
    static let timeoutSeconds: Double = 10.0

    private var manager: CLLocationManager?
    private var completion: (@MainActor () -> Void)?
    private var timeoutTask: Task<Void, Never>?

    func start(completion: @escaping @MainActor () -> Void) {
        self.completion = completion
        let m = CLLocationManager()
        if m.authorizationStatus != .notDetermined {
            Log.workout.info("Location permission already answered: \(m.authorizationStatus.rawValue)")
            finish()
            return
        }
        manager = m
        m.delegate = self
        m.requestWhenInUseAuthorization()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(LocationPermissionRequest.timeoutSeconds * 1_000_000_000))
            if Task.isCancelled { return }
            self?.finish()
        }
    }

    private func answered() {
        guard let m = manager, m.authorizationStatus != .notDetermined else { return }
        if m.authorizationStatus == .denied || m.authorizationStatus == .restricted {
            Log.workout.error("Location permission refused; runs will have no GPS")
        }
        finish()
    }

    private func finish() {
        timeoutTask?.cancel()
        timeoutTask = nil
        manager?.delegate = nil
        manager = nil
        let done = completion
        completion = nil
        done?()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.answered()
            }
        }
    }
}
