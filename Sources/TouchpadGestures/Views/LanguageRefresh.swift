import SwiftUI
import Combine
import GestureEngine

// MARK: - 语言热切换宿主

/// 让「独立 NSHostingView 根」在切语言时重绘。
///
/// 背景：设置窗口的视图树天然订阅了 `AppDelegate.appSettings`（@Published），
/// 切语言时 `didSet` → `objectWillChange` → 整棵树重算，`tr()` 自然拿到新文案。
/// 但**引导窗和报告面板是独立创建的 NSHostingView 根**，不引用 AppDelegate，
/// 也没有别的可观察源 —— 语言变了它们不知道，会一直显示创建时那份语言。
///
/// 用法（包在 rootView 外层）：
/// ```swift
/// let hosting = NSHostingView(rootView: LanguageRefresh { OnboardingView(...) })
/// ```
///
/// 为什么用闭包而不是直接存 `Content`：body 重算时必须**重新构造**子视图，
/// 否则子视图值不变，SwiftUI 可能判定无事可做而跳过重绘。
/// 这里不改变视图身份（不套 `.id`），所以子视图的 @State（如引导页第几步）不会被重置。
struct LanguageRefresh<Content: View>: View {
    /// 语言版本号：写入即让本视图失效（@State 赋值必然触发 body 重算），
    /// 语言版本号。
    ///
    /// @ai `revision` **必须在 body 里被真正读取**（`let _ = revision` 不够 ——
    /// 那是一次读，但编译器会把它优化成常量折叠，SwiftUI 的依赖追踪也就断了）。
    /// 早期实现只写不读，结果通知收到、状态也写了，body 却不重建，
    /// 窗口停在旧语言上（由 I18nRenderTests.testLanguageRefreshRebuildsBodyOnNotification 抓到）。
    /// 正确做法：把它作为一个真实的视图输入参与构图（用 `.id` 会重建子视图、
    /// 丢掉 @State，所以用不参与布局的 `hidden` 文本承载依赖）。
    @State private var revision = L10n.revision
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        // revision 作为「不参与布局但参与依赖」的输入：任何变化都会换掉这个
        // 隐藏文本的标识，从而让整个 body 重新求值（内容闭包随之重建）。
        ZStack {
            content()
            Text(verbatim: String(revision))
                .hidden()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .l10nLanguageDidChange)) { _ in
            revision = L10n.revision
        }
    }
}
