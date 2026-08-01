import Foundation

// MARK: - v2 管线值对象（迁移器输入）

/// v2 线性管线的全部可配置参数（迁移前 GestureConfig 的字段集合）
/// 引擎/配置解码时从 v2 字段组装此对象 → 迁移为 Timeline 图
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

/// v2 线性管线 → Timeline 图集迁移器
///
/// 生成 4 条 Timeline（等价于 v2 配置的全部行为）：
///   - onFirstTap：触发识别（轻点参数）→ 状态机读取
///   - onEnterHolding：记录基线 + 锁鼠标 + 进入震动
///   - onTick：信号→变换→量化→分支(边界?)→消费/冻结
///   - onExitHolding：解锁鼠标 + 退出震动
///
/// 用户打开旧配置 → 看到等价的 Timeline 图，可在此基础上修改扩展。
public enum TimelineMigrator {

    /// 生成 4 条 Timeline（v2 配置的等价图）
    public static func migrate(pipeline: LegacyPipelineConfig, event: EventConfig) -> [TimelineConfig] {
        var timelines: [TimelineConfig] = []
        timelines.append(buildRecognizeTimeline(pipeline))
        timelines.append(buildEnterTimeline(pipeline))
        timelines.append(buildTickTimeline(pipeline, event: event))
        timelines.append(buildExitTimeline(pipeline))
        return timelines
    }

    // MARK: - onFirstTap（触发识别）

    private static func buildRecognizeTimeline(_ p: LegacyPipelineConfig) -> TimelineConfig {
        let node = NodeConfig(
            type: .recognize,
            params: NodeParams(
                tapMaxDuration: p.tapMaxDuration,
                tapMaxDrift: p.tapMaxDrift,
                tapMaxGap: p.tapMaxGap,
                holdMinDuration: p.holdMinDuration
            ),
            x: 0, y: 0, title: "轻点识别"
        )
        return TimelineConfig(trigger: .onFirstTap, nodes: [node], edges: [], entryNodeIDs: [node.id])
    }

    // MARK: - onEnterHolding

    private static func buildEnterTimeline(_ p: LegacyPipelineConfig) -> TimelineConfig {
        var nodes: [NodeConfig] = []
        let edges: [Edge] = []
        var entries: [UUID] = []

        // 1. BaselineNode：记录进入时的原始信号值（key: "startRaw"）
        let baseline = NodeConfig(
            type: .baseline,
            params: NodeParams(source: p.signalSource, key: "startRaw"),
            x: 0, y: 0, title: "记录起始信号"
        )
        nodes.append(baseline)
        entries.append(baseline.id)

        // 2. MouseNode：锁定光标（若配置了解除关联）
        if p.disassociateMouse {
            let mouse = NodeConfig(
                type: .mouse,
                params: NodeParams(mouseMode: .lockPosition),
                x: 0, y: 60, title: "锁定光标"
            )
            nodes.append(mouse)
        }

        // 3. HapticNode：进入震动
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
        }

        return TimelineConfig(trigger: .onEnterHolding, nodes: nodes, edges: edges, entryNodeIDs: entries)
    }

    // MARK: - onTick（核心调节链路）

    private static func buildTickTimeline(_ p: LegacyPipelineConfig, event: EventConfig) -> TimelineConfig {
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

        return TimelineConfig(trigger: .onTick, nodes: nodes, edges: edges, entryNodeIDs: entries)
    }

    // MARK: - onExitHolding

    private static func buildExitTimeline(_ p: LegacyPipelineConfig) -> TimelineConfig {
        var nodes: [NodeConfig] = []
        let edges: [Edge] = []
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

        return TimelineConfig(trigger: .onExitHolding, nodes: nodes, edges: edges, entryNodeIDs: entries)
    }
}
