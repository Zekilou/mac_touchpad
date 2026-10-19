import XCTest
@testable import TouchpadGestures
import GestureEngine

// MARK: - 上报模块单测
//
// 覆盖能离线验证的部分：指纹稳定性、脱敏、请求构造、契约字段、队列与过期清理。
// 真正的网络往返不在这里（需要服务端），由 docs/debug-upload-contract.md 的 curl 用例验证。

final class ReportTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // 隔离：所有队列/崩溃文件写进临时目录，绝不碰用户真实 Application Support
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ReportScope.overrideSupportDir = tempDir
    }

    override func tearDownWithError() throws {
        ReportScope.overrideSupportDir = nil
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - 指纹

    func testFingerprintIsStableAcrossCalls() {
        let a = ReportFingerprint.hash(["com.touchpad.graph", "invalid_graph", "图非法"])
        let b = ReportFingerprint.hash(["com.touchpad.graph", "invalid_graph", "图非法"])
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasPrefix("sha256:"))
    }

    func testFingerprintSeparatesComponents() {
        // ["ab","c"] 与 ["a","bc"] 不能撞车（拼接必须带分隔符）
        XCTAssertNotEqual(ReportFingerprint.hash(["ab", "c"]),
                          ReportFingerprint.hash(["a", "bc"]))
        // 大小写/内容不同必须不同
        XCTAssertNotEqual(ReportFingerprint.hash(["A"]), ReportFingerprint.hash(["a"]))
    }

    func testFingerprintDiffersByDomain() {
        XCTAssertNotEqual(
            ReportFingerprint.hash(["com.touchpad.graph", "x"]),
            ReportFingerprint.hash(["com.touchpad.config", "x"]))
    }

    // MARK: - 脱敏

    func testRedactRemovesUserNameFromPaths() {
        let raw = "at /Users/zekiwithcat/Library/Application Support/TouchpadGestures/config.json:12"
        let redacted = DiagnosticsCollector.redact(raw)
        XCTAssertFalse(redacted.contains("zekiwithcat"))
        XCTAssertTrue(redacted.contains("~/Library"))
    }

    func testRedactRemovesTemporaryFolders() {
        let raw = "path=/private/var/folders/ab/cdefgh/T/tmp123/file.log"
        let redacted = DiagnosticsCollector.redact(raw)
        XCTAssertFalse(redacted.contains("/private/var/folders"))
        XCTAssertTrue(redacted.contains("<tmp>"))
    }

    func testRedactKeepsUnrelatedText() {
        let raw = "Signal: SIGSEGV at 2026-10-19 12:07:55"
        XCTAssertEqual(DiagnosticsCollector.redact(raw), raw)
    }

    // MARK: - 截断

    func testTruncateKeepsTailUnderLimit() {
        let long = String(repeating: "a", count: 5000) + "TAIL"
        let cut = DiagnosticsCollector.truncate(long, maxBytes: 500)
        XCTAssertLessThan(cut.utf8.count, 1000)
        XCTAssertTrue(cut.contains("TAIL"))
        XCTAssertTrue(cut.hasPrefix("…（已截断）…"))
    }

    func testTruncateLeavesShortTextAlone() {
        XCTAssertEqual(DiagnosticsCollector.truncate("short", maxBytes: 100), "short")
    }

    // MARK: - 请求构造（契约核心）

    func testRequestCarriesScopeHeadersAndIdempotency() throws {
        let doc = makeDocument()
        let request = try ReportUploader.makeRequest(for: doc)

        // 作用域：URL 路径第一段 + header + body 三处一致
        XCTAssertEqual(request.url?.host, "debug.zeki.casa")
        XCTAssertEqual(request.url?.path, "/touchpad-gestures/v1/report")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Debug-Scope"), "touchpad-gestures")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Debug-Schema"), "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), doc.report.id)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"),
                       "application/json; charset=utf-8")
        XCTAssertFalse(request.value(forHTTPHeaderField: "X-Client-Token")?.isEmpty ?? true)

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let scope = try XCTUnwrap(json["scope"] as? [String: Any])
        XCTAssertEqual(scope["project"] as? String, "touchpad-gestures")
        XCTAssertEqual(json["schema_version"] as? Int, 1)
    }

    func testRequestIdempotencyKeyMatchesBodyReportID() throws {
        let doc = makeDocument()
        let request = try ReportUploader.makeRequest(for: doc)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let report = try XCTUnwrap(json["report"] as? [String: Any])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"),
                       report["id"] as? String)
        XCTAssertEqual(report["id"] as? String, doc.report.id)
    }

    func testReportIDIs32LowercaseHex() throws {
        let doc = makeDocument()
        let id = doc.report.id
        XCTAssertEqual(id.count, 32)
        XCTAssertTrue(id.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(try ReportUploader.makeRequest(for: doc)
            .value(forHTTPHeaderField: "Idempotency-Key"), id)
    }

    // MARK: - 契约字段

    func testDocumentEncodesContractKeys() throws {
        let doc = makeDocument()
        let data = try ReportJSON.encoder.encode(doc)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        for key in ["schema_version", "report", "scope", "errors", "environment", "user", "consent"] {
            XCTAssertNotNil(json[key], "缺少契约字段 \(key)")
        }

        let report = try XCTUnwrap(json["report"] as? [String: Any])
        for key in ["id", "created_at", "trigger", "severity", "fingerprint",
                    "occurred_at", "app_uptime_seconds", "previous_session_crashed"] {
            XCTAssertNotNil(report[key], "缺少 report.\(key)")
        }

        let environment = try XCTUnwrap(json["environment"] as? [String: Any])
        XCTAssertNotNil(environment["os_version"])
        XCTAssertNotNil(environment["permissions"])
        XCTAssertNotNil(environment["trackpad"])
    }

    func testTimestampsAreISO8601WithOffset() throws {
        let doc = makeDocument()
        let data = try ReportJSON.encoder.encode(doc)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let report = try XCTUnwrap(json["report"] as? [String: Any])
        let createdAt = try XCTUnwrap(report["created_at"] as? String)

        // 契约要求带时区偏移（+08:00 / Z 均可），且能被解码回原值
        XCTAssertTrue(createdAt.contains("+") || createdAt.hasSuffix("Z"),
                      "created_at 缺少时区: \(createdAt)")
        let decoded = try ReportJSON.decoder.decode(ReportDocument.self, from: data)
        XCTAssertEqual(decoded.report.id, doc.report.id)
        XCTAssertEqual(decoded.report.trigger, doc.report.trigger)
    }

    func testConsentReflectsOptInChoices() {
        let host = makeHost()
        let withConfig = DiagnosticsCollector.makeDocument(
            trigger: .manual, issues: [], host: host, user: .empty,
            includeLogs: true, includeCrash: true, includeConfig: true,
            previousSessionCrashed: false)
        XCTAssertTrue(withConfig.consent.collected.contains("config"))
        XCTAssertFalse(withConfig.consent.excluded.contains("config"))
        XCTAssertNotNil(withConfig.configSnapshot)

        let withoutConfig = DiagnosticsCollector.makeDocument(
            trigger: .manual, issues: [], host: host, user: .empty,
            includeLogs: false, includeCrash: false, includeConfig: false,
            previousSessionCrashed: false)
        XCTAssertFalse(withoutConfig.consent.collected.contains("config"))
        XCTAssertTrue(withoutConfig.consent.excluded.contains("config"))
        XCTAssertNil(withoutConfig.configSnapshot)
        XCTAssertNil(withoutConfig.logs)
        XCTAssertNil(withoutConfig.crash)
    }

    func testDocumentLimitsErrorCount() {
        let issues = (0..<80).map { i in
            CapturedIssue(fingerprint: "fp\(i)", domain: "com.touchpad.graph", code: "c\(i)",
                          message: "m\(i)", severity: .error, stack: [], context: [:],
                          count: 1, firstSeen: Date(), lastSeen: Date())
        }
        let doc = DiagnosticsCollector.makeDocument(
            trigger: .error, issues: issues, host: makeHost(), user: .empty,
            includeLogs: false, includeCrash: false, includeConfig: false,
            previousSessionCrashed: false)
        XCTAssertEqual(doc.errors.count, ReportScope.maxErrorsPerReport)
    }

    func testManualReportWithoutIssuesStillBuilds() {
        let doc = DiagnosticsCollector.makeDocument(
            trigger: .manual, issues: [], host: makeHost(),
            user: UserInfo(description: "音量键无反应", steps: "重按右边缘", contact: "a@b.c"),
            includeLogs: false, includeCrash: false, includeConfig: false,
            previousSessionCrashed: false)
        XCTAssertEqual(doc.report.trigger, .manual)
        XCTAssertEqual(doc.errors.count, 0)
        XCTAssertEqual(doc.user.description, "音量键无反应")
        XCTAssertFalse(doc.report.fingerprint.isEmpty)
    }

    // MARK: - 环境信息

    func testEnvironmentCapturesEngineAndConfig() {
        let host = makeHost()
        let env = DiagnosticsCollector.environment(from: host)
        XCTAssertEqual(env.engine.running, true)
        XCTAssertEqual(env.trackpad.deviceCount, 1)
        XCTAssertEqual(env.config.version, 3)
        XCTAssertTrue(env.arch.isEmpty == false)
    }

    func testEnvironmentTextHasNoUserName() {
        let text = DiagnosticsCollector.environmentText(from: makeHost())
        XCTAssertTrue(text.contains("Touchpad Gestures 诊断包"))
        XCTAssertTrue(text.contains("手势数"))
        XCTAssertFalse(text.contains(NSUserName()))
    }

    // MARK: - 队列

    func testQueueRoundTripAndRemoval() throws {
        let doc = makeDocument()
        let url = try XCTUnwrap(ReportQueue.saveDraft(doc))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(ReportQueue.pendingDrafts().contains { $0.id == doc.report.id })

        ReportQueue.enqueue(doc)
        XCTAssertTrue(ReportQueue.pendingOutbox().contains { $0.id == doc.report.id })
        // 入队后草稿应被移除，避免重复提示
        XCTAssertFalse(ReportQueue.pendingDrafts().contains { $0.id == doc.report.id })

        ReportQueue.remove(id: doc.report.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPruneDropsExpiredDrafts() throws {
        let doc = makeDocument()
        let url = try XCTUnwrap(ReportQueue.saveDraft(doc))
        // 把修改时间改到 30 天前，模拟长期未确认
        let old = Date().addingTimeInterval(-30 * 86400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)

        ReportQueue.prune()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - 夹具

    private func makeHost() -> DiagnosticsCollector.HostInfo {
        DiagnosticsCollector.HostInfo(
            appVersion: "2.1.0", appBuild: "1",
            deviceID: 1234567890, deviceCount: 1, trackpadReady: true,
            accessibilityOK: true, inputMonitoringOK: false,
            engineRunning: true, engineHolding: false, engineIdleSlowed: true,
            language: .zh, config: AppConfig(),
            uptime: 812.4)
    }

    private func makeDocument() -> ReportDocument {
        let issue = CapturedIssue(
            fingerprint: ReportFingerprint.hash(["com.touchpad.graph", "invalid_graph", "图非法"]),
            domain: "com.touchpad.graph", code: "invalid_graph",
            message: "手势「左侧Force」的图非法", severity: .error,
            stack: ["GestureEngine.runtime(for:)"],
            context: ["gesture": "左侧Force"],
            count: 3, firstSeen: Date().addingTimeInterval(-300), lastSeen: Date())
        return DiagnosticsCollector.makeDocument(
            trigger: .error, issues: [issue], host: makeHost(), user: .empty,
            includeLogs: false, includeCrash: false, includeConfig: false,
            previousSessionCrashed: false)
    }
}
