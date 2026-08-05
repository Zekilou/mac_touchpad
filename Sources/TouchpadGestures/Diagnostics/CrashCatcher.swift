import Foundation
import Darwin

// MARK: - 崩溃捕获（可插拔诊断模块，仅 DEBUG 构建编译）
// 正式 release 构建（#if DEBUG 排除）完全不含崩溃捕获——"诊断模块不进正式版"。
// 捕获 NSException + 常见 signal（ABRT/SEGV/BUS/ILL/FPE/TRAP），崩溃信息写入
// Application Support/TouchpadGestures/Diagnostics/crash-<时间戳>.log，
// 诊断模块导出时一并打包，用户手动发送给开发者。

#if DEBUG

enum CrashCatcher {

    /// 诊断目录（崩溃日志存放处）
    static let diagnosticsDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TouchpadGestures", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// 新崩溃日志路径（时间戳命名）
    static func newCrashURL() -> URL {
        diagnosticsDir.appendingPathComponent("crash-\(timestampFormatter.string(from: Date())).log")
    }

    /// 未导出的崩溃日志列表（诊断模块列出）
    static func pendingCrashLogs() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: diagnosticsDir,
                                                      includingPropertiesForKeys: nil)) ?? []
    }

    // MARK: - 安装

    /// 安装崩溃捕获（App 启动时调用；release 构建不编译本文件 → 无调用）
    static func install() {
        // NSException（Swift 越界/断言等走 signal，ObjC 运行时错误走这里）
        NSSetUncaughtExceptionHandler { exception in
            let content = """
            NSException: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "?")
            UserInfo: \(exception.userInfo ?? [:])

            Stack:
            \(exception.callStackSymbols.joined(separator: "\n"))

            """
            try? content.write(to: CrashCatcher.newCrashURL(), atomically: true, encoding: .utf8)
        }

        // signal（Swift fatalError/强制解包/内存错误）
        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]
        for sig in signals {
            signal(sig, signalHandler)
        }

        // 预缓存（signal handler 必须用 async-signal-safe 的预构建值，不能分配内存）
        cacheSignalContext()
    }

    // MARK: - signal handler（async-signal-safe：只用 open/write/close/strlen/signal/raise + 预构建字符串）

    private static var cachedPath: UnsafeMutablePointer<CChar>?
    private static var cachedTimestamp: UnsafeMutablePointer<CChar>?
    private static var cachedNames: [Int32: UnsafeMutablePointer<CChar>] = [:]

    private static func cacheSignalContext() {
        cachedPath = strdup(newCrashURL().path)
        cachedTimestamp = strdup(formattedNow())
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
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

    /// C 函数指针（signal handler）：写崩溃日志 → 恢复默认 → 重新触发（让系统也记录）
    private static let signalHandler: @convention(c) (Int32) -> Void = { sig in
        guard let path = CrashCatcher.cachedPath,
              let ts = CrashCatcher.cachedTimestamp else {
            signal(sig, SIG_DFL)
            raise(sig)
            return
        }
        let name = CrashCatcher.cachedNames[sig] ?? CrashCatcher.cachedNames[SIGABRT]!
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            _ = write(fd, "Signal: ", 8)
            _ = write(fd, name, Int(strlen(name)))
            _ = write(fd, " at ", 4)
            _ = write(fd, ts, Int(strlen(ts)))
            _ = write(fd, "\n", 1)
            close(fd)
        }
        // 恢复默认 handler 并重抛，让系统 crash reporter 也记录（并终止进程）
        signal(sig, SIG_DFL)
        raise(sig)
    }
}

#endif
