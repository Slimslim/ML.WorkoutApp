import XCTest
@testable import BarPathKit

final class RingBufferTests: XCTestCase {

    private func m(_ t: Double) -> MotionSample {
        return MotionSample(t: t, attitude: Quat.identity, userAccel: Vec3.zero,
                            gravity: Vec3(-1, 0, 0), rotationRate: Vec3.zero)
    }

    func testMotionBufferBeforeWrap() {
        var buf = MotionRingBuffer(capacity: 5)
        XCTAssertEqual(buf.count, 0)
        XCTAssertNil(buf.latestTime)
        XCTAssertTrue(buf.samples(from: -100, to: 100).isEmpty)
        for i in 0..<3 { buf.append(m(Double(i))) }
        XCTAssertEqual(buf.count, 3)
        XCTAssertEqual(buf.latestTime, 2)
        XCTAssertEqual(buf.samples(from: 0, to: 2).map { $0.t }, [0, 1, 2])
        XCTAssertEqual(buf.samples(from: 0.5, to: 1.5).map { $0.t }, [1])
    }

    func testMotionBufferWrapAround() {
        var buf = MotionRingBuffer(capacity: 5)
        for i in 0..<12 { buf.append(m(Double(i))) }
        XCTAssertEqual(buf.count, 5)
        XCTAssertEqual(buf.latestTime, 11)
        XCTAssertEqual(buf.samples(from: -1, to: 100).map { $0.t }, [7, 8, 9, 10, 11])
        // Inclusive bounds, time order across the wrap point.
        XCTAssertEqual(buf.samples(from: 8, to: 10).map { $0.t }, [8, 9, 10])
        XCTAssertEqual(buf.samples(from: 0, to: 6.9).map { $0.t }, [])
        XCTAssertTrue(buf.samples(from: 10, to: 9).isEmpty)
        buf.removeAll()
        XCTAssertEqual(buf.count, 0)
        XCTAssertNil(buf.latestTime)
        buf.append(m(42))
        XCTAssertEqual(buf.samples(from: 0, to: 100).map { $0.t }, [42])
    }

    func testMotionBufferExactlyFull() {
        var buf = MotionRingBuffer(capacity: 4)
        for i in 0..<4 { buf.append(m(Double(i))) }
        XCTAssertEqual(buf.count, 4)
        XCTAssertEqual(buf.latestTime, 3)
        XCTAssertEqual(buf.samples(from: 0, to: 3).map { $0.t }, [0, 1, 2, 3])
        buf.append(m(4))
        XCTAssertEqual(buf.samples(from: 0, to: 4).map { $0.t }, [1, 2, 3, 4])
    }

    func testAccelBufferWrapAround() {
        var buf = AccelRingBuffer(capacity: 3)
        XCTAssertNil(buf.latestTime)
        for i in 0..<7 { buf.append(AccelSample(t: Double(i) * 0.5, accel: Vec3(0, 0, -1))) }
        XCTAssertEqual(buf.count, 3)
        XCTAssertEqual(buf.latestTime, 3.0)
        XCTAssertEqual(buf.samples(from: 0, to: 10).map { $0.t }, [2.0, 2.5, 3.0])
        XCTAssertEqual(buf.samples(from: 2.5, to: 3.0).map { $0.t }, [2.5, 3.0])
        buf.removeAll()
        XCTAssertEqual(buf.count, 0)
    }

    func testCapacityIsAtLeastOne() {
        var buf = MotionRingBuffer(capacity: 0)
        buf.append(m(1))
        buf.append(m(2))
        XCTAssertEqual(buf.count, 1)
        XCTAssertEqual(buf.latestTime, 2)
    }
}
