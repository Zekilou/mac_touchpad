import Foundation
import CoreGraphics

// MARK: - 触发事件（时间轴挂载点）

/// 状态机中的 6 种触发时机，每个 TriggerEvent 对应一条独立 Timeline
/// @ai: do not remove existing cases
public enum TriggerEvent: String, Codable, CaseIterable {
    /// 第一次轻点落下
    case onFirstTap
    /// 第二次轻点落下
    case onSecondTap
    /// 进入 holding（双击保持成功）
    case onEnterHolding
    /// holding 中每次量化触发（每帧检查）
    case onTick
    /// 首次到达边界
    case onBoundaryHit
    /// 退出 holding（手指抬起）
    case onExitHolding

    public var displayName: String {
        switch self {
        case .onFirstTap:    return L10n.tr("第一次轻点", "First Tap")
        case .onSecondTap:   return L10n.tr("第二次轻点", "Second Tap")
        case .onEnterHolding: return L10n.tr("进入保持", "Enter Holding")
        case .onTick:        return L10n.tr("刻度触发", "Tick")
        case .onBoundaryHit: return L10n.tr("到达边界", "Boundary Hit")
        case .onExitHolding: return L10n.tr("退出保持", "Exit Holding")
        }
    }
}

// MARK: - 节点类型（6 大类 20+ 种）

/// 可在 Timeline 上拖放的逻辑节点
/// @ai: do not remove existing cases
public enum NodeType: String, Codable, CaseIterable {
    // 数据源
    case signal, value
    // 触发识别（状态机参数）
    case recognize
    // 绑定引用（手势↔区域/事件 关联）
    case region, event
    // 数学/变换
    case transform, scale, clamp, abs, sign
    // 量化/门控
    case quantize, gate, debounce
    // 条件分支
    case branch, `switch`
    // 副作用/反馈
    case consume, haptic, hud, mouse, freeze, notify
    // 流控制
    case split, merge, baseline, state

    public var displayName: String {
        switch self {
        // 数据源
        case .signal:    return L10n.tr("信号源", "Signal")
        case .value:     return L10n.tr("常量值", "Value")
        // 触发识别
        case .recognize: return L10n.tr("触发识别", "Recognize")
        // 绑定引用
        case .region:    return L10n.tr("区域引用", "Region Ref")
        case .event:     return L10n.tr("事件引用", "Event Ref")
        // 数学/变换
        case .transform: return L10n.tr("变换", "Transform")
        case .scale:     return L10n.tr("缩放", "Scale")
        case .clamp:     return L10n.tr("限幅", "Clamp")
        case .abs:       return L10n.tr("绝对值", "Abs")
        case .sign:      return L10n.tr("取符号", "Sign")
        // 量化/门控
        case .quantize:  return L10n.tr("量化", "Quantize")
        case .gate:      return L10n.tr("门控", "Gate")
        case .debounce:  return L10n.tr("防抖", "Debounce")
        // 条件分支
        case .branch:    return L10n.tr("条件分支", "Branch")
        case .`switch`:  return L10n.tr("多路开关", "Switch")
        // 副作用/反馈
        case .consume:   return L10n.tr("消费输出", "Consume")
        case .haptic:    return L10n.tr("触觉反馈", "Haptic")
        case .hud:       return L10n.tr("HUD 唤起", "HUD")
        case .mouse:     return L10n.tr("鼠标控制", "Mouse")
        case .freeze:    return L10n.tr("冻结", "Freeze")
        case .notify:    return L10n.tr("通知", "Notify")
        // 流控制
        case .split:     return L10n.tr("分路", "Split")
        case .merge:     return L10n.tr("合并", "Merge")
        case .baseline:  return L10n.tr("基线记录", "Baseline")
        case .state:     return L10n.tr("状态存储", "State")
        }
    }
}

// MARK: - 端口标识

/// 节点上某个端口的唯一标识（nodeID + 端口名）
/// 端口名约定：输入统一 "input"，输出 "output"；Branch 额外有 "true"/"false"；Switch 有 "case0"..."caseN"
public struct PortID: Codable, Hashable {
    public var nodeID: UUID
    public var portName: String

