import XCTest
@testable import BarPathKit

final class GzipTests: XCTestCase {
    func testCrc32OfCheckString() {
        XCTAssertEqual(Gzip.crc32(Data("123456789".utf8)), 0xCBF43926)
    }

    func testCrc32OfEmptyDataIsZero() {
        XCTAssertEqual(Gzip.crc32(Data()), 0)
    }

    func testContainerLayout() {
        let deflated = Data([0xAA, 0xBB, 0xCC])
        let out = Gzip.container(deflated: deflated, crc32: 0x11223344, inputSize: 0x01020304)
        XCTAssertEqual(out.count, 10 + 3 + 8)
        XCTAssertEqual(Array(out[0..<10]), [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        XCTAssertEqual(Array(out[10..<13]), [0xAA, 0xBB, 0xCC])
        XCTAssertEqual(Array(out[13..<17]), [0x44, 0x33, 0x22, 0x11])
        XCTAssertEqual(Array(out[17..<21]), [0x04, 0x03, 0x02, 0x01])
    }

    func testWrapUsesCrcAndLengthOfOriginal() {
        let original = Data("123456789".utf8)
        let out = Gzip.wrap(deflated: Data([0x01]), of: original)
        XCTAssertEqual(Array(out[11..<15]), [0x26, 0x39, 0xF4, 0xCB])
        XCTAssertEqual(Array(out[15..<19]), [9, 0, 0, 0])
    }

    func testEmptyInputContainer() {
        let out = Gzip.wrap(deflated: Gzip.emptyDeflate, of: Data())
        XCTAssertEqual(out.count, 10 + 2 + 8)
        XCTAssertEqual(Array(out[12..<20]), [0, 0, 0, 0, 0, 0, 0, 0])
    }
}
