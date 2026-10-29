import Foundation

/// Fixed-capacity ring buffer of device-motion samples (the watch's pre-roll).
/// When full, appending overwrites the oldest sample.
public struct MotionRingBuffer: Sendable {
    private var storage: [MotionSample]
    private var head: Int = 0          // index of the oldest element once full
    private var stored: Int = 0
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.storage = []
        self.storage.reserveCapacity(self.capacity)
    }

    public mutating func append(_ s: MotionSample) {
        if stored < capacity {
            storage.append(s)
            stored += 1
        } else {
            storage[head] = s
            head = (head + 1) % capacity
        }
    }

    public var count: Int { return stored }

    public var latestTime: Double? {
        if stored == 0 { return nil }
        if stored < capacity { return storage[stored - 1].t }
        let last = (head + capacity - 1) % capacity
        return storage[last].t
    }

    /// Samples with t0 <= t <= t1, in time (insertion) order.
    public func samples(from t0: Double, to t1: Double) -> [MotionSample] {
        var out: [MotionSample] = []
        if stored == 0 || t1 < t0 { return out }
        let start = stored < capacity ? 0 : head
        for k in 0..<stored {
            let s = storage[(start + k) % capacity]
            if s.t >= t0 && s.t <= t1 {
                out.append(s)
            }
        }
        return out
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
        stored = 0
    }
}

/// Fixed-capacity ring buffer of raw accelerometer samples. Same API as `MotionRingBuffer`.
public struct AccelRingBuffer: Sendable {
    private var storage: [AccelSample]
    private var head: Int = 0
    private var stored: Int = 0
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.storage = []
        self.storage.reserveCapacity(self.capacity)
    }

    public mutating func append(_ s: AccelSample) {
        if stored < capacity {
            storage.append(s)
            stored += 1
        } else {
            storage[head] = s
            head = (head + 1) % capacity
        }
    }

    public var count: Int { return stored }

    public var latestTime: Double? {
        if stored == 0 { return nil }
        if stored < capacity { return storage[stored - 1].t }
        let last = (head + capacity - 1) % capacity
        return storage[last].t
    }

    /// Samples with t0 <= t <= t1, in time (insertion) order.
    public func samples(from t0: Double, to t1: Double) -> [AccelSample] {
        var out: [AccelSample] = []
        if stored == 0 || t1 < t0 { return out }
        let start = stored < capacity ? 0 : head
        for k in 0..<stored {
            let s = storage[(start + k) % capacity]
            if s.t >= t0 && s.t <= t1 {
                out.append(s)
            }
        }
        return out
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
        stored = 0
    }
}
