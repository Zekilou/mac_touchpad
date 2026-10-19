import XCTest
import SwiftUI
import AppKit
@testable import TouchpadGestures
import GestureEngine

// MARK: - 报告窗口快照
//
// 用 ImageRenderer 把真实 SwiftUI 视图渲成 PNG，人工确认排版（不依赖启动 App）。
// 产物写到 /tmp/touchpad-report-snapshots/，只在调试时查看，不参与断言失败。

@MainActor
final class ReportViewSnapshotTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ReportScope.overrideSupportDir = tempDir
        DiagnosticsBus.clear()
        DiagnosticsBus.isEnabled = true
        ReportCenter.shared.resetForTesting()
    }

    override func tearDownWithError() throws {
        ReportCenter.shared.resetForTesting()
        DiagnosticsBus.clear()
        ReportScope.overrideSupportDir = nil
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testRenderErrorWindow() throws {
        let center = ReportCenter.shared
        center.report(domain: "com.touchpad.graph", code: "invalid_graph",
                      message: "手势「左侧Force」的图非法，已回退空执行器")
        center.report(domain: "com.touchpad.graph", code: "invalid_graph",
                      message: "手势「左侧Force」的图非法，已回退空执行器")
        center.report(domain: "com.touchpad.config", code: "config_corrupted",
                      message: "配置文件损坏，已备份为 config.corrupt-2026-10-19.json 并以默认配置启动")
        center.report(domain: "com.touchpad.trackpad", code: "haptic_device_unavailable",
                      message: "触觉设备 ID 为 0，震动被跳过（手势仍会执行，只是没有反馈）",
                      severity: .warning)

        try render(ReportView(manual: false).environmentObject(center), name: "error-window")
    }

    func testRenderManualWindow() throws {
        let center = ReportCenter.shared
        try render(ReportView(manual: true).environmentObject(center), name: "manual-window")
    }

    // MARK: - 渲染
    //
    // 走真实 AppKit 路径（NSHostingView + 窗口 cacheDisplay），而不是 ImageRenderer：
    // 后者不会布局 ScrollView 内容、也不解析部分按钮样式，截出来的空白是渲染器限制，
    // 很容易被误判成 UI bug。这里渲染的才是用户真正看到的东西。

    private func render<V: View>(_ view: V, name: String) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 620)

        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        window.setFrame(host.frame, display: true)
        // 强制完整布局（SwiftUI 在非显示窗口里也会布局，但需要显式跑一轮 runloop）
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()

        let bounds = host.bounds
        guard let rep = host.bitmapImageRepForCachingDisplay(in: bounds) else {
            return XCTFail("创建位图失败: \(name)")
        }
        host.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("PNG 编码失败: \(name)")
        }

        let outDir = URL(fileURLWithPath: "/tmp/touchpad-report-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let url = outDir.appendingPathComponent("\(name).png")
        try png.write(to: url)
        print("[snapshot] \(url.path)")
    }
}
