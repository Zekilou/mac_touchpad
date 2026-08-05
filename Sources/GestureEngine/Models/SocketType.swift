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
        // 无输入：常量 / 参数承载 / 视觉 / 系统状态源（数据从 FrameContext 注入）
        case .value, .event, .group, .boundaryState:
            return []
        // 区域引用：无输入（区域数据从 FrameContext 读取，卡片内 regionID 关联）
        case .region:
            return []
        // 识别器（废弃）：数据流输入全显式（fingers 原始帧 + region 触发区域）
        case .recognizer:
            return [SocketDef(name: "fingers", type: .fingers),
                    SocketDef(name: "region", type: .region)]
        // 变量：trigger+value 为写请求（帧尾生效）；无写请求时仅读
        case .varRef:
            return [SocketDef(name: "trigger", type: .unit, required: false),
                    SocketDef(name: "value", type: .generic, required: false)]
        // 手指事件：fingers 原始帧（+ 可选 region 区域过滤）→ 按下/抬起/存在 + 手指信号
        case .finger:
            return [SocketDef(name: "fingers", type: .fingers),
                    SocketDef(name: "region", type: .region, required: false)]
        // 数学/变换：单 float 输入
        case .transform, .scale, .clamp, .abs, .sign:
            return [SocketDef(name: "value", type: .float)]
        // 比较：a 与 b（threshold 或输入）
        case .compare:
            return [SocketDef(name: "a", type: .generic, required: false),
                    SocketDef(name: "b", type: .generic, required: false)]
        // 算术：a ± × ÷ b
        case .arith:
            return [SocketDef(name: "a", type: .float),
                    SocketDef(name: "b", type: .float)]
        // 取反（bool）
        case .not:
            return [SocketDef(name: "value", type: .bool)]
        // 时间：now 无输入；elapsed trigger 重置计时
        case .now:
            return []
        case .elapsed:
            return [SocketDef(name: "trigger", type: .unit, required: false)]
        // 累积：value 每帧合并（sum/max/min），trigger 重置
        case .accumulate:
            return [SocketDef(name: "value", type: .float),
                    SocketDef(name: "trigger", type: .unit, required: false)]
        // 量化/门控
        case .quantize:
            return [SocketDef(name: "value", type: .float)]
        case .gate:
            return [SocketDef(name: "value", type: .float)]
        case .debounce:
            return [SocketDef(name: "trigger", type: .unit)]
        // 条件分支：路由器（cond 决定把 value 路由到 out1/out2 之一）
        // cond 为 generic：接收 bool 值（true/false 路由）或 unit/output 脉冲（执行器"有效即 true"）
        case .branch:
            return [SocketDef(name: "cond", type: .generic),
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
        // 模块：端口由 params.moduleInputs 动态声明（见 inputSockets(of: node:)）
        case .module:
            return []
        // 连接器：moduleInput 无输入；moduleOutput 接收内部计算值
        case .moduleInput:
            return []
        case .moduleOutput:
            return [SocketDef(name: "value", type: .generic)]
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
        // 边界状态：当前值在哪个边界（-1 下 / 0 无 / +1 上）+ 是否在边界（side 用 float 便于 arith 乘积判定）
        case .boundaryState:
            return [SocketDef(name: "side", type: .float),
                    SocketDef(name: "atBoundary", type: .bool)]
        // 区域引用：输出 region 数据（给识别器/手指事件）
        case .region:
            return [SocketDef(name: "region", type: .region)]
        // 变量：输出当前值
        case .varRef:
            return [SocketDef(name: "value", type: .generic)]
        // 手指事件：按下/抬起脉冲（unit）+ 边沿（bool）+ 存在状态 + 手指信号 + 身份
        case .finger:
            return [SocketDef(name: "touchDown", type: .unit),
                    SocketDef(name: "touchUp", type: .unit),
                    SocketDef(name: "down", type: .bool),
                    SocketDef(name: "up", type: .bool),
                    SocketDef(name: "touching", type: .bool),
                    SocketDef(name: "present", type: .bool),
                    SocketDef(name: "normY", type: .float),
                    SocketDef(name: "normX", type: .float),
                    SocketDef(name: "pathIndex", type: .int),
                    SocketDef(name: "pressure", type: .float)]
        // 无输出：参数承载 / 视觉
        case .event, .group:
            return []
        // 数学/变换
        case .transform, .scale, .clamp, .abs, .sign:
            return [SocketDef(name: "result", type: .float)]
        // 比较 → bool；算术 → float；取反 → bool
        case .compare, .not:
            return [SocketDef(name: "result", type: .bool)]
        case .arith:
            return [SocketDef(name: "result", type: .float)]
        // 时间
        case .now, .elapsed:
            return [SocketDef(name: "result", type: .float)]
        // 累积
        case .accumulate:
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
        // 模块：端口由 params.moduleOutputs 动态声明（见 outputSockets(of: node:)）
        case .module:
            return []
        // 连接器：moduleInput 输出注入值；moduleOutput 无输出（只收集内部值）
        case .moduleInput:
            return [SocketDef(name: "value", type: .generic)]
        case .moduleOutput:
            return []
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

    // MARK: - 节点动态端口（module 端口声明来自 params）

    /// 节点输入端口（module 读 params.moduleInputs 动态声明；moduleOutput 连接器接收内部值）
    public static func inputSockets(of node: NodeConfig) -> [SocketDef] {
        switch node.type {
        case .module:
            return (node.params.moduleInputs ?? []).map { SocketDef(name: $0.name, type: $0.type) }
        case .moduleOutput:
            return [SocketDef(name: "value", type: .generic)]
        default:
            return inputSockets(of: node.type)
        }
    }

    /// 节点输出端口（module 读 params.moduleOutputs 动态声明；moduleInput 连接器输出注入值）
    public static func outputSockets(of node: NodeConfig) -> [SocketDef] {
        switch node.type {
        case .module:
            return (node.params.moduleOutputs ?? []).map { SocketDef(name: $0.name, type: $0.type) }
        case .moduleInput:
            return [SocketDef(name: "value", type: .generic)]
        default:
            return outputSockets(of: node.type)
        }
    }
}

