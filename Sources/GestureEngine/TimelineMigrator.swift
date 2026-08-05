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

// MARK: - 迁移器（v8：状态机完全展开到图上）

/// v2 线性管线 → 单张自由节点图迁移器（v8 全显式状态机）
///
/// **识别器不再黑盒**——状态机用 11 个变量 + 10 条转移链完全展开在图上：
/// - 变量（varRef，帧首读/帧尾写）：phase(0=idle/1=firstTapDown/2=firstTapUp/3=secondTapDown/4=holding/5=cooldown)、
///   pathIndex、startTime、startPosX/Y、endTime、cursorLocked（frozen/freezeDir/startRaw/lastTriggerVal 已随冻结屏蔽移除）
/// - 物理层：finger 节点（面积/区域过滤 → 按下/抬起边沿 + 手指信号 + 身份）
/// - 转移链：compare(phase==N) AND 事件/时序/漂移条件 → branch 组合 → 写 phase + 附带变量
/// - 执行链：enterHolding（锁光标+进入震动）/ tick（信号→变换→量化→方向感知边界分流→消费+震动）/
///   exitHolding（解锁+退出震动）
/// 冻结已屏蔽（v10.1）：到达边界不再冻结——朝外滑动只触发边界震动（值由系统 clamp），反向立即可调
/// 摩尔状态机语义：拓扑排序忽略 varRef 写边，GraphEvaluator 两遍执行（读旧值 → 转移 → 帧尾写）
public enum TimelineMigrator {

    /// 状态枚举（phase 变量值）
    enum Phase: Int32 {
        case idle = 0, firstTapDown = 1, firstTapUp = 2, secondTapDown = 3, holding = 4, cooldown = 5
    }

    // MARK: - 图构建器（收集节点/边/入口）

    /// 图构建辅助：节点/边/入口收集 + 便捷工厂
    final class GraphBuilder {
        var nodes: [NodeConfig] = []
        var edges: [Edge] = []
        var entries: [UUID] = []
        /// 无数据入边的节点（touchData/now/value/varRef）——校验与可达性用
        var entryCandidates: [UUID] = []

        @discardableResult
        func node(_ type: NodeType, _ params: NodeParams = NodeParams(),
                  x: Double, y: Double, title: String, isEntry: Bool = false) -> UUID {
            let n = NodeConfig(type: type, params: params, x: x, y: y, title: title)
            nodes.append(n)
            if isEntry { entryCandidates.append(n.id) }
            return n.id
        }

        func edge(_ from: UUID, _ fp: String, _ to: UUID, _ tp: String) {
            edges.append(Edge(from: PortID(nodeID: from, portName: fp),
                              to: PortID(nodeID: to, portName: tp)))
        }
    }

    // MARK: - 迁移入口

