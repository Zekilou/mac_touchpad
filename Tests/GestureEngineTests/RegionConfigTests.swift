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

    func testDefaultTopBottomRegions() {
        let top = RegionConfig.defaultTop
        let bottom = RegionConfig.defaultBottom
        // norm_y 0 = 顶部
        XCTAssertEqual(top.yMin, 0)
        XCTAssertEqual(top.yMax, 0.2)
        XCTAssertEqual(bottom.yMin, 0.8)
        XCTAssertEqual(bottom.yMax, 1)
    }

    /// 默认四个区域两两**面积**不重叠：同一次触摸不能同时落入两个手势区域（会同时调两个事件）。
    /// 相邻矩形共享边界线是不可避免的（测度零），这里只断言重叠面积为 0。
    func testDefaultRegions_noOverlapArea() {
        let defaults = [RegionConfig.defaultLeft, RegionConfig.defaultRight,
                        RegionConfig.defaultTop, RegionConfig.defaultBottom]
        func overlapArea(_ a: RegionConfig, _ b: RegionConfig) -> Float {
            let dx = min(a.xMax, b.xMax) - max(a.xMin, b.xMin)
            let dy = min(a.yMax, b.yMax) - max(a.yMin, b.yMin)
            return (dx > 0 && dy > 0) ? dx * dy : 0
        }
        for i in defaults.indices {
            for j in defaults.indices where j > i {
                let a = defaults[i], b = defaults[j]
                XCTAssertEqual(overlapArea(a, b), 0,
                               "\(a.name) 与 \(b.name) 存在面积重叠")
            }
        }
    }
}
