import Foundation

/// 引擎诊断日志：stderr + 落盘 /tmp/touchpad_run.log（.app 环境下 stderr 用户看不到，
/// 落盘后用户可 `tail -f /tmp/touchpad_run.log` 实时观察 finger/quantize/holding 链路）
/// 大小上限 512KB，超出后清空重写（防日志膨胀占满 /tmp）
public enum EngineLog {
    public static let url = URL(fileURLWithPath: "/tmp/touchpad_run.log")
    private static let lock = NSLock()
    private static let maxBytes = 512 * 1024
    private static var cachedSize = -1

    public static func append(_ msg: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "[\(timestamp())] " + msg
        fputs(line + "\n", stderr)
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if cachedSize < 0 {
            cachedSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        }
        if cachedSize > maxBytes {
            try? FileManager.default.removeItem(at: url)
            cachedSize = 0
        }
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            fh.seekToEndOfFile()
            fh.write(data)
            cachedSize += data.count
        } else {
            try? data.write(to: url)
            cachedSize = data.count
        }
    }

    /// 锁内读取全部日志内容（诊断导出用；文件可能正在被追加，读到半行可接受）
    public static var contents: String {
        lock.lock()
        defer { lock.unlock() }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