    /// 生成单张节点图（等价 v2 配置的全部行为；v9 模块化：识别算法封装成可折叠模块组）
    /// - Parameters:
    ///   - regionID / eventID: 手势绑定（非 nil 时生成 RegionRef/EventRef 节点）
    ///   - touchSizeMin/Max: 手指尺寸过滤（防手掌/防按压丢失；默认跟随全局配置）
    /// - 结构：数据源区 + 「识别状态机」模块 + 光标锁定/震动/tick 执行链（冻结已屏蔽）
    /// - 折叠模块只见输入/输出口子 + 备注；展开（双击）进嵌套画布编辑内部节点
    public static func migrate(pipeline: LegacyPipelineConfig, event: EventConfig,
                               regionID: UUID? = nil, eventID: UUID? = nil,
                               touchSizeMin: Float = 0.1, touchSizeMax: Float = 1.35,
                               minimalDiagnostic: Bool = false,
                               useForcePress: (threshold: Float, hold: Double)? = nil) -> TimelineConfig {
        if minimalDiagnostic {
            return migrateMinimal(pipeline: pipeline, event: event, regionID: regionID,
                                  eventID: eventID, touchSizeMin: touchSizeMin, touchSizeMax: touchSizeMax)
        }
        let g = GraphBuilder()
        let p = pipeline
        let src = p.signalSource

        // ═══ 1. 数据源区（物理层）═══
        let touchData = g.node(.touchData, x: -1180, y: 0, title: "触控板数据", isEntry: true)
        let regionNode: UUID?
        if let regionID {
            regionNode = g.node(.region, NodeParams(regionID: regionID), x: -1180, y: 120, title: "触发区域")
        } else { regionNode = nil }
        if let eventID {
            g.node(.event, NodeParams(eventID: eventID), x: -1180, y: 200, title: "绑定事件")
        }
        let finger = g.node(.finger, NodeParams(touchSizeMin: touchSizeMin, touchSizeMax: touchSizeMax),
                            x: -1000, y: 0, title: "手指事件")
        g.edge(touchData, "fingers", finger, "fingers")
        if let regionNode {
            g.edge(regionNode, "region", finger, "region")
        }
        let nowID = g.node(.now, x: -1180, y: 300, title: "当前时间", isEntry: true)

        // ═══ 2. 模块区（识别状态机，折叠封装内部算法；useForcePress 时换 Force 按压保持识别）═══
        let sm: NodeConfig
        if let force = useForcePress {
            sm = TimelineModuleTemplates.forcePress(pressureThreshold: force.threshold,
                                                    holdMinDuration: force.hold)
        } else {
            sm = TimelineModuleTemplates.stateMachine(tapMaxDuration: p.tapMaxDuration,
                                                      tapMaxDrift: p.tapMaxDrift,
                                                      tapMaxGap: p.tapMaxGap,
                                                      holdMinDuration: p.holdMinDuration)
        }
        // 模块节点落位
        var smNode = sm
        smNode.x = -720; smNode.y = 0
        g.nodes.append(smNode)
        // 模块输出端口引用（组端口名）
        let smPhase = port(smNode.id, "phase")
        let smHoldingPulse = port(smNode.id, "holdingPulse")
        let smExitPulse = port(smNode.id, "exitPulse")

        // ═══ 3. 光标锁定变量 + 常量（enter/exit 写链同源配对）═══
        let cursorLockedVar = varRef(g, key: "cursorLocked", initialBool: false, x: -540, y: 700, title: "光标锁定")
        let trueConst = makeBool(g, true, x: -400, y: 760, title: "真")
        let falseConst = makeBool(g, false, x: -400, y: 840, title: "假")

        // ═══ 4. enter/exit 链（模块脉冲 → 震动 + 光标锁定写链）═══
        if p.hapticEnter.enabled {
            let hapticID = g.node(.haptic,
                NodeParams(waveform: p.hapticEnter.waveform, count: p.hapticEnter.count,
                           intervalUs: p.hapticEnter.intervalUs, async: true),
                x: -200, y: 40, title: "进入震动")
            g.edge(smHoldingPulse.nodeID, smHoldingPulse.portName, hapticID, "trigger")
        }
        if p.hapticExit.enabled {
            let hapticID = g.node(.haptic,
                NodeParams(waveform: p.hapticExit.waveform, count: p.hapticExit.count,
                           intervalUs: p.hapticExit.intervalUs, async: true),
                x: -200, y: 140, title: "退出震动")
            g.edge(smExitPulse.nodeID, smExitPulse.portName, hapticID, "trigger")
        }
        if p.disassociateMouse {
            let enWrite = g.node(.branch, x: -400, y: 640, title: "锁光标")
            g.edge(smHoldingPulse.nodeID, smHoldingPulse.portName, enWrite, "cond")
            g.edge(trueConst, "value", enWrite, "value")
            let enOut = port(enWrite, "out1")
            g.edge(enOut.nodeID, enOut.portName, cursorLockedVar, "trigger")
            g.edge(enOut.nodeID, enOut.portName, cursorLockedVar, "value")
            let exWrite = g.node(.branch, x: -400, y: 700, title: "解光标")
            g.edge(smExitPulse.nodeID, smExitPulse.portName, exWrite, "cond")
            g.edge(falseConst, "value", exWrite, "value")
            let exOut = port(exWrite, "out1")
            g.edge(exOut.nodeID, exOut.portName, cursorLockedVar, "trigger")
            g.edge(exOut.nodeID, exOut.portName, cursorLockedVar, "value")
        }

        // ═══ 5. 模块输入连线（物理层 → 模块：Force 用 pressure/touching/now；状态机用 down/up/...）
        // Force 的 pressure 必须来自 **finger.pressure（区域内+尺寸有效的手指 = 用户手指）**——
        // 不能用 touchData.pressure（touches.first 可能是手掌/其他手指，zP 虚高 1.1~1.3 → 手掌轻放就触发"很轻很轻都触发"）。
        // T4 压力退出依赖 finger.pressure（区域外 invalid → 不触发）——滑出区域由 T5（区域离开 0.1s）兜底退出。
        if useForcePress != nil {
            g.edge(finger, "pressure", smNode.id, "pressure")
            g.edge(finger, "touching", smNode.id, "touching")
            g.edge(nowID, "result", smNode.id, "now")
        } else {
            g.edge(finger, "down", smNode.id, "down")
            g.edge(finger, "up", smNode.id, "up")
            g.edge(finger, "touching", smNode.id, "touching")
            g.edge(finger, "pathIndex", smNode.id, "pathIndex")
            g.edge(finger, "normX", smNode.id, "normX")
            g.edge(finger, "normY", smNode.id, "normY")
            g.edge(nowID, "result", smNode.id, "now")
        }

        // ═══ 6. tick 链（holding 中每帧：信号→变换→量化→执行调节）═══
        // tickActive = phase==4 AND present（v10.7 原则：持续/门控类判定用宽松信号 present——
        // 滑动中 size 波动/手指滑出区域会让 touching 闪断 → 链断，完整图同诊断模式修复）
        // **无边界分流（v10.17）**：boundaryState 依赖 mediaKey trackedValue 数学推进，与系统真实值漂移
        // → 反复反向滑动后 trackedValue 虚高误判"朝外"→ 只震不调 → 值卡中间（用户"必然卡住"）。
        // 朝外/朝内都直接 consume——边界由系统自身 clamp（值到 0/100% 自然停），不会卡中间值。
        let signalPort = port(touchData, src.rawValue)
        let phase4Cmp = g.node(.compare, NodeParams(comparator: .eq, initial: 4), x: -320, y: 0, title: "状态==4")
        g.edge(smPhase.nodeID, smPhase.portName, phase4Cmp, "a")
        let tickActive = andChain(g, conds: [port(phase4Cmp, "result"),
                                             port(finger, "present")],
                                  x: -240, y: 0)
        let gate = g.node(.branch, x: -140, y: 0, title: "保持中?")
        g.edge(tickActive.nodeID, tickActive.portName, gate, "cond")
        g.edge(signalPort.nodeID, signalPort.portName, gate, "value")
        let transform = g.node(.transform, NodeParams(transform: p.transformMode), x: -40, y: 0, title: "变换")
        g.edge(gate, "out1", transform, "value")
        let quantize = g.node(.quantize,
            NodeParams(stepNorm: p.stepNorm, sensitivity: p.sensitivity, triggerMode: p.triggerMode),
            x: 60, y: 0, title: "量化")
        g.edge(transform, "result", quantize, "value")

        // quantize.tick → consume 直接执行调节（无边界分流）+ tick 震动
        let consume = g.node(.consume,
            NodeParams(action: event.actionType, method: event.executionMethod, step: event.step),
            x: 160, y: 0, title: "执行调节")
        g.edge(quantize, "tick", consume, "data")
        if p.hapticTick.enabled {
            let hapticID = g.node(.haptic,
                NodeParams(waveform: p.hapticTick.waveform, count: p.hapticTick.count,
                           intervalUs: p.hapticTick.intervalUs, async: true),
                x: 260, y: 0, title: "刻度震动")
            g.edge(consume, "result", hapticID, "trigger")
        }

        // 入口：无数据入边的节点（数据源/时间/变量/常量）
        g.entries = g.entryCandidates
        return TimelineConfig(trigger: .onFirstTap, nodes: g.nodes, edges: g.edges, entryNodeIDs: g.entries)
    }

