import XCTest
@testable import GestureEngine
import mt_bridge

/// 模块模板测试：识别状态机 / 冻结管理模板的结构 + 写类端口（isWrite）帧末延迟注入端到端
final class TimelineModuleTemplatesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        NodeExecutors.resetRuntime()
    }

    private func makePipeline() -> LegacyPipelineConfig { LegacyPipelineConfig() }
    private func makeEvent() -> EventConfig {
        EventConfig(name: "音量", actionType: .volume, step: 0.0125, boundaryThreshold: 0.001)
    }

    // MARK: - 模板结构

    func testStateMachineTemplate_Structure() {
        let sm = TimelineModuleTemplates.stateMachine(tapMaxDuration: 0.2, tapMaxDrift: 0.05,
                                                      tapMaxGap: 0.3, holdMinDuration: 0.2)
        XCTAssertEqual(sm.type, .module)
        // 端口声明：7 输入 / 3 输出
        XCTAssertEqual(sm.params.moduleInputs?.map(\.name),
                       ["down", "up", "touching", "pathIndex", "normX", "normY", "now"])
        XCTAssertEqual(sm.params.moduleOutputs?.map(\.name), ["phase", "holdingPulse", "exitPulse"])
        // 子图：输入/输出连接器 + 状态变量（phase 等 6 个）
        let sub = sm.subgraph!
        XCTAssertEqual(sub.nodes.filter { $0.type == .moduleInput }.count, 7)
        XCTAssertEqual(sub.nodes.filter { $0.type == .moduleOutput }.count, 3)
        XCTAssertEqual(sub.allNodes.filter { $0.type == .varRef }.count, 6)
        // 连接器通过 modulePortName 对应组端口
        let downConn = sub.nodes.first { $0.type == .moduleInput && $0.params.modulePortName == "down" }
        XCTAssertNotNil(downConn)
        // 子图拓扑有效（忽略写边）
        guard case .valid = TimelineGraphValidator.topologicalOrder(of: sub, ignoreWriteEdges: true) else {
            return XCTFail("状态机模块子图拓扑非法")
        }
    }

    func testFreezeTemplate_BoundaryPulseIsWritePort() {
        let f = TimelineModuleTemplates.freeze(stepNorm: 0.02)
        XCTAssertEqual(f.type, .module)
        // boundaryPulse 声明为写类端口（内部驱动 frozen/freezeDir 写请求 → 帧末延迟注入）
        let boundary = f.params.moduleInputs?.first { $0.name == "boundaryPulse" }
        XCTAssertEqual(boundary?.isWrite, true)
        let signal = f.params.moduleInputs?.first { $0.name == "signal" }
        XCTAssertEqual(signal?.isWrite, false)
        // 子图含 4 个变量（lastTriggerVal/startRaw/frozen/freezeDir）
        XCTAssertEqual(f.subgraph?.allNodes.filter { $0.type == .varRef }.count, 4)
    }

    func testMigrate_ProducesModuleGrouping() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        let modules = graph.nodes.filter { $0.type == .module }
        XCTAssertEqual(modules.count, 1, "冻结已屏蔽：迁移图只有识别状态机一个模块组")
        let titles = Set(modules.compactMap(\.title))
        XCTAssertTrue(titles.contains("识别状态机"))
        // 备注（折叠时显示用途）
        XCTAssertFalse(modules.allSatisfy { $0.params.note?.isEmpty ?? true })
        // 根图拓扑有效（写类端口边已忽略）
        guard case .valid = TimelineGraphValidator.topologicalOrder(of: graph, ignoreWriteEdges: true) else {
            return XCTFail("模块化迁移图拓扑非法")
        }
    }

    // MARK: - v8 扁平图自动升级为模块化图

    /// 构造 v8 风格扁平图（参数散在根图，无 module）：验证 upgradeModularGraph 提取参数重建
    private func makeV8FlatGraph() -> TimelineConfig {
        let td = NodeConfig(type: .touchData, x: 0, y: 0, title: "触控板数据")
        let transform = NodeConfig(type: .transform, params: NodeParams(transform: .delta), x: 200, y: 0, title: "变换")
        let quantize = NodeConfig(type: .quantize, params: NodeParams(stepNorm: 0.02, sensitivity: 1.0, triggerMode: .discrete),
                                  x: 300, y: 0, title: "量化")
        let consume = NodeConfig(type: .consume,
                                 params: NodeParams(action: .volume, method: .mediaKey, step: 0.0125),
                                 x: 400, y: 0, title: "执行调节")
        let phaseVar = NodeConfig(type: .varRef, params: NodeParams(initial: 0, key: "phase"), x: 0, y: 100, title: "状态")
        let cursorVar = NodeConfig(type: .varRef, params: NodeParams(initialBool: false, key: "cursorLocked"), x: 0, y: 180, title: "光标锁定")
        func cmp(_ title: String, _ threshold: Float) -> NodeConfig {
            NodeConfig(type: .compare, params: NodeParams(comparator: .gt, threshold: threshold),
                       x: 150, y: 260, title: title)
        }
        let nodes = [td, transform, quantize, consume, phaseVar, cursorVar,
                     cmp("漂移过大?", 0.05), cmp("按下超时?", 0.2),
                     cmp("间隔内?", 0.3), cmp("保持够久?", 0.2),
                     NodeConfig(type: .haptic, params: NodeParams(waveform: 2, count: 1, intervalUs: 0, async: true),
                                x: 200, y: 300, title: "进入震动")]
        return TimelineConfig(trigger: .onFirstTap, nodes: nodes, edges: [
            Edge(from: PortID(nodeID: td.id, portName: "normY"), to: PortID(nodeID: transform.id, portName: "value")),
            Edge(from: PortID(nodeID: transform.id, portName: "result"), to: PortID(nodeID: quantize.id, portName: "value")),
            Edge(from: PortID(nodeID: quantize.id, portName: "tick"), to: PortID(nodeID: consume.id, portName: "data")),
        ], entryNodeIDs: [td.id, phaseVar.id, cursorVar.id])
    }

    func testUpgradeV8FlatGraph_ToModularGraph() {
        var gesture = GestureConfig(name: "旧手势", regionID: UUID(), eventID: makeEvent().id,
                                    timeline: makeV8FlatGraph())
        gesture.upgradeModularGraph(events: [makeEvent()])
        let tl = gesture.timeline
        // 根图出现模块组（冻结已屏蔽 → 只有识别状态机）
        XCTAssertEqual(tl.nodes.filter { $0.type == .module }.count, 1, "v8 扁平图应升级为模块化图")
        // 识别参数从旧图标题匹配提取（阈值节点进模块子图）
        let thresholds = tl.allNodes.compactMap { $0.params.threshold }
        XCTAssertTrue(thresholds.contains(0.05), "漂移阈值应保留")
        XCTAssertTrue(thresholds.contains(Float(0.2)), "按下超时/保持时长阈值应保留")
        XCTAssertTrue(thresholds.contains(Float(0.3)), "间隔阈值应保留")
        // 信号源/变换/量化从旧图提取
        let q = tl.firstNode(of: .quantize)
        XCTAssertEqual(q?.params.stepNorm, 0.02)
        // 状态变量全部进模块（根图只剩 cursorLocked）
        let rootVars = tl.nodes.filter { $0.type == .varRef }
        XCTAssertEqual(rootVars.count, 1)
        XCTAssertEqual(rootVars.first?.params.key, "cursorLocked")
        // 光标锁定变量存在 → disassociateMouse 保留
        XCTAssertTrue(tl.allNodes.contains { $0.type == .varRef && $0.params.key == "cursorLocked" })
        // 拓扑有效
        guard case .valid = TimelineGraphValidator.topologicalOrder(of: tl, ignoreWriteEdges: true) else {
            return XCTFail("升级后拓扑非法")
        }
    }

    // MARK: - 冻结模块端到端（写类端口帧末延迟注入 + 反向解冻）

    /// 构造最小根图：touchData(信号) + 常量 + 边界脉冲源(branch，未选中路 invalid) → 冻结模块
    private func makeFreezeRoot(signal: Float, boundaryHit: Bool) -> TimelineConfig {
        let td = NodeConfig(type: .touchData, x: 0, y: 0, title: "触控板数据")
        let holding = NodeConfig(type: .value, params: NodeParams(constantBool: true), x: 0, y: 100, title: "保持中")
        let touching = NodeConfig(type: .value, params: NodeParams(constantBool: true), x: 0, y: 180, title: "手指在")
        let hit = NodeConfig(type: .value, params: NodeParams(constantBool: boundaryHit), x: 0, y: 260, title: "到边界")
        let trueC = NodeConfig(type: .value, params: NodeParams(constantBool: true), x: 0, y: 340, title: "真")
        // 边界脉冲源：branch 路由器（cond=到边界？value=真）→ out1 = 有效脉冲（未到边界 → invalid）
        let br = NodeConfig(type: .branch, x: 180, y: 260, title: "边界脉冲")
        var f = TimelineModuleTemplates.freeze(stepNorm: 0.02)
        f.x = 400; f.y = 0
        let fID = f.id
        return TimelineConfig(trigger: .onFirstTap, nodes: [td, holding, touching, hit, trueC, br, f], edges: [
            Edge(from: PortID(nodeID: td.id, portName: "normY"), to: PortID(nodeID: fID, portName: "signal")),
            Edge(from: PortID(nodeID: holding.id, portName: "value"), to: PortID(nodeID: fID, portName: "holding")),
            Edge(from: PortID(nodeID: touching.id, portName: "value"), to: PortID(nodeID: fID, portName: "touching")),
            Edge(from: PortID(nodeID: hit.id, portName: "value"), to: PortID(nodeID: br.id, portName: "cond")),
            Edge(from: PortID(nodeID: trueC.id, portName: "value"), to: PortID(nodeID: br.id, portName: "value")),
            Edge(from: PortID(nodeID: br.id, portName: "out1"), to: PortID(nodeID: fID, portName: "boundaryPulse")),
        ], entryNodeIDs: [td.id, holding.id, touching.id, hit.id, trueC.id])
    }

    func testFreezeModule_BoundaryPulseFreezes() {
        var store: StateStore = ["lastTriggerVal": .float(0.5)]  // 模拟进入保持时已重置触发点
        let effects = MockEffects()
        let root = makeFreezeRoot(signal: 0.3, boundaryHit: true)
        let eval = GraphEvaluator(timeline: root)!
        let frame = FrameContext(rawSignals: [.normY: 0.3], now: 0, isAtBoundary: true)
        eval.evaluate(frame: frame, state: &store, effects: effects)

        // 边界脉冲（写类端口）帧末延迟注入 → frozen=true；freezeDir = sign(delta = 0.3-0.5 = -0.2) = -1
        XCTAssertEqual(store["frozen"]?.boolValue, true, "边界脉冲应写 frozen=true")
        XCTAssertEqual(store["freezeDir"]?.floatValue, -1, "冻结方向 = 信号变化方向")
    }

    func testFreezeModule_ReverseSwipeUnfreezes() {
        // 帧 1：到达边界 → 冻结
        var store: StateStore = ["lastTriggerVal": .float(0.5)]
        let effects = MockEffects()
        let frame1 = FrameContext(rawSignals: [.normY: 0.3], now: 0, isAtBoundary: true)
        GraphEvaluator(timeline: makeFreezeRoot(signal: 0.3, boundaryHit: true))!
            .evaluate(frame: frame1, state: &store, effects: effects)
        XCTAssertEqual(store["frozen"]?.boolValue, true)

        // 帧 2：无边界脉冲，反向滑动（信号 0.6，Δ=+0.1 与冻结方向 -1 相反）→ 解冻
        let frame2 = FrameContext(rawSignals: [.normY: 0.6], now: 0.02, isAtBoundary: false)
        GraphEvaluator(timeline: makeFreezeRoot(signal: 0.6, boundaryHit: false))!
            .evaluate(frame: frame2, state: &store, effects: effects)
        XCTAssertEqual(store["frozen"]?.boolValue, false, "反向滑动应解冻")
    }

    // MARK: - 状态机模板端到端（模块内状态转移）

    func testStateMachineModule_RunsFullGestureSequence() {
        // 复用迁移图（识别状态机封装在模块内），跑完整双击保持流程
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        let eval = GraphEvaluator(timeline: graph)!
        var store: StateStore = [:]
        let effects = MockEffects()

        func frame(_ f: Int32, _ st: Int32, _ x: Float, _ y: Float) -> FrameContext {
            var t = mt_touch_t()
            t.frame = f; t.state = st; t.norm_x = x; t.norm_y = y
            t.size = 0.4; t.pathIndex = 0
            return FrameContext(rawSignals: [.normY: y, .normX: x], now: Double(f) * 0.01,
                                isAtBoundary: false, touches: [t])
        }
        // 按下（state=3 make）
        eval.evaluate(frame: frame(1, 3, 0.5, 0.5), state: &store, effects: effects)
        XCTAssertEqual(store["phase"]?.intValue, 1, "按下应进入 firstTapDown")
        // 按住中（touching）
        eval.evaluate(frame: frame(2, 4, 0.5, 0.5), state: &store, effects: effects)
        // 抬起（state=7 lift）+ 空手（state=0）——无手指持续 <100ms 不触发 up
        eval.evaluate(frame: frame(3, 7, 0.5, 0.5), state: &store, effects: effects)
        for f in 4...12 {
            eval.evaluate(frame: frame(Int32(f), 0, 0.5, 0.5), state: &store, effects: effects)
        }
        XCTAssertEqual(store["phase"]?.intValue, 1, "无手指不足 100ms 不应触发抬起")
        // 帧13：无手指持续 >100ms → up 确认
        eval.evaluate(frame: frame(13, 0, 0.5, 0.5), state: &store, effects: effects)
        XCTAssertEqual(store["phase"]?.intValue, 2, "持续无手指 100ms 应确认抬起进入 firstTapUp")
        // 间隔内再按下
        eval.evaluate(frame: frame(14, 3, 0.5, 0.5), state: &store, effects: effects)
        XCTAssertEqual(store["phase"]?.intValue, 3, "第二次按下应进入 secondTapDown")
        // 保持超过 holdMinDuration（20 帧后）
        for f in 15...35 {
            eval.evaluate(frame: frame(Int32(f), 4, 0.5, 0.5), state: &store, effects: effects)
        }
        XCTAssertEqual(store["phase"]?.intValue, 4, "保持够久应进入 holding")
        // 抬起退出（无手指持续 100ms）
        eval.evaluate(frame: frame(36, 7, 0.5, 0.5), state: &store, effects: effects)
        for f in 37...46 {
            eval.evaluate(frame: frame(Int32(f), 0, 0.5, 0.5), state: &store, effects: effects)
        }
        XCTAssertEqual(store["phase"]?.intValue, 0, "抬起应回到 idle")
    }
}
