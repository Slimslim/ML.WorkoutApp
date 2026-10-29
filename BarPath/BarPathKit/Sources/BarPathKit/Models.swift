import Foundation

// MARK: - Enums

public enum LiftType: String, Codable, CaseIterable, Identifiable, Sendable {
    case snatch, cleanAndJerk, powerSnatch, hangSnatch, powerClean, hangClean, clean, jerk, deadlift, other

    public var id: String { return rawValue }

    public var displayName: String {
        switch self {
        case .snatch: return "Snatch"
        case .cleanAndJerk: return "Clean & Jerk"
        case .powerSnatch: return "Power Snatch"
        case .hangSnatch: return "Hang Snatch"
        case .powerClean: return "Power Clean"
        case .hangClean: return "Hang Clean"
        case .clean: return "Clean"
        case .jerk: return "Jerk"
        case .deadlift: return "Deadlift"
        case .other: return "Other"
        }
    }

    /// Strength mode: the watch counts reps and sends one recording per set (RepCounter)
    /// instead of one bar-path snippet per lift.
    public var countsReps: Bool {
        return self == .deadlift
    }
}

public enum EndReason: String, Codable, Sendable {
    case drop, returned, timeout, manual, sessionEnd
}

// MARK: - Samples

public struct MotionSample: Equatable, Sendable {
    public var t: Double
    public var attitude: Quat
    public var userAccel: Vec3      // g
    public var gravity: Vec3        // g
    public var rotationRate: Vec3   // rad/s

    public init(t: Double, attitude: Quat, userAccel: Vec3, gravity: Vec3, rotationRate: Vec3) {
        self.t = t
        self.attitude = attitude
        self.userAccel = userAccel
        self.gravity = gravity
        self.rotationRate = rotationRate
    }
}

public struct AccelSample: Equatable, Sendable {
    public var t: Double
    public var accel: Vec3          // g

    public init(t: Double, accel: Vec3) {
        self.t = t
        self.accel = accel
    }
}

// MARK: - MotionSeries (columnar)

public struct MotionSeries: Codable, Equatable, Sendable {
    public var t: [Double] = []
    public var qw: [Double] = []
    public var qx: [Double] = []
    public var qy: [Double] = []
    public var qz: [Double] = []
    public var ax: [Double] = []
    public var ay: [Double] = []
    public var az: [Double] = []
    public var gx: [Double] = []
    public var gy: [Double] = []
    public var gz: [Double] = []
    public var rx: [Double] = []
    public var ry: [Double] = []
    public var rz: [Double] = []

    public init() {}

    public init(_ samples: [MotionSample]) {
        reserve(samples.count)
        for s in samples {
            append(s)
        }
    }

    public var count: Int { return t.count }

    public mutating func append(_ s: MotionSample) {
        t.append(s.t)
        qw.append(s.attitude.w)
        qx.append(s.attitude.x)
        qy.append(s.attitude.y)
        qz.append(s.attitude.z)
        ax.append(s.userAccel.x)
        ay.append(s.userAccel.y)
        az.append(s.userAccel.z)
        gx.append(s.gravity.x)
        gy.append(s.gravity.y)
        gz.append(s.gravity.z)
        rx.append(s.rotationRate.x)
        ry.append(s.rotationRate.y)
        rz.append(s.rotationRate.z)
    }

    public subscript(i: Int) -> MotionSample {
        return MotionSample(t: t[i],
                            attitude: Quat(w: qw[i], x: qx[i], y: qy[i], z: qz[i]),
                            userAccel: Vec3(ax[i], ay[i], az[i]),
                            gravity: Vec3(gx[i], gy[i], gz[i]),
                            rotationRate: Vec3(rx[i], ry[i], rz[i]))
    }

