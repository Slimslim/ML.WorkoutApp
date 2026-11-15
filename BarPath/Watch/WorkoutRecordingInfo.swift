import Foundation
import WatchKit
import WatchConnectivity

/// W29: every workout recording says how it was made (battery, power, settings, phone).
///
/// Header keys (additive to format v1, after the existing device keys):
///   `batteryStart=<0-100>`, `charging=yes|no`, `lowPower=on|off`,
///   `thermal=nominal|fair|serious|critical`, `units=kg|lb`, `hrZoneSource=custom|age|none`,
///   `phoneModel=`, `phoneOS=`, `phoneBuild=` (as the phone last sent them in the application
///   context key `phoneDevice`; "unknown" when it never did).
/// Event lines (`# event t=<s> ...`):
///   `name=battery level=<0-100> charging=yes|no`        once a minute
///   `name=thermal state=<state>`                        when the thermal state changes
///   `name=lowPower state=on|off`                        when Low Power Mode changes
///   `name=end reason=<r> batteryEnd=<0-100> duration=<s>[ backgroundRecovery=yes]`  last line
/// A value that cannot be read is written as `unknown`.
///
/// Cheap by design: no timer and no sensor of its own. `tick(now:)` is called from the session's
/// existing clock; it reads three properties and writes one line a minute. Battery monitoring is
/// on only between `begin()` and `finish()`.
///
/// Main actor only (called from `WorkoutSessionModel`).
@MainActor
final class WorkoutRecordingInfo {
    /// Seconds between battery lines.
    static let batteryInterval: Double = 60.0
    /// Application context key the phone puts its model / iOS / build under (W29).
    static let phoneDeviceContextKey = "phoneDevice"

    private(set) var isActive = false
    private var lastBatteryUptime: Double = 0
    private var lastThermal: String = ""
    private var lastLowPower: String = ""
    private var startUptime: Double = 0

    /// Turns battery monitoring on and returns the header pairs (", batteryStart=83, ...").
    func begin() -> String {
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        isActive = true
        startUptime = ProcessInfo.processInfo.systemUptime
        lastBatteryUptime = startUptime
        lastThermal = WorkoutRecordingInfo.thermalText(ProcessInfo.processInfo.thermalState)
        lastLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off"

        var pairs = ", batteryStart=" + WorkoutRecordingInfo.batteryText(device.batteryLevel)
        pairs += ", charging=" + WorkoutRecordingInfo.chargingText(device.batteryState)
        pairs += ", lowPower=" + lastLowPower
        pairs += ", thermal=" + lastThermal
        pairs += ", units=" + PhoneLink.storedWeightUnit().rawValue
        let phone: [String: String] = WorkoutRecordingInfo.phoneDevice()
        pairs += ", hrZoneSource=" + DebugCSVWriter.headerValue(phone["hrZoneSource"] ?? "unknown")
        pairs += ", phoneModel=" + DebugCSVWriter.headerValue(phone["model"] ?? "unknown")
        pairs += ", phoneOS=" + DebugCSVWriter.headerValue(phone["os"] ?? "unknown")
        pairs += ", phoneBuild=" + DebugCSVWriter.headerValue(phone["build"] ?? "unknown")
        return pairs
    }

    /// Called from the session clock (several times a second). Returns the event lines due now
    /// (without the `# event t=` prefix), usually none.
    func tick(uptime: Double) -> [String] {
        guard isActive else { return [] }
        var lines: [String] = []
        let thermal = WorkoutRecordingInfo.thermalText(ProcessInfo.processInfo.thermalState)
        if thermal != lastThermal {
            lastThermal = thermal
            lines.append("name=thermal state=" + thermal)
        }
        let lowPower: String = ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off"
        if lowPower != lastLowPower {
            lastLowPower = lowPower
            lines.append("name=lowPower state=" + lowPower)
        }
        if uptime - lastBatteryUptime >= WorkoutRecordingInfo.batteryInterval {
            lastBatteryUptime = uptime
            let device = WKInterfaceDevice.current()
            lines.append("name=battery level=" + WorkoutRecordingInfo.batteryText(device.batteryLevel)
                         + " charging=" + WorkoutRecordingInfo.chargingText(device.batteryState))
        }
        return lines
    }

    /// The end line (without the `# event t=` prefix). Does not turn monitoring off (`stop()`).
    func endLine(reason: String, duration: Double, backgroundRecovery: Bool) -> String {
        let level = WKInterfaceDevice.current().batteryLevel
        var line = "name=end reason=" + reason + " batteryEnd=" + WorkoutRecordingInfo.batteryText(level)
        line += String(format: " duration=%.1f", max(0, duration))
        if backgroundRecovery {
            line += " backgroundRecovery=yes"
        }
        return line
    }

    /// Battery monitoring off. Safe to call more than once.
    func stop() {
        guard isActive else { return }
        isActive = false
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = false
    }

    // MARK: - Values

    /// 0...1 → "83"; negative (monitoring off or unknown) → "unknown".
    static func batteryText(_ level: Float) -> String {
        guard level >= 0 else { return "unknown" }
        let pct = Int((Double(level) * 100.0).rounded())
        return String(min(100, max(0, pct)))
    }

    static func chargingText(_ state: WKInterfaceDeviceBatteryState) -> String {
        switch state {
        case .charging, .full:
            return "yes"
        case .unplugged:
            return "no"
        case .unknown:
            return "unknown"
        @unknown default:
            return "unknown"
        }
    }

    static func thermalText(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }

    /// What the phone last put under `phoneDevice` in the application context (model, os, build,
    /// hrZoneSource), empty when nothing was received yet.
    static func phoneDevice() -> [String: String] {
        guard WCSession.isSupported() else { return [:] }
        let context: [String: Any] = WCSession.default.receivedApplicationContext
        guard let raw = context[WorkoutRecordingInfo.phoneDeviceContextKey] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in raw {
            if let text = value as? String {
                out[key] = text
            }
        }
        return out
    }
}
