import XCTest
@testable import GestureEngine

// MARK: - 源码扫描工具（GestureEngineTests 侧副本）
//
// ReportTests 有一份同样的 `SourceScanner`（两 target 不能互相 import）。
// 两边都只是纯函数，改动时请同步。

enum SourceScanner {

    /// 定位仓库根：从调用文件路径向上找含 Package.swift + .git 的目录
    static func repositoryRoot(file: StaticString = #filePath) throws -> URL {
        var url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url
            }
            url = url.deletingLastPathComponent()
        }
        throw XCTSkip("找不到仓库根（\(file) 向上 8 层内没有 Package.swift/.git），跳过源码扫描")
    }

    /// 枚举 Sources 下的 .swift 文件（相对路径, 内容），按路径排序保证失败信息稳定
    static func swiftSources(under root: URL) throws -> [(String, String)] {
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw XCTSkip("Sources 目录不存在：\(sources.path)")
        }
        var result: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            result.append((relative, text))
        }
        return result.sorted { $0.0 < $1.0 }
    }

    /// 抽取所有成对 `L10n.tr("zh", "en")`（单行与跨行都覆盖）
    static func translationPairs(in source: String) -> [(zh: String, en: String, line: Int)] {
        let pattern = #"L10n\.tr\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                    options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let ns = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).map { match in
            let zh = ns.substring(with: match.range(at: 1))
            let en = ns.substring(with: match.range(at: 2))
            let prefix = source[..<source.index(source.startIndex, offsetBy: match.range.location)]
            let line = prefix.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } + 1
            return (zh: zh, en: en, line: line)
        }
    }

    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return true
            default: return false
            }
        }
    }

    /// Swift 字符串插值 `\(...)` 的个数
    static func interpolationCount(_ text: String) -> Int {
        var count = 0
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if text[index] == "\\", next < text.endIndex, text[next] == "(" {
                count += 1
                index = text.index(index, offsetBy: 2)
                continue
            }
            index = next
        }
        return count
    }
}
