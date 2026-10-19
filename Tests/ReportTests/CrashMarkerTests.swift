import XCTest
@testable import TouchpadGestures
import GestureEngine

// MARK: - 崩溃标记 / 诊断总线 / 去重
//
// 这些是"该不该弹窗"的判定核心，出错的表现是：要么每次启动都烦用户，
// 要么真崩溃了却静默不报。两者都属于不可接受的回归，因此单独覆盖。

final class CrashMarkerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashMarkerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ReportScope.overrideSupportDir = tempDir
        DiagnosticsBus.clear()
        DiagnosticsBus.isEnabled = true
    }

    override func tearDownWithError() throws {
        DiagnosticsBus.clear()
        DiagnosticsBus.isEnabled = true
        ReportScope.overrideSupportDir = nil
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - 崩溃标记

    func testCleanExitLeavesNoEvidence() {
        CrashCatcher.install(enabled: true)
        CrashCatcher.markCleanExit()
        XCTAssertFalse(CrashCatcher.previousSessionCrashed)
        XCTAssertFalse(CrashCatcher.hasCrashEvidence)
    }

    func testUncleanExitIsDetectedOnNextInstall() {
        CrashCatcher.install(enabled: true)
        // 模拟崩溃：不调用 markCleanExit，直接再"启动"一次
        CrashCatcher.install(enabled: true)
        XCTAssertTrue(CrashCatcher.previousSessionCrashed)
        XCTAssertTrue(CrashCatcher.hasCrashEvidence)
    }

    func testInstallDoesNotSelfReportAsCrash() {
        // 首次安装（无历史标记）绝不能把自己写下的标记当成"上次崩溃"
        CrashCatcher.install(enabled: true)
        XCTAssertFalse(CrashCatcher.previousSessionCrashed)
    }

    func testConsumeFlagStopsRepeatedPrompts() {
        CrashCatcher.install(enabled: true)
        CrashCatcher.install(enabled: true)   // 制造"上次崩溃"
        XCTAssertTrue(CrashCatcher.previousSessionCrashed)

        CrashCatcher.consumePreviousSessionFlag()
        XCTAssertFalse(CrashCatcher.previousSessionCrashed)
    }

    func testDisabledCollectionWritesNoMarker() {
        CrashCatcher.install(enabled: false)
        // 用户拒绝采集：连会话标记都不该留
        XCTAssertFalse(CrashCatcher.previousSessionCrashed)
        XCTAssertFalse(CrashCatcher.hasCrashEvidence)
    }

    // MARK: - 崩溃日志归档

    func testCrashLogsAreArchivedAfterUpload() throws {
        let dir = ReportScope.diagnosticsDir
        let crash = dir.appendingPathComponent("crash-20260101-000000-1.log")
        try "Signal: SIGSEGV".write(to: crash, atomically: true, encoding: .utf8)

        XCTAssertEqual(CrashCatcher.pendingCrashLogs().count, 1)
        CrashCatcher.markCrashLogsUploaded()
        XCTAssertEqual(CrashCatcher.pendingCrashLogs().count, 0)

        // 归档后不应再被当成待上报
        let archived = dir.appendingPathComponent("uploaded").appendingPathComponent(crash.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.path))
    }

    func testPromptedLogsAreNotReoffered() throws {
        let dir = ReportScope.diagnosticsDir
        let crash = dir.appendingPathComponent("crash-20260101-000000-2.log")
        try "Signal: SIGABRT".write(to: crash, atomically: true, encoding: .utf8)

        XCTAssertEqual(CrashCatcher.unpromptedCrashLogs().count, 1)
        CrashCatcher.markCrashPrompted()
        // 用户点过「稍后」：不再每次启动都追问，但文件仍保留
        XCTAssertEqual(CrashCatcher.unpromptedCrashLogs().count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: crash.path))
    }

    // MARK: - 诊断总线

    func testBusAggregatesByDomainAndCode() {
        for _ in 0..<5 {
            DiagnosticsBus.report(domain: "com.touchpad.graph", code: "invalid_graph",
                                  message: "图非法")
        }
        DiagnosticsBus.report(domain: "com.touchpad.config", code: "config_corrupted",
                              message: "配置损坏")

        let aggregates = DiagnosticsBus.aggregates()
        XCTAssertEqual(aggregates.count, 2)
        let graph = aggregates.first { $0.code == "invalid_graph" }
        XCTAssertEqual(graph?.count, 5)
    }

    func testBusRespectsDisabledSwitch() {
        DiagnosticsBus.isEnabled = false
        DiagnosticsBus.report(domain: "x", code: "y", message: "z")
        XCTAssertTrue(DiagnosticsBus.events.isEmpty)

        DiagnosticsBus.isEnabled = true
        DiagnosticsBus.report(domain: "x", code: "y", message: "z")
        XCTAssertEqual(DiagnosticsBus.events.count, 1)
    }

    func testBusNotifiesObserver() {
        var received: [DiagnosticEvent] = []
        let token = DiagnosticsBus.observe { received.append($0) }
        DiagnosticsBus.report(domain: "com.touchpad.trackpad", code: "no_device",
                              message: "无设备")
        token()
        DiagnosticsBus.report(domain: "com.touchpad.trackpad", code: "no_device",
                              message: "无设备（取消订阅后不应再收到）")

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.code, "no_device")
    }

    func testBusRingBufferIsBounded() {
        for i in 0..<(DiagnosticsBus.capacity + 50) {
            DiagnosticsBus.report(domain: "d", code: "c\(i)", message: "m")
        }
        XCTAssertLessThanOrEqual(DiagnosticsBus.events.count, DiagnosticsBus.capacity)
    }
}

// MARK: - 上报中心（聚合与去重）

@MainActor
final class ReportCenterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReportCenterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ReportScope.overrideSupportDir = tempDir
        DiagnosticsBus.clear()
        DiagnosticsBus.isEnabled = true
        ReportCenter.shared.resetForTesting()
    }

    override func tearDownWithError() throws {
        ReportCenter.shared.resetForTesting()
        DiagnosticsBus.clear()
        DiagnosticsBus.isEnabled = true
        ReportScope.overrideSupportDir = nil
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testSameErrorAggregatesIntoOneIssue() async {
        let center = ReportCenter.shared
        await MainActor.run {
            for _ in 0..<3 {
                center.report(domain: "com.touchpad.graph", code: "invalid_graph",
                              message: "图非法")
            }
        }
        // 相同 domain/code/message → 一条，计数 3
        let matching = center.issues.filter { $0.code == "invalid_graph" }
        XCTAssertEqual(matching.count, 1)
        XCTAssertEqual(matching.first?.count, 3)
    }

    func testDifferentMessagesMakeDifferentIssues() async {
        let center = ReportCenter.shared
        await MainActor.run {
            center.report(domain: "com.touchpad.graph", code: "invalid_graph", message: "手势 A 图非法")
            center.report(domain: "com.touchpad.graph", code: "invalid_graph", message: "手势 B 图非法")
        }
        // 不同手势名 → 不同指纹，不能合并成一个（否则会漏掉另一个手势的问题）
        XCTAssertGreaterThanOrEqual(center.issues.filter { $0.code == "invalid_graph" }.count, 2)
    }
}
