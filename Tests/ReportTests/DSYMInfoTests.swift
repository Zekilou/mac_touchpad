import XCTest
@testable import TouchpadGestures
import GestureEngine

/// dSYM / 构建标识
///
/// 崩溃报告只有栈地址；没有与构建匹配的 dSYM 就无法符号化。
/// 这里锁住"包内 UUID 能被读出来"这件事——它是后端匹配符号文件的唯一依据。
final class DSYMInfoTests: XCTestCase {

    func testUUIDIsResolvable() throws {
        // 测试进程的 Bundle 是 xctest 包，不是 App 包，因此这里验证的是
        // "能读到运行中二进制的 LC_UUID"这条兜底路径必须work。
        let uuid = DSYMInfo.uuid
        XCTAssertNotNil(uuid, "无法解析二进制 UUID，崩溃报告将无法符号化")
        guard let uuid else { return }
        let pattern = "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"
        XCTAssertNotNil(uuid.range(of: pattern, options: .regularExpression),
                        "UUID 格式不对: \(uuid)")
    }

    func testArchIsReported() {
        XCTAssertFalse(DSYMInfo.arch.isEmpty)
        XCTAssertNotEqual(DSYMInfo.arch, "unknown")
    }
}
