import Foundation

// MARK: - 上传器
//
// 只负责「把一份已经生成好的 ReportDocument 发出去」，不做采集、不做 UI。
// 状态码语义见 docs/debug-upload-contract.md 第 5 节。

enum ReportUploader {

    // MARK: - 结果

    enum Outcome {
        /// 服务端接受了（201 首次 / 200 幂等重放）
        case accepted(reportID: String)
        /// 网络或 5xx，可重试
        case retryable(message: String)
        /// 4xx，重试无意义（token 错 / scope 不支持 / 体积超限等）
        case rejected(status: Int, message: String)
    }

    /// 上传接口（测试可注入）
    static var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = ReportScope.requestTimeout
        config.timeoutIntervalForResource = ReportScope.requestTimeout * 2
        // 上报通道不落 cookie / 缓存
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    // MARK: - 请求构造

    /// 生成 URLRequest（拆出来便于单测检查 header / body）
    static func makeRequest(for document: ReportDocument) throws -> URLRequest {
        let body = try ReportJSON.encoder.encode(document)
        guard body.count <= ReportScope.maxBodyBytes else {
            throw UploadError.tooLarge(body.count)
        }

        var request = URLRequest(url: ReportScope.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = ReportScope.requestTimeout
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(ReportScope.project, forHTTPHeaderField: "X-Debug-Scope")
        request.setValue(String(ReportScope.schemaVersion), forHTTPHeaderField: "X-Debug-Schema")
        request.setValue(document.report.id, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(ReportScope.clientToken, forHTTPHeaderField: "X-Client-Token")
        request.setValue("TouchpadGestures/\(document.scope.appVersion) (\(document.scope.channel))",
                         forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        return request
    }

    enum UploadError: LocalizedError {
        case tooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes):
                return "报告体积 \(bytes) 字节，超过上限 \(ReportScope.maxBodyBytes)"
            }
        }
    }

    // MARK: - 发送

    /// 发送一次（不含重试）
    static func send(_ document: ReportDocument) async -> Outcome {
        let request: URLRequest
        do {
            request = try makeRequest(for: document)
        } catch {
            return .rejected(status: 0, message: error.localizedDescription)
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .retryable(message: "响应不是 HTTP")
            }
            switch http.statusCode {
            case 200, 201:
                return .accepted(reportID: document.report.id)
            case 400, 401, 403, 404, 409, 413, 415, 422:
                return .rejected(status: http.statusCode, message: serverMessage(from: data))
            case 429:
                return .retryable(message: "429 限流")
            default:
                return .retryable(message: "HTTP \(http.statusCode)")
            }
        } catch {
            return .retryable(message: error.localizedDescription)
        }
    }

    /// 带重试的发送（指数退避：0 / 2 / 8 / 30 秒，共 4 次尝试）
    /// - Returns: 最终结果；`.retryable` 表示应留在 outbox 等下次
    static func sendWithRetry(_ document: ReportDocument) async -> Outcome {
        var last: Outcome = .retryable(message: "未执行")
        for delay in ([0.0] + ReportScope.retryDelays) {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            last = await send(document)
            switch last {
            case .accepted, .rejected:
                return last
            case .retryable:
                continue
            }
        }
        return last
    }

    private static func serverMessage(from data: Data) -> String {
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return String(text.prefix(300))
        }
        return "（无响应体）"
    }
}

// MARK: - 本地队列（drafts / outbox）
//
// 一次上报的完整生命周期：
//   采集 → 写 drafts/<id>.json（等用户确认）
//        → 用户点「发送」→ 移入 outbox/<id>.json
//        → 上传成功 → 删除 outbox 文件
//        → 上传失败（可重试）→ 留在 outbox，下次启动/定时重试

enum ReportQueue {

    struct StoredReport: Identifiable {
        let id: String
        let url: URL
        let createdAt: Date
        let trigger: ReportTrigger
        let severity: ReportSeverity
        let title: String
        let document: ReportDocument
    }

    // MARK: - 写入

    /// 把文档写进 drafts（等用户确认）
    @discardableResult
    static func saveDraft(_ document: ReportDocument) -> URL? {
        write(document, to: ReportScope.draftsDir)
    }

    /// 用户确认后移入 outbox
    @discardableResult
    static func enqueue(_ document: ReportDocument) -> URL? {
        let url = write(document, to: ReportScope.outboxDir)
        // 确认过就从 drafts 移除，避免下次启动重复提示
        removeDraft(id: document.report.id)
        return url
    }

    private static func write(_ document: ReportDocument, to dir: URL) -> URL? {
        do {
            let data = try ReportJSON.encoder.encode(document)
            let url = dir.appendingPathComponent("\(document.report.id).json")
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            fputs("[Report] 写入报告失败: \(error)\n", stderr)
            return nil
        }
    }

    // MARK: - 读取

    static func pendingDrafts() -> [StoredReport] {
        load(from: ReportScope.draftsDir)
    }

    static func pendingOutbox() -> [StoredReport] {
        load(from: ReportScope.outboxDir)
    }

    private static func load(from dir: URL) -> [StoredReport] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> StoredReport? in
                guard let data = try? Data(contentsOf: url),
                      let doc = try? ReportJSON.decoder.decode(ReportDocument.self, from: data) else {
                    return nil
                }
                let created = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? doc.report.createdAt
                let title = doc.errors.first?.message ?? doc.user.description
                return StoredReport(id: doc.report.id, url: url, createdAt: created,
                                    trigger: doc.report.trigger,
                                    severity: doc.report.severity,
                                    title: title.isEmpty ? "(无描述)" : title,
                                    document: doc)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - 删除 / 清理

    static func remove(id: String) {
        for dir in [ReportScope.draftsDir, ReportScope.outboxDir] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
        }
    }

    static func removeDraft(id: String) {
        try? FileManager.default.removeItem(at: ReportScope.draftsDir.appendingPathComponent("\(id).json"))
    }

    /// 过期草稿（用户一直没确认）+ outbox 超量清理
    static func prune() {
        let cutoff = Date().addingTimeInterval(-Double(ReportPrefs.draftTTLDays) * 86400)
        for draft in pendingDrafts() where draft.createdAt < cutoff {
            try? FileManager.default.removeItem(at: draft.url)
        }
        // outbox 只保留最近的 N 条，防无限堆积
        let outbox = pendingOutbox()
        if outbox.count > ReportScope.maxOutboxCount {
            for stale in outbox.dropFirst(ReportScope.maxOutboxCount) {
                try? FileManager.default.removeItem(at: stale.url)
            }
        }
    }

    /// outbox 是否为空（设置页显示待发数量用）
    static var outboxCount: Int { pendingOutbox().count }
    static var draftCount: Int { pendingDrafts().count }
}
