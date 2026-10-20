import XCTest
import SwiftUI
import AppKit
@testable import TouchpadGestures
import GestureEngine

// MARK: - 双语渲染守门
//
// 目的不是“截图存证给人看”，而是把两件只在中英文切换时才暴露的问题变成断言：
//   1. 关键页面在 zh / en 下都能渲染出文字（不是空白窗口）；
//   2. 英文标签不能被 150pt 定宽标签列裁掉/折行（中文短、英文长，是中→英最常见的破版点）。
//
// 截图仍会写到 /tmp/touchpad-i18n-shots/，人工复盘时可以直接看。

@MainActor
final class I18nRenderTests: XCTestCase {

    private let shotDir = URL(fileURLWithPath: "/tmp/touchpad-i18n-shots", isDirectory: true)

    override func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        L10n.currentLanguage = .system
        super.tearDown()
    }

    // MARK: - 渲染

    /// 把视图渲成位图；返回 (位图, 视图子树里的所有文本)
    private func render<V: View>(_ view: V, size: CGSize,
                                 name: String) throws -> (NSBitmapImageRep, CGFloat) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: shotDir.appendingPathComponent("\(name).png"))
        return (rep, host.fittingSize.height)
    }

    /// 位图里是否存在「非背景」像素（判断页面没渲染成空白）
    private func hasVisibleContent(_ rep: NSBitmapImageRep) -> Bool {
        guard let data = rep.bitmapData else { return false }
        let samplesPerPixel = rep.bitsPerPixel / 8
        guard samplesPerPixel >= 3 else { return false }
        var nonBackground = 0
        // 抽样：整图逐像素太慢，按 4x4 步长扫（260 万点 → 16 万点，够判定）
        let stepX = max(1, rep.pixelsWide / 256)
        let stepY = max(1, rep.pixelsHigh / 256)
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                let offset = y * rep.bytesPerRow + x * samplesPerPixel
                let r = data[offset], g = data[offset + 1], b = data[offset + 2]
                // 背景是浅灰/白（三通道接近），文字/控件会明显偏离
                if abs(Int(r) - Int(g)) > 12 || abs(Int(g) - Int(b)) > 12 || r < 120 {
                    nonBackground += 1
                    if nonBackground > 200 { return true }
                }
            }
        }
        return false
    }

    // MARK: - 断言：英文标签不超 150pt 定宽列

    /// 所有行内 `Text(tr(...)).frame(width: 150, ...)` 的英文侧必须放得下。
    ///
    /// 这类标签是「左侧定宽标签列 + 右侧控件」的布局；SwiftUI 会给 Text 换行，
    /// 换行后行高变化、与右侧控件基线错位 —— 中文 4 个字（~52pt）永远测不出来。
    func testEnglishLabelsFitTheFixedWidthLabelColumn() throws {
        let root = try SourceScanner.repositoryRoot()
        var overflows: [String] = []
        let font = NSFont.systemFont(ofSize: 13)   // SwiftUI body 默认字号

        for (file, source) in try SourceScanner.swiftSources(under: root) {
            guard file.contains("/Views/") else { continue }
            let lines = source.components(separatedBy: "\n")
            for pair in SourceScanner.translationPairs(in: source) {
                // 该 tr() 所在行起 3 行内出现 width: 150 → 视为定宽标签列
                // （不用跨行正则：`(.|\n)*?` 在这个文件长度上会灾难性回溯）
                let start = max(0, pair.line - 1)
                let window = lines[start..<min(lines.count, start + 3)].joined(separator: "\n")
                guard window.contains("width: 150") else { continue }
                let width = (pair.en as NSString).size(withAttributes: [.font: font]).width
                guard width > 150 else { continue }
                let formatted = String(format: "%.1f", width)
                overflows.append("\(file):\(pair.line)  \"\(pair.en)\" = \(formatted)pt > 150pt")
            }
        }
        XCTAssertTrue(overflows.isEmpty,
                      "英文标签超出 150pt 定宽列，会折行/被裁（\(overflows.count) 处）：\n"
                      + overflows.joined(separator: "\n"))
    }

    // MARK: - 渲染守门

    func testOnboardingRendersInBothLanguages() throws {
        let perm = PermissionManager()
        for lang in [AppLanguage.zh, .en] {
            L10n.currentLanguage = lang
            let (rep, _) = try render(
                OnboardingView(permissionManager: perm, appVersion: "2.1.3", onFinish: {}),
                size: CGSize(width: 520, height: 460),
                name: "onboarding-\(lang.rawValue)")
            XCTAssertTrue(hasVisibleContent(rep), "引导页 \(lang.rawValue) 渲染为空")
        }
    }

    func testBasicGestureSettingsRenderInBothLanguages() throws {
        let cfg = AppConfig()
        let gesture = try XCTUnwrap(cfg.gestures.first)
        for lang in [AppLanguage.zh, .en] {
            L10n.currentLanguage = lang
            let view = BasicGestureSettingsView(
                gesture: .constant(gesture), enabled: .constant(true),
                events: cfg.events, regions: cfg.regions)
                .frame(width: 640, height: 900)
            let (rep, _) = try render(view, size: CGSize(width: 640, height: 900),
                                      name: "basic-\(lang.rawValue)")
            XCTAssertTrue(hasVisibleContent(rep), "基础设置页 \(lang.rawValue) 渲染为空")
        }
    }

    func testEventTabRenderInBothLanguages() throws {
        let cfg = AppConfig()
        let event = try XCTUnwrap(cfg.events.first)
        for lang in [AppLanguage.zh, .en] {
            L10n.currentLanguage = lang
            let view = EventTabView(config: .constant(cfg),
                                    selectedEventID: .constant(event.id))
                .frame(width: 640, height: 820)
            let (rep, _) = try render(view, size: CGSize(width: 640, height: 820),
                                      name: "event-\(lang.rawValue)")
            XCTAssertTrue(hasVisibleContent(rep), "事件页 \(lang.rawValue) 渲染为空")
        }
    }

    // MARK: - 语言热切换（引导窗/报告窗的独立根）

    /// `LanguageRefresh` 必须是「通知一来就重算 body」：
    /// 引导窗/报告面板不在 AppDelegate 观察链上，全靠它才不会停在旧语言。
    func testLanguageRefreshRebuildsBodyOnNotification() throws {
        final class Counter: ObservableObject {
            var builds = 0
        }
        let counter = Counter()
        let host = NSHostingView(rootView: LanguageRefresh { () -> Text in
            counter.builds += 1
            return Text(L10n.tr("中文标题", "English Title"))
        })
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 60)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let initialBuilds = counter.builds
        XCTAssertGreaterThan(initialBuilds, 0, "首帧应至少构建一次")

        L10n.currentLanguage = .en
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertGreaterThan(counter.builds, initialBuilds,
                             "收到 .l10nLanguageDidChange 后应重算 body（否则窗口停留在旧语言）")
    }
}
