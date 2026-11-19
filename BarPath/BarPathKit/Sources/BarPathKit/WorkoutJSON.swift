import Foundation
import CryptoKit

/// A JSON value that keeps everything it was given, so a v2 workout definition passes through
/// every hop unchanged, unknown keys included (docs/WORKOUT_MODEL_RFC.md §14.3 A5).
/// Python reference: tools/barpath/workout_engine.py (`canonical_json`).
public enum JSONValue: Equatable {
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

    /// Python's `int(x)` of a number: truncates toward zero.
    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return d.isFinite ? Int(d) : nil
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
        if d.isFinite && d == d.rounded() && abs(d) < 9.0e15 {
            return .int(Int(d))
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
        let digest = SHA256.hash(data: Data(canonicalJSON.utf8))
        var hex: String = ""
        for byte in digest {
            hex += String(format: "%02x", byte)
        }
        return hex
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
            if d.isFinite && d == d.rounded() && abs(d) < 9.0e15 {
                out += String(Int(d))
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
