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

/// v2 线性管线 → 单张自由节点图迁移器（v5 完全配置化）
///
/// 不再有「四个阶段」——输出一张图，含 4 个 Trigger 入口节点（轻点/进入保持/每帧/退出保持），
/// 各阶段原逻辑垂直堆叠，入口节点连到对应 Trigger。用户可在图上自由连线扩展。
public enum TimelineMigrator {

    /// 一个逻辑块的产物（节点 + 内部边 + 入口节点）
    private typealias Block = (nodes: [NodeConfig], edges: [Edge], entries: [UUID])

    /// 生成单张节点图（等价 v2 配置的全部行为）
    /// - Parameters:
    ///   - regionID / eventID: 手势绑定（非 nil 时生成 RegionRef/EventRef 节点）
    public static func migrate(pipeline: LegacyPipelineConfig, event: EventConfig,
                               regionID: UUID? = nil, eventID: UUID? = nil) -> TimelineConfig {
        let blocks: [(trigger: TriggerEvent, block: Block, dy: Double)] = [
            (.onFirstTap,      buildRecognizeBlock(pipeline, regionID: regionID, eventID: eventID), 0),
            (.onEnterHolding,  buildEnterBlock(pipeline), 400),
            (.onTick,          buildTickBlock(pipeline, event: event), 800),
            (.onExitHolding,   buildExitBlock(pipeline), 1200),
        ]

        var nodes: [NodeConfig] = []
        var edges: [Edge] = []
        var entries: [UUID] = []

        for item in blocks {
            // Trigger 入口节点（引擎执行时机）
            let trigger = NodeConfig(
                type: .trigger,
                params: NodeParams(trigger: item.trigger),
                x: -240, y: item.dy + 20,
                title: item.trigger.displayName
            )
            nodes.append(trigger)
            entries.append(trigger.id)

            // 块内节点垂直堆叠
            for var node in item.block.nodes {
                node.y += item.dy
                nodes.append(node)
            }
            edges.append(contentsOf: item.block.edges)

            // 块入口连到 Trigger
            for entryID in item.block.entries {
                edges.append(Edge(from: PortID(nodeID: trigger.id, portName: "output"),
                                  to: PortID(nodeID: entryID, portName: "input")))
            }
        }

        return TimelineConfig(trigger: .onFirstTap, nodes: nodes, edges: edges, entryNodeIDs: entries)
    }

    // MARK: - onFirstTap（触发识别 + 绑定引用）

    private static func buildRecognizeBlock(_ p: LegacyPipelineConfig,
                                            regionID: UUID?, eventID: UUID?) -> Block {
        var nodes: [NodeConfig] = []
        var entries: [UUID] = []

        // RegionRefNode：手势绑定的触发区域
        if let regionID {
            let node = NodeConfig(
                type: .region,
                params: NodeParams(regionID: regionID),
                x: 0, y: 0, title: "触发区域"
            )
            nodes.append(node)
            entries.append(node.id)
        }

        // EventRefNode：手势绑定的事件
        if let eventID {
            let node = NodeConfig(
                type: .event,
                params: NodeParams(eventID: eventID),
                x: 200, y: 0, title: "绑定事件"
            )
            nodes.append(node)
            entries.append(node.id)
        }

        // RecognizeNode：轻点识别参数
        let recognize = NodeConfig(
            type: .recognize,
            params: NodeParams(
                tapMaxDuration: p.tapMaxDuration,
                tapMaxDrift: p.tapMaxDrift,
                tapMaxGap: p.tapMaxGap,
                holdMinDuration: p.holdMinDuration
            ),
            x: 0, y: 60, title: "轻点识别"
        )
        nodes.append(recognize)
        entries.append(recognize.id)

        return (nodes, [], entries)
    }

    // MARK: - onEnterHolding