    public var samples: [MotionSample] {
        var out: [MotionSample] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            out.append(self[i])
        }
        return out
    }

    private mutating func reserve(_ n: Int) {
        t.reserveCapacity(n)
        qw.reserveCapacity(n); qx.reserveCapacity(n); qy.reserveCapacity(n); qz.reserveCapacity(n)
        ax.reserveCapacity(n); ay.reserveCapacity(n); az.reserveCapacity(n)
        gx.reserveCapacity(n); gy.reserveCapacity(n); gz.reserveCapacity(n)
        rx.reserveCapacity(n); ry.reserveCapacity(n); rz.reserveCapacity(n)
    }

    // MARK: Codable (keys exactly as §2; all columns must have equal length)

    private enum CodingKeys: String, CodingKey {
        case t, qw, qx, qy, qz, ax, ay, az, gx, gy, gz, rx, ry, rz
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode([Double].self, forKey: .t)
        qw = try c.decode([Double].self, forKey: .qw)
        qx = try c.decode([Double].self, forKey: .qx)
        qy = try c.decode([Double].self, forKey: .qy)
        qz = try c.decode([Double].self, forKey: .qz)
        ax = try c.decode([Double].self, forKey: .ax)
        ay = try c.decode([Double].self, forKey: .ay)
        az = try c.decode([Double].self, forKey: .az)
        gx = try c.decode([Double].self, forKey: .gx)
        gy = try c.decode([Double].self, forKey: .gy)
        gz = try c.decode([Double].self, forKey: .gz)
        rx = try c.decode([Double].self, forKey: .rx)
        ry = try c.decode([Double].self, forKey: .ry)
        rz = try c.decode([Double].self, forKey: .rz)
        let n = t.count
        let columns: [[Double]] = [qw, qx, qy, qz, ax, ay, az, gx, gy, gz, rx, ry, rz]
        for col in columns where col.count != n {
            throw DecodingError.dataCorruptedError(forKey: CodingKeys.t, in: c,
                                                   debugDescription: "motion columns have unequal lengths")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(t, forKey: .t)
        try c.encode(qw, forKey: .qw)
        try c.encode(qx, forKey: .qx)
        try c.encode(qy, forKey: .qy)
        try c.encode(qz, forKey: .qz)
        try c.encode(ax, forKey: .ax)
        try c.encode(ay, forKey: .ay)
        try c.encode(az, forKey: .az)
        try c.encode(gx, forKey: .gx)
        try c.encode(gy, forKey: .gy)
        try c.encode(gz, forKey: .gz)
        try c.encode(rx, forKey: .rx)
        try c.encode(ry, forKey: .ry)
        try c.encode(rz, forKey: .rz)
    }
}

// MARK: - AccelSeries (columnar)

public struct AccelSeries: Codable, Equatable, Sendable {
    public var t: [Double] = []
    public var x: [Double] = []
    public var y: [Double] = []
    public var z: [Double] = []

    public init() {}

    public init(_ samples: [AccelSample]) {
        t.reserveCapacity(samples.count)
        x.reserveCapacity(samples.count)
        y.reserveCapacity(samples.count)
        z.reserveCapacity(samples.count)
        for s in samples {
            append(s)
        }
    }

    public var count: Int { return t.count }

    public mutating func append(_ s: AccelSample) {
        t.append(s.t)
        x.append(s.accel.x)
        y.append(s.accel.y)
        z.append(s.accel.z)
    }

    public subscript(i: Int) -> AccelSample {
        return AccelSample(t: t[i], accel: Vec3(x[i], y[i], z[i]))
    }

    public var samples: [AccelSample] {
        var out: [AccelSample] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            out.append(self[i])
        }
        return out
    }

    private enum CodingKeys: String, CodingKey {
        case t, x, y, z
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decodeIfPresent([Double].self, forKey: .t) ?? []
        x = try c.decodeIfPresent([Double].self, forKey: .x) ?? []
        y = try c.decodeIfPresent([Double].self, forKey: .y) ?? []
        z = try c.decodeIfPresent([Double].self, forKey: .z) ?? []
        if x.count != t.count || y.count != t.count || z.count != t.count {
            throw DecodingError.dataCorruptedError(forKey: CodingKeys.t, in: c,
                                                   debugDescription: "accel columns have unequal lengths")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(t, forKey: .t)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(z, forKey: .z)
    }
}

// MARK: - Phone → watch lift selection

/// Next lift chosen on the phone's Lifts tab. Travels as a plain dictionary under
/// `contextKey` in the WatchConnectivity application context / a message.
public struct LiftSelection: Equatable, Sendable {
    public static let contextKey = "liftSelection"

    public var liftType: LiftType
    public var loadLb: Double?      // nil = don't log load
    public var sentAt: Double       // seconds since 1970; the watch applies each one once

    public init(liftType: LiftType, loadLb: Double?, sentAt: Double) {
        self.liftType = liftType
        self.loadLb = loadLb
        self.sentAt = sentAt
    }

    public var dictionary: [String: Any] {
        var d: [String: Any] = ["liftType": liftType.rawValue, "sentAt": sentAt]
        if let lb = loadLb {
            d["loadLb"] = lb
        }
        return d
    }

    public init?(dictionary d: [String: Any]) {
        guard let raw = d["liftType"] as? String, let type = LiftType(rawValue: raw) else { return nil }
        liftType = type
        loadLb = (d["loadLb"] as? NSNumber)?.doubleValue
        sentAt = (d["sentAt"] as? NSNumber)?.doubleValue ?? 0
    }

    public var summary: String {
        guard let lb = loadLb else { return liftType.displayName }
        return liftType.displayName + String(format: " · %.0f lb", lb)
    }
}