    public init(nodeID: UUID, portName: String) {
        self.nodeID = nodeID
        self.portName = portName
    }
}

// MARK: - 节点参数（扁平结构，仅相关节点使用相关字段）

/// 所有节点的参数合集；Optional 字段未设置时 = 默认行为
/// 类型安全的"AnyCodable"替代，UI 绑定和 Codable 都简单
public struct NodeParams: Codable, Hashable {
    // 数据源
    public var source: SignalSource?     // signal
    public var constant: Float?          // value
    // 触发识别（状态机参数）
    public var tapMaxDuration: Double?   // recognize
    public var tapMaxDrift: Float?       // recognize
    public var tapMaxGap: Double?        // recognize
    public var holdMinDuration: Double?  // recognize
    // 绑定引用
    public var regionID: UUID?           // region
    public var eventID: UUID?            // event
    // 变换
    public var transform: TransformMode? // transform
    public var multiplier: Float?        // scale
    public var offset: Float?            // scale
    public var min: Float?               // clamp
    public var max: Float?               // clamp
    // 量化
    public var stepNorm: Float?          // quantize
    public var sensitivity: Float?       // quantize
    public var triggerMode: TriggerMode? // quantize（discrete/continuous）
    // 门控
    public var threshold: Float?         // gate
    public var comparator: Comparator?   // gate
    public var minIntervalMs: Double?    // debounce
    // 分支
    public var predicate: Predicate?     // branch
    // 副作用
    public var action: ActionType?       // consume
    public var method: ExecutionMethod?  // consume
    public var step: Float?              // consume
    public var waveform: Int32?          // haptic
    public var count: Int?               // haptic
    public var intervalUs: Int32?        // haptic
    public var async: Bool?              // haptic
    public var mouseMode: MouseMode?     // mouse
    public var unfreeze: UnfreezeMode?   // freeze
    public var timeoutMs: Double?        // freeze
    public var label: String?            // notify
    // 流控制
    public var mergeMode: MergeMode?     // merge
    public var key: String?              // baseline/state
    // 时间轴
    public var delayMs: Double?          // 节点在时间轴上的延迟位置

    public init() {}

    /// 便捷初始化：常用参数一键填充（其余字段默认 nil）
    public init(source: SignalSource? = nil,
                constant: Float? = nil,
                tapMaxDuration: Double? = nil,
                tapMaxDrift: Float? = nil,
                tapMaxGap: Double? = nil,
                holdMinDuration: Double? = nil,
                regionID: UUID? = nil,
                eventID: UUID? = nil,
                transform: TransformMode? = nil,
                multiplier: Float? = nil,
                offset: Float? = nil,
                min: Float? = nil,
                max: Float? = nil,
                stepNorm: Float? = nil,
                sensitivity: Float? = nil,
                triggerMode: TriggerMode? = nil,
                threshold: Float? = nil,
                comparator: Comparator? = nil,
                minIntervalMs: Double? = nil,
                predicate: Predicate? = nil,
                action: ActionType? = nil,
                method: ExecutionMethod? = nil,
                step: Float? = nil,
                waveform: Int32? = nil,
                count: Int? = nil,
                intervalUs: Int32? = nil,
                async: Bool? = nil,
                mouseMode: MouseMode? = nil,
                unfreeze: UnfreezeMode? = nil,
                timeoutMs: Double? = nil,
                label: String? = nil,
                mergeMode: MergeMode? = nil,
                key: String? = nil,
                delayMs: Double? = nil) {
        self.source = source
        self.constant = constant
        self.tapMaxDuration = tapMaxDuration
        self.tapMaxDrift = tapMaxDrift
        self.tapMaxGap = tapMaxGap
        self.holdMinDuration = holdMinDuration
        self.regionID = regionID
        self.eventID = eventID
        self.transform = transform
        self.multiplier = multiplier
        self.offset = offset
        self.min = min
        self.max = max
        self.stepNorm = stepNorm
        self.sensitivity = sensitivity
        self.triggerMode = triggerMode
        self.threshold = threshold
        self.comparator = comparator
        self.minIntervalMs = minIntervalMs
        self.predicate = predicate
        self.action = action
        self.method = method
        self.step = step
        self.waveform = waveform
        self.count = count
        self.intervalUs = intervalUs
        self.async = async
        self.mouseMode = mouseMode
        self.unfreeze = unfreeze
        self.timeoutMs = timeoutMs
        self.label = label
        self.mergeMode = mergeMode
        self.key = key
        self.delayMs = delayMs
    }

