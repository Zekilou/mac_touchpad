import SwiftUI
import AppKit
import GestureEngine

// MARK: - 报告窗口控制器
//
// 用一个**非激活**浮动面板承载报告 UI：
//   - 抢焦点会在用户正滑音量时打断手势，对这个 App 是硬伤
//   - 面板不遮挡菜单栏、不进入 Dock，关掉即释放
// 全局只存在一个实例；新错误只刷新内容，不叠窗。

@MainActor
final class ReportWindowController: NSObject, NSWindowDelegate {

    static let shared = ReportWindowController()

    private var window: NSPanel?

    /// 窗口是否需要以「主动上报」形态打开（决定标题与空态文案）
    private(set) var isManual = false

    func show(manual: Bool) {
        isManual = manual

        if let window {
            window.orderFrontRegardless()
            return
        }

        let view = ReportView(manual: manual)
            .environmentObject(ReportCenter.shared)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 620)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        panel.title = manual
            ? L10n.tr("报告问题", "Report a Problem")
            : L10n.tr("出现了问题", "Something Went Wrong")
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.delegate = self
        panel.center()
        panel.orderFrontRegardless()

        self.window = panel
    }

    func windowWillClose(_ notification: Notification) {
        // 关闭即视为「稍后」：错误保留在本地，可随时从设置页再发
        ReportCenter.shared.dismiss()
        window = nil
    }

    /// 上传完成且用户看到结果后，窗口可以由用户自行关闭
    func close() {
        window?.close()
        window = nil
    }
}
