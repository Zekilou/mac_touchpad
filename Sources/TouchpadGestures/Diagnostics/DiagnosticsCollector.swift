import Foundation
import GestureEngine

// MARK: - 诊断采集器
//
// 负责把「当前环境的快照」+「内存里的错误/日志/崩溃」组装成一份 ReportDocument。
// 不做网络、不碰 UI —— 那两件事分别在 ReportUploader / ReportCenter。

enum DiagnosticsCollector {

    // MARK: - 环境

    struct HostInfo {
        var appVersion: String
        var appBuild: String
        var deviceID: UInt64
        var deviceCount: Int32
        var trackpadReady: Bool
        var accessibilityOK: Bool
        var inputMonitoringOK: Bool
        var engineRunning: Bool
        var engineHolding: Bool
        var engineIdleSlowed: Bool
        var language: AppLanguage
        var config: AppConfig
        var uptime: TimeInterval
    }

    /// 组装环境信息（不含敏感字段）
    static func environment(from host: HostInfo) -> EnvironmentInfo {
        EnvironmentInfo(
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            arch: architecture,
            model: machineModel,
            locale: Locale.current.identifier,
            language: L10n.isChinese ? "zh" : "en",
            permissions: EnvironmentInfo.Permissions(
                accessibility: host.accessibilityOK ? "granted" : "unknown",
                inputMonitoring: host.inputMonitoringOK ? "granted" : "unknown"),
            trackpad: EnvironmentInfo.Trackpad(
                deviceID: host.deviceID,
                deviceCount: host.deviceCount,
                ready: host.trackpadReady),
            engine: EnvironmentInfo.EngineState(
                running: host.engineRunning,
                holding: host.engineHolding,
                idleSlowed: host.engineIdleSlowed),
            config: EnvironmentInfo.ConfigSummary(
                gestures: host.config.gestures.count,
                events: host.config.events.count,
                regions: host.config.regions.count,
                version: host.config.version))
    }

    /// 环境摘要文本（导出诊断包 / 用户预览用，人读友好）
    static func environmentText(from host: HostInfo) -> String {
        var lines: [String] = []
        lines.append("Touchpad Gestures 诊断包")
        lines.append("生成时间: \(Date())")
        lines.append("App 版本: \(host.appVersion) (\(host.appBuild))")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("机型: \(machineModel)  架构: \(architecture)")
        lines.append("触控板设备 ID: \(host.deviceID) (设备数: \(host.deviceCount))")
        lines.append("触控板就绪: \(host.trackpadReady ? "是" : "否")")
        lines.append("权限: 辅助功能=\(host.accessibilityOK ? "已授权" : "未授权")  "
                     + "输入监控=\(host.inputMonitoringOK ? "已授权" : "未授权")")
        lines.append("界面语言: \(host.language.displayName)")
        lines.append("引擎: 运行=\(host.engineRunning ? "是" : "否")  "
                     + "holding=\(host.engineHolding ? "是" : "否")  "
                     + "省电时钟=\(host.engineIdleSlowed ? "是" : "否")")
        lines.append("手势数: \(host.config.gestures.count) "
                     + "(\(host.config.gestures.map(\.name).joined(separator: ", ")))")
        lines.append("事件数: \(host.config.events.count)  区域数: \(host.config.regions.count)")
        return lines.joined(separator: "\n") + "\n"
    }