    /// 按字段名返回修改后的副本（可编辑 Inspector 通用写入）
    /// - Returns: 若 key 未知返回原值
    public func setting(key: String, _ value: Any?) -> NodeParams {
        var p = self
        switch key {
        case "source":         p.source = value as? SignalSource
        case "constant":       p.constant = value as? Float
        case "tapMaxDuration": p.tapMaxDuration = value as? Double
        case "tapMaxDrift":    p.tapMaxDrift = value as? Float
        case "tapMaxGap":      p.tapMaxGap = value as? Double
        case "holdMinDuration": p.holdMinDuration = value as? Double
        case "regionID":       p.regionID = value as? UUID
        case "eventID":        p.eventID = value as? UUID
        case "transform":      p.transform = value as? TransformMode
        case "multiplier":     p.multiplier = value as? Float
        case "offset":         p.offset = value as? Float
        case "min":            p.min = value as? Float
        case "max":            p.max = value as? Float
        case "stepNorm":       p.stepNorm = value as? Float
        case "sensitivity":    p.sensitivity = value as? Float
        case "triggerMode":    p.triggerMode = value as? TriggerMode
        case "threshold":      p.threshold = value as? Float
        case "comparator":     p.comparator = value as? Comparator
        case "minIntervalMs":  p.minIntervalMs = value as? Double
        case "predicate":      p.predicate = value as? Predicate
        case "action":         p.action = value as? ActionType
        case "method":         p.method = value as? ExecutionMethod
        case "step":           p.step = value as? Float
        case "waveform":       p.waveform = value as? Int32
        case "count":          p.count = value as? Int
        case "intervalUs":     p.intervalUs = value as? Int32
        case "async":          p.async = value as? Bool
        case "mouseMode":      p.mouseMode = value as? MouseMode
        case "unfreeze":       p.unfreeze = value as? UnfreezeMode
        case "timeoutMs":      p.timeoutMs = value as? Double
        case "label":          p.label = value as? String
        case "mergeMode":      p.mergeMode = value as? MergeMode
        case "key":            p.key = value as? String
        case "delayMs":        p.delayMs = value as? Double
        default: break
        }
        return p
    }
}

/// 鼠标控制模式
public enum MouseMode: String, Codable, CaseIterable, Hashable {
    case lockPosition    // 锁定光标位置（holding 期间）
    case unlockPosition  // 恢复光标关联
}

/// 冻结解冻条件
public enum UnfreezeMode: String, Codable, CaseIterable, Hashable {
    case reverseSlide    // 反向滑动解冻（默认）
    case timeout         // 超时自动解冻
}

/// 合并模式
public enum MergeMode: String, Codable, CaseIterable, Hashable {
    case sum, max, min
}

// MARK: - 节点

public struct NodeConfig: Codable, Identifiable, Hashable {
    public let id: UUID
    public var type: NodeType
    public var params: NodeParams
    /// 画布坐标（x = 时间轴位置，y = 垂直顺序）
    public var x: Double
    public var y: Double
    public var title: String?

    public init(id: UUID = UUID(),
                type: NodeType,
                params: NodeParams = NodeParams(),
                x: Double = 0, y: Double = 0,
                title: String? = nil) {
        self.id = id
        self.type = type
        self.params = params
        self.x = x
        self.y = y
        self.title = title
    }
}

// MARK: - 连线

public struct Edge: Codable, Hashable {
    public var from: PortID
    public var to: PortID

    public init(from: PortID, to: PortID) {
        self.from = from
        self.to = to
    }
}

