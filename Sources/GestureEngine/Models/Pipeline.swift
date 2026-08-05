import Foundation
import mt_bridge

// MARK: - 阶段1：信号源选取

/// 从 mt_touch_t 提取哪个字段作为控制信号
/// @ai: do not remove existing cases
public enum SignalSource: String, Codable, CaseIterable {
    /// Y 轴归一化坐标（默认）：0.0=顶部，1.0=底部
    case normY
    /// X 轴归一化坐标：0.0=左，1.0=右
    case normX
    /// 接触面积/瞬时压力：~0.3 轻触 → ~1.35 重按
    case size
    /// Z 轴压力：上限 ~1.54
    case pressure
    /// X 轴归一化速度
    case velX
    /// Y 轴归一化速度
    case velY

    /// 从 mt_touch_t 提取对应字段值
    /// - Parameter t: 原始触摸帧（96 字节 struct，来自 mt_bridge.h）
    public func extract(from t: mt_touch_t) -> Float {
        switch self {
        case .normY:    return t.norm_y
        case .normX:    return t.norm_x
        case .size:     return t.size
        case .pressure: return t.zPressure
        case .velX:     return t.vel_x
        case .velY:     return t.vel_y
        }
    }

    /// UI 展示名
    public var displayName: String {
        switch self {
        case .normY:    return L10n.tr("Y 轴坐标", "Y Axis")
        case .normX:    return L10n.tr("X 轴坐标", "X Axis")
        case .size:     return L10n.tr("接触面积", "Touch Size")
        case .pressure: return L10n.tr("Z 轴压力", "Z Pressure")
        case .velX:     return L10n.tr("X 轴速度", "X Velocity")
        case .velY:     return L10n.tr("Y 轴速度", "Y Velocity")
        }
    }
}

// MARK: - 阶段2：信号变换

/// 如何从原始信号产生「变化量 delta」
/// @ai: do not remove existing cases
public enum TransformMode: String, Codable, CaseIterable {
    /// 相对差值：delta = rawValue - lastTriggerValue
    /// 适合滑动调节（上下滑 → 值增减）
    case delta
    /// 直接绝对值：delta = rawValue
    /// 适合"绝对位置映射"（手指顶部 = 0%，底部 = 100%）
    case absolute

    public var displayName: String {
        switch self {
        case .delta:    return L10n.tr("相对差值", "Delta")
        case .absolute: return L10n.tr("绝对值", "Absolute")
        }
    }
}

// MARK: - 阶段3：量化模式

/// 如何把 delta 转成 GestureOutput
/// @ai: do not remove existing cases
public enum TriggerMode: String, Codable, CaseIterable {
    /// 离散刻度：每达到 stepNorm 触发一次 tick，支持多档补偿
    /// 例：|delta| = 0.07，stepNorm = 0.02 → tickCount = 3（不丢刻度）
    case discrete
    /// 连续比例：output = delta × sensitivity，直接加减到系统值
    /// 滑动越快变化越大，适合精细控制
    case continuous

    public var displayName: String {
        switch self {
        case .discrete:   return L10n.tr("离散刻度", "Discrete Steps")
        case .continuous: return L10n.tr("连续比例", "Continuous")
        }
    }
}

// MARK: - 阶段4：GestureOutput（引擎 → 事件的数据合同）

/// 手势引擎输出，统一封装离散/连续两种模式
/// 事件通过 consume(output:) 消费此类型
@frozen
public enum GestureOutput: Equatable {
    /// 离散刻度输出
    /// - Parameters:
    ///   - direction: ±1（已应用 directionRule：+1=目标值增加，-1=减少）
    ///   - count: 本次跨了几个刻度（>=1，多档补偿）
    case tick(direction: Int, count: Int)

    /// 连续比例输出
    /// - Parameter delta: 带符号的变化量（已 × sensitivity，可直接加减到系统值）
    case continuous(delta: Float)
}

// MARK: - 阶段5：BoundaryResult（事件 → 引擎的反馈）