    private static func buildEnterBlock(_ p: LegacyPipelineConfig) -> Block {
        var nodes: [NodeConfig] = []
        var entries: [UUID] = []

        // BaselineNode：记录进入时的原始信号值（key: "startRaw"）
        let baseline = NodeConfig(
            type: .baseline,
            params: NodeParams(source: p.signalSource, key: "startRaw"),
            x: 0, y: 0, title: "记录起始信号"
        )
        nodes.append(baseline)
        entries.append(baseline.id)

        // MouseNode：锁定光标（若配置了解除关联）
        if p.disassociateMouse {
            let mouse = NodeConfig(
                type: .mouse,
                params: NodeParams(mouseMode: .lockPosition),
                x: 0, y: 60, title: "锁定光标"
            )
            nodes.append(mouse)
            entries.append(mouse.id)
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

        return (nodes, [], entries)
    }

    // MARK: - onTick（核心调节链路）

    private static func buildTickBlock(_ p: LegacyPipelineConfig, event: EventConfig) -> Block {
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

        // 1. SignalNode：提取信号源
        let signal = add(NodeConfig(
            type: .signal,
            params: NodeParams(source: p.signalSource),
            x: 0, y: 0, title: "信号源"
        ))
        entries.append(signal)

        // 2. TransformNode：delta/absolute
        let transform = add(NodeConfig(
            type: .transform,
            params: NodeParams(transform: p.transformMode),
            x: 200, y: 0, title: "变换"
        ))
        connect(PortID(nodeID: signal, portName: "output"), PortID(nodeID: transform, portName: "input"))

        // 3. QuantizeNode：discrete/continuous
        let quantize = add(NodeConfig(
            type: .quantize,
            params: NodeParams(
                stepNorm: p.stepNorm,
                sensitivity: p.sensitivity,
                triggerMode: p.triggerMode
            ),
            x: 400, y: 0, title: "量化"
        ))
        connect(PortID(nodeID: transform, portName: "output"), PortID(nodeID: quantize, portName: "input"))

        // 4. BranchNode：是否在边界？
        let branch = add(NodeConfig(
            type: .branch,
            params: NodeParams(predicate: .notAtBoundary),
            x: 600, y: 0, title: "在边界内?"
        ))
        connect(PortID(nodeID: quantize, portName: "output"), PortID(nodeID: branch, portName: "input"))

        // 5. true 分支：ConsumeNode + HapticNode(tick)
        let consume = add(NodeConfig(
            type: .consume,
            params: NodeParams(
                action: event.actionType,
                method: event.executionMethod,
                step: event.step
            ),
            x: 800, y: -80, title: "执行调节"
        ))
        connect(PortID(nodeID: branch, portName: "true"), PortID(nodeID: consume, portName: "input"))

        if p.hapticTick.enabled {
            let haptic = add(NodeConfig(
                type: .haptic,
                params: NodeParams(
                    waveform: p.hapticTick.waveform,
                    count: p.hapticTick.count,
                    intervalUs: p.hapticTick.intervalUs,
                    async: true
                ),
                x: 1000, y: -80, title: "刻度震动"
            ))
            connect(PortID(nodeID: consume, portName: "output"), PortID(nodeID: haptic, portName: "input"))
        }

        // 6. false 分支：首次到达边界 → 边界震动 + 冻结
        if p.hapticBoundary.enabled {
            let haptic = add(NodeConfig(
                type: .haptic,
                params: NodeParams(
                    waveform: p.hapticBoundary.waveform,
                    count: p.hapticBoundary.count,
                    intervalUs: p.hapticBoundary.intervalUs,
                    async: true
                ),
                x: 800, y: 80, title: "边界震动"
            ))
            connect(PortID(nodeID: branch, portName: "false"), PortID(nodeID: haptic, portName: "input"))
        }

        let freeze = add(NodeConfig(
            type: .freeze,
            params: NodeParams(unfreeze: .reverseSlide),
            x: 1000, y: 80, title: "冻结"
        ))
        connect(PortID(nodeID: branch, portName: "false"), PortID(nodeID: freeze, portName: "input"))

        return (nodes, edges, entries)
    }

    // MARK: - onExitHolding

    private static func buildExitBlock(_ p: LegacyPipelineConfig) -> Block {
        var nodes: [NodeConfig] = []
        var entries: [UUID] = []

        if p.disassociateMouse {
            let mouse = NodeConfig(
                type: .mouse,
                params: NodeParams(mouseMode: .unlockPosition),
                x: 0, y: 0, title: "解锁光标"
            )
            nodes.append(mouse)
            entries.append(mouse.id)
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

        return (nodes, [], entries)
    }
}
