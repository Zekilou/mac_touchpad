import Foundation

// MARK: - 上报通道常量
//
// 所有与 debug.zeki.casa 相关的固定值集中在这里，便于轮换 token / 换域名。
// 契约见 docs/debug-upload-contract.md。

enum ReportScope {

    // MARK: - 作用域

    /// 项目作用域。debug.zeki.casa 同时接多个软件的上报：
    /// 既作为 URL 第一段（主路由依据），也作为 X-Debug-Scope 头与 body 的 scope.project。
    static let project = "touchpad-gestures"

    /// 构建通道（正式版 / 开发版），仅作区分，不影响是否上报
    static var channel: String {
        #if DEBUG
        return "dev"
        #else
        return "release"
        #endif
    }

    // MARK: - 端点
    //
    // 项目名在路径里：debug.zeki.casa 同时接多个软件的上报，
    // 后端按路径第一段直接路由/分目录，不解析 body。
    /// 调试期覆盖（正式版恒为 nil）：指向本地 probe 服务验证契约
    static var endpointOverride: URL?

    static var endpoint: URL {
        endpointOverride ?? URL(string: "https://debug.zeki.casa/\(project)/v1/report")!
    }

    static let schemaVersion = 1

    /// 客户端内置 token（服务端登记，用于挡住随手刷接口；可被逆向，主要配合服务端限流）
    static let clientToken = "8bd77558e9348eb9b45b9b41312fd71a"

    // MARK: - 限额（与契约一致）

    static let maxBodyBytes = 5 * 1024 * 1024
    static let maxLogBytes = 256 * 1024
    static let maxCrashBytes = 128 * 1024
    static let maxErrorsPerReport = 50
    static let maxOutboxCount = 10

    // MARK: - 网络

    static let requestTimeout: TimeInterval = 20
    static let retryDelays: [TimeInterval] = [2, 8, 30]

    // MARK: - 本地目录

    /// 测试注入：重定向根目录，避免单测写进用户真实的 Application Support
    /// （与 ConfigStore.overrideConfigURL 同一思路：测试绝不能碰用户数据）
    static var overrideSupportDir: URL?

    /// Application Support/TouchpadGestures
    static var supportDir: URL {
        if let override = overrideSupportDir {
            try? FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
            return override
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TouchpadGestures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 上报相关本地状态根目录
    static var reportsDir: URL {
        let dir = supportDir.appendingPathComponent("Reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 已采集、等待用户确认的报告
    static var draftsDir: URL {
        let dir = reportsDir.appendingPathComponent("drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 用户已确认、等待上传的报告
    static var outboxDir: URL {
        let dir = reportsDir.appendingPathComponent("outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 崩溃日志 / 会话标记
    static var diagnosticsDir: URL {
        let dir = supportDir.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - 用户偏好的 key

enum ReportPrefs {
    /// 自动采集（崩溃日志 / 错误事件）。关闭后不记录任何诊断信息。
    static let autoCollect = "report.autoCollect"
    /// 未确认的报告最多保留天数
    static let draftTTLDays = 7

    /// 默认开启自动采集
    static var isAutoCollectEnabled: Bool {
        UserDefaults.standard.object(forKey: autoCollect) as? Bool ?? true
    }
}
