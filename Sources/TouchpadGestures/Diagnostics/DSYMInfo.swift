import Foundation

// MARK: - 二进制符号信息
//
// 崩溃报告里只有栈地址。要把地址还原成函数名/行号，需要一个与**确切构建**对应的
// dSYM（UUID 必须一致）。这里读取随包携带的 UUID，随崩溃报告一起上报，
// 后端就能判断该用哪份 dSYM 去符号化——否则收集到的崩溃日志无法定位。

enum DSYMInfo {

    /// 二进制（或 dSYM）的 UUID。优先取包内 dSYM 记录的文件，
    /// 缺失时回退到运行中二进制自身的 LC_UUID。
    static var uuid: String? {
        if let bundled = bundledUUID, !bundled.isEmpty { return bundled }
        return binaryUUID
    }

    static var arch: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// 构建脚本写进 Resources/dSYM/UUID.txt 的值
    private static var bundledUUID: String? {
        guard let url = Bundle.main.url(forResource: "UUID",
                                        withExtension: "txt",
                                        subdirectory: "dSYM"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        // dwarfuuid 输出形如：UUID: 1A2B3C4D-... (arm64) file.dSYM/...
        return extractUUID(from: text)
    }

    /// 直接读运行中二进制的 LC_UUID（随包 dSYM 缺失时的兜底）
    private static var binaryUUID: String? {
        guard let exec = Bundle.main.executableURL else { return nil }
        return uuidOfMachO(at: exec)
    }

    /// 用 `dwarfdump --uuid` 读 Mach-O 的 UUID（系统自带，无需第三方库）
    private static func uuidOfMachO(at url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dwarfdump")
        process.arguments = ["--uuid", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return extractUUID(from: String(decoding: data, as: UTF8.self))
    }

    /// 从任意文本里提取第一个 UUID（8-4-4-4-12 大写十六进制）
    private static func extractUUID(from text: String) -> String? {
        let pattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text,
                                           range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else {
            return nil
        }
        return String(text[range]).uppercased()
    }
}