    private static var machineModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    private static var architecture: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }

    // MARK: - 日志

    /// 取最近日志（环形缓冲 + 可选的 /tmp 落盘日志），限制长度并脱敏
    static func collectLogs(maxBytes: Int = ReportScope.maxLogBytes) -> String {
        var sections: [String] = []

        let ring = DiagnosticsLog.contents
        if !ring.isEmpty {
            sections.append("== 引擎日志（最近的 \(ring.count) 条） ==\n" + ring.joined(separator: "\n"))
        }

        let run = EngineLog.contents
        if !run.isEmpty {
            // 落盘日志可能很长，只保留尾部（最近的更有价值）
            let tail = String(run.suffix(maxBytes / 2))
            sections.append("== 数据流日志（/tmp/touchpad_run.log 尾部） ==\n" + tail)
        }

        let bus = DiagnosticsBus.events
        if !bus.isEmpty {
            let lines = bus.suffix(100).map { event -> String in
                "[\(ReportJSON.clockFormatter.string(from: event.time))] "
                    + "[\(event.domain)/\(event.code)] \(event.message)"
                    + (event.context.isEmpty ? "" : " \(event.context)")
            }
            sections.append("== 诊断事件（最近 \(min(bus.count, 100)) 条） ==\n" + lines.joined(separator: "\n"))
        }

        let joined = sections.joined(separator: "\n\n")
        return truncate(redact(joined), maxBytes: maxBytes)
    }

    /// 取待上报的崩溃日志文本（没有则 nil）
    static func collectCrash(maxBytes: Int = ReportScope.maxCrashBytes) -> String? {
        var parts: [String] = []

        for url in CrashCatcher.pendingCrashLogs() {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                parts.append("== \(url.lastPathComponent) ==\n" + text)
            }
        }

        // 崩溃前最后一段日志（signal handler 写不了，靠定时落盘的面包屑）
        if let crumbs = CrashCatcher.breadcrumbs() {
            parts.append("== 崩溃前日志（breadcrumbs） ==\n" + crumbs)
        }

        guard !parts.isEmpty else { return nil }
        return truncate(redact(parts.joined(separator: "\n\n")), maxBytes: maxBytes)
    }

    // MARK: - 脱敏

    /// 把 `/Users/<用户名>/…` 收成 `~/…`，并抹掉主机名等路径片段。
    ///
    /// 崩溃日志与 stderr 里常带完整路径（含用户名）。上报内容不允许出现个人标识，
    /// 因此在**采集阶段**统一处理，而不是指望读取者忽略。
    static func redact(_ text: String) -> String {
        var result = text

        // /Users/xxx/ → ~/
        if let regex = try? NSRegularExpression(pattern: "/Users/[^/\\s]+/", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: "~/")
        }
        // /private/var/folders/… 这类临时目录也含用户名哈希，收成 <tmp>
        if let regex = try? NSRegularExpression(pattern: "/private/var/folders/[^\\s]+", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: "<tmp>")
        }
        return result
    }

    /// 按字节截断（尾部保留，前缀标记）
    static func truncate(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let suffix = String(text.suffix(maxBytes / 2))
        return "…（已截断）…\n" + suffix
    }

    // MARK: - 组装文档

    /// 生成一份完整上报文档
    /// - Parameters:
    ///   - trigger: 触发来源
    ///   - issues: 聚合后的错误（已按指纹合并）
    ///   - host: 环境快照
    ///   - user: 用户填写内容
    ///   - includeLogs / includeCrash / includeConfig: 用户勾选的收集项
    ///   - previousSessionCrashed: 上次是否异常退出
    static func makeDocument(trigger: ReportTrigger,
                             issues: [CapturedIssue],
                             host: HostInfo,
                             user: UserInfo,
                             includeLogs: Bool,
                             includeCrash: Bool,
                             includeConfig: Bool,
                             previousSessionCrashed: Bool) -> ReportDocument {
        let now = Date()
        let limited = Array(issues.sorted { $0.severity > $1.severity }
                                  .prefix(ReportScope.maxErrorsPerReport))

        // 报告整体严重度 = 最严重的那个
        let severity = limited.map(\.severity).max() ?? (trigger == .manual ? .info : .warning)

        // 报告指纹：手动反馈按内容区分，自动上报按最严重错误的指纹
        let reportFingerprint: String
        if let first = limited.first(where: { $0.severity == severity }) ?? limited.first {
            reportFingerprint = first.fingerprint
        } else {
            reportFingerprint = ReportFingerprint.hash([
                "manual", trigger.rawValue, ScopeBuild.bundleID,
                user.description, ReportJSON.isoString(now),
            ])
        }

        var collected: [String] = ["environment", "errors"]
        if includeLogs { collected.append("logs") }
        if includeCrash { collected.append("crash") }
        if includeConfig { collected.append("config") }
        var excluded: [String] = []
        if !includeLogs { excluded.append("logs") }
        if !includeCrash { excluded.append("crash") }
        if !includeConfig { excluded.append("config") }

        return ReportDocument(
            report: ReportHeader(
                id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                createdAt: now,
                trigger: trigger,
                severity: severity,
                fingerprint: reportFingerprint,
                occurredAt: limited.map(\.firstSeen).min() ?? now,
                appUptimeSeconds: host.uptime,
                previousSessionCrashed: previousSessionCrashed),
            scope: ScopeInfo(
                project: ReportScope.project,
                channel: ReportScope.channel,
                bundleID: ScopeBuild.bundleID,
                appVersion: host.appVersion,
                appBuild: host.appBuild,
                schemaVersion: ReportScope.schemaVersion),
            errors: limited.map { $0.entry() },
            environment: environment(from: host),
            user: user,
            consent: ConsentInfo(granted: true, collected: collected, excluded: excluded),
            logs: includeLogs ? collectLogs() : nil,
            crash: includeCrash ? collectCrash() : nil,
            configSnapshot: includeConfig ? host.config : nil)
    }
}

// MARK: - 构建信息

enum ScopeBuild {
    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.zekiwithcat.TouchpadGestures"
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }
}
