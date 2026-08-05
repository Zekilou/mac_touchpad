import Foundation

// MARK: - 诊断日志环形缓冲（可插拔诊断模块）
// 仅 DEBUG 构建编译（#if DEBUG）——正式 release 构建完全排除（"诊断模块不进正式版"）
// 用途：手势引擎/节点执行器的日志统一写入环形缓冲（最近 N 条），
// 崩溃后由诊断模块导出为 engine.log，供开发者排查行为问题。
// 成本：每次 log 一次锁 + 数组追加，微秒级，常驻无碍。

#if DEBUG

/// 诊断日志缓冲（线程安全环形数组）
public enum DiagnosticsLog {
    /// 缓冲上限（条）；超过丢弃最旧
    public static let capacity = 200

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

#endif
