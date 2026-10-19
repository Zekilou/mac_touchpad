import Foundation

// MARK: - 诊断日志环形缓冲
//
// **正式版可用**：错误上报需要最近一段日志做上下文，崩溃时也要能带走。
// 成本：每次 log 一次锁 + 数组追加（微秒级），缓冲上限 300 条 → 常驻几十 KB。
// 与 EngineLog（/tmp 落盘、默认关闭）分工：本缓冲只在内存，随进程结束消失，
// 由上报模块读取；不写磁盘，不产生常驻 IO。

/// 诊断日志缓冲（线程安全环形数组）
public enum DiagnosticsLog {
    /// 缓冲上限（条）；超过丢弃最旧
    public static let capacity = 300

    private static let lock = NSLock()
    private static var buffer: [String] = []
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// 追加一条日志（线程安全；满则滚动丢弃最旧）
    public static func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "[\(dateFormatter.string(from: Date()))] \(message)"
        buffer.append(line)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
    }

    /// 全部缓冲日志（按时间顺序）
    public static var contents: [String] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    /// 清空（导出后/测试用）
    public static func clear() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: true)
    }
}
