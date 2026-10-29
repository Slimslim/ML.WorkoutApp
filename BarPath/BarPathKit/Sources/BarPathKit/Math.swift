import Foundation

/// Standard gravity in m/s² (CoreMotion acceleration values are in units of g).
public let standardGravity: Double = 9.80665

// MARK: - Vec3

public struct Vec3: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero: Vec3 = Vec3(0.0, 0.0, 0.0)

    public static func + (a: Vec3, b: Vec3) -> Vec3 {
        return Vec3(a.x + b.x, a.y + b.y, a.z + b.z)
    }

    public static func - (a: Vec3, b: Vec3) -> Vec3 {
        return Vec3(a.x - b.x, a.y - b.y, a.z - b.z)
    }

    public static prefix func - (a: Vec3) -> Vec3 {
        return Vec3(-a.x, -a.y, -a.z)
    }

    public static func * (a: Vec3, s: Double) -> Vec3 {
        return Vec3(a.x * s, a.y * s, a.z * s)
    }

    public static func * (s: Double, a: Vec3) -> Vec3 {
        return Vec3(a.x * s, a.y * s, a.z * s)
    }

    public static func / (a: Vec3, s: Double) -> Vec3 {
        return Vec3(a.x / s, a.y / s, a.z / s)
    }

    public func dot(_ o: Vec3) -> Double {
        return x * o.x + y * o.y + z * o.z
    }

    public func cross(_ o: Vec3) -> Vec3 {
        return Vec3(y * o.z - z * o.y,
                    z * o.x - x * o.z,
                    x * o.y - y * o.x)
    }

    public var norm: Double {
        return (x * x + y * y + z * z).squareRoot()
    }

    /// Unit vector in the same direction; `.zero` if the norm is below 1e-12.
    public var normalized: Vec3 {
        let n = norm
        if n < 1e-12 { return Vec3.zero }
        return Vec3(x / n, y / n, z / n)
    }
}

// MARK: - Quat

/// Unit quaternion (w, x, y, z).
public struct Quat: Codable, Equatable, Sendable {
    public var w: Double
    public var x: Double
    public var y: Double
    public var z: Double

    public init(w: Double, x: Double, y: Double, z: Double) {
        self.w = w
        self.x = x
        self.y = y
        self.z = z
    }

    public static let identity: Quat = Quat(w: 1.0, x: 0.0, y: 0.0, z: 0.0)

    public var conjugate: Quat {
        return Quat(w: w, x: -x, y: -y, z: -z)
    }

    /// Rotates `v` by this (unit) quaternion: v' = q * v * q^-1.
    public func rotate(_ v: Vec3) -> Vec3 {
        // t = 2 * (q.xyz × v);  v' = v + w * t + q.xyz × t
        let u = Vec3(x, y, z)
        let t = u.cross(v) * 2.0
        return v + t * w + u.cross(t)
    }
}

// MARK: - Internal helpers

@inline(__always)
func clampValue(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
    if v < lo { return lo }
    if v > hi { return hi }
    return v
}

/// Median like numpy.median (mean of the two middle values for even counts). 0 for empty input.
func medianOf(_ values: [Double]) -> Double {
    if values.isEmpty { return 0.0 }
    let sorted = values.sorted()
    let n = sorted.count
    if n % 2 == 1 {
        return sorted[n / 2]
    }
    return 0.5 * (sorted[n / 2 - 1] + sorted[n / 2])
}
