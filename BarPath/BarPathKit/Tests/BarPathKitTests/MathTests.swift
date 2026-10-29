import XCTest
@testable import BarPathKit

final class MathTests: XCTestCase {
    private let eps = 1e-12

    private func assertVec(_ a: Vec3, _ b: Vec3, accuracy: Double = 1e-12,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, file: file, line: line)
    }

    func testVecOperators() {
        let a = Vec3(1, 2, 3)
        let b = Vec3(4, -5, 6)
        XCTAssertEqual(a + b, Vec3(5, -3, 9))
        XCTAssertEqual(a - b, Vec3(-3, 7, -3))
        XCTAssertEqual(a * 2.0, Vec3(2, 4, 6))
        XCTAssertEqual(a / 2.0, Vec3(0.5, 1, 1.5))
        XCTAssertEqual(a.dot(b), 4 - 10 + 18)
        XCTAssertEqual(Vec3(1, 0, 0).cross(Vec3(0, 1, 0)), Vec3(0, 0, 1))
        XCTAssertEqual(Vec3(3, 4, 0).norm, 5, accuracy: eps)
        assertVec(Vec3(3, 4, 0).normalized, Vec3(0.6, 0.8, 0))
        XCTAssertEqual(Vec3(1e-13, 0, 0).normalized, Vec3.zero)
        XCTAssertEqual(Vec3.zero.normalized, Vec3.zero)
    }

    func testQuaternionRotate90AboutZ() {
        let s = 0.5.squareRoot()
        let q = Quat(w: s, x: 0, y: 0, z: s)          // +90° about z
        assertVec(q.rotate(Vec3(1, 0, 0)), Vec3(0, 1, 0))
        assertVec(q.rotate(Vec3(0, 1, 0)), Vec3(-1, 0, 0))
        assertVec(q.rotate(Vec3(0, 0, 1)), Vec3(0, 0, 1))
    }

    func testQuaternionRotate180AboutX() {
        let q = Quat(w: 0, x: 1, y: 0, z: 0)          // 180° about x
        assertVec(q.rotate(Vec3(0, 1, 0)), Vec3(0, -1, 0))
        assertVec(q.rotate(Vec3(0, 0, 1)), Vec3(0, 0, -1))
        assertVec(q.rotate(Vec3(1, 0, 0)), Vec3(1, 0, 0))
    }

    func testQuaternionRotateMinus90AboutY() {
        let s = 0.5.squareRoot()
        let q = Quat(w: s, x: 0, y: -s, z: 0)         // -90° about y
        assertVec(q.rotate(Vec3(1, 0, 0)), Vec3(0, 0, 1))
        assertVec(q.rotate(Vec3(0, 0, 1)), Vec3(-1, 0, 0))
    }

    func testConjugateIsInverseRotation() {
        // Arbitrary unit quaternion (axis (1,2,3), angle 0.7 rad).
        let axis = Vec3(1, 2, 3).normalized
        let half = 0.35
        let q = Quat(w: cos(half), x: axis.x * sin(half), y: axis.y * sin(half), z: axis.z * sin(half))
        let v = Vec3(0.3, -1.2, 2.5)
        let r = q.rotate(v)
        XCTAssertEqual(r.norm, v.norm, accuracy: 1e-12)
        assertVec(q.conjugate.rotate(r), v)
        assertVec(q.rotate(q.conjugate.rotate(v)), v)
        XCTAssertEqual(q.conjugate, Quat(w: q.w, x: -q.x, y: -q.y, z: -q.z))
        assertVec(Quat.identity.rotate(v), v)
    }

    func testMedian() {
        XCTAssertEqual(medianOf([]), 0)
        XCTAssertEqual(medianOf([3, 1, 2]), 2)
        XCTAssertEqual(medianOf([4, 1, 3, 2]), 2.5)
    }
}
