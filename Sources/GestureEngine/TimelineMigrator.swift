import Foundation

// MARK: - v2 管线值对象（迁移器输入）

/// v2 线性管线的全部可配置参数（迁移前 GestureConfig 的字段集合）
/// 引擎/配置解码时从 v2 字段组装此对象 → 迁移为单张节点图
public struct LegacyPipelineConfig {
    public var signalSource: SignalSource
    public var transformMode: TransformMode
    public var triggerMode: TriggerMode
    public var stepNorm: Float
    public var sensitivity: Float
    public var hapticEnter: HapticEvent
    public var hapticTick: HapticEvent
    public var hapticBoundary: HapticEvent
    public var hapticExit: HapticEvent
    public var disassociateMouse: Bool
    // 触发识别参数
    public var tapMaxDuration: Double
    public var tapMaxDrift: Float
    public var tapMaxGap: Double
    public var holdMinDuration: Double

    public init(signalSource: SignalSource = .normY,
                transformMode: TransformMode = .delta,
                triggerMode: TriggerMode = .discrete,
                stepNorm: Float = 0.02,
                sensitivity: Float = 1.0,
                hapticEnter: HapticEvent = .enter,
                hapticTick: HapticEvent = .tick,
                hapticBoundary: HapticEvent = .boundary,
                hapticExit: HapticEvent = .exit,
                disassociateMouse: Bool = true,
                tapMaxDuration: Double = 0.20,
                tapMaxDrift: Float = 0.05,
                tapMaxGap: Double = 0.30,
                holdMinDuration: Double = 0.20) {
        self.signalSource = signalSource
        self.transformMode = transformMode
        self.triggerMode = triggerMode
        self.stepNorm = stepNorm
        self.sensitivity = sensitivity
        self.hapticEnter = hapticEnter
        self.hapticTick = hapticTick
        self.hapticBoundary = hapticBoundary
        self.hapticExit = hapticExit
        self.disassociateMouse = disassociateMouse
        self.tapMaxDuration = tapMaxDuration
        self.tapMaxDrift = tapMaxDrift
        self.tapMaxGap = tapMaxGap
        self.holdMinDuration = holdMinDuration
    }
}

// MARK: - 迁移器

/// v2 线性管线 → 单张自由节点图迁移器（v7 全显式数据流）
///
/// 一张图，含：
/// - touchData 唯一数据源（纯输出：各信号 + fingers 原始帧）
/// - RegionRef 输出 region 数据
/// - recognizer 黑盒算法（显式输入 fingers+region，输出时机脉冲 + isHolding）
/// - 4 个 pipeOut 管道出口（每个 TriggerEvent 一个链入口）
/// - 外部状态用 StateNode 变量 + set/toggle 操作节点（cursorLocked/frozen）
/// 各阶段原逻辑垂直堆叠，挂在对应 pipeOut 之后。用户可在图上自由连线扩展。
public enum TimelineMigrator {

    /// 一个逻辑块的产物（节点 + 内部边 + 入口节点）
    private typealias Block = (nodes: [NodeConfig], edges: [Edge], entries: [UUID])

