import Foundation
import mt_bridge

// MARK: - 节点值（节点间传递的数据）

/// 节点输出端口的统一值类型
/// 纯计算链传 .float；量化节点传 .output(GestureOutput)；分支/gate 传 .bool；副作用节点传 .unit
/// 数据流传 .fingers（原始触摸帧）/ .region（触发区域）
public enum NodeValue: Equatable {
    case float(Float)
    case output(GestureOutput)
    case bool(Bool)
    case unit
    /// 原始触摸帧数组（touchData.fingers 输出 → recognizer 输入）
    case fingers([mt_touch_t])
    /// 触发区域数据（RegionRef 输出 → recognizer 输入）
    case region(RegionConfig)

    public var floatValue: Float? {
        if case .float(let v) = self { return v }
        return nil
    }
    public var outputValue: GestureOutput? {
        if case .output(let v) = self { return v }
        return nil
    }
    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
    public var fingersValue: [mt_touch_t]? {
        if case .fingers(let v) = self { return v }
        return nil
    }
    public var regionValue: RegionConfig? {
        if case .region(let v) = self { return v }
        return nil
    }
}

// MARK: - mt_touch_t Equatable（fingers 值需要）

extension mt_touch_t: Equatable {
    public static func == (lhs: mt_touch_t, rhs: mt_touch_t) -> Bool {
        lhs.frame == rhs.frame && lhs.timestamp == rhs.timestamp
            && lhs.pathIndex == rhs.pathIndex && lhs.state == rhs.state
            && lhs.fingerID == rhs.fingerID && lhs.handID == rhs.handID
            && lhs.norm_x == rhs.norm_x && lhs.norm_y == rhs.norm_y
            && lhs.vel_x == rhs.vel_x && lhs.vel_y == rhs.vel_y
            && lhs.size == rhs.size && lhs.pressure == rhs.pressure
            && lhs.angle == rhs.angle && lhs.majorAxis == rhs.majorAxis
            && lhs.minorAxis == rhs.minorAxis && lhs.density == rhs.density
            && lhs.abs_x == rhs.abs_x && lhs.abs_vel_x == rhs.abs_vel_x
            && lhs.abs_vel_y == rhs.abs_vel_y && lhs.zPressure == rhs.zPressure
    }
}

// MARK: - 端口运行时值（数据 + 有效性标记）

/// 端口运行时值：数据 + 有效性标记
/// valid = 本帧该端口有没有产出数据（存在性，与值本身无关；"合法性"是节点业务逻辑）
/// 传播规则：节点任一必需输入 invalid → 输出全 invalid；副作用节点仅在输入 valid 时执行
public struct SocketValue: Equatable {
    /// 有没有数据（false = 上游未产出，链路断开）
    public var valid: Bool
    /// 数据值（unit 类型端口为占位值；invalid 时为 .unit 占位）
    public var value: NodeValue

    public init(valid: Bool = true, value: NodeValue) {
        self.valid = valid
        self.value = value
    }

    /// 事件脉冲：unit 类型端口的有效输出（"事件发生了"，无数据）
    public static func unit() -> SocketValue { SocketValue(valid: true, value: .unit) }

    /// 无数据（invalid）：链路断开 / 条件未选中 / 未产出
    public static func invalid() -> SocketValue { SocketValue(valid: false, value: .unit) }

    /// 便捷：有效浮点值
    public static func float(_ v: Float) -> SocketValue { SocketValue(valid: true, value: .float(v)) }
    /// 便捷：有效布尔值
    public static func bool(_ v: Bool) -> SocketValue { SocketValue(valid: true, value: .bool(v)) }
    /// 便捷：有效量化输出
    public static func output(_ v: GestureOutput) -> SocketValue { SocketValue(valid: true, value: .output(v)) }
    /// 便捷：有效原始触摸帧
    public static func fingers(_ v: [mt_touch_t]) -> SocketValue { SocketValue(valid: true, value: .fingers(v)) }
    /// 便捷：有效触发区域
    public static func region(_ v: RegionConfig) -> SocketValue { SocketValue(valid: true, value: .region(v)) }

    // MARK: - 值透传（读 value 内层）

    public var floatValue: Float? { value.floatValue }
    public var boolValue: Bool? { value.boolValue }
    public var outputValue: GestureOutput? { value.outputValue }
}

// MARK: - 跨节点共享状态

/// 节点图执行时的共享状态存储（baseline/transform.last/debounce.last/state 节点共用）
public typealias StateStore = [String: NodeValue]

// MARK: - 帧上下文（执行引擎每帧的输入）

/// 一次 evaluate 的输入：当前帧信号值 + 时间 + 方向规则 + 边界状态
/// 由引擎（GestureEngine）在状态机各时机构建传入
public struct FrameContext {
    /// 当前帧各信号源的值（signal 节点按 source 读取）
    public var rawSignals: [SignalSource: Float]
    /// 系统时间（秒，debounce 防抖用）
    public var now: Double
    /// 方向映射规则（quantize 节点计算 direction 用）
    public var directionRule: DirectionRule
    /// 当前事件值是否在边界（branch 的 atBoundary/notAtBoundary 用，由外部注入）
    public var isAtBoundary: Bool
    /// 原始触摸帧（touchData 数据源节点用：输出 fingers + 各信号）
    public var touches: [mt_touch_t]
    /// 手势绑定区域（RegionRef 节点输出用；数据流端口，非识别器隐式注入）
    public var region: RegionConfig?

    public init(rawSignals: [SignalSource: Float] = [:],
                now: Double = 0,
                directionRule: DirectionRule = .positiveDecrease,
                isAtBoundary: Bool = false,
                touches: [mt_touch_t] = [],
                region: RegionConfig? = nil) {
        self.rawSignals = rawSignals
        self.now = now
        self.directionRule = directionRule
        self.isAtBoundary = isAtBoundary
        self.touches = touches
        self.region = region
    }
}

// MARK: - 副作用接口（执行引擎 → 外部系统）

/// 副作用节点（consume/haptic/hud/mouse/freeze/notify）通过此协议把效果派发到外部
/// 纯计算节点不依赖此协议 → 可独立 dry-run 测试
public protocol TimelineEffects {
    /// 触觉反馈（HapticNode）
    func triggerHaptic(waveform: Int32, count: Int, intervalUs: Int32, async: Bool)
    /// 消费量化输出，执行系统调节（ConsumeNode）
    func consume(_ output: GestureOutput) -> BoundaryResult
    /// 唤起系统 HUD（HUDNode）
    func showHUD(direction: Int)
    /// 锁定光标（MouseNode .lockPosition）
    func lockMouse()
    /// 恢复光标关联（MouseNode .unlockPosition）
    func unlockMouse()
    /// 冻结直到反向滑动（FreezeNode）
    func freeze()
    /// 通知 UI（NotifyNode）
    func notify(label: String)
    /// 识别器 holding 状态变化（引擎据此维护鼠标锁定/事件引用）
    func recognizerState(holding: Bool)
}

// MARK: - 节点执行结果

/// 单节点执行结果：输出端口值（[端口名: SocketValue]；nil = 该节点无输出端口）
/// 必需输入无效 → 输出全 .invalid()（显式 valid 传播）；副作用节点仅在输入有效时执行
public struct NodeExecutionResult {
    public var outputs: [String: SocketValue]?

    public init(outputs: [String: SocketValue]? = nil) {
        self.outputs = outputs
    }
}
