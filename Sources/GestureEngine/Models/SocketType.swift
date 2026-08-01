import Foundation

// MARK: - Socket 类型（端口数据类型：决定可连性与 UI 形状）

/// 端口数据类型：连线两端必须类型匹配（generic 除外）
/// UI 形状：float=圆 ● / int=方 ■ / bool=菱 ◆ / output=三角 ▲ / unit=空心 ○ / generic=星 ☆
///         fingers=多指 〇〇 / region=矩形 ▭
/// @ai: do not remove existing cases
public enum SocketType: String, Codable, CaseIterable, Hashable {
    /// 标量信号（normY、变换结果）
    case float
    /// 整数（frame、tick 次数）
    case int
    /// 条件（比较/边界判断结果）
    case bool
    /// 量化结果（GestureOutput：tick/continuous）
    case output
    /// 事件脉冲（无数据，只表示"事件发生了"；副作用节点触发输入）
    case unit
    /// 泛型（路由器/分流等：与任何类型匹配，同组端口类型一致）
    case generic
    /// 原始触摸帧数组（touchData.fingers → recognizer 输入）
    case fingers
    /// 触发区域数据（RegionRef 输出 → recognizer 输入）
    case region
}

// MARK: - 端口声明

/// 单个端口（socket）声明：名称 + 类型 + 是否必需
/// required = true（默认）：该输入无效时节点不执行、输出全 invalid；可选输入按节点逻辑处理
public struct SocketDef: Codable, Hashable {
    public var name: String
    public var type: SocketType
    public var required: Bool

    public init(name: String, type: SocketType, required: Bool = true) {
        self.name = name
        self.type = type
        self.required = required
    }
}

// MARK: - 节点端口注册表（每个 NodeType 的固定输入/输出接口）

/// 每个 NodeType 固定声明的输入/输出 socket 列表——"给 UI 和引擎的 API 合同"。
/// 连线两端形状必须匹配（generic 匹配任意）；执行引擎按端口名读写数据。
public enum NodeTypeDef {

    /// 输入端口（节点左侧）
    public static func inputSockets(of type: NodeType) -> [SocketDef] {
        switch type {
        // 管道出口：接收识别器脉冲（trigger:unit）→ 透传启动下游
        case .pipeOut:
            return [SocketDef(name: "trigger", type: .unit)]
        // 触控板数据源：纯输出，无输入（数据从原始帧注入节点内部读取）
        case .touchData:
            return []
        // 无输入：常量 / 参数承载 / 视觉
        case .value, .event, .group:
            return []
        // 区域引用：无输入（区域数据从 FrameContext 读取，卡片内 regionID 关联）
        case .region:
            return []
        // 识别器：数据流输入全显式（fingers 原始帧 + region 触发区域）
        case .recognizer:
            return [SocketDef(name: "fingers", type: .fingers),
                    SocketDef(name: "region", type: .region)]
        // 数学/变换：单 float 输入
        case .transform, .scale, .clamp, .abs, .sign:
            return [SocketDef(name: "value", type: .float)]
        // 量化/门控
        case .quantize:
            return [SocketDef(name: "value", type: .float)]
        case .gate:
            return [SocketDef(name: "value", type: .float)]
        case .debounce:
            return [SocketDef(name: "trigger", type: .unit)]
        // 条件分支：路由器（cond 决定把 value 路由到 out1/out2 之一）
        case .branch:
            return [SocketDef(name: "cond", type: .bool),
                    SocketDef(name: "value", type: .generic)]
        case .`switch`:
            return [SocketDef(name: "index", type: .int),
                    SocketDef(name: "value", type: .generic)]
        // 变量操作：trigger 脉冲驱动，value 是要写入变量的数据
        case .set:
            return [SocketDef(name: "trigger", type: .unit),
                    SocketDef(name: "value", type: .generic)]
        case .toggle:
            return [SocketDef(name: "trigger", type: .unit)]
        // 副作用
        case .consume:
            return [SocketDef(name: "data", type: .output)]
        case .hud:
            return [SocketDef(name: "data", type: .output)]
        case .haptic, .mouse, .freeze, .notify:
            return [SocketDef(name: "trigger", type: .unit)]
        // 流控制
        case .split:
            return [SocketDef(name: "value", type: .generic)]
        case .merge:
            return [SocketDef(name: "input1", type: .float),
                    SocketDef(name: "input2", type: .float)]
        case .baseline:
            return [SocketDef(name: "trigger", type: .unit, required: false)]
        case .state:
            return [SocketDef(name: "value", type: .generic, required: false)]
        }
    }

    /// 输出端口（节点右侧）
    public static func outputSockets(of type: NodeType) -> [SocketDef] {
        switch type {
        case .pipeOut:
            return [SocketDef(name: "trigger", type: .unit)]
        /// 识别器：时机脉冲输出（unit，时机切换那帧有效）+ isHolding（bool，每帧）
        case .recognizer:
            return [SocketDef(name: "firstTap", type: .unit),
                    SocketDef(name: "enterHolding", type: .unit),
                    SocketDef(name: "tick", type: .unit),
                    SocketDef(name: "exitHolding", type: .unit),
                    SocketDef(name: "isHolding", type: .bool)]
        /// 唯一数据源：触控板多变量输出 + 原始帧（fingers 给识别器）
        case .touchData:
            return [SocketDef(name: "normX", type: .float),
                    SocketDef(name: "normY", type: .float),
                    SocketDef(name: "size", type: .float),
                    SocketDef(name: "pressure", type: .float),
                    SocketDef(name: "velX", type: .float),
                    SocketDef(name: "velY", type: .float),
                    SocketDef(name: "fingers", type: .fingers)]
        case .value:
            return [SocketDef(name: "value", type: .float)]
        // 区域引用：输出 region 数据（给识别器）
        case .region:
            return [SocketDef(name: "region", type: .region)]
        // 无输出：参数承载 / 视觉
        case .event, .group:
            return []
        // 数学/变换
        case .transform, .scale, .clamp, .abs, .sign:
            return [SocketDef(name: "result", type: .float)]
        case .quantize:
            return [SocketDef(name: "tick", type: .output)]
        case .gate:
            return [SocketDef(name: "pass", type: .bool)]
        case .debounce:
            return [SocketDef(name: "trigger", type: .unit)]
        case .branch:
            return [SocketDef(name: "out1", type: .generic),
                    SocketDef(name: "out2", type: .generic)]
        case .`switch`:
            return [SocketDef(name: "result", type: .generic)]
        // 变量操作：执行后输出 unit（事件脉冲，供后续节点串联）
        case .set, .toggle:
            return [SocketDef(name: "result", type: .unit)]
        // 副作用：执行完输出 unit（事件脉冲，供后续节点串联）
        case .consume, .haptic, .hud, .mouse, .freeze, .notify:
            return [SocketDef(name: "result", type: .unit)]
        // 流控制
        case .split:
            return [SocketDef(name: "out1", type: .generic),
                    SocketDef(name: "out2", type: .generic)]
        case .merge:
            return [SocketDef(name: "result", type: .float)]
        case .baseline:
            return [SocketDef(name: "result", type: .float)]
        case .state:
            return [SocketDef(name: "value", type: .generic)]
        }
    }

    /// 连线类型匹配：两端类型一致，或任一端为 generic（泛型匹配任意）
    public static func canConnect(from outputType: SocketType, to inputType: SocketType) -> Bool {
        outputType == inputType || outputType == .generic || inputType == .generic
    }
}