    /// 生成单张节点图（等价 v2 配置的全部行为）
    /// - Parameters:
    ///   - regionID / eventID: 手势绑定（非 nil 时生成 RegionRef/EventRef 节点）
    public static func migrate(pipeline: LegacyPipelineConfig, event: EventConfig,
                               regionID: UUID? = nil, eventID: UUID? = nil) -> TimelineConfig {
        var nodes: [NodeConfig] = []
        var edges: [Edge] = []
        var entries: [UUID] = []

        // 1. touchData 唯一数据源（纯输出：信号 + fingers 原始帧给识别器）
        let touchData = NodeConfig(type: .touchData, x: -480, y: 20, title: "触控板数据")
        nodes.append(touchData)

        // 2. RegionRef：输出 region 数据（给识别器；boundRegionID 从图上读取）
        if let regionID {
            nodes.append(NodeConfig(type: .region, params: NodeParams(regionID: regionID),
                                    x: -320, y: -80, title: "触发区域"))
        }
        if let eventID {
            nodes.append(NodeConfig(type: .event, params: NodeParams(eventID: eventID),
                                    x: -160, y: -80, title: "绑定事件"))
        }

        // 3. recognizer 黑盒算法：显式输入 fingers + region
        let recognizer = NodeConfig(
            type: .recognizer,
            params: NodeParams(
                source: pipeline.signalSource,
                tapMaxDuration: pipeline.tapMaxDuration,
                tapMaxDrift: pipeline.tapMaxDrift,
                tapMaxGap: pipeline.tapMaxGap,
                holdMinDuration: pipeline.holdMinDuration,
                stepNorm: pipeline.stepNorm
            ),
            x: -320, y: 20, title: "识别器"
        )
        nodes.append(recognizer)
        entries.append(recognizer.id)
        // 数据流连线：touchData.fingers → recognizer.fingers；RegionRef.region → recognizer.region
        edges.append(Edge(from: PortID(nodeID: touchData.id, portName: "fingers"),
                          to: PortID(nodeID: recognizer.id, portName: "fingers")))
        if let regionID, let regionRef = nodes.first(where: { $0.type == .region }) {
            edges.append(Edge(from: PortID(nodeID: regionRef.id, portName: "region"),
                              to: PortID(nodeID: recognizer.id, portName: "region")))
        }

        // 4. 各触发链：recognizer.<pulse> → pipeOut(trigger) → 块内节点
        func addPipe(_ triggerEvent: TriggerEvent, pulse: String, dy: Double) -> UUID {
            let pipe = NodeConfig(
                type: .pipeOut,
                params: NodeParams(trigger: triggerEvent),
                x: -200, y: dy + 20,
                title: triggerEvent.displayName
            )
            nodes.append(pipe)
            edges.append(Edge(from: PortID(nodeID: recognizer.id, portName: pulse),
                              to: PortID(nodeID: pipe.id, portName: "trigger")))
            return pipe.id
        }

        let blocks: [(trigger: TriggerEvent, pulse: String, block: Block, dy: Double)] = [
            // onFirstTap：识别在 recognizer 完成，块为空（仅管道出口作链入口标记）
            (.onFirstTap, "firstTap", Block([], [], []), 0),
            (.onEnterHolding, "enterHolding", buildEnterBlock(pipeline), 260),
            (.onTick, "tick", buildTickBlock(pipeline, event: event, recognizerID: recognizer.id, touchDataID: touchData.id), 520),
            (.onExitHolding, "exitHolding", buildExitBlock(pipeline), 780),
        ]

        for item in blocks {
            let pipeID = addPipe(item.trigger, pulse: item.pulse, dy: item.dy)

            // 块内节点垂直堆叠
            for var node in item.block.nodes {
                node.y += item.dy
                nodes.append(node)
            }
            edges.append(contentsOf: item.block.edges)

            // 块入口连到 pipeOut（管道出口透传启动下游；入口节点输入端口为 "trigger"）
            for entryID in item.block.entries {
                edges.append(Edge(from: PortID(nodeID: pipeID, portName: "trigger"),
                                  to: PortID(nodeID: entryID, portName: "trigger")))
            }
        }

        return TimelineConfig(trigger: .onFirstTap, nodes: nodes, edges: edges, entryNodeIDs: entries)
    }

    // MARK: - onEnterHolding

    private static func buildEnterBlock(_ p: LegacyPipelineConfig) -> Block {
        var nodes: [NodeConfig] = []
        var edges: [Edge] = []
        var entries: [UUID] = []

        // BaselineNode：记录进入时的原始信号值（key: "startRaw"）
        let baseline = NodeConfig(
            type: .baseline,
            params: NodeParams(source: p.signalSource, key: "startRaw"),
            x: 0, y: 0, title: "记录起始信号"
        )
        nodes.append(baseline)
        entries.append(baseline.id)

        // cursorLocked = 1（外部状态变量，替代 mouse 专有卡片）
        if p.disassociateMouse {
            let one = NodeConfig(type: .value, params: NodeParams(constant: 1),
                                 x: 0, y: 60, title: "值 1")
            let set = NodeConfig(type: .set, params: NodeParams(key: "cursorLocked"),
                                 x: 150, y: 60, title: "设置锁定")
            nodes.append(one)
            nodes.append(set)
            entries.append(set.id)
            edges.append(Edge(from: PortID(nodeID: one.id, portName: "value"),
                              to: PortID(nodeID: set.id, portName: "value")))
        }

        // HapticNode：进入震动
        if p.hapticEnter.enabled {
            let haptic = NodeConfig(
                type: .haptic,
                params: NodeParams(
                    waveform: p.hapticEnter.waveform,
                    count: p.hapticEnter.count,
                    intervalUs: p.hapticEnter.intervalUs,
                    async: true
                ),
                x: 0, y: 120, title: "进入震动"
            )
            nodes.append(haptic)
            entries.append(haptic.id)
        }

        return (nodes, edges, entries)
    }

    // MARK: - onTick（核心调节链路）