    /// **诊断最简图**：屏蔽识别状态机（轻点/双击/漂移/计时/进入 holding）等一切与 tick 无关的逻辑。
    /// 手指在绑定区域内接触（touching）直接门控 tick 链：信号→变换→量化→消费+刻度震动；
    /// touching 同时写 phase 变量（接触=4 / 离开=0）——引擎复用"phase==4 建立 eventBox"逻辑，
    /// consume 才有事件引用可执行。目的：隔离验证"MT 回调 → finger → tick 调节"底层链路是否工作。
    static func migrateMinimal(pipeline: LegacyPipelineConfig, event: EventConfig,
                               regionID: UUID?, eventID: UUID?,
                               touchSizeMin: Float, touchSizeMax: Float) -> TimelineConfig {
        let g = GraphBuilder()
        let src = pipeline.signalSource

        // 物理层（数据源 + 手指事件）
        let touchData = g.node(.touchData, x: -600, y: 0, title: "触控板数据", isEntry: true)
        var regionNode: UUID?
        if let regionID {
            regionNode = g.node(.region, NodeParams(regionID: regionID), x: -600, y: 100, title: "触发区域")
        }
        let finger = g.node(.finger, NodeParams(touchSizeMin: touchSizeMin, touchSizeMax: touchSizeMax),
                            x: -420, y: 0, title: "手指事件")
        g.edge(touchData, "fingers", finger, "fingers")
        if let regionNode {
            g.edge(regionNode, "region", finger, "region")
        }

        // phase 变量（引擎读 phase==4 建立 eventBox）：present → 写 4；!present → 写 0。
        // 用 present（触控板上有手指，不过滤 size/区域）而非 touching（区域内+尺寸有效）——
        // 滑动时 size 波动/手指 x 抖动超出区域会让 touching 闪断 → phase 反复 0/4 → eventBox 反复销毁 → 调节中断
        let phaseVar = varRef(g, key: "phase", initial: Phase.idle.rawValue, x: -240, y: 220, title: "状态")
        let four = makeInt(g, Phase.holding.rawValue, x: -420, y: 260, title: "4")
        let zero = makeInt(g, Phase.idle.rawValue, x: -420, y: 360, title: "0")
        let notTouch = g.node(.not, x: -420, y: 310, title: "手指离开")
        g.edge(finger, "present", notTouch, "value")
        let wEnter = g.node(.branch, x: -330, y: 260, title: "接触写4")
        g.edge(finger, "present", wEnter, "cond")
        g.edge(four, "value", wEnter, "value")
        let enterOut = port(wEnter, "out1")
        g.edge(enterOut.nodeID, enterOut.portName, phaseVar, "trigger")
        g.edge(enterOut.nodeID, enterOut.portName, phaseVar, "value")
        let wExit = g.node(.branch, x: -330, y: 360, title: "离开写0")
        g.edge(notTouch, "result", wExit, "cond")
        g.edge(zero, "value", wExit, "value")
        let exitOut = port(wExit, "out1")
        g.edge(exitOut.nodeID, exitOut.portName, phaseVar, "trigger")
        g.edge(exitOut.nodeID, exitOut.portName, phaseVar, "value")

        // tick 链：present 门控信号 → 变换 → 量化 → 消费 + 刻度震动（无边界分流，系统自然 clamp）
        let gate = g.node(.branch, x: -240, y: 0, title: "手指接触?")
        g.edge(finger, "present", gate, "cond")
        g.edge(touchData, src.rawValue, gate, "value")
        let transform = g.node(.transform, NodeParams(transform: pipeline.transformMode), x: -80, y: 0, title: "变换")
        g.edge(gate, "out1", transform, "value")
        let quantize = g.node(.quantize,
            NodeParams(stepNorm: pipeline.stepNorm, sensitivity: pipeline.sensitivity,
                       triggerMode: pipeline.triggerMode),
            x: 40, y: 0, title: "量化")
        g.edge(transform, "result", quantize, "value")
        let consume = g.node(.consume,
            NodeParams(action: event.actionType, method: event.executionMethod, step: event.step),
            x: 160, y: 0, title: "执行调节")
        g.edge(quantize, "tick", consume, "data")
        if pipeline.hapticTick.enabled {
            let hapticID = g.node(.haptic,
                NodeParams(waveform: pipeline.hapticTick.waveform, count: pipeline.hapticTick.count,
                           intervalUs: pipeline.hapticTick.intervalUs, async: true),
                x: 260, y: 0, title: "刻度震动")
            g.edge(consume, "result", hapticID, "trigger")
        }

        g.entries = g.entryCandidates
        return TimelineConfig(trigger: .onFirstTap, nodes: g.nodes, edges: g.edges, entryNodeIDs: g.entries)
    }

