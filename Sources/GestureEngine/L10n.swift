import Foundation

/// UI 语言选项（设置页可选：跟随系统 / 中文 / 英文）
/// @ai: do not remove existing cases
public enum AppLanguage: String, Codable, CaseIterable {
    /// 跟随系统语言（Locale.preferredLanguages）
    case system
    /// 强制中文
    case zh
    /// 强制英文
    case en

    /// 选择器显示名（zh/en 用本地名，不随界面语言变）
    public var displayName: String {
        switch self {
        case .system: return L10n.tr("跟随系统", "Follow System")
        case .zh:     return "中文"
        case .en:     return "English"
        }
    }
}

/// 国际化工具（GestureEngine + TouchpadGestures 两 target 共享）
/// 不依赖 .strings 文件加载机制（SwiftPM 可执行目标对 .lproj 支持有限）
/// 语言由 `currentLanguage` 决定（App 启动时从设置同步，设置变更时实时切换）：
///   .system → 依据 `Locale.preferredLanguages.first` 是否以 "zh" 开头；
///   .zh / .en → 强制。
/// 注意：isChinese 是**每次调用**求值的计算属性（支持运行时热切换），非启动时快照。
public enum L10n {
    /// 当前 UI 语言（App 设置写入；GestureEngine 层读此决定 tr 取 zh/en）
    public static var currentLanguage: AppLanguage = .system

    /// 是否显示中文（每次调用求值——切语言后下一次 body 求值即生效）
    public static var isChinese: Bool {
        switch currentLanguage {
        case .system:
            return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        case .zh:
            return true
        case .en:
            return false
        }
    }

    /// 中英二选一翻译
    /// - Parameters:
    ///   - zh: 中文文案
    ///   - en: 英文文案
    /// - Returns: 根据当前语言返回对应文案
    public static func tr(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }
}
