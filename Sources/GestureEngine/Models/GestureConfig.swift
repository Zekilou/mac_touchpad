import Foundation

/// 手势 = 触发识别 + 所有震动反馈 + 滑动刻度 + 鼠标
/// 持有 regionID 和 eventID 绑定区域和事件
/// @ai: do not change field names (Codable 合同)
public struct GestureConfig: Codable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public var name: String
    public var regionID: UUID
    public var eventID: UUID

    // 第一次轻点
    public var tapMaxDuration: Double
    public var tapMaxDrift: Float
    // 两次轻点衔接
    public var tapMaxGap: Double
    // 第二次轻点保持
    public var holdMinDuration: Double
    // 滑动
    public var slideStepNorm: Float
    // 鼠标
    public var disassociateMouse: Bool
    // 所有震动（归手势）
    public var hapticEnter: Int32
    public var hapticTick: Int32
    public var hapticBoundary: Int32
    public var boundaryHapticInterval: Int32

    public init(
        id: UUID = UUID(),
        name: String,
        regionID: UUID,
        eventID: UUID,
        tapMaxDuration: Double = 0.20,
        tapMaxDrift: Float = 0.05,
        tapMaxGap: Double = 0.30,
        holdMinDuration: Double = 0.20,
        slideStepNorm: Float = 0.02,
        disassociateMouse: Bool = true,
        hapticEnter: Int32 = 2,
        hapticTick: Int32 = 4,
        hapticBoundary: Int32 = 2,
        boundaryHapticInterval: Int32 = 50000
    ) {
        self.id = id
        self.name = name
        self.regionID = regionID
        self.eventID = eventID
        self.tapMaxDuration = tapMaxDuration
        self.tapMaxDrift = tapMaxDrift
        self.tapMaxGap = tapMaxGap
        self.holdMinDuration = holdMinDuration
        self.slideStepNorm = slideStepNorm
        self.disassociateMouse = disassociateMouse
        self.hapticEnter = hapticEnter
        self.hapticTick = hapticTick
        self.hapticBoundary = hapticBoundary
        self.boundaryHapticInterval = boundaryHapticInterval
    }
}
