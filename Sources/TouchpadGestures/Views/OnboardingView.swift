import SwiftUI
import AppKit
import GestureEngine

// MARK: - 首次启动引导
//
// 为什么必须有：本 App 是 LSUIElement（无 Dock 图标），用户双击后**看不到任何窗口**，
// 只有菜单栏多出一个图标。没有引导的话，用户既不知道要授权辅助功能，
// 也不知道该在哪里双击——最常见的反馈就是"装了没反应"。
//
// 设计要点：
// - 只显示一次（UserDefaults 记标记），之后从设置页可再次打开
// - 任何一步都不能阻塞用户：可以随时关掉，功能本身仍然可用
// - 直接给出可点的按钮（去授权 / 试一下），而不是让用户自己去翻系统设置

struct OnboardingView: View {
    @ObservedObject var permissionManager: PermissionManager
    let appVersion: String
    let onFinish: () -> Void

    @State private var step: Int = 0

    private let steps = 3

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch step {
                    case 0: welcomeStep
                    case 1: permissionStep
                    default: tryItStep
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            footer
        }
        .frame(width: 520, height: 460)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("欢迎使用 Touchpad Gestures", "Welcome to Touchpad Gestures"))
                    .font(.title3.weight(.semibold))
                Text(L10n.tr("版本 \(appVersion) · 菜单栏应用，没有主窗口",
                             "Version \(appVersion) · menu bar app, no main window"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    // MARK: - 第 1 步

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("它在哪里？", "Where is it?"))
                .font(.headline)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "menubar.rectangle")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(.init(L10n.tr("看屏幕右上角的**菜单栏**，会有一个手势图标。所有功能都从那里进入——设置、重试、报告问题、退出。",
                                   "Look at the **menu bar** in the top-right corner for a hand icon. Everything is reachable from there — settings, retry, report a problem, quit.")))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(L10n.tr("它不会出现在 Dock 里，也没有主窗口。这是正常的设计，不是没装上。",
                         "It does not appear in the Dock and has no main window. That is by design, not a failed install."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text(L10n.tr("怎么用？", "How do I use it?"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                bullet(L10n.tr("双击触控板**右边缘**并保持，然后上下滑动 → 调节音量",
                               "Double-tap the **right edge** of the trackpad, keep holding, then slide → volume"))
                bullet(L10n.tr("双击**左边缘**并保持，然后上下滑动 → 调节亮度",
                               "Double-tap the **left edge**, keep holding, then slide → brightness"))
                bullet(L10n.tr("上边缘横向滑动 → 调节播放进度（媒体应用）",
                               "Slide horizontally on the top edge → seek in media apps"))
            }
        }
    }

    // MARK: - 第 2 步

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("授予「辅助功能」权限", "Grant Accessibility permission"))
                .font(.headline)

            Text(.init(L10n.tr("这是本 App **唯一必需**的权限。没有它，手势能被识别、也能震动，但无法真正调节系统音量或亮度。",
                               "This is the **only** permission this app needs. Without it gestures are recognized and buzz, but cannot actually change system volume or brightness.")))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                statusBadge(
                    ok: permissionManager.accessibility.isOK,
                    okText: L10n.tr("已授权", "Granted"),
                    badText: L10n.tr("未授权", "Not granted"))

                Button(L10n.tr("打开系统设置", "Open System Settings")) {
                    permissionManager.requestAccessibility()
                    permissionManager.openAccessibilitySettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("步骤：", "Steps:"))
                    .font(.callout.weight(.medium))
                Text(L10n.tr("1. 在「隐私与安全性 → 辅助功能」里开启 TouchpadGestures\n2. 如果列表里没有它，点左下角「+」手动添加\n3. 授权后回到这里，状态会自动变成「已授权」",
                             "1. Enable TouchpadGestures under Privacy & Security → Accessibility\n2. If it is not listed, add it with the \"+\" button\n3. Come back here — the status updates automatically"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))

            Text(L10n.tr("「输入监控」不需要开启——触控板读取走的是系统私有接口，不受这项权限限制。",
                         "Input Monitoring is not required — trackpad input is read through a system interface that this permission does not gate."))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { permissionManager.refresh() }
    }

    // MARK: - 第 3 步

    private var tryItStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("试一下", "Try it"))
                .font(.headline)

            Text(.init(L10n.tr("把两根手指快速轻点两下触控板**右边缘**，第二下不要抬起，保持按住然后上下滑动。",
                               "Tap twice quickly with two fingers on the **right edge**, keep the second tap held down, then slide up and down.")))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: permissionManager.accessibility.isOK
                      ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(permissionManager.accessibility.isOK ? .green : .orange)
                Text(permissionManager.accessibility.isOK
                     ? L10n.tr("辅助功能已就绪，应该能直接调节音量", "Accessibility is ready — volume should respond")
                     : L10n.tr("辅助功能还没授权，手势暂时只能震动", "Accessibility is not granted yet — gestures will only buzz"))
                    .font(.callout)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))

            Divider()

            Text(L10n.tr("如果没反应", "If nothing happens"))
                .font(.callout.weight(.medium))

            VStack(alignment: .leading, spacing: 6) {
                bullet(L10n.tr("双击后必须**保持按住**再滑动，直接滑动不会触发",
                               "You must **keep holding** after the double-tap before sliding"))
                bullet(L10n.tr("看菜单栏图标下的状态行，它会显示触控板是否就绪",
                               "Check the status line under the menu bar icon — it reports trackpad readiness"))
                bullet(L10n.tr("仍然不行可以从菜单栏打开「设置 → 触摸数据流」检查区域范围",
                               "If it still fails, open Settings → Touch Data Stream to check the region bounds"))
            }

            Text(L10n.tr("这些设置随时可以从菜单栏重新打开。",
                         "You can always reopen these settings from the menu bar."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                // 步骤指示
                HStack(spacing: 6) {
                    ForEach(0..<steps, id: \.self) { i in
                        Circle()
                            .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }

                Spacer()

                Button(L10n.tr("跳过", "Skip")) { finish() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)

                if step > 0 {
                    Button(L10n.tr("上一步", "Back")) {
                        withAnimation { step -= 1 }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }

                Button(step == steps - 1 ? L10n.tr("开始使用", "Get Started")
                                         : L10n.tr("继续", "Continue")) {
                    if step == steps - 1 {
                        finish()
                    } else {
                        withAnimation { step += 1 }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
    }

    private func finish() {
        onFinish()
        OnboardingWindowController.shared.close()
    }

    // MARK: - 小组件

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(.init(text))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusBadge(ok: Bool, okText: String, badText: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(ok ? okText : badText)
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill((ok ? Color.green : Color.orange).opacity(0.12)))
    }
}

// MARK: - 引导窗口控制器

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {

    static let shared = OnboardingWindowController()

    /// UserDefaults key：已完成引导（含"跳过"）
    static let completedKey = "onboarding.completed"

    private var window: NSWindow?

    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completedKey)
    }

    /// 首次启动才显示（已完成后不再打扰）
    func showIfFirstLaunch(permissionManager: PermissionManager, appVersion: String) {
        guard !Self.hasCompleted else { return }
        show(permissionManager: permissionManager, appVersion: appVersion)
    }

    /// 从设置页手动再次打开
    func show(permissionManager: PermissionManager, appVersion: String) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = OnboardingView(
            permissionManager: permissionManager,
            appVersion: appVersion,
            onFinish: { Self.markCompleted() })
        // 独立 hosting 根不订阅 AppDelegate → 用 LanguageRefresh 让切语言时重算文案
        let hosting = NSHostingView(rootView: LanguageRefresh { view })

        // 普通窗口（需要键盘焦点走"继续"按钮），而不是非激活 panel：
        // 引导是用户主动要看的东西，这时候抢焦点是正确的
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        win.title = L10n.tr("欢迎", "Welcome")
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isReleasedWhenClosed = false
        win.contentView = hosting
        win.delegate = self
        win.center()
        win.level = .floating

        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // 关窗即视为完成，避免下次启动又弹
        OnboardingWindowController.markCompleted()
        window = nil
    }

    func close() {
        window?.close()
        window = nil
    }
}
