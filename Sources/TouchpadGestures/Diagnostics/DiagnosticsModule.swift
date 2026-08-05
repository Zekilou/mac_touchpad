import Foundation
import GestureEngine

// MARK: - 诊断模块（可插拔，仅 DEBUG 构建编译）
// 正式 release 构建（#if DEBUG 排除）完全不含本模块——"诊断模块不进正式版"。
// 用途：收集环境信息 / config.json 副本 / 引擎日志（环形缓冲）/ 崩溃日志，
// 导出为文件夹（TouchpadGestures-Diagnostics-<时间戳>），用户手动发送给开发者。
// 收集项可配置（UserDefaults，设置页「诊断」卡片勾选，默认全开）。

#if DEBUG

enum DiagnosticsModule {

    /// 收集项开关 key（与设置页 @AppStorage 一致）
    static let keyEnvironment = "diag.includeEnvironment"
    static let keyConfig      = "diag.includeConfig"
    static let keyLogs        = "diag.includeLogs"
    static let keyCrash       = "diag.includeCrash"

    // MARK: - 环境信息

    /// 环境信息文本（诊断包 diagnostics.txt）
    static func environmentText(deviceID: UInt64, deviceCount: Int32,
                                inputMonitoringOK: Bool, accessibilityOK: Bool,
                                appVersion: String, appBuild: String,
                                language: AppLanguage,
                                gestureNames: [String], eventCount: Int, regionCount: Int) -> String {
        var lines: [String] = []
        lines.append("Touchpad Gestures 诊断包")
        lines.append("生成时间: \(Date())")
        lines.append("App 版本: \(appVersion) (\(appBuild))")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("机型: \(machineModel)")
        lines.append("触控板设备 ID: \(deviceID) (设备数: \(deviceCount))")
        lines.append("权限: 输入监控=\(inputMonitoringOK ? "已授权" : "未授权")  辅助功能=\(accessibilityOK ? "已授权" : "未授权")")
        lines.append("界面语言: \(language.displayName)")
        lines.append("手势数: \(gestureNames.count) (\(gestureNames.joined(separator: ", ")))")
        lines.append("事件数: \(eventCount)  区域数: \(regionCount)")
        return lines.joined(separator: "\n") + "\n"
    }

    /// 机型（sysctl hw.model）
    private static var machineModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    // MARK: - 导出

    /// 生成诊断包文件夹（写入指定目录下 TouchpadGestures-Diagnostics-<时间戳>/）
    /// - Returns: 生成的文件名列表（失败信息打印 stderr）
    static func writeDiagnostics(to parent: URL,
                                 includeConfig: Bool, includeLogs: Bool, includeCrash: Bool,
                                 environment: String, configData: Data?) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let dir = parent.appendingPathComponent("TouchpadGestures-Diagnostics-\(formatter.string(from: Date()))",
                                                isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var written: [String] = []

        // 1. 环境信息
        do {
            try environment.write(to: dir.appendingPathComponent("diagnostics.txt"),
                                  atomically: true, encoding: .utf8)
            written.append("diagnostics.txt")
        } catch { fputs("[Diagnostics] 写 diagnostics.txt 失败: \(error)\n", stderr) }

        // 2. config.json 副本
        if includeConfig, let configData {
            do {
                try configData.write(to: dir.appendingPathComponent("config.json"))
                written.append("config.json")
            } catch { fputs("[Diagnostics] 写 config.json 失败: \(error)\n", stderr) }
        }

        // 3. 引擎日志（环形缓冲）
        if includeLogs {
            let logs = DiagnosticsLog.contents.joined(separator: "\n") + "\n"
            do {
                try logs.write(to: dir.appendingPathComponent("engine.log"),
                               atomically: true, encoding: .utf8)
                written.append("engine.log")
            } catch { fputs("[Diagnostics] 写 engine.log 失败: \(error)\n", stderr) }
        }

        // 4. 崩溃日志
        if includeCrash {
            let crashes = CrashCatcher.pendingCrashLogs()
            if !crashes.isEmpty {
                let crashDir = dir.appendingPathComponent("crashes", isDirectory: true)
                try? FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: true)
                for url in crashes {
                    let dest = crashDir.appendingPathComponent(url.lastPathComponent)
                    if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                        written.append("crashes/\(url.lastPathComponent)")
                    }
                }
            }
        }

        return written
    }
}

#endif
