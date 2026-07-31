import Foundation

/// 手势 = 触发识别 + 信号处理管线 + 结构化触觉反馈 + 鼠标
/// 持有 regionID 和 eventID 绑定区域和事件
/// @ai: do not change field names without Codable 迁移测试
public struct GestureConfig: Codable, Identifiable, Equatable, Hashable {
    // MARK: - 稳定 ID（不随版本变）

    public let id: UUID
    public var name: String
    public var regionID: UUID
    public var eventID: UUID

    // MARK: - 轻触识别参数（与 v1 一致，无变更）

    /// 第一次轻点：最大持续时间（秒）
    public var tapMaxDuration: Double
    /// 第一次轻点：最大位移（归一化，0.05 = 触控板短边 5%）
    public var tapMaxDrift: Float
    /// 两次轻点之间：最大时间间隔（秒）
    public var tapMaxGap: Double
    /// 第二次轻点：最小保持时间（秒）才认定为「按住」
    public var holdMinDuration: Double

    // MARK: - 鼠标控制（与 v1 一致，无变更）

    /// holding 期间是否解除鼠标-光标关联（并每帧 warp 回原点）
    public var disassociateMouse: Bool

    // MARK: - 新增：6 阶段信号处理管线（v2）

    /// [阶段1] 信号源：从 mt_touch_t 提取哪个字段
    public var signalSource: SignalSource
    /// [阶段2] 信号变换：相对差值 / 绝对值
    public var transformMode: TransformMode
    /// [阶段3] 量化模式：离散刻度 / 连续比例
    public var triggerMode: TriggerMode
    /// 离散模式：步进间距（归一化，原 slideStepNorm 改名，默认 0.02）
    public var stepNorm: Float
    /// 连续模式：灵敏度（0.1~10.0，默认 1.0 = 直接使用 delta）
    public var sensitivity: Float

    // MARK: - 新增：结构化触觉反馈（v2，替代旧 4 个散落字段）

    /// 进入 holding 瞬间
    public var hapticEnter: HapticEvent
    /// 每次正常刻度调节后
    public var hapticTick: HapticEvent
    /// 首次到达边界时
    public var hapticBoundary: HapticEvent
    /// 退出 holding 瞬间（手指抬起）
    public var hapticExit: HapticEvent

    // MARK: - Codable 合同

    /// @ai: do not remove cases — 所有字段必须显式列出，decode 迁移靠它
    enum CodingKeys: String, CodingKey {
        // 稳定 ID
        case id, name, regionID, eventID
        // 轻触识别
        case tapMaxDuration, tapMaxDrift, tapMaxGap, holdMinDuration
        // 鼠标
        case disassociateMouse
        // v1 滑动（迁移后改名为 stepNorm；保留此 case 用于读取旧 JSON）
        case slideStepNorm
        // v1 散落震动字段（Int32 类型；迁移到 haptic* 结构）
        case hapticEnter, hapticTick, hapticBoundary, boundaryHapticInterval
        // v2 信号处理管线
        case signalSource, transformMode, triggerMode, stepNorm, sensitivity
        // v2 结构化触觉：用独立 key 避免与 v1 Int32 hapticEnter 重名冲突
        case hapticEnterV2, hapticTickV2, hapticBoundaryV2, hapticExitV2
    }

    // MARK: - 初始化（全默认值 = 右手势音量调节行为）

    public init(
        id: UUID = UUID(),
        name: String,
        regionID: UUID,
        eventID: UUID,
        tapMaxDuration: Double = 0.20,
        tapMaxDrift: Float = 0.05,
        tapMaxGap: Double = 0.30,
        holdMinDuration: Double = 0.20,
        disassociateMouse: Bool = true,
        // v2 信号处理管线
        signalSource: SignalSource = .normY,
        transformMode: TransformMode = .delta,
        triggerMode: TriggerMode = .discrete,
        stepNorm: Float = 0.02,
        sensitivity: Float = 1.0,
        // v2 结构化触觉
        hapticEnter: HapticEvent = .enter,
        hapticTick: HapticEvent = .tick,
        hapticBoundary: HapticEvent = .boundary,
        hapticExit: HapticEvent = .exit
    ) {
        self.id = id
        self.name = name
        self.regionID = regionID
        self.eventID = eventID
        self.tapMaxDuration = tapMaxDuration
        self.tapMaxDrift = tapMaxDrift
        self.tapMaxGap = tapMaxGap
        self.holdMinDuration = holdMinDuration
        self.disassociateMouse = disassociateMouse
        self.signalSource = signalSource
        self.transformMode = transformMode
        self.triggerMode = triggerMode
        self.stepNorm = stepNorm
        self.sensitivity = sensitivity
        self.hapticEnter = hapticEnter
        self.hapticTick = hapticTick
        self.hapticBoundary = hapticBoundary
        self.hapticExit = hapticExit
    }

