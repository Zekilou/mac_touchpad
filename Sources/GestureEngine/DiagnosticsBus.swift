import Foundation

// MARK: - 引擎侧诊断总线
//
// **正式版可用**（不再用 #if DEBUG 排除）。
// GestureEngine 不能依赖 AppKit / 网络，因此这里只做两件事：
//   1. 接收结构化诊断事件（错误 / 警告），线程安全地存进环形缓冲；
//   2. 供 App 侧 ReportCenter 拉取 / 订阅。
// 是否弹窗、是否上传、是否脱敏，全部由 App 层决定。

// MARK: - 事件

public struct DiagnosticEvent: Sendable {
    public enum Kind: String, Sendable {
        case error
        case warning
        case info
    }

    /// 稳定命名空间（见契约 4.1），如 com.touchpad.graph
    public let domain: String
    /// 稳定错误码（同一含义永远同一 code）
    public let code: String
    /// 面向人的一句话描述（可含用户手势名）
    public let message: String
    public let kind: Kind
    /// 可选堆栈（调用方传入，最多保留前 8 帧）
    public let stack: [String]
    /// 可选结构化上下文（值已转字符串）
    public let context: [String: String]
    public let time: Date
    /// 出错时线程（signal handler 里不会走到这）
    public let isMainThread: Bool

    public init(domain: String, code: String, message: String,
                kind: Kind = .error,
                stack: [String] = [],
                context: [String: String] = [:]) {
        self.domain = domain
        self.code = code
        self.message = message
        self.kind = kind
        self.stack = Array(stack.prefix(8))
        self.context = context
        self.time = Date()
        self.isMainThread = Thread.isMainThread
    }
}

// MARK: - 总线

public enum DiagnosticsBus {

    /// 缓冲上限（低频事件，200 条足够；溢出丢弃最旧）
    public static let capacity = 200

    private static let lock = NSLock()
    private static var ring: [DiagnosticEvent] = []
    /// 每个事件的累计次数（key = domain|code）——同一问题反复出现只占一条
    private static var counts: [String: Int] = [:]
    /// 首次出现时间
    private static var firstSeen: [String: Date] = [:]

    /// App 层订阅（在锁外回调，避免持有锁调用外部代码）
    private static var observers: [(DiagnosticEvent) -> Void] = []

    /// 自动采集开关。关闭后 error/warning 一律丢弃（info 也丢），
    /// 由 App 层在启动时按用户偏好设置。
    public static var isEnabled = true

    // MARK: - 写入

    public static func report(domain: String, code: String, message: String,
                              kind: DiagnosticEvent.Kind = .error,
                              stack: [String] = [],
                              context: [String: String] = [:],
                              file: String = #fileID, line: Int = #line) {
        guard isEnabled else { return }
        var stack = stack
        if stack.isEmpty {
            // 调用点作为最小线索（完整符号栈对 Swift 帮助有限，且体积大）
            stack = ["\(file):\(line)"]
        }
        let event = DiagnosticEvent(domain: domain, code: code, message: message,
                                    kind: kind, stack: stack, context: context)
        record(event)
    }

    /// 直接投递已构造好的事件（崩溃恢复等场景）
    public static func record(_ event: DiagnosticEvent) {
        guard isEnabled else { return }
        let key = event.domain + "|" + event.code

        lock.lock()
        counts[key, default: 0] += 1
        if firstSeen[key] == nil { firstSeen[key] = event.time }
        ring.append(event)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        let snapshot = observers
        lock.unlock()

        for observer in snapshot { observer(event) }
    }

    // MARK: - 读取

    public struct Aggregate {
        public let domain: String
        public let code: String
        public let severity: DiagnosticEvent.Kind
        public let message: String
        public let stack: [String]
        public let context: [String: String]
        public let count: Int
        public let firstSeen: Date
        public let lastSeen: Date
    }

    /// 按 domain|code 聚合的全部事件（最近一条的内容为准）
    public static func aggregates() -> [Aggregate] {
        lock.lock()
        defer { lock.unlock() }
        var byKey: [String: Aggregate] = [:]
        for e in ring {
            let key = e.domain + "|" + e.code
            let count = counts[key] ?? 1
            let first = firstSeen[key] ?? e.time
            if let existing = byKey[key] {
                byKey[key] = Aggregate(domain: existing.domain, code: existing.code,
                                       severity: existing.severity,
                                       message: existing.message,
                                       stack: existing.stack,
                                       context: existing.context,
                                       count: count, firstSeen: first,
                                       lastSeen: e.time)
            } else {
                byKey[key] = Aggregate(domain: e.domain, code: e.code,
                                       severity: e.kind, message: e.message,
                                       stack: e.stack, context: e.context,
                                       count: count, firstSeen: first,
                                       lastSeen: e.time)
            }
        }
        return byKey.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// 原始事件（按时间顺序；导出日志时用）
    public static var events: [DiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return ring
    }

    /// 订阅（App 层用来即时弹窗）。返回取消闭包。
    @discardableResult
    public static func observe(_ handler: @escaping (DiagnosticEvent) -> Void) -> () -> Void {
        lock.lock()
        let token = UUID()
        tokens[token] = handler
        observers = Array(tokens.values)
        lock.unlock()
        return {
            lock.lock()
            tokens[token] = nil
            observers = Array(tokens.values)
            lock.unlock()
        }
    }

    private static var tokens: [UUID: (DiagnosticEvent) -> Void] = [:]

    /// 清空（用户关闭自动采集 / 测试用）
    public static func clear() {
        lock.lock()
        ring.removeAll(keepingCapacity: true)
        counts.removeAll(keepingCapacity: true)
        firstSeen.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

// MARK: - 便捷入口（domain 固定，减少调用点噪音）

public extension DiagnosticsBus {
    static func config(_ code: String, _ message: String,
                       context: [String: String] = [:],
                       kind: DiagnosticEvent.Kind = .error) {
        report(domain: "com.touchpad.config", code: code, message: message,
               kind: kind, context: context)
    }

    static func graph(_ code: String, _ message: String,
                      context: [String: String] = [:]) {
        report(domain: "com.touchpad.graph", code: code, message: message,
               kind: .error, context: context)
    }

    static func trackpad(_ code: String, _ message: String,
                         context: [String: String] = [:],
                         kind: DiagnosticEvent.Kind = .error) {
        report(domain: "com.touchpad.trackpad", code: code, message: message,
               kind: kind, context: context)
    }

    static func permission(_ code: String, _ message: String,
                           context: [String: String] = [:]) {
        report(domain: "com.touchpad.permission", code: code, message: message,
               kind: .warning, context: context)
    }

    static func system(_ code: String, _ message: String,
                       context: [String: String] = [:],
                       kind: DiagnosticEvent.Kind = .warning) {
        report(domain: "com.touchpad.system", code: code, message: message,
               kind: kind, context: context)
    }
}
