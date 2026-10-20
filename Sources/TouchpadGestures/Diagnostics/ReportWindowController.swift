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
    /// 语言切换订阅（面板标题也要跟着换，否则英文界面顶着中文窗口名）
    private var languageObserver: NSObjectProtocol?

    /// 窗口是否需要以「主动上报」形态打开（决定标题与空态文案）
    private(set) var isManual = false

    private var panelTitle: String {
        isManual
            ? L10n.tr("报告问题", "Report a Problem")
            : L10n.tr("出现了问题", "Something Went Wrong")
    }

    deinit {
        if let token = languageObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func show(manual: Bool) {
        isManual = manual

        if let window {
            // 复用已有面板时也刷新标题（本次可能是不同形态）
            window.title = panelTitle
            window.orderFrontRegardless()
            return
        }

        let view = ReportView(manual: manual)
            .environmentObject(ReportCenter.shared)
        // 独立 hosting 根不订阅 AppDelegate → 用 LanguageRefresh 让切语言时重算文案
        let hosting = NSHostingView(rootView: LanguageRefresh { view })
        hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 620)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        panel.title = panelTitle
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
        languageObserver = NotificationCenter.default.addObserver(
            forName: .l10nLanguageDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let panel = self.window else { return }
            panel.title = self.panelTitle
        }
    }

    func windowWillClose(_ notification: Notification) {
        // 关闭即视为「稍后」：错误保留在本地，可随时从设置页再发
        ReportCenter.shared.dismiss()
        if let token = languageObserver {
            NotificationCenter.default.removeObserver(token)
            languageObserver = nil
        }
        window = nil
    }

    /// 上传完成且用户看到结果后，窗口可以由用户自行关闭
    func close() {
        window?.close()
        window = nil
    }
}