    // MARK: - Codable 解码（带 v1 → v2 自动迁移）

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // --- 稳定字段（直接解码）---
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        regionID = try container.decode(UUID.self, forKey: .regionID)
        eventID = try container.decode(UUID.self, forKey: .eventID)
        tapMaxDuration = try container.decode(Double.self, forKey: .tapMaxDuration)
        tapMaxDrift = try container.decode(Float.self, forKey: .tapMaxDrift)
        tapMaxGap = try container.decode(Double.self, forKey: .tapMaxGap)
        holdMinDuration = try container.decode(Double.self, forKey: .holdMinDuration)
        disassociateMouse = try container.decode(Bool.self, forKey: .disassociateMouse)

        // --- v2 信号处理管线：缺字段 → 用 v1 slideStepNorm + 合理默认值 ---
        signalSource = try container.decodeIfPresent(SignalSource.self, forKey: .signalSource) ?? .normY
        transformMode = try container.decodeIfPresent(TransformMode.self, forKey: .transformMode) ?? .delta
        triggerMode = try container.decodeIfPresent(TriggerMode.self, forKey: .triggerMode) ?? .discrete
        // stepNorm：优先读 v2 字段，其次读 v1 slideStepNorm，最后用默认 0.02
        if let v2Step = try container.decodeIfPresent(Float.self, forKey: .stepNorm) {
            stepNorm = v2Step
        } else if let v1SlideStep = try container.decodeIfPresent(Float.self, forKey: .slideStepNorm) {
            stepNorm = v1SlideStep
        } else {
            stepNorm = 0.02
        }
        sensitivity = try container.decodeIfPresent(Float.self, forKey: .sensitivity) ?? 1.0

        // --- v2 结构化触觉：缺字段 → 用 v1 散落波形迁移 ---
        // 注意：v1 hapticEnter/hapticTick/hapticBoundary 是 Int32（波形 ID），v2 是 HapticEvent struct
        // 为避免 key 冲突，v2 用 hapticEnterV2 等独立 key
        if let v2 = try container.decodeIfPresent(HapticEvent.self, forKey: .hapticEnterV2) {
            hapticEnter = v2
        } else {
            let oldWave = try container.decodeIfPresent(Int32.self, forKey: .hapticEnter) ?? 2
            hapticEnter = HapticEvent(enabled: true, waveform: oldWave, count: 1, intervalUs: 0)
        }
        if let v2 = try container.decodeIfPresent(HapticEvent.self, forKey: .hapticTickV2) {
            hapticTick = v2
        } else {
            let oldWave = try container.decodeIfPresent(Int32.self, forKey: .hapticTick) ?? 4
            hapticTick = HapticEvent(enabled: true, waveform: oldWave, count: 1, intervalUs: 0)
        }
        if let v2 = try container.decodeIfPresent(HapticEvent.self, forKey: .hapticBoundaryV2) {
            hapticBoundary = v2
        } else {
            let oldWave = try container.decodeIfPresent(Int32.self, forKey: .hapticBoundary) ?? 2
            let oldInterval = try container.decodeIfPresent(Int32.self, forKey: .boundaryHapticInterval) ?? 50000
            hapticBoundary = HapticEvent(enabled: true, waveform: oldWave, count: 2, intervalUs: oldInterval)
        }
        // hapticExit：v1 无对应字段，默认关闭
        hapticExit = try container.decodeIfPresent(HapticEvent.self, forKey: .hapticExitV2) ?? .exit
    }

    // MARK: - Encodable（编码时只写 v2 字段）

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(regionID, forKey: .regionID)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(tapMaxDuration, forKey: .tapMaxDuration)
        try container.encode(tapMaxDrift, forKey: .tapMaxDrift)
        try container.encode(tapMaxGap, forKey: .tapMaxGap)
        try container.encode(holdMinDuration, forKey: .holdMinDuration)
        try container.encode(disassociateMouse, forKey: .disassociateMouse)
        // v2 信号处理
        try container.encode(signalSource, forKey: .signalSource)
        try container.encode(transformMode, forKey: .transformMode)
        try container.encode(triggerMode, forKey: .triggerMode)
        try container.encode(stepNorm, forKey: .stepNorm)
        try container.encode(sensitivity, forKey: .sensitivity)
        // v2 结构化触觉（使用 V2 key，避免和 v1 Int32 冲突）
        try container.encode(hapticEnter, forKey: .hapticEnterV2)
        try container.encode(hapticTick, forKey: .hapticTickV2)
        try container.encode(hapticBoundary, forKey: .hapticBoundaryV2)
        try container.encode(hapticExit, forKey: .hapticExitV2)
    }
}
