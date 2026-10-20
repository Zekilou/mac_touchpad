import XCTest
@testable import GestureEngine

// MARK: - 国际化守门（源码级）
//
// 这些断言的共同目标：把「只在中英文切换时才暴露、且不会编译失败」的问题
// 变成红灯。它们扫 Sources/ 下的真实源码，不依赖运行时。

final class L10nSourceGuardTests: XCTestCase {

    /// 扫描器自检：确认真的扫到了词条。
    ///
    /// 没有这条，下面几个守门测试在「正则写错 / 路径解析错」时会零命中通过 ——
    /// 看起来全绿，实际什么都没守。
    func testScannerFindsExpectedNumberOfTranslations() throws {
        let root = try SourceScanner.repositoryRoot()
        var total = 0
        for (_, source) in try SourceScanner.swiftSources(under: root) {
            total += SourceScanner.translationPairs(in: source).count
        }
        XCTAssertGreaterThan(total, 400,
                             "只扫到 \(total) 条 tr()，扫描器可能没生效（本仓库应有 460+ 条）")
    }

    /// 英文侧不得残留中日韩字符 —— 这类问题不会编译失败，
    /// 只会在英文界面上露出半个中文句子。
    func testEnglishSideOfEveryTranslationHasNoCJK() throws {
        let root = try SourceScanner.repositoryRoot()
        var offenders: [String] = []
        for (file, source) in try SourceScanner.swiftSources(under: root) {
            for pair in SourceScanner.translationPairs(in: source)
            where SourceScanner.containsCJK(pair.en) {
                offenders.append("\(file):\(pair.line)  en=\(pair.en)  zh=\(pair.zh)")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "英文文案里混入了中文（\(offenders.count) 处）：\n"
                      + offenders.joined(separator: "\n"))
    }

    /// 双语占位符必须一一对应：少一个会丢参数，多一个会显示错值。
    func testInterpolationPlaceholdersMatchOnBothSides() throws {
        let root = try SourceScanner.repositoryRoot()
        var offenders: [String] = []
        for (file, source) in try SourceScanner.swiftSources(under: root) {
            for pair in SourceScanner.translationPairs(in: source) {
                let zhCount = SourceScanner.interpolationCount(pair.zh)
                let enCount = SourceScanner.interpolationCount(pair.en)
                guard zhCount != enCount else { continue }
                offenders.append("\(file):\(pair.line)  zh \(zhCount) 处 / en \(enCount) 处\n"
                                 + "    zh: \(pair.zh)\n    en: \(pair.en)")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "双语插值数量不一致（\(offenders.count) 处）：\n"
                      + offenders.joined(separator: "\n"))
    }

    /// 禁止「假翻译」：`tr("xMin", "xMin")` 这类两侧完全相同的条目会虚增覆盖率，
    /// 让真正的漏翻被掩盖。纯标识符/符号应直接用字面量，不要套 tr()。
    func testNoIdentityTranslations() throws {
        let root = try SourceScanner.repositoryRoot()
        var offenders: [String] = []
        for (file, source) in try SourceScanner.swiftSources(under: root) {
            for pair in SourceScanner.translationPairs(in: source) where pair.zh == pair.en {
                offenders.append("\(file):\(pair.line)  \(pair.zh)")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "两侧文案完全相同，应按字面量处理而不是 tr()（\(offenders.count) 处）：\n"
                      + offenders.joined(separator: "\n"))
    }

    /// 省略号统一用 U+2026（…），不用 ASCII 三点 `...`。
    /// 菜单项 / 按钮文案里两者混用是肉眼可见的不一致。
    func testMenuTitlesUseTypographicEllipsis() throws {
        let root = try SourceScanner.repositoryRoot()
        var offenders: [String] = []
        for (file, source) in try SourceScanner.swiftSources(under: root) where file.contains("/Views/")
            || file.hasSuffix("App.swift") {
            for pair in SourceScanner.translationPairs(in: source)
            where pair.zh.contains("...") || pair.en.contains("...") {
                offenders.append("\(file):\(pair.line)  zh=\(pair.zh)  en=\(pair.en)")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "省略号应统一为 …（\(offenders.count) 处）：\n"
                      + offenders.joined(separator: "\n"))
    }
}