    private static func buildTickBlock(_ p: LegacyPipelineConfig, event: EventConfig,
                                       recognizerID: UUID, touchDataID: UUID) -> Block {
        var nodes: [NodeConfig] = []
        var edges: [Edge] = []
        var entries: [UUID] = []

        func add(_ node: NodeConfig) -> UUID {
            nodes.append(node)
            return node.id
        }
        func connect(_ from: PortID, _ to: PortID) {
            edges.append(Edge(from: from, to: to))
        }

        // 1. isHolding 门控：识别器 holding 状态 → branch.cond（数据只在 holding 时放行）
        //    touchData 是全局唯一数据源（复用顶层节点），经 branch 门控后进入变换链
        let gate = add(NodeConfig(
            type: .branch,
            params: NodeParams(predicate: .positive),
            x: 0, y: 0, title: "保持中?"
        ))
        entries.append(gate)
        connect(PortID(nodeID: recognizerID, portName: "isHolding"),
                PortID(nodeID: gate, portName: "cond"))
        connect(PortID(nodeID: touchDataID, portName: p.signalSource.rawValue),
                PortID(nodeID: gate, portName: "value"))

        // 2. TransformNode：delta/absolute
        let transform = add(NodeConfig(
            type: .transform,
            params: NodeParams(transform: p.transformMode),
            x: 150, y: 0, title: "变换"
        ))
        connect(PortID(nodeID: gate, portName: "out1"), PortID(nodeID: transform, portName: "value"))

        // 3. QuantizeNode：discrete/continuous
        let quantize = add(NodeConfig(
            type: .quantize,
            params: NodeParams(
                stepNorm: p.stepNorm,
                sensitivity: p.sensitivity,
                triggerMode: p.triggerMode
            ),
            x: 300, y: 0, title: "量化"
        ))
        connect(PortID(nodeID: transform, portName: "result"), PortID(nodeID: quantize, portName: "value"))

        // 4. BranchNode（路由器）：是否在边界？cond 用 predicate（无输入连线时回退）
        let branch = add(NodeConfig(
            type: .branch,
            params: NodeParams(predicate: .notAtBoundary),
            x: 450, y: 0, title: "在边界内?"
        ))
        connect(PortID(nodeID: quantize, portName: "tick"), PortID(nodeID: branch, portName: "value"))

        // 5. true 分支（out1）：ConsumeNode + HapticNode(tick)
        let consume = add(NodeConfig(
            type: .consume,
            params: NodeParams(
                action: event.actionType,
                method: event.executionMethod,
                step: event.step
            ),
            x: 600, y: -60, title: "执行调节"
        ))
        connect(PortID(nodeID: branch, portName: "out1"), PortID(nodeID: consume, portName: "data"))

        if p.hapticTick.enabled {
            let haptic = add(NodeConfig(
                type: .haptic,
                params: NodeParams(
                    waveform: p.hapticTick.waveform,
                    count: p.hapticTick.count,
                    intervalUs: p.hapticTick.intervalUs,
                    async: true
                ),
                x: 750, y: -60, title: "刻度震动"
            ))
            connect(PortID(nodeID: consume, portName: "result"), PortID(nodeID: haptic, portName: "trigger"))
        }

        // 6. false 分支（out2）：到达边界 → 边界震动 + frozen=1（变量，替代 freeze 卡片）
        if p.hapticBoundary.enabled {
            let haptic = add(NodeConfig(
                type: .haptic,
                params: NodeParams(
                    waveform: p.hapticBoundary.waveform,
                    count: p.hapticBoundary.count,
                    intervalUs: p.hapticBoundary.intervalUs,
                    async: true
                ),
                x: 600, y: 60, title: "边界震动"
            ))
            connect(PortID(nodeID: branch, portName: "out2"), PortID(nodeID: haptic, portName: "trigger"))
        }

        let one = add(NodeConfig(type: .value, params: NodeParams(constant: 1),
                                 x: 750, y: 60, title: "值 1"))
        let setFrozen = add(NodeConfig(type: .set, params: NodeParams(key: "frozen"),
                                       x: 900, y: 60, title: "设置冻结"))
        connect(PortID(nodeID: branch, portName: "out2"), PortID(nodeID: setFrozen, portName: "trigger"))
        connect(PortID(nodeID: one, portName: "value"), PortID(nodeID: setFrozen, portName: "value"))

        return (nodes, edges, entries)
    }

    // MARK: - onExitHolding

    private static func buildExitBlock(_ p: LegacyPipelineConfig) -> Block {
        var nodes: [NodeConfig] = []
        var edges: [Edge] = []
        var entries: [UUID] = []

        // cursorLocked = 0（解锁光标：变量操作，替代 mouse 专有卡片）
        if p.disassociateMouse {
            let zero = NodeConfig(type: .value, params: NodeParams(constant: 0),
                                  x: 0, y: 0, title: "值 0")
            let set = NodeConfig(type: .set, params: NodeParams(key: "cursorLocked"),
                                 x: 150, y: 0, title: "解除锁定")
            nodes.append(zero)
            nodes.append(set)
            entries.append(set.id)
            edges.append(Edge(from: PortID(nodeID: zero.id, portName: "value"),
                              to: PortID(nodeID: set.id, portName: "value")))
        }

        if p.hapticExit.enabled {
            let haptic = NodeConfig(
                type: .haptic,
                params: NodeParams(
                    waveform: p.hapticExit.waveform,
                    count: p.hapticExit.count,
                    intervalUs: p.hapticExit.intervalUs,
                    async: true
                ),
                x: 0, y: 60, title: "退出震动"
            )
            nodes.append(haptic)
            entries.append(haptic.id)
        }

        return (nodes, edges, entries)
    }
}