    // MARK: - 构建辅助

    /// 变量节点（varRef：帧首读/帧尾写，卡片内初始值回退）
    static func varRef(_ g: GraphBuilder, key: String,
                       initial: Int32? = nil, initialBool: Bool? = nil, initialFloat: Float? = nil,
                       x: Double, y: Double, title: String) -> UUID {
        g.node(.varRef, NodeParams(initial: initial, initialBool: initialBool,
                                   initialFloat: initialFloat, key: key),
               x: x, y: y, title: title, isEntry: true)
    }

    /// 整数常量（状态枚举值）
    @discardableResult
    static func makeInt(_ g: GraphBuilder, _ v: Int32, x: Double, y: Double, title: String) -> UUID {
        g.node(.value, NodeParams(constantInt: v), x: x, y: y, title: title, isEntry: true)
    }

    /// 布尔常量（变量写入值）
    @discardableResult
    static func makeBool(_ g: GraphBuilder, _ v: Bool, x: Double, y: Double, title: String) -> UUID {
        g.node(.value, NodeParams(constantBool: v), x: x, y: y, title: title, isEntry: true)
    }

    /// 浮点常量
    @discardableResult
    static func makeFloat(_ g: GraphBuilder, _ v: Float, x: Double, y: Double, title: String) -> UUID {
        g.node(.value, NodeParams(constant: v), x: x, y: y, title: title, isEntry: true)
    }

