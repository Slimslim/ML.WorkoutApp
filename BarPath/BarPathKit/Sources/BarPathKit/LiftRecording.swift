import Foundation

/// One lift snippet (spec §2). JSON coding uses exactly the §2 keys, columnar motion/accel
/// objects, and ISO8601 dates (encoded with fractional seconds; decoded with or without).
public struct LiftRecording: Codable, Identifiable, Equatable, Sendable {
    public var version: Int                  // 1
    public var id: UUID
    public var sessionId: UUID
    public var index: Int                    // 1-based lift number within the session
    public var kind: String                  // "lift"
    public var liftType: LiftType
    public var loadKg: Double?
    public var startDate: Date               // wall clock of motion.t == 0
    public var homingTime: Double?
    public var endTime: Double?
    public var endReason: EndReason?
    public var motion: MotionSeries
    public var accel: AccelSeries

    public init(id: UUID = UUID(), sessionId: UUID, index: Int, liftType: LiftType, loadKg: Double? = nil,
                startDate: Date, homingTime: Double?, endTime: Double?, endReason: EndReason?,
                motion: MotionSeries, accel: AccelSeries) {
        self.version = 1
        self.id = id
        self.sessionId = sessionId
        self.index = index
        self.kind = "lift"
        self.liftType = liftType
        self.loadKg = loadKg
        self.startDate = startDate
        self.homingTime = homingTime
        self.endTime = endTime
        self.endReason = endReason
        self.motion = motion
        self.accel = accel
    }

    /// JSON, ISO8601 dates.
    public func encoded() throws -> Data {
        return try BarPathJSON.makeEncoder().encode(self)
    }

    public static func decode(from data: Data) throws -> LiftRecording {
        return try BarPathJSON.makeDecoder().decode(LiftRecording.self, from: data)
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case version, id, sessionId, index, kind, liftType, loadKg, startDate
        case homingTime, endTime, endReason, motion, accel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        sessionId = try c.decode(UUID.self, forKey: .sessionId)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "lift"
        let liftRaw: String = try c.decodeIfPresent(String.self, forKey: .liftType) ?? LiftType.other.rawValue
        liftType = LiftType(rawValue: liftRaw) ?? .other
        loadKg = try c.decodeIfPresent(Double.self, forKey: .loadKg)
        startDate = try c.decode(Date.self, forKey: .startDate)
        homingTime = try c.decodeIfPresent(Double.self, forKey: .homingTime)
        endTime = try c.decodeIfPresent(Double.self, forKey: .endTime)
        if let reasonRaw = try c.decodeIfPresent(String.self, forKey: .endReason) {
            endReason = EndReason(rawValue: reasonRaw)
        } else {
            endReason = nil
        }
        motion = try c.decode(MotionSeries.self, forKey: .motion)
        accel = try c.decodeIfPresent(AccelSeries.self, forKey: .accel) ?? AccelSeries()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(id, forKey: .id)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(index, forKey: .index)
        try c.encode(kind, forKey: .kind)
        try c.encode(liftType.rawValue, forKey: .liftType)
        if let v = loadKg { try c.encode(v, forKey: .loadKg) } else { try c.encodeNil(forKey: .loadKg) }
        try c.encode(startDate, forKey: .startDate)
        if let v = homingTime { try c.encode(v, forKey: .homingTime) } else { try c.encodeNil(forKey: .homingTime) }
        if let v = endTime { try c.encode(v, forKey: .endTime) } else { try c.encodeNil(forKey: .endTime) }
        if let v = endReason { try c.encode(v.rawValue, forKey: .endReason) } else { try c.encodeNil(forKey: .endReason) }
        try c.encode(motion, forKey: .motion)
        try c.encode(accel, forKey: .accel)
    }
}

/// Shared JSON / ISO8601 helpers (used for LiftRecording files and the debug CSV header).
public enum BarPathJSON {
    /// ISO8601 with fractional seconds, UTC, e.g. "2026-10-25T18:03:11.250Z".
    public static func formatDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Parses ISO8601 with or without fractional seconds.
    public static func parseDate(_ string: String) -> Date? {
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom({ (date: Date, enc: Encoder) throws -> Void in
            var c = enc.singleValueContainer()
            try c.encode(BarPathJSON.formatDate(date))
        })
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom({ (dec: Decoder) throws -> Date in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            if let d = BarPathJSON.parseDate(s) { return d }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid ISO8601 date: \(s)")
        })
        return decoder
    }
}