// MARK: - 透传类型推导（generic 端口沿数据流确定实际类型）

/// generic（透传）端口的类型是「沿数据流动态确定」的，但**静态可推导**：
/// - 输入端口：看入边对端输出类型（连了什么就是什么）
/// - 输出端口：看节点自身透传来源输入端口（branch/split/switch/varRef/state 的 value 输入）的入边对端
/// - 对端仍是 generic → 递归（深度上限防环）
/// - 无法确定（无入边 / 环）→ nil，UI 显示纯空心六边形 any
extension TimelineConfig {
    public func resolvedPortType(of nodeID: UUID, port: String, isInput: Bool) -> SocketType? {
        resolvePortType(nodeID: nodeID, port: port, isInput: isInput, depth: 0)
    }

    private func resolvePortType(nodeID: UUID, port: String, isInput: Bool, depth: Int) -> SocketType? {
        guard depth < 4, let node = nodes.first(where: { $0.id == nodeID }) else { return nil }
        let sockets = isInput ? NodeTypeDef.inputSockets(of: node) : NodeTypeDef.outputSockets(of: node)
        guard let declared = sockets.first(where: { $0.name == port })?.type else { return nil }
        // 非 generic：类型已静态确定，直接返回
        guard declared == .generic else { return declared }

        // 输入端口：直接看入边对端输出类型
        if isInput {
            guard let e = edges.first(where: { $0.to.nodeID == nodeID && $0.to.portName == port }) else { return nil }
            return resolvePortType(nodeID: e.from.nodeID, port: e.from.portName, isInput: false, depth: depth + 1)
        }
        // 输出端口：透传来源 = 节点自身的 value 输入端口（输入什么就输出什么）
        for sp in passthroughInputPorts(of: node.type) {
            if let e = edges.first(where: { $0.to.nodeID == nodeID && $0.to.portName == sp }) {
                return resolvePortType(nodeID: e.from.nodeID, port: e.from.portName, isInput: false, depth: depth + 1)
            }
        }
        return nil
    }

    /// 透传来源输入端口名：这些节点的输出类型恒等于其 value 输入
    private func passthroughInputPorts(of type: NodeType) -> [String] {
        switch type {
        case .branch, .split, .`switch`, .varRef, .state:
            return ["value"]
        default:
            return []
        }
    }
}

// MARK: - 多选 / 复制粘贴 / 框选（纯逻辑，UI 调用）

extension TimelineConfig {

    /// 复制选中节点集：节点本体 + 两端都在选中集内的边（内部连线；连到集外的边不复制）
    public func clipSelection(_ ids: Set<UUID>) -> (nodes: [NodeConfig], edges: [Edge]) {
        let clipped = nodes.filter { ids.contains($0.id) }
        let idSet = Set(clipped.map(\.id))
        let internalEdges = edges.filter { idSet.contains($0.from.nodeID) && idSet.contains($0.to.nodeID) }
        return (clipped, internalEdges)
    }

    /// 粘贴：复制节点+边并整体偏移 (dx,dy)；节点生成新 UUID，内部边按 idMap 重映射。
    /// 返回的新节点/边由 UI 追加到图并选中。
    public func pasteClip(_ nodes: [NodeConfig], _ edges: [Edge], dx: Double, dy: Double)
        -> (nodes: [NodeConfig], edges: [Edge]) {
        let idMap = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, UUID()) })
        let newNodes = nodes.map { n in
            NodeConfig(id: idMap[n.id]!,
                       type: n.type,
                       params: n.params,
                       x: n.x + dx, y: n.y + dy,
                       title: n.title,
                       subgraph: n.subgraph)
        }
        let newEdges = edges.map { e in
            Edge(from: PortID(nodeID: idMap[e.from.nodeID]!, portName: e.from.portName),
                 to: PortID(nodeID: idMap[e.to.nodeID]!, portName: e.to.portName))
        }
        return (newNodes, newEdges)
    }

    /// 框选命中：画布坐标 rect 与节点矩形相交的节点 id（节点卡片 + 组框都算）。
    /// 普通节点高度按固定值估算（框选相交判定对高度不敏感，只要求头部/端口区落入即可）。
    public func nodes(in rect: CGRect, nodeWidth: CGFloat) -> Set<UUID> {
        guard rect.width > 0.5, rect.height > 0.5 else { return [] }
        var hits = Set<UUID>()
        for n in nodes {
            let w: CGFloat = n.type == .group ? CGFloat(n.params.groupWidth ?? 300) : nodeWidth
            let h: CGFloat = n.type == .group ? CGFloat(n.params.groupHeight ?? 200) : 120
            let nodeRect = CGRect(x: CGFloat(n.x), y: CGFloat(n.y), width: w, height: h)
            if rect.intersects(nodeRect) { hits.insert(n.id) }
        }
        return hits
    }
}
