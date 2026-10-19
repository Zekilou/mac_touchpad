import Foundation
import GestureEngine

// MARK: - 诊断包导出（正式版可用）
//
// 「不想上传」时的替代路径：内容与上报一致，但落成本地文件夹，用户自己决定怎么给。
// 与上报共享脱敏逻辑（DiagnosticsCollector.redact），避免两条路径出现隐私口径差异。

enum DiagnosticsExporter {

    /// 生成诊断包文件夹（写入 parent 下 TouchpadGestures-Diagnostics-<时间戳>/）
    /// - Returns: 生成的文件名列表
    @discardableResult
    static func writeDiagnostics(to parent: URL,
                                 includeConfig: Bool,
                                 includeLogs: Bool,
                                 includeCrash: Bool,
                                 environment: String,
                                 configData: Data?) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let dir = parent.appendingPathComponent(
            "TouchpadGestures-Diagnostics-\(formatter.string(from: Date()))",
            isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            fputs("[Diagnostics] 创建目录失败: \(error)\n", stderr)
            return []
        }

        var written: [String] = []

        // 1. 环境信息
        write(environment, name: "diagnostics.txt", to: dir, into: &written)

        // 2. config.json 副本
        if includeConfig, let configData {
            let url = dir.appendingPathComponent("config.json")
            do {
                try configData.write(to: url)
                written.append("config.json")
            } catch {
                fputs("[Diagnostics] 写 config.json 失败: \(error)\n", stderr)
            }
        }

        // 3. 日志（内存环形缓冲 + 可选落盘日志 + 结构化诊断事件）
        if includeLogs {
            write(DiagnosticsCollector.collectLogs(), name: "engine.log", to: dir, into: &written)
        }

        // 4. 崩溃日志（含面包屑）
        if includeCrash, let crash = DiagnosticsCollector.collectCrash() {
            write(crash, name: "crash.log", to: dir, into: &written)
        }

        return written
    }

    private static func write(_ text: String, name: String, to dir: URL,
                              into written: inout [String]) {
        guard !text.isEmpty else { return }
        let url = dir.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            written.append(name)
        } catch {
            fputs("[Diagnostics] 写 \(name) 失败: \(error)\n", stderr)
        }
    }
}
