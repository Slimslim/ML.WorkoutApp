import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// A JSON value that keeps everything it was given, so a v2 workout definition passes through
/// every hop unchanged, unknown keys included (docs/WORKOUT_MODEL_RFC.md §14.3 A5).
/// Python reference: tools/barpath/workout_engine.py (`canonical_json`).
///
/// Canonical JSON is byte-for-byte Python's for every value a workout holds. Known limits outside
/// that domain: an integer beyond Int.max decodes as a Double (precision lost), and two object keys
/// that differ only in Unicode normalization (NFC vs NFD) collapse into one, since Swift compares
/// strings by canonical equivalence. Neither occurs in a definition the compiler writes.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
            return
        }
        if let b = try? c.decode(Bool.self) {
            self = .bool(b)
            return
        }
        if let i = try? c.decode(Int.self) {
            self = .int(i)
            return
        }
        if let d = try? c.decode(Double.self) {
            self = .double(d)
            return
        }
        if let s = try? c.decode(String.self) {
            self = .string(s)
            return
        }
        if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
            return
        }
        if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
            return
        }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

public extension JSONValue {
    static func parse(_ data: Data) throws -> JSONValue {
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self {
            return o[key]
        }
        return nil
    }

    var object: [String: JSONValue]? {
        if case .object(let o) = self {
            return o
        }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let a) = self {
            return a
        }
        return nil
    }

    var string: String? {
        if case .string(let s) = self {
            return s
        }
        return nil
    }

    var bool: Bool? {
        if case .bool(let b) = self {
            return b
        }
        return nil
    }

    /// A number as a Double (ints included); nil for anything else.
    var number: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    /// Python's `int(x)` of a number: truncates toward zero; nil when it doesn't fit an Int.
    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d):
            guard d.isFinite, abs(d) < 9.0e18 else { return nil }
            return Int(d)
        default: return nil
        }
    }

    var isNull: Bool {
        if case .null = self {
            return true
        }
        return false
    }

    var isNumber: Bool {
        return number != nil
    }

    /// Python truthiness (an empty string, list or object, 0 and null are false).
    var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    /// A number that is whole and fits an Int becomes `.int` (Python `_canon`: 40 never 40.0).
    static func numeric(_ d: Double) -> JSONValue {
        if let i = Int(exactly: d) {
            return .int(i)
        }
        return .double(d)
    }

    /// Sorted keys, no spaces, whole numbers as integers, non-ASCII kept: byte-for-byte what
    /// Python's `canonical_json` writes (RFC §14.3 E6).
    var canonicalJSON: String {
        var out: String = ""
        JSONValue.write(self, into: &out)
        return out
    }

    /// SHA-256 of the canonical JSON, lowercase hex (the plan hash shared with Python).
    var canonicalHash: String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(canonicalJSON.utf8))
        return WorkoutSHA256.hex(Array(digest))
        #else
        return WorkoutSHA256.hex(WorkoutSHA256.digest(Array(canonicalJSON.utf8)))
        #endif
    }

    private static func write(_ v: JSONValue, into out: inout String) {
        switch v {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .int(let i):
            out += String(i)
        case .double(let d):
            // Python `_canon`: any whole float is written as an integer.
            if let i = Int(exactly: d) {
                out += String(i)
            } else if d.isFinite && d == d.rounded() {
                out += String(format: "%.0f", d)
            } else {
                out += "\(d)"
            }
        case .string(let s):
            writeString(s, into: &out)
        case .array(let a):
            out += "["
            var first: Bool = true
            for x in a {
                if !first {
                    out += ","
                }
                first = false
                write(x, into: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            let keys: [String] = o.keys.sorted { (a: String, b: String) -> Bool in
                return a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
            }
            var first: Bool = true
            for k in keys {
                if !first {
                    out += ","
                }
                first = false
                writeString(k, into: &out)
                out += ":"
                if let x = o[k] {
                    write(x, into: &out)
                }
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}


/// SHA-256 in plain Swift (FIPS 180-4), for platforms without CryptoKit (the Linux CI job).
/// Apple platforms hash with CryptoKit; a test checks both agree.
enum WorkoutSHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        return (x >> n) | (x << (32 - n))
    }

    static func digest(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                           0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var m: [UInt8] = message
        let bitLength: UInt64 = UInt64(message.count) &* 8
        m.append(0x80)
        while m.count % 64 != 56 {
            m.append(0)
        }
        for i in (0..<8).reversed() {
            m.append(UInt8(truncatingIfNeeded: bitLength >> (UInt64(i) * 8)))
        }
        var w: [UInt32] = [UInt32](repeating: 0, count: 64)
        var chunk: Int = 0
        while chunk < m.count {
            for i in 0..<16 {
                let b: Int = chunk + 4 * i
                w[i] = (UInt32(m[b]) << 24) | (UInt32(m[b + 1]) << 16) | (UInt32(m[b + 2]) << 8) | UInt32(m[b + 3])
            }
            for i in 16..<64 {
                let s0: UInt32 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1: UInt32 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a: UInt32 = h[0]
            var b: UInt32 = h[1]
            var c: UInt32 = h[2]
            var d: UInt32 = h[3]
            var e: UInt32 = h[4]
            var f: UInt32 = h[5]
            var g: UInt32 = h[6]
            var hh: UInt32 = h[7]
            for i in 0..<64 {
                let bigS1: UInt32 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch: UInt32 = (e & f) ^ (~e & g)
                let t1: UInt32 = hh &+ bigS1 &+ ch &+ k[i] &+ w[i]
                let bigS0: UInt32 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj: UInt32 = (a & b) ^ (a & c) ^ (b & c)
                let t2: UInt32 = bigS0 &+ maj
                hh = g
                g = f
                f = e
                e = d &+ t1
                d = c
                c = b
                b = a
                a = t1 &+ t2
            }
            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ hh
            chunk += 64
        }
        var out: [UInt8] = []
        for x in h {
            out.append(UInt8(truncatingIfNeeded: x >> 24))
            out.append(UInt8(truncatingIfNeeded: x >> 16))
            out.append(UInt8(truncatingIfNeeded: x >> 8))
            out.append(UInt8(truncatingIfNeeded: x))
        }
        return out
    }

    static func hex(_ bytes: [UInt8]) -> String {
        let digits: [Character] = Array("0123456789abcdef")
        var s: String = ""
        for byte in bytes {
            s.append(digits[Int(byte >> 4)])
            s.append(digits[Int(byte & 0x0f)])
        }
        return s
    }
}
