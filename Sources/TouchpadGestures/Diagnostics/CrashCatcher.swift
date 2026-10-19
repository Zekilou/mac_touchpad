import Foundation
import Darwin
import GestureEngine

// MARK: - 崩溃捕获
//
// **正式版也编译**：崩溃是这个 App 最需要知道的信息，不能只在开发版有。
// 成本：启动时装几个 signal handler + 一个会话标记文件；无常驻 IO。
//
// 机制：
//   1. 启动时**先判断**上次是否留下会话标记（上次崩溃）→ 记录到 previousSessionCrashedFlag
//   2. 再为本次会话写新标记；正常退出删除
//   3. signal handler 用 async-signal-safe 的 open/write/close 追加写崩溃日志
//      （append，不 truncate —— 一次会话崩多次时保留全部）
//   4. 每 15s 把内存日志环形缓冲落到 breadcrumbs.log（只在与上次不同时写），
//      崩溃后再也没人写它 → 文件自然停在崩溃前那一刻
//   5. 启动时若发现上次有面包屑，先归档为 breadcrumbs.previous.log，不覆盖

enum CrashCatcher {

    /// 诊断目录（崩溃日志 / 会话标记存放处）
    ///
    /// 必须是计算属性：`static let` 只求值一次，会把路径钉死在首次访问时的值上，
    /// 之后测试注入的 overrideSupportDir 就再也无法重定向（单测会写进用户真实目录）。
    static var diagnosticsDir: URL { ReportScope.diagnosticsDir }

    // 一律用计算属性：static let 会把路径钉死在首次访问的值上（测试无法重定向、换目录也不生效）
    private static var sessionMarker: URL { diagnosticsDir.appendingPathComponent("session.active") }
    private static var breadcrumbFile: URL { diagnosticsDir.appendingPathComponent("breadcrumbs.log") }
    private static var previousBreadcrumbFile: URL { diagnosticsDir.appendingPathComponent("breadcrumbs.previous.log") }
    private static var promptedFile: URL { diagnosticsDir.appendingPathComponent("prompted.json") }

    // MARK: - 安装

    private(set) static var previousSessionCrashedFlag = false

    /// 安装崩溃捕获。`enabled == false`（用户关掉自动采集）时什么都不做，
    /// 连会话标记都不写——用户明确拒绝后不应继续留痕。
    static func install(enabled: Bool) {
        guard enabled else { return }

        // ① 先判断上次是否异常退出（必须在写本次标记之前！）
        previousSessionCrashedFlag = FileManager.default.fileExists(atPath: sessionMarker.path)

        // ② 上次留下的面包屑是崩溃前的日志，归档而不是被本次会话覆盖
        if previousSessionCrashedFlag, FileManager.default.fileExists(atPath: breadcrumbFile.path) {
            try? FileManager.default.removeItem(at: previousBreadcrumbFile)
            try? FileManager.default.moveItem(at: breadcrumbFile, to: previousBreadcrumbFile)
        }

        // ③ 写本次会话标记
        writeSessionMarker()

        // ④ 崩溃 handler
        installExceptionHandler()
        installSignalHandlers()
    }

    // MARK: - 会话标记

    private static func writeSessionMarker() {
        let payload = """
        pid=\(ProcessInfo.processInfo.processIdentifier)
        started=\(ISO8601DateFormatter().string(from: Date()))
        version=\(ScopeBuild.appVersion) (\(ScopeBuild.appBuild))
        channel=\(ReportScope.channel)
        """
        try? payload.write(to: sessionMarker, atomically: true, encoding: .utf8)
    }

    /// 正常退出：删除标记（下次启动据此区分"崩溃"与"正常关闭"）
    static func markCleanExit() {
        try? FileManager.default.removeItem(at: sessionMarker)
    }

    /// 上次是否异常退出（install 时捕获的值，不会被本次启动覆盖）
    static var previousSessionCrashed: Bool { previousSessionCrashedFlag }

    /// 报告已生成：清掉"上次崩溃"标记，避免下次启动重复追问
    static func consumePreviousSessionFlag() {
        previousSessionCrashedFlag = false
        try? FileManager.default.removeItem(at: sessionMarker)
        try? FileManager.default.removeItem(at: previousBreadcrumbFile)
    }

    // MARK: - 崩溃日志

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// 本次会话的崩溃日志（预构建路径；signal handler 里不能再分配内存）
    private static func newCrashURL() -> URL {
        let stamp = timestampFormatter.string(from: Date())
        let pid = ProcessInfo.processInfo.processIdentifier
        return diagnosticsDir.appendingPathComponent("crash-\(stamp)-\(pid).log")
    }

    /// 尚未上传的崩溃日志
    static func pendingCrashLogs() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: diagnosticsDir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("crash-") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 本次会话以来的崩溃日志（已被提示过的不算）
    static func unpromptedCrashLogs() -> [URL] {
        let prompted = loadPrompted()
        return pendingCrashLogs().filter { !prompted.contains($0.lastPathComponent) }
    }