/// 事件消费结果，告诉引擎发生了什么（用于决定震动 + 下一帧状态）
/// @ai: do not remove existing cases
@frozen
public enum BoundaryResult: Equatable {
    /// 正常调节了（在边界内，或在边界内继续朝内滑动）
    case normal
    /// 首次到达边界（已发 HUD + 执行了最后一次调节）
    case hitBoundary
    /// 冻结中：已在边界且继续朝外滑动，不执行任何操作
    case frozen
}

// MARK: - 阶段6：HapticEvent（单个震动事件配置）

/// 单个触觉反馈配置：开关 + 波形 + 次数 + 间隔
/// 4 个实例（enter/tick/boundary/exit）挂在 GestureConfig 上
public struct HapticEvent: Codable, Equatable, Hashable {
    /// 是否启用（关闭时引擎完全跳过此震动时机）
    public var enabled: Bool
    /// 波形 ID：1~16，含义见「触觉波形对照表」卡片
    public var waveform: Int32
    /// 连续发几次（>=1）
    public var count: Int
    /// 多次之间的间隔（微秒，默认 50000 = 50ms，count>1 时才生效）
    public var intervalUs: Int32

    /// @ai: do not change default values — 保持与旧配置行为一致
    public init(enabled: Bool, waveform: Int32, count: Int = 1, intervalUs: Int32 = 0) {
        self.enabled = enabled
        self.waveform = waveform
        self.count = max(1, count)
        self.intervalUs = intervalUs
    }

    // MARK: - 预设（与旧 hapticEnter/hapticTick/hapticBoundary 对齐）

    /// 进入 holding：强 click 1 次（默认开）
    public static let `enter` = HapticEvent(enabled: true, waveform: 2, count: 1, intervalUs: 0)

    /// 正常刻度：轻 tap 1 次（默认开）
    public static let tick = HapticEvent(enabled: true, waveform: 4, count: 1, intervalUs: 0)

    /// 到达边界：强 click ×2，间隔 50ms（默认开）
    public static let boundary = HapticEvent(enabled: true, waveform: 2, count: 2, intervalUs: 50000)

    /// 退出 holding：默认关闭
    public static let exit = HapticEvent(enabled: false, waveform: 4, count: 1, intervalUs: 0)
}

// MARK: - 阶段3辅助：量化函数（引擎 holding 分支调用）

/// 把 delta 按 TriggerMode 量化为 GestureOutput
/// - Parameters:
///   - delta: 变换后的变化量（正数=信号增大，负数=信号减小）
///   - gesture: 手势配置（读取 stepNorm / sensitivity / directionRule 等）
///   - mapDirection: (Float) -> Int — 信号 delta 符号 → 目标值增减方向的映射函数
///                    传入 EventConfig.mapSignalDirection（语义：positiveIncrease / positiveDecrease）
/// - Returns: 若无需触发输出返回 nil（如 discrete 模式下 |delta| < stepNorm）
public func quantize(
    delta: Float,
    triggerMode: TriggerMode,
    stepNorm: Float,
    sensitivity: Float,
    mapDirection: (Float) -> Int
) -> GestureOutput? {
    switch triggerMode {
    case .discrete:
        let absDelta = abs(delta)
        // 浮点容差：normY 帧间差值恰为 stepNorm（0.02）时 Float 表示成 0.01999998，
        // 严格 `>= stepNorm` 会漏掉整刻度 → 慢速滑动"时调时不调"（随机感）。
        // 容差 = stepNorm 的 0.5%（0.02 → 1e-4），既容忍精度误差又不虚增刻度。
        let eps = max(stepNorm * 0.005, 1e-5)
        guard absDelta >= stepNorm - eps, stepNorm > 0 else { return nil }
        let tickCount = Int(floor((absDelta + eps) / stepNorm))
        guard tickCount >= 1 else { return nil }
        let direction = mapDirection(delta) // signal + → 目标增/减
        return .tick(direction: direction, count: tickCount)

    case .continuous:
        let scaled = delta * sensitivity
        guard abs(scaled) > 1e-6 else { return nil }
        // continuous 模式：信号增大 → scaled>0 → directionRule 决定 target 增减
        let sign: Float = Float(mapDirection(delta)) // ±1
        return .continuous(delta: sign * abs(scaled))
    }
}
