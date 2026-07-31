import XCTest
@testable import GestureEngine

final class RegionConfigTests: XCTestCase {
    func testContains_pointInside() {
        let r = RegionConfig(name: "test", xMin: 0.1, xMax: 0.3, yMin: 0.2, yMax: 0.8)
        XCTAssertTrue(r.contains(x: 0.2, y: 0.5))
    }

    func testContains_pointOutside() {
        let r = RegionConfig(name: "test", xMin: 0.1, xMax: 0.3, yMin: 0.2, yMax: 0.8)
        XCTAssertFalse(r.contains(x: 0.5, y: 0.5))
        XCTAssertFalse(r.contains(x: 0.2, y: 0.1))
    }

    func testContains_boundary() {
        let r = RegionConfig(name: "test", xMin: 0.1, xMax: 0.3, yMin: 0.2, yMax: 0.8)
        XCTAssertTrue(r.contains(x: 0.1, y: 0.2))
        XCTAssertTrue(r.contains(x: 0.3, y: 0.8))
    }

    func testDefaultRegions() {
        XCTAssertEqual(RegionConfig.defaultLeft.xMin, 0)
        XCTAssertEqual(RegionConfig.defaultLeft.xMax, 0.2)
        XCTAssertEqual(RegionConfig.defaultRight.xMin, 0.8)
        XCTAssertEqual(RegionConfig.defaultRight.xMax, 1)
    }
}
