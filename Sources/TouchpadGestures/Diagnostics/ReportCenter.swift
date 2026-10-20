import Foundation
import SwiftUI
import AppKit
import GestureEngine
import Combine

// MARK: - 上报中心
//
// 唯一的编排点：
//   - 订阅 DiagnosticsBus（引擎侧错误）与 App 侧的显式上报
//   - 按指纹聚合、按会话去重、合并风暴、手势中延后
//   - 决定何时弹窗（交给 ReportWindowController）
//   - 用户确认后入 outbox 并上传；失败则留待重试
//
// 铁律：**任何路径都不会静默上传**。enqueue 只在用户点「发送」时被调用。

@MainActor
final class ReportCenter: ObservableObject {

    static let shared = ReportCenter()

    // MARK: - 对外状态（设置页 / 窗口绑定）

    /// 当前待用户处理的错误（按指纹聚合，最近在前）
    @Published private(set) var issues: [CapturedIssue] = []
    /// 窗口是否已展示
    @Published private(set) var isPresented = false
    /// 上传状态文案（窗口结果态）
    @Published private(set) var uploadStatus: UploadStatus = .idle
    /// outbox 待发数量（设置页红点）
    @Published private(set) var pendingUploadCount = 0

    enum UploadStatus: Equatable {
        case idle
        case sending
        case done(reportID: String)
        case failed(String)
    }

    // MARK: - 依赖

    /// 由 AppDelegate 注入：读取当前环境快照（含 config / 权限 / 引擎状态）
    var hostProvider: (() -> DiagnosticsCollector.HostInfo)?
    /// 由 AppDelegate 注入：引擎当前是否 in holding（决定弹窗是否延后）
    var isHoldingProvider: (() -> Bool)?
    /// 由 AppDelegate 注入：把报告窗口带到前台（保持 App 的窗口策略集中在一处）
    var presentHandler: ((_ manual: Bool) -> Void)?

    // MARK: - 内部状态

    /// 已在本会话弹过的指纹（避免同一问题反复打扰）
    private var promptedThisSession: Set<String> = []
    /// 用户点过「不再提示」的指纹（本次运行有效，不落盘）
    private var mutedThisSession: Set<String> = []
    /// 待合并窗口：短时间内的连续错误合成一次弹窗
    private var flushTask: Task<Void, Never>?
    /// 手势中延后弹窗的轮询
    private var deferTask: Task<Void, Never>?
    /// 上传/重试任务（防并发）
    private var uploadTask: Task<Void, Never>?

    private var busObserver: (() -> Void)?
    private var retryTimer: Timer?
    private var breadcrumbTask: Task<Void, Never>?

    private static let mergeWindow: TimeInterval = 1.5
    private static let holdingPollInterval: TimeInterval = 1.0

    // MARK: - 生命周期

    private init() {}