    /// 崩溃日志已随报告上传 → 归档，避免下次重复附加
    static func markCrashLogsUploaded() {
        let dir = diagnosticsDir.appendingPathComponent("uploaded", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for url in pendingCrashLogs() {
            let dest = dir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.moveItem(at: url, to: dest)
        }
    }

    /// 已向用户展示过（用户选了「稍后」也一样）→ 不再每次启动都追问
    static func markCrashPrompted() {
        var prompted = loadPrompted()
        for url in pendingCrashLogs() { prompted.insert(url.lastPathComponent) }
        savePrompted(prompted)
    }

    private static func loadPrompted() -> Set<String> {
        guard let data = try? Data(contentsOf: promptedFile),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(list)
    }

    private static func savePrompted(_ set: Set<String>) {
        // 只保留仍存在的日志名，避免文件无限增长
        let existing = Set(pendingCrashLogs().map(\.lastPathComponent))
        let pruned = set.intersection(existing)
        if let data = try? JSONEncoder().encode(Array(pruned).sorted()) {
            try? data.write(to: promptedFile, options: .atomic)
        }
    }

    // MARK: - NSException

    private static func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let content = """
            NSException: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "?")
            UserInfo: \(exception.userInfo ?? [:])

            Stack:
            \(exception.callStackSymbols.joined(separator: "\n"))

            == 崩溃前日志 ==
            \(DiagnosticsLog.contents.suffix(80).joined(separator: "\n"))
            """
            try? content.write(to: CrashCatcher.newCrashURL(), atomically: true, encoding: .utf8)
        }
    }

    // MARK: - signal handler
    //
    // 约束：handler 内只能用 async-signal-safe 的调用（open/write/close/strlen/signal/raise），
    // 所有字符串在 install 时预构建。signal 到来时再做 DateFormatter / String 拼接会死锁或二次崩溃。

    private static var cachedPath: UnsafeMutablePointer<CChar>?
    private static var cachedTimestamp: UnsafeMutablePointer<CChar>?
    private static var cachedNames: [Int32: UnsafeMutablePointer<CChar>] = [:]

    private static let handledSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

    private static func installSignalHandlers() {
        cacheSignalContext()
        for sig in handledSignals {
            signal(sig, signalHandler)
        }
    }

    private static func cacheSignalContext() {
        cachedPath = strdup(newCrashURL().path)
        cachedTimestamp = strdup(formattedNow())
        for sig in handledSignals {
            cachedNames[sig] = strdup(signalName(sig))
        }
    }

    private static func formattedNow() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    private static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT (abort/fatalError)"
        case SIGSEGV: return "SIGSEGV (bad memory access)"
        case SIGBUS:  return "SIGBUS (bus error)"
        case SIGILL:  return "SIGILL (illegal instruction)"
        case SIGFPE:  return "SIGFPE (float point error)"
        case SIGTRAP: return "SIGTRAP (trap)"
        default:      return "SIGNAL(\(sig))"
        }
    }

    /// handler：写崩溃日志 → 恢复默认 → 重抛（让系统 crash reporter 也记录并终止进程）
    private static let signalHandler: @convention(c) (Int32) -> Void = { sig in
        guard let path = CrashCatcher.cachedPath,
              let ts = CrashCatcher.cachedTimestamp else {
            signal(sig, SIG_DFL)
            raise(sig)
            return
        }
        let name = CrashCatcher.cachedNames[sig] ?? CrashCatcher.cachedNames[SIGABRT]!

        // O_APPEND：同一会话多次崩溃不会互相覆盖
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 {
            _ = write(fd, "Signal: ", 8)
            _ = write(fd, name, Int(strlen(name)))
            _ = write(fd, " at ", 4)
            _ = write(fd, ts, Int(strlen(ts)))
            _ = write(fd, "\n", 1)
            close(fd)
        }

        signal(sig, SIG_DFL)
        raise(sig)
    }

    // MARK: - 面包屑（崩溃前最后一段日志）

    private static var lastFlushedLineCount = -1
    private static let crumbLock = NSLock()

    static func flushBreadcrumbsIfChanged() {
        let lines = DiagnosticsLog.contents
        crumbLock.lock()
        defer { crumbLock.unlock() }
        guard lines.count != lastFlushedLineCount else { return }
        lastFlushedLineCount = lines.count
        let tail = lines.suffix(120).joined(separator: "\n") + "\n"
        try? DiagnosticsCollector.redact(tail).write(to: breadcrumbFile, atomically: true, encoding: .utf8)
    }

    /// 崩溃前日志（崩溃报告附加用）：优先上次会话归档的那份
    static func breadcrumbs() -> String? {
        for url in [previousBreadcrumbFile, breadcrumbFile] {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    /// 是否有需要询问用户的崩溃证据
    static var hasCrashEvidence: Bool {
        previousSessionCrashedFlag
            || !unpromptedCrashLogs().isEmpty
            || FileManager.default.fileExists(atPath: previousBreadcrumbFile.path)
    }

    /// 清掉面包屑（报告生成后）
    static func clearBreadcrumbs() {
        crumbLock.lock()
        defer { crumbLock.unlock() }
        try? FileManager.default.removeItem(at: breadcrumbFile)
        try? FileManager.default.removeItem(at: previousBreadcrumbFile)
        lastFlushedLineCount = -1
    }
}
