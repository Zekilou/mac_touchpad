import Foundation

/// v2 GestureConfig → [TimelineConfig] 迁移器
///
/// 旧配置（信号源/变换/量化/震动散落字段）自动生成 3 条 Timeline 图：
///   - onEnterHolding：记录基线 + 锁鼠标 + 进入震动 + 边界 HUD
///   - onTick：信号→变换→量化→分支(边界?)→消费/冻结
///   - onExitHolding：解锁鼠标 + 退出震动
///
/// 用户打开旧配置 → 看到等价的 Timeline 图，可在此基础上修改扩展。
public enum TimelineMigrator {

    /// 生成 3 条 Timeline（v2 配置的等价图）
    /// - Parameters:
    ///   - gesture: 手势配置（信号管线 + 触觉 + 鼠标）
    ///   - event: 事件配置（action/method/step/directionRule）
    /// - Returns: 按执行顺序排列的 Timeline 数组（enter → tick → exit）
    public static func migrate(gesture: GestureConfig, event: EventConfig) -> [TimelineConfig] {
        var timelines: [TimelineConfig] = []
        timelines.append(buildEnterTimeline(gesture: gesture))
        timelines.append(buildTickTimeline(gesture: gesture, event: event))
        timelines.append(buildExitTimeline(gesture: gesture))
        return timelines
    }

    // MARK: - onEnterHolding

    private static func buildEnterTimeline(gesture: GestureConfig) -> TimelineConfig {
        var nodes: [NodeConfig] = []
        let edges: [Edge] = []
        var entries: [UUID] = []

        // 1. BaselineNode：记录进入时的原始信号值（key: "startRaw"）
        let baseline = NodeConfig(
            type: .baseline,
            params: NodeParams(source: gesture.signalSource, key: "startRaw"),
            x: 0, y: 0, title: "记录起始信号"
        )
        nodes.append(baseline)
        entries.append(baseline.id)

        // 2. MouseNode：锁定光标（若配置了解除关联）
        if gesture.disassociateMouse {
            let mouse = NodeConfig(
                type: .mouse,
                params: NodeParams(mouseMode: .lockPosition),
                x: 0, y: 60, title: "锁定光标"
            )
            nodes.append(mouse)
        }

        // 3. HapticNode：进入震动
        if gesture.hapticEnter.enabled {
            let haptic = NodeConfig(
                type: .haptic,
                params: NodeParams(
                    waveform: gesture.hapticEnter.waveform,
                    count: gesture.hapticEnter.count,
                    intervalUs: gesture.hapticEnter.intervalUs,
                    async: true
                ),
                x: 0, y: 120, title: "进入震动"
            )
            nodes.append(haptic)
        }

        return TimelineConfig(trigger: .onEnterHolding, nodes: nodes, edges: edges, entryNodeIDs: entries)
    }

    // MARK: - onTick（核心调节链路）

    private static func buildTickTimeline(gesture: GestureConfig, event: EventConfig) -> TimelineConfig {
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
            params: NodeParams(source: gesture.signalSource),
            x: 0, y: 0, title: "信号源"
        ))
        entries.append(signal)

        // 2. TransformNode：delta/absolute
        let transform = add(NodeConfig(
            type: .transform,
            params: NodeParams(transform: gesture.transformMode),
            x: 200, y: 0, title: "变换"
        ))
        connect(PortID(nodeID: signal, portName: "output"), PortID(nodeID: transform, portName: "input"))

        // 3. QuantizeNode：discrete/continuous
        let quantize = add(NodeConfig(
            type: .quantize,
            params: NodeParams(
                stepNorm: gesture.stepNorm,
                sensitivity: gesture.sensitivity
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

        if gesture.hapticTick.enabled {
            let haptic = add(NodeConfig(
                type: .haptic,
                params: NodeParams(
                    waveform: gesture.hapticTick.waveform,
                    count: gesture.hapticTick.count,
                    intervalUs: gesture.hapticTick.intervalUs,
                    async: true
                ),
                x: 1000, y: -80, title: "刻度震动"
            ))
            connect(PortID(nodeID: consume, portName: "output"), PortID(nodeID: haptic, portName: "input"))
        }

        // 6. false 分支：首次到达边界 → 边界震动 + 冻结
        if gesture.hapticBoundary.enabled {
            let haptic = add(NodeConfig(
                type: .haptic,
                params: NodeParams(
                    waveform: gesture.hapticBoundary.waveform,
                    count: gesture.hapticBoundary.count,
                    intervalUs: gesture.hapticBoundary.intervalUs,
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

    private static func buildExitTimeline(gesture: GestureConfig) -> TimelineConfig {
        var nodes: [NodeConfig] = []
        let edges: [Edge] = []
        var entries: [UUID] = []

        if gesture.disassociateMouse {
            let mouse = NodeConfig(
                type: .mouse,
                params: NodeParams(mouseMode: .unlockPosition),
                x: 0, y: 0, title: "解锁光标"
            )
            nodes.append(mouse)
            entries.append(mouse.id)
        }

        if gesture.hapticExit.enabled {
            let haptic = NodeConfig(
                type: .haptic,
                params: NodeParams(
                    waveform: gesture.hapticExit.waveform,
                    count: gesture.hapticExit.count,
                    intervalUs: gesture.hapticExit.intervalUs,
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
