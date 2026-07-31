import Foundation

/// 国际化工具（GestureEngine + TouchpadGestures 两 target 共享）
/// 不依赖 .strings 文件加载机制（SwiftPM 可执行目标对 .lproj 支持有限）
/// 依据 `Locale.preferredLanguages.first` 是否以 "zh" 开头判断中英文。
public enum L10n {
    /// 一次性取系统语言偏好（启动时决定，不支持运行时热切换）
    public static let isChinese: Bool = {
        Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    }()

    /// 中英二选一翻译
    /// - Parameters:
    ///   - zh: 中文文案
    ///   - en: 英文文案
    /// - Returns: 根据 isChinese 返回对应文案
    @inlinable
    public static func tr(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }
}
