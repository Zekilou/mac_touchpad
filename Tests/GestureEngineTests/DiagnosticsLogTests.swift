import XCTest
@testable import GestureEngine

#if DEBUG

final class DiagnosticsLogTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DiagnosticsLog.clear()
    }

    func testAppendAndReadInOrder() {
        DiagnosticsLog.log("a")
        DiagnosticsLog.log("b")
        DiagnosticsLog.log("c")
        let lines = DiagnosticsLog.contents
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix("a"))
        XCTAssertTrue(lines[1].hasSuffix("b"))
        XCTAssertTrue(lines[2].hasSuffix("c"))
    }

    func testRingCapacityDropsOldest() {
        for i in 0..<(DiagnosticsLog.capacity + 20) {
            DiagnosticsLog.log("msg-\(i)")
        }
        let lines = DiagnosticsLog.contents
        XCTAssertEqual(lines.count, DiagnosticsLog.capacity, "环形缓冲保留最近 capacity 条")
        // 最旧的 20 条被丢弃，第一条应为 msg-20
        XCTAssertTrue(lines[0].hasSuffix("msg-20"))
        XCTAssertTrue(lines.last!.hasSuffix("msg-\(DiagnosticsLog.capacity + 19)"))
    }

    func testClear() {
        DiagnosticsLog.log("x")
        DiagnosticsLog.clear()
        XCTAssertTrue(DiagnosticsLog.contents.isEmpty)
    }

    /// 并发写入不崩溃（引擎多线程场景：MT 回调/tick 队列同时 log）
    func testConcurrentLogging() {
        let group = DispatchGroup()
        for t in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                for i in 0..<200 {
                    DiagnosticsLog.log("thread-\(t)-\(i)")
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(DiagnosticsLog.contents.count, DiagnosticsLog.capacity)
    }
}

#endif
