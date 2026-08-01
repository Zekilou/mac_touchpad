import Foundation

// MARK: - 节点值（节点间传递的数据）

/// 节点输出端口的统一值类型
/// 纯计算链传 .float；量化节点传 .output(GestureOutput)；分支/gate 传 .bool；副作用节点传 .unit
public enum NodeValue: Equatable {
    case float(Float)
    case output(GestureOutput)
    case bool(Bool)
    case unit

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

    public init(rawSignals: [SignalSource: Float] = [:],
                now: Double = 0,
                directionRule: DirectionRule = .positiveDecrease,
                isAtBoundary: Bool = false) {
        self.rawSignals = rawSignals
        self.now = now
        self.directionRule = directionRule
        self.isAtBoundary = isAtBoundary
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
}

// MARK: - 节点执行结果

/// 单节点执行结果：输出端口值（nil = 无输出/链断开）+ 分支结果（branch 专用）
public struct NodeExecutionResult {
    public var outputs: [String: NodeValue]?
    public var branchResult: Bool?

    public init(outputs: [String: NodeValue]? = nil, branchResult: Bool? = nil) {
        self.outputs = outputs
        self.branchResult = branchResult
    }
}
