import XCTest
@testable import TouchpadGestures
import GestureEngine

// MARK: - 端到端上传测试
//
// 起一个真实的 HTTP 服务（本机端口），让 ReportUploader 走完整 URLSession 流程，
// 然后按契约校验服务端看到的东西。这是唯一能证明"网络层真的按契约发"的测试。
//
// 覆盖：路径/头/幂等键/JSON 结构/状态码映射/重试策略。

/// 极简 HTTP 服务（只服务于本测试）
private final class TestHTTPServer {
    struct Captured {
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private let listener: Int32
    let port: UInt16
    private let lock = NSLock()
    private(set) var captured: [Captured] = []
    /// 依次返回的状态码（默认 201）；用完后重复最后一个
    var responses: [Int] = [201]
    private var responseIndex = 0

    init() throws {
        listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw NSError(domain: "socket", code: Int(errno)) }

        let socketFD = listener
        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes,
                   socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                     // 让系统挑空闲端口
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw NSError(domain: "bind", code: Int(errno)) }
        guard listen(socketFD, 8) == 0 else { throw NSError(domain: "listen", code: Int(errno)) }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &len)
            }
        }
        port = UInt16(bigEndian: bound.sin_port)
    }

    func start() {
        DispatchQueue.global().async { [weak self] in
            while let self {
                var clientAddr = sockaddr()
                var len = socklen_t(MemoryLayout<sockaddr>.size)
                let client = accept(self.listener, &clientAddr, &len)
                guard client >= 0 else { return }
                self.handle(client)
            }
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)

        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = read(client, &chunk, chunk.count)
            guard n > 0 else { return }
            buffer.append(contentsOf: chunk[0..<n])
        }

        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
        let headerText = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        let requestParts = lines.first?.components(separatedBy: " ") ?? []
        let path = requestParts.count > 1 ? requestParts[1] : ""

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] =
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        var body = Data(buffer[headerEnd.upperBound...])
        while body.count < contentLength {
            let n = read(client, &chunk, chunk.count)
            guard n > 0 else { break }
            body.append(contentsOf: chunk[0..<n])
        }

        lock.lock()
        captured.append(Captured(path: path, headers: headers, body: body))
        let status = responses[min(responseIndex, responses.count - 1)]
        responseIndex += 1
        lock.unlock()

        let payload = Data(#"{"ok":true,"id":"x"}"#.utf8)
        var head = "HTTP/1.1 \(status) OK\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Connection: close\r\n\r\n"
        let response = Data(head.utf8) + payload
        response.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(client, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    deinit { close(listener) }
}

final class UploadTransportTests: XCTestCase {

    private var server: TestHTTPServer!
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UploadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ReportScope.overrideSupportDir = tempDir

        server = try TestHTTPServer()
        server.start()
        ReportScope.endpointOverride = URL(string: "http://127.0.0.1:\(server.port)/touchpad-gestures/v1/report")!
    }

    override func tearDownWithError() throws {
        ReportScope.endpointOverride = nil
        ReportScope.overrideSupportDir = nil
        server = nil
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - 成功路径

    func testRealRequestMatchesContract() async throws {
        let doc = makeDocument()
        let outcome = await ReportUploader.send(doc)

        guard case .accepted = outcome else {
            return XCTFail("应被接受，实际 \(outcome)")
        }

        let captured = try XCTUnwrap(server.captured.first)
        XCTAssertEqual(captured.path, "/touchpad-gestures/v1/report")
        XCTAssertEqual(captured.headers["x-debug-scope"], "touchpad-gestures")
        XCTAssertEqual(captured.headers["x-debug-schema"], "1")
        XCTAssertEqual(captured.headers["idempotency-key"], doc.report.id)
        XCTAssertFalse(captured.headers["x-client-token"]?.isEmpty ?? true)
        XCTAssertTrue(captured.headers["content-type"]?.hasPrefix("application/json") ?? false)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: captured.body) as? [String: Any])
        XCTAssertEqual(json["schema_version"] as? Int, 1)
        XCTAssertEqual((json["scope"] as? [String: Any])?["project"] as? String, "touchpad-gestures")
        XCTAssertEqual((json["report"] as? [String: Any])?["id"] as? String, doc.report.id)
        XCTAssertNotNil(json["environment"])
        XCTAssertNotNil(json["consent"])
    }

    func testIdempotencyKeyStableAcrossRetries() async throws {
        // 同一个文档重发两次（模拟幂等重放），服务端应看到相同 key
        let doc = makeDocument()
        server.responses = [201, 200]
        _ = await ReportUploader.send(doc)
        _ = await ReportUploader.send(doc)

        let keys = server.captured.map { $0.headers["idempotency-key"] }
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0], keys[1])
        XCTAssertEqual(keys[0], doc.report.id)
    }

    // MARK: - 状态码映射

    func testClientErrorsArePermanent() async {
        for status in [400, 401, 403, 413, 422] {
            server.responses = [status]
            let outcome = await ReportUploader.send(makeDocument())
            guard case .rejected(let code, _) = outcome else {
                return XCTFail("\(status) 应判定为不可重试，实际 \(outcome)")
            }
            XCTAssertEqual(code, status)
        }
    }

    func testServerErrorsAreRetryable() async {
        for status in [429, 500, 503] {
            server.responses = [status]
            let outcome = await ReportUploader.send(makeDocument())
            guard case .retryable = outcome else {
                return XCTFail("\(status) 应判定为可重试，实际 \(outcome)")
            }
        }
    }

    func testNetworkFailureIsRetryable() async {
        // 指向一个必然拒绝连接的端口
        ReportScope.endpointOverride = URL(string: "http://127.0.0.1:1/touchpad-gestures/v1/report")!
        let outcome = await ReportUploader.send(makeDocument())
        guard case .retryable = outcome else {
            return XCTFail("连接失败应可重试，实际 \(outcome)")
        }
    }

    // MARK: - 夹具

    private func makeDocument() -> ReportDocument {
        let host = DiagnosticsCollector.HostInfo(
            appVersion: "2.1.0", appBuild: "1",
            deviceID: 42, deviceCount: 1, trackpadReady: true,
            accessibilityOK: true, inputMonitoringOK: false,
            engineRunning: true, engineHolding: false, engineIdleSlowed: false,
            language: .zh, config: AppConfig(), uptime: 12.5)
        let issue = CapturedIssue(
            fingerprint: ReportFingerprint.hash(["com.touchpad.graph", "invalid_graph", "x"]),
            domain: "com.touchpad.graph", code: "invalid_graph", message: "图非法",
            severity: .error, stack: [], context: [:],
            count: 1, firstSeen: Date(), lastSeen: Date())
        return DiagnosticsCollector.makeDocument(
            trigger: .error, issues: [issue], host: host, user: .empty,
            includeLogs: false, includeCrash: false, includeConfig: false,
            previousSessionCrashed: false)
    }
}