// MARK: - Timeline

/// 单个触发事件对应的节点图
public struct TimelineConfig: Codable, Identifiable, Hashable {
    public let id: UUID
    public var trigger: TriggerEvent
    public var nodes: [NodeConfig]
    public var edges: [Edge]
    /// 起点（无入边的 Node），执行从它们开始
    public var entryNodeIDs: [UUID]

    public init(id: UUID = UUID(),
                trigger: TriggerEvent,
                nodes: [NodeConfig] = [],
                edges: [Edge] = [],
                entryNodeIDs: [UUID] = []) {
        self.id = id
        self.trigger = trigger
        self.nodes = nodes
        self.edges = edges
        self.entryNodeIDs = entryNodeIDs
    }

    /// 便捷：取某类型的第一个节点
    public func firstNode(of type: NodeType) -> NodeConfig? {
        nodes.first { $0.type == type }
    }

    /// 便捷：某节点的所有出边
    public func outgoingEdges(from nodeID: UUID) -> [Edge] {
        edges.filter { $0.from.nodeID == nodeID }
    }

    /// 便捷：某节点的所有入边
    public func incomingEdges(to nodeID: UUID) -> [Edge] {
        edges.filter { $0.to.nodeID == nodeID }
    }
}

// MARK: - Predicate（条件表达式，简化版）

public enum Comparator: String, Codable, CaseIterable, Hashable {
    case gt, gte, lt, lte, eq, neq

    public var symbol: String {
        switch self {
        case .gt: return ">"
        case .gte: return ">="
        case .lt: return "<"
        case .lte: return "<="
        case .eq: return "=="
        case .neq: return "!="
        }
    }
}

/// BranchNode 的条件表达式
public indirect enum Predicate: Codable, Hashable {
    case atBoundary        // 当前事件值在边界
    case notAtBoundary
    case firstTime         // 第一次到这条路径
    case positive          // 上一步输出 > 0
    case negative
    case compare(Comparator, Float)
    case and(Predicate, Predicate)
    case or(Predicate, Predicate)
    case not(Predicate)
}

// MARK: - Codable 手动实现（Predicate 关联值）

extension Predicate {
    enum CodingKeys: String, CodingKey { case kind, value, left, right, comparator, threshold }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "atBoundary":    self = .atBoundary
        case "notAtBoundary": self = .notAtBoundary
        case "firstTime":     self = .firstTime
        case "positive":      self = .positive
        case "negative":      self = .negative
        case "compare":
            let cmp = try c.decode(Comparator.self, forKey: .comparator)
            let thr = try c.decode(Float.self, forKey: .threshold)
            self = .compare(cmp, thr)
        case "and":
            self = .and(try c.decode(Predicate.self, forKey: .left),
                        try c.decode(Predicate.self, forKey: .right))
        case "or":
            self = .or(try c.decode(Predicate.self, forKey: .left),
                       try c.decode(Predicate.self, forKey: .right))
        case "not":
            self = .not(try c.decode(Predicate.self, forKey: .value))
        default:
            self = .atBoundary
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .atBoundary:    try c.encode("atBoundary", forKey: .kind)
        case .notAtBoundary: try c.encode("notAtBoundary", forKey: .kind)
        case .firstTime:     try c.encode("firstTime", forKey: .kind)
        case .positive:      try c.encode("positive", forKey: .kind)
        case .negative:      try c.encode("negative", forKey: .kind)
        case .compare(let cmp, let thr):
            try c.encode("compare", forKey: .kind)
            try c.encode(cmp, forKey: .comparator)
            try c.encode(thr, forKey: .threshold)
        case .and(let l, let r):
            try c.encode("and", forKey: .kind)
            try c.encode(l, forKey: .left)
            try c.encode(r, forKey: .right)
        case .or(let l, let r):
            try c.encode("or", forKey: .kind)
            try c.encode(l, forKey: .left)
            try c.encode(r, forKey: .right)
        case .not(let p):
            try c.encode("not", forKey: .kind)
            try c.encode(p, forKey: .value)
        }
    }
}