    /// App 启动时调用一次
    func start() {
        guard busObserver == nil else { return }

        DiagnosticsBus.isEnabled = ReportPrefs.isAutoCollectEnabled

        // 订阅引擎侧事件
        busObserver = DiagnosticsBus.observe { [weak self] event in
            Task { @MainActor in self?.ingest(event) }
        }

        ReportQueue.prune()
        refreshPendingCount()

        // 崩溃证据 → 弹窗（延后一拍，等窗口系统/主机状态就绪）
        if CrashCatcher.hasCrashEvidence {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }
                self.presentCrashReportIfNeeded()
            }
        }

        // 网络恢复 / 定期重试 outbox
        retryTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.retryOutbox() }
        }
        Task { @MainActor in self.retryOutbox() }

        // 面包屑落盘（崩溃后能拿到最后一段日志）
        breadcrumbTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                CrashCatcher.flushBreadcrumbsIfChanged()
            }
        }
    }

    /// 用户切换自动采集开关
    func setAutoCollect(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: ReportPrefs.autoCollect)
        DiagnosticsBus.isEnabled = enabled
        if !enabled {
            DiagnosticsBus.clear()
            CrashCatcher.clearBreadcrumbs()
        }
    }

    var autoCollectEnabled: Bool { ReportPrefs.isAutoCollectEnabled }

    /// 清空运行态（测试用）。只重置内存状态，不动磁盘。
    func resetForTesting() {
        issues.removeAll()
        promptedThisSession.removeAll()
        mutedThisSession.removeAll()
        flushTask?.cancel()
        deferTask?.cancel()
        uploadStatus = .idle
        isPresented = false
        previousSessionCrashed = false
    }

    /// 停止后台任务（测试 / 退出时用；正常运行时进程存活即持续）
    func stop() {
        busObserver?()
        busObserver = nil
        retryTimer?.invalidate()
        retryTimer = nil
        breadcrumbTask?.cancel()
        breadcrumbTask = nil
        flushTask?.cancel()
        deferTask?.cancel()
    }

    // MARK: - 采集入口 A：引擎侧事件

    private func ingest(_ event: DiagnosticEvent) {
        guard autoCollectEnabled else { return }
        guard event.kind != .info else { return }

        let severity: ReportSeverity = event.kind == .warning ? .warning : .error
        addIssue(domain: event.domain, code: event.code, message: event.message,
                 severity: severity, stack: event.stack, context: event.context,
                 time: event.time)
    }

    // MARK: - 采集入口 B：App 侧显式上报

    func report(domain: String, code: String, message: String,
                severity: ReportSeverity = .error,
                context: [String: String] = [:],
                file: String = #fileID, line: Int = #line) {
        guard autoCollectEnabled else { return }
        addIssue(domain: domain, code: code, message: message,
                 severity: severity,
                 stack: ["\(file):\(line)"], context: context, time: Date())
    }

    // MARK: - 聚合

    private func addIssue(domain: String, code: String, message: String,
                          severity: ReportSeverity, stack: [String],
                          context: [String: String], time: Date) {
        let fingerprint = ReportFingerprint.hash([domain, code, message])

        if let index = issues.firstIndex(where: { $0.fingerprint == fingerprint }) {
            var existing = issues[index]
            existing.count += 1
            existing.lastSeen = time
            issues[index] = existing
        } else {
            issues.append(CapturedIssue(fingerprint: fingerprint, domain: domain, code: code,
                                        message: message, severity: severity,
                                        stack: Array(stack.prefix(8)), context: context,
                                        count: 1, firstSeen: time, lastSeen: time))
            // 新问题才需要考虑弹窗（老问题只累加次数，不重复打扰）
            schedulePrompt(for: fingerprint)
        }
    }

    // MARK: - 弹窗编排

    private func schedulePrompt(for fingerprint: String) {
        guard !mutedThisSession.contains(fingerprint) else { return }
        guard !promptedThisSession.contains(fingerprint) else { return }
        // 窗口已开着 → 直接刷新列表，不另开
        guard !isPresented else { return }

        // 短时间内的连续错误合并成一次弹窗
        flushTask?.cancel()
        flushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.mergeWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.presentWhenIdle()
        }
    }

    /// 手势进行中不打扰：等手指离开再弹（音量/亮度滑到一半被窗口抢焦点很致命）
    private func presentWhenIdle() {
        guard !isPresented else { return }
        guard let isHolding = holdingProvider(), isHolding else {
            present(manual: false)
            return
        }
        deferTask?.cancel()
        deferTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.holdingPollInterval * 1_000_000_000))
                guard let holding = self.holdingProvider() else { break }
                if !holding { break }
            }
            guard !Task.isCancelled else { return }
            // 再等 1s，让退出 holding 的收尾逻辑跑完
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.present(manual: false)
        }
    }

    private func holdingProvider() -> Bool? {
        isHoldingProvider?()
    }

    // MARK: - 主动上报

    /// 菜单栏 / 设置页「报告问题…」
    func presentManualReport() {
        present(manual: true)
    }

    /// 展示窗口。manual = 用户主动，即使没有已捕获的错误也开（空表单）。
    private func present(manual: Bool) {
        isPresented = true
        uploadStatus = .idle
        if manual {
            // 主动上报时，当前已捕获的问题一并带上（用户可取消勾选）
            for issue in issues { promptedThisSession.insert(issue.fingerprint) }
        } else {
            for issue in issues where !promptedThisSession.contains(issue.fingerprint) {
                promptedThisSession.insert(issue.fingerprint)
            }
        }
        presentHandler?(manual)
    }

    /// 用户关闭窗口 / 点「稍后」
    func dismiss() {
        isPresented = false
        uploadStatus = .idle
        flushTask?.cancel()
        deferTask?.cancel()
        refreshPendingCount()
    }

    /// 用户点「不再提示」：本次运行内不再为该指纹弹窗（错误仍保留在本地）
    func mute() {
        for issue in issues { mutedThisSession.insert(issue.fingerprint) }
        dismiss()
    }

    // MARK: - 崩溃上报

    private var previousSessionCrashed = false

    /// 启动时若发现崩溃证据，构造崩溃报告并弹窗
    func presentCrashReportIfNeeded() {
        guard autoCollectEnabled else {
            // 用户关了自动采集：清掉痕迹，不再追问
            CrashCatcher.consumePreviousSessionFlag()
            CrashCatcher.clearBreadcrumbs()
            return
        }
        guard CrashCatcher.hasCrashEvidence else { return }

        previousSessionCrashed = CrashCatcher.previousSessionCrashed

        let crashText = DiagnosticsCollector.collectCrash() ?? "（无 crash 日志文件，仅检测到上次非正常退出）"
        let message = previousSessionCrashed
            ? "上次运行时 App 异常退出"
            : "检测到未处理的崩溃日志"

        // 带上 dSYM UUID：后端用它能匹配到对应版本的符号文件，把栈地址还原成代码行。
        // 没有它，崩溃报告只是一堆十六进制地址，无法定位。
        addIssue(domain: "com.touchpad.crash", code: "previous_session_crash",
                 message: message, severity: .fatal,
                 stack: [], context: [
                    "crash_log_bytes": String(crashText.utf8.count),
                    "dsym_uuid": DSYMInfo.uuid ?? "unknown",
                    "arch": DSYMInfo.arch,
                 ],
                 time: Date())

        // 崩溃日志直接塞进文档，不等用户勾选（这是最有价值的证据）
        present(manual: false)

        // 标记"已问过"：用户点「稍后」也不会每次启动都再追问
        CrashCatcher.consumePreviousSessionFlag()
        CrashCatcher.markCrashPrompted()
    }

    // MARK: - 生成文档

    /// 由窗口根据用户勾选与填写内容调用
    func buildDocument(trigger: ReportTrigger,
                       selectedFingerprints: Set<String>,
                       user: UserInfo,
                       includeLogs: Bool,
                       includeCrash: Bool,
                       includeConfig: Bool) -> ReportDocument? {
        guard let host = hostProvider?() else { return nil }
        let selected = issues.filter { selectedFingerprints.contains($0.fingerprint) }
        return DiagnosticsCollector.makeDocument(
            trigger: trigger,
            issues: selected,
            host: host,
            user: user,
            includeLogs: includeLogs,
            includeCrash: includeCrash,
            includeConfig: includeConfig,
            previousSessionCrashed: previousSessionCrashed)
    }

    // MARK: - 发送

    /// 用户确认发送
    func send(_ document: ReportDocument) {
        guard uploadTask == nil else { return }
        uploadStatus = .sending
        ReportQueue.enqueue(document)

        uploadTask = Task { @MainActor in
            let outcome = await ReportUploader.sendWithRetry(document)
            self.handle(outcome, reportID: document.report.id)
            self.uploadTask = nil
        }
    }

    private func handle(_ outcome: ReportUploader.Outcome, reportID: String) {
        switch outcome {
        case .accepted(let id):
            ReportQueue.remove(id: id)
            // 崩溃日志已随报告送出 → 归档，下次不再重复附加
            if issues.contains(where: { $0.domain == "com.touchpad.crash" }) {
                CrashCatcher.markCrashLogsUploaded()
                CrashCatcher.clearBreadcrumbs()
            }
            // 已上报的问题从列表移除（避免下次窗口里又出现旧条目）
            issues.removeAll { promptedThisSession.contains($0.fingerprint) }
            uploadStatus = .done(reportID: id)
            refreshPendingCount()

        case .rejected(let status, let message):
            // 4xx：重试无意义。保留本地副本，明确告知用户。
            uploadStatus = .failed("\(status) \(message)")
            refreshPendingCount()

        case .retryable(let message):
            uploadStatus = .failed(L10n.tr("网络不可用（\(message)），报告已保存，稍后自动重试。",
                                          "Network unavailable (\(message)). Report saved; will retry later."))
            refreshPendingCount()
        }
    }

    /// 重试 outbox（启动 / 定时 / 网络恢复）
    func retryOutbox() {
        guard uploadTask == nil else { return }
        let pending = ReportQueue.pendingOutbox()
        refreshPendingCount()
        guard !pending.isEmpty else { return }

        uploadTask = Task { @MainActor in
            for item in pending {
                let outcome = await ReportUploader.send(item.document)
                switch outcome {
                case .accepted:
                    ReportQueue.remove(id: item.id)
                case .rejected:
                    // 永久失败：删掉，避免每次启动都徒劳重试
                    ReportQueue.remove(id: item.id)
                case .retryable:
                    break   // 留到下次
                }
            }
            self.uploadTask = nil
            self.refreshPendingCount()
        }
    }

    private func refreshPendingCount() {
        pendingUploadCount = ReportQueue.outboxCount
    }

    // MARK: - 导出诊断包（保留原功能，正式版可用）

    /// 当前环境快照（导出与组装文档共用）
    func hostInfo() -> DiagnosticsCollector.HostInfo? {
        hostProvider?()
    }

    func environmentText() -> String? {
        guard let host = hostProvider?() else { return nil }
        return DiagnosticsCollector.environmentText(from: host)
    }
}
