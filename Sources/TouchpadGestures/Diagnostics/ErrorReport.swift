import Foundation
import CryptoKit
import GestureEngine

// MARK: - 上报数据模型（契约 v1，见 docs/debug-upload-contract.md）
//
// 设计原则：整条上报 = 一个自包含 JSON 文档。日志/崩溃都以字符串内嵌，
// 不用 multipart —— 数据的最终读者是人，单文件最省事。

// MARK: - 触发来源 / 严重度

enum ReportTrigger: String, Codable {
    /// 崩溃后下次启动生成
    case crash
    /// 运行中捕获的可恢复错误
    case error
    /// 用户主动反馈
    case manual
}

enum ReportSeverity: String, Codable, Comparable {
    case fatal, error, warning, info

    /// 排序用（fatal 最大）
    private var rank: Int {
        switch self {
        case .fatal: return 3
        case .error: return 2
        case .warning: return 1
        case .info: return 0
        }
    }

    static func < (lhs: ReportSeverity, rhs: ReportSeverity) -> Bool {
        lhs.rank < rhs.rank
    }

    var localizedName: String {
        switch self {
        case .fatal:   return L10n.tr("致命", "Fatal")
        case .error:   return L10n.tr("错误", "Error")
        case .warning: return L10n.tr("警告", "Warning")
        case .info:    return L10n.tr("提示", "Info")
        }
    }
}

// MARK: - 文档根

struct ReportDocument: Codable {
    var schemaVersion: Int = ReportScope.schemaVersion
    var report: ReportHeader
    var scope: ScopeInfo
    var errors: [ErrorEntry]
    var environment: EnvironmentInfo
    var user: UserInfo
    var consent: ConsentInfo
    var logs: String?
    var crash: String?
    var configSnapshot: AppConfig?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case report, scope, errors, environment, user, consent, logs, crash
        case configSnapshot = "config_snapshot"
    }
}

struct ReportHeader: Codable {
    var id: String
    var createdAt: Date
    var trigger: ReportTrigger
    var severity: ReportSeverity
    var fingerprint: String
    var occurredAt: Date
    var appUptimeSeconds: Double
    var previousSessionCrashed: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case trigger, severity, fingerprint
        case occurredAt = "occurred_at"
        case appUptimeSeconds = "app_uptime_seconds"
        case previousSessionCrashed = "previous_session_crashed"
    }
}

struct ScopeInfo: Codable {
    var project: String
    var channel: String
    var bundleID: String
    var appVersion: String
    var appBuild: String
    var schemaVersion: Int

    enum CodingKeys: String, CodingKey {
        case project, channel
        case bundleID = "bundle_id"
        case appVersion = "app_version"
        case appBuild = "app_build"
        case schemaVersion = "schema_version"
    }
}

struct ErrorEntry: Codable {
    var fingerprint: String
    var domain: String
    var code: String
    var message: String
    var count: Int
    var firstSeen: Date
    var lastSeen: Date
    var stack: [String]
    var context: [String: String]

    enum CodingKeys: String, CodingKey {
        case fingerprint, domain, code, message, count
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
        case stack, context
    }
}

struct EnvironmentInfo: Codable {
    var osVersion: String
    var arch: String
    var model: String
    var locale: String
    var language: String
    var permissions: Permissions
    var trackpad: Trackpad
    var engine: EngineState
    var config: ConfigSummary

    enum CodingKeys: String, CodingKey {
        case osVersion = "os_version"
        case arch, model, locale, language
        case permissions, trackpad, engine, config
    }

    struct Permissions: Codable {
        var accessibility: String
        var inputMonitoring: String

        enum CodingKeys: String, CodingKey {
            case accessibility
            case inputMonitoring = "input_monitoring"
        }
    }

    struct Trackpad: Codable {
        var deviceID: UInt64
        var deviceCount: Int32
        var ready: Bool

        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id"
            case deviceCount = "device_count"
            case ready
        }
    }

    struct EngineState: Codable {
        var running: Bool
        var holding: Bool
        var idleSlowed: Bool

        enum CodingKeys: String, CodingKey {
            case running, holding
            case idleSlowed = "idle_slowed"
        }
    }

    struct ConfigSummary: Codable {
        var gestures: Int
        var events: Int
        var regions: Int
        var version: Int
    }
}

struct UserInfo: Codable {
    var description: String
    var steps: String
    var contact: String

    static let empty = UserInfo(description: "", steps: "", contact: "")
}

struct ConsentInfo: Codable {
    var granted: Bool
    var collected: [String]
    var excluded: [String]
}

// MARK: - 内存中的错误聚合体
//
// 采集期用这个（含 severity / 稳定指纹 / 上下文），
// 生成文档时转成 ErrorEntry（契约里不带 severity，靠 report.severity 表达）。

struct CapturedIssue: Identifiable {
    let fingerprint: String
    let domain: String
    let code: String
    let message: String
    let severity: ReportSeverity
    let stack: [String]
    let context: [String: String]
    var count: Int
    let firstSeen: Date
    var lastSeen: Date

    var id: String { fingerprint }

    /// 转契约条目
    func entry() -> ErrorEntry {
        ErrorEntry(fingerprint: fingerprint, domain: domain, code: code, message: message,
                   count: count, firstSeen: firstSeen, lastSeen: lastSeen,
                   stack: stack, context: context)
    }
}

// MARK: - JSON 编解码（统一日期格式：ISO 8601 带本地时区偏移）

enum ReportJSON {

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(isoString(date))
        }
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = isoFormatter.date(from: s) ?? isoFormatterNoFraction.date(from: s) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "无法解析时间: \(s)")
        }
        return d
    }()

    /// 契约要求带时区偏移；用当前时区（+08:00 这种），便于人直接阅读
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    static func isoString(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    /// UI 显示的本地短时间（HH:mm:ss）
    static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - 稳定指纹

enum ReportFingerprint {

    /// SHA256（跨运行稳定）截取 16 位十六进制。
    ///
    /// 不用 `Hasher` / `String.hashValue`：它们每次进程启动随机加盐，
    /// 同一错误在两次启动里会得到不同指纹 → 去重和"每会话只弹一次"全部失效。
    static func hash(_ components: [String]) -> String {
        // 用 \u{1F}（单元分隔符）连接，避免 ["ab","c"] 与 ["a","bc"] 撞车
        let joined = components.joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:" + hex.prefix(16)
    }
}