    /// 端口便捷构造
    static func port(_ id: UUID, _ name: String) -> PortID {
        PortID(nodeID: id, portName: name)
    }

    /// 状态比较节点：compare(phase == expected) → result(bool)
    @discardableResult
    static func comparePhase(_ g: GraphBuilder, phaseVar: UUID, _ expected: Int32,
                             x: Double, y: Double) -> UUID {
        let cmp = g.node(.compare, NodeParams(comparator: .eq, initial: expected),
                         x: x, y: y, title: "状态==\(expected)")
        g.edge(phaseVar, "value", cmp, "a")
        return cmp
    }

    /// AND 组合多个 bool 条件（branch 链：cond=前一个、value=下一个；最后一层 out1 = 全部成立）
    /// 空条件列表 → 返回常量 true 端口（无条件转移）
    @discardableResult
    static func andChain(_ g: GraphBuilder, conds: [PortID], x: Double, y: Double) -> PortID {
        guard let first = conds.first else {
            return port(makeBool(g, true, x: x, y: y, title: "无条件真"), "value")
        }
        var current = first
        for (i, c) in conds.dropFirst().enumerated() {
            let b = g.node(.branch, x: x + Double(i) * 60, y: y, title: "条件与")
            g.edge(current.nodeID, current.portName, b, "cond")
            g.edge(c.nodeID, c.portName, b, "value")
            current = PortID(nodeID: b, portName: "out1")
        }
        return current
    }

    /// 一条状态转移链：phase==from AND extraConds 全成立 → 写 phase=to + 附带变量
    /// 转移条件成立帧产生脉冲（branch.out1 = 新状态 int），驱动 varRef 写请求（帧尾生效）
    /// - Returns: 转移脉冲端口（pulse=true 时），供外部消费（如 holdElapsed 重置）
    @discardableResult
    static func transition(_ g: GraphBuilder, phaseVar: UUID,
                           from: Phase, to: Phase,
                           extraConds: [PortID] = [],
                           writes: [(UUID, PortID)] = [],
                           x: Double, y: Double, title: String,
                           pulse: Bool = false) -> PortID? {
        var conds = [port(comparePhase(g, phaseVar: phaseVar, from.rawValue, x: x, y: y), "result")]
        conds.append(contentsOf: extraConds)
        let andPort = andChain(g, conds: conds, x: x + 70, y: y)
        let toConst = makeInt(g, to.rawValue, x: x + 330, y: y, title: "状态 \(to.rawValue)")
        let br = g.node(.branch, x: x + 240, y: y, title: title)
        g.edge(andPort.nodeID, andPort.portName, br, "cond")
        g.edge(toConst, "value", br, "value")
        let out1 = PortID(nodeID: br, portName: "out1")
        // 写 phase（帧尾生效）：out1 本身就是目标状态 int，同时连 trigger + value（多写源同源配对）
        g.edge(out1.nodeID, out1.portName, phaseVar, "trigger")
        g.edge(out1.nodeID, out1.portName, phaseVar, "value")
        // 附带写：每链独立 branchFinal（cond=转移条件, value=附带值）→ out1 同时连 trigger+value
        // 保证多写源变量的 trigger/value 同源配对（如 cursorLocked 被 enter/exit 两链写不同值）
        for (varID, valuePort) in writes {
            let wb = g.node(.branch, x: x + 350, y: y, title: "\(title)-写")
            g.edge(andPort.nodeID, andPort.portName, wb, "cond")
            g.edge(valuePort.nodeID, valuePort.portName, wb, "value")
            let wout = PortID(nodeID: wb, portName: "out1")
            g.edge(wout.nodeID, wout.portName, varID, "trigger")
            g.edge(wout.nodeID, wout.portName, varID, "value")
        }
        return pulse ? out1 : nil
    }
}
