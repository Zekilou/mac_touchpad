import Foundation

/// 全局设置（不归属于任何具体手势/事件/区域）
/// @ai: do not change field names (Codable 合同)
public struct GlobalSettings: Codable, Equatable {
    /// 帧处理限频（Hz），0 = 不限频
    public var frameRateLimit: Double = 0
    /// 接触面积下限
    public var touchSizeMin: Float = 0.1
    /// 接触面积上限
    public var touchSizeMax: Float = 1.0

    public init() {}

    public init(frameRateLimit: Double, touchSizeMin: Float, touchSizeMax: Float) {
        self.frameRateLimit = frameRateLimit
        self.touchSizeMin = touchSizeMin
        self.touchSizeMax = touchSizeMax
    }

    public static let `default` = GlobalSettings()
}
