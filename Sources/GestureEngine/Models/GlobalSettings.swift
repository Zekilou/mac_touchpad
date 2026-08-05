import Foundation

/// 全局设置（不归属于任何具体手势/事件/区域）
/// @ai: do not change field names (Codable 合同)
public struct GlobalSettings: Codable, Equatable {
    /// 帧处理限频（Hz），0 = 不限频
    public var frameRateLimit: Double = 0
    /// 接触面积下限（过滤过轻的误触/悬停）
    public var touchSizeMin: Float = 0.1
    /// 接触面积上限（默认 1.35：手指按压 size 可达 ~1.35；旧默认 1.0 会过滤较重按压
    /// → touching 随机 false → 双击保持中随机退出。防手掌仍可靠上限 + 下限共同过滤）
    public var touchSizeMax: Float = 1.35
    /// 手掌过滤开关（默认开）：接触面积超过 touchSizeMax 的手指视为手掌，从手指识别（touching/active）中排除。
    /// 关闭后只按下限过滤——重压/手掌也会进入识别，可能误触发（v10.21「形态识别」设置）
    public var palmFilter: Bool = true

    public init() {}

    public init(frameRateLimit: Double, touchSizeMin: Float, touchSizeMax: Float, palmFilter: Bool = true) {
        self.frameRateLimit = frameRateLimit
        self.touchSizeMin = touchSizeMin
        self.touchSizeMax = touchSizeMax
        self.palmFilter = palmFilter
    }

    // MARK: - 手动 Codable（新字段 decodeIfPresent 回退默认——旧 config.json 的 global
    // 缺 palmFilter 时不能整体 decode 失败，否则用户配置全丢回默认）

    enum CodingKeys: String, CodingKey { case frameRateLimit, touchSizeMin, touchSizeMax, palmFilter }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frameRateLimit = try c.decodeIfPresent(Double.self, forKey: .frameRateLimit) ?? 0
        touchSizeMin = try c.decodeIfPresent(Float.self, forKey: .touchSizeMin) ?? 0.1
        touchSizeMax = try c.decodeIfPresent(Float.self, forKey: .touchSizeMax) ?? 1.35
        palmFilter = try c.decodeIfPresent(Bool.self, forKey: .palmFilter) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(frameRateLimit, forKey: .frameRateLimit)
        try c.encode(touchSizeMin, forKey: .touchSizeMin)
        try c.encode(touchSizeMax, forKey: .touchSizeMax)
        try c.encode(palmFilter, forKey: .palmFilter)
    }

    public static let `default` = GlobalSettings()
}
