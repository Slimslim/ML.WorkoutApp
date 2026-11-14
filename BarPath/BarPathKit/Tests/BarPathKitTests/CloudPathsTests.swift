import XCTest
@testable import BarPathKit

final class CloudPathsTests: XCTestCase {
    func testJoinBuildsNestedObjectPaths() {
        XCTAssertEqual(CloudPaths.join(folder: "", name: "abc"), "abc")
        XCTAssertEqual(CloudPaths.join(folder: "abc", name: "Lifts"), "abc/Lifts")
        XCTAssertEqual(CloudPaths.join(folder: "abc/Lifts/", name: "s1.csv.gz"), "abc/Lifts/s1.csv.gz")
    }

    func testBatchesSplitAtSizeAndDropDuplicates() {
        let paths: [String] = (0..<250).map { "u/f\($0)" } + ["u/f0", "u/f249"]
        let groups: [[String]] = CloudPaths.batches(paths, size: 100)
        XCTAssertEqual(groups.map { $0.count }, [100, 100, 50])
        XCTAssertEqual(groups.flatMap { $0 }.count, 250)
        XCTAssertTrue(CloudPaths.batches([]).isEmpty)
    }
}
