import XCTest
@testable import GestureEngine
import mt_bridge

final class TimelineMigratorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        NodeExecutors.resetRuntime()
    }

    /// 默认管线（v8 迁移输入，等价 v2 全默认）
    private func makePipeline() -> LegacyPipelineConfig {
        LegacyPipelineConfig()
    }

    /// 音量事件（mediaKey 模式）
    private func makeEvent() -> EventConfig {
        EventConfig(name: "音量", actionType: .volume,
                    step: 0.0125, boundaryThreshold: 0.001)
    }

    // MARK: - 总体结构（状态机完全展开：无 recognizer/pipeOut，有 finger/varRef）

    func testMigrate_StateMachineExpanded_NoBlackBox() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        // 黑盒/专有卡片全部消失
        XCTAssertNil(graph.firstNode(of: .recognizer), "识别器黑盒必须拆掉")
        XCTAssertTrue(graph.nodes.filter { $0.type == .pipeOut }.isEmpty)
        XCTAssertTrue(graph.nodes.filter { $0.type == .set }.isEmpty)
        XCTAssertTrue(graph.nodes.filter { $0.type == .toggle }.isEmpty)
        XCTAssertTrue(graph.nodes.filter { $0.type == .mouse }.isEmpty)
        XCTAssertTrue(graph.nodes.filter { $0.type == .freeze }.isEmpty)
        // 物理层：finger + touchData
        XCTAssertNotNil(graph.firstNode(of: .finger))
        XCTAssertNotNil(graph.firstNode(of: .touchData))
        // 拓扑验证（忽略 varRef 写边）
        switch TimelineGraphValidator.topologicalOrder(of: graph, ignoreWriteEdges: true) {
        case .valid(let order):
            XCTAssertEqual(Set(order), Set(graph.nodes.map(\.id)))
        case let result:
            XCTFail("拓扑验证失败: \(result)")
        }
    }

    func testMigrate_StateVarsAllDeclared() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        // 变量在模块子图内（识别状态机），递归收集；冻结屏蔽后无 frozen/freezeDir/startRaw/lastTriggerVal
        let vars = graph.allNodes.filter { $0.type == .varRef }
        let keys = Set(vars.compactMap { $0.params.key })
        let expected: Set<String> = ["phase", "pathIndex", "startTime", "startPosX", "startPosY",
                                     "endTime", "cursorLocked"]
        XCTAssertEqual(keys, expected)
        // phase 初始 idle(0)；cursorLocked 初始 false
        let phase = vars.first { $0.params.key == "phase" }
        XCTAssertEqual(phase?.params.initial, 0)
        let cursor = vars.first { $0.params.key == "cursorLocked" }
        XCTAssertEqual(cursor?.params.initialBool, false)
    }

    func testMigrate_DataFlowExplicit() {
        let region = UUID()
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent(),
                                             regionID: region)
        let finger = graph.firstNode(of: .finger)!
        let touchData = graph.firstNode(of: .touchData)!
        let regionRef = graph.firstNode(of: .region)!
        // 显式数据流：touchData.fingers → finger.fingers；regionRef.region → finger.region
        XCTAssertTrue(graph.edges.contains {
            $0.from == PortID(nodeID: touchData.id, portName: "fingers")
                && $0.to == PortID(nodeID: finger.id, portName: "fingers")
        })
        XCTAssertTrue(graph.edges.contains {
            $0.from == PortID(nodeID: regionRef.id, portName: "region")
                && $0.to == PortID(nodeID: finger.id, portName: "region")
        })
    }

    func testMigrate_WithBindings_GeneratesRefNodes() {
        let region = UUID()
        let event = UUID()
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent(),
                                             regionID: region, eventID: event)
        XCTAssertEqual(graph.firstNode(of: .region)?.params.regionID, region)
        XCTAssertEqual(graph.firstNode(of: .event)?.params.eventID, event)
        // 不带绑定时无 ref 节点
        let plain = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        XCTAssertNil(plain.firstNode(of: .region))
        XCTAssertNil(plain.firstNode(of: .event))
    }

    // MARK: - 识别参数落图（compare threshold / elapsed）

    func testMigrate_TapParamsLandOnGraph() {
        var pipeline = makePipeline()
        pipeline.tapMaxDuration = 0.35
        pipeline.tapMaxDrift = 0.08
        pipeline.tapMaxGap = 0.5
        pipeline.holdMinDuration = 0.25

        let graph = TimelineMigrator.migrate(pipeline: pipeline, event: makeEvent())
        // 阈值节点在模块子图内（识别状态机），递归收集
        let thresholds = graph.allNodes.compactMap { $0.params.threshold }
        // 漂移阈值 / 按下超时 / 间隔(两处) / 保持时长
        XCTAssertTrue(thresholds.contains(0.08))
        XCTAssertTrue(thresholds.contains(Float(0.35)))
        XCTAssertEqual(thresholds.filter { $0 == Float(0.5) }.count, 2)
        XCTAssertTrue(thresholds.contains(Float(0.25)))
        // finger 物理层（面积过滤卡片参数；touchSizeMax 默认 1.35——旧 1.0 会过滤较重按压）
        let finger = graph.firstNode(of: .finger)!
        XCTAssertEqual(finger.params.touchSizeMin, 0.1)
        XCTAssertEqual(finger.params.touchSizeMax, 1.35)
    }

    // MARK: - tick 链（核心调节链路）

    func testTickChain_CoreNodesAndEdges() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())

        let touchData = graph.firstNode(of: .touchData)!
        let transform = graph.firstNode(of: .transform)!
        let quantize = graph.firstNode(of: .quantize)!
        let consume = graph.firstNode(of: .consume)!
        // 冻结已屏蔽：无冻结管理模块
        XCTAssertTrue(graph.nodes.filter { $0.type == .module }.allSatisfy { $0.title == "识别状态机" })
        // v10.17：无边界分流（boundaryState 依赖 trackedValue 漂移 → 反复反向滑动值卡中间）
        XCTAssertNil(graph.firstNode(of: .boundaryState), "不应有 boundaryState（边界分流已移除）")
        XCTAssertNil(graph.nodes.first { $0.type == .branch && $0.title == "边界分流" }, "不应有边界分流分支")
        XCTAssertFalse(graph.nodes.contains { $0.type == .haptic && $0.title == "边界震动" }, "不应有边界震动节点")

        // 参数透传
        XCTAssertEqual(transform.params.transform, .delta)
        XCTAssertEqual(quantize.params.stepNorm, 0.02)
        XCTAssertEqual(quantize.params.triggerMode, .discrete)
        XCTAssertEqual(consume.params.action, .volume)
        XCTAssertEqual(consume.params.method, .mediaKey)
        XCTAssertEqual(consume.params.step, 0.0125)

        // 边：touchData.<source> → gate.value（tick 门控）→ transform → quantize → consume.data（直接）
        let gate = graph.nodes.first { node in
            node.type == .branch && graph.edges.contains {
                $0.from.nodeID == node.id && $0.from.portName == "out1"
                    && $0.to == PortID(nodeID: transform.id, portName: "value")
            }
        }!
        XCTAssertTrue(graph.edges.contains {
            $0.from == PortID(nodeID: touchData.id, portName: "normY")
                && $0.to == PortID(nodeID: gate.id, portName: "value")
        })
        func connected(_ from: NodeConfig?, _ to: NodeConfig?, port: String, toPort: String = "value") -> Bool {
            guard let from, let to else { return false }
            return graph.edges.contains {
                $0.from == PortID(nodeID: from.id, portName: port)
                    && $0.to == PortID(nodeID: to.id, portName: toPort)
            }
        }
        XCTAssertTrue(connected(gate, transform, port: "out1"))
        XCTAssertTrue(connected(transform, quantize, port: "result"))
        XCTAssertTrue(connected(quantize, consume, port: "tick", toPort: "data"),
                      "quantize.tick → consume.data 直接（无边界分流）")
        // 刻度震动：consume.result → haptic.trigger
        let tickHaptic = graph.nodes.first { $0.type == .haptic && $0.title == "刻度震动" }!
        XCTAssertTrue(connected(consume, tickHaptic, port: "result", toPort: "trigger"), "调节后触发刻度震动")
    }

    // MARK: - 无边界分流（v10.17：朝外/朝内都执行调节——系统自身 clamp 边界，不卡中间值）

    func testTickChain_NoBoundarySplit_AlwaysConsumes() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        guard let eval = GraphEvaluator(timeline: graph) else {
            return XCTFail("迁移图拓扑非法")
        }
        let effects = MockEffects()
        var store: StateStore = [
            "phase": .int(4),            // holding 中
            "cursorLocked": .bool(false),
        ]
        func frame(_ y: Float, _ side: Int) -> FrameContext {
            var t = mt_touch_t()
            t.frame = 1; t.state = 4; t.norm_x = 0.5; t.norm_y = y
            t.size = 0.4; t.pathIndex = 0
            return FrameContext(rawSignals: [.normY: y], now: 0,
                                isAtBoundary: side != 0, boundarySide: side,
                                touches: [t])
        }
        // 帧 0：建立 transform.last 基线（delta=0 → 无刻度）
        eval.evaluate(frame: frame(0.5, 0), state: &store, effects: effects)
        XCTAssertTrue(effects.consumeOutputs.isEmpty)

        // 上边界 + 朝外滑动（normY 减小 → 音量增大 → 朝上边界外）：无分流 → 照样执行调节
        // （boundaryState 依赖 trackedValue 数学推进会漂移误判 → 已移除；边界由系统 clamp）
        eval.evaluate(frame: frame(0.4, 1), state: &store, effects: effects)
        XCTAssertFalse(effects.consumeOutputs.isEmpty,
                       "朝外滑动也执行调节（无边界分流——trackedValue 漂移不再导致值卡中间）")
        XCTAssertFalse(effects.hapticCalls.contains { $0.waveform == 2 }, "无边界震动节点")

        // 朝内滑动：正常调节 + 刻度震动
        effects.consumeOutputs.removeAll()
        effects.hapticCalls.removeAll()
        eval.evaluate(frame: frame(0.55, 1), state: &store, effects: effects)
        XCTAssertFalse(effects.consumeOutputs.isEmpty, "朝内滑动应正常调节")
        XCTAssertTrue(effects.hapticCalls.contains { $0.waveform == 4 }, "正常调节应触发刻度震动")
    }

    // MARK: - v10.17 升级（旧边界分流 → 无分流）

    /// 构造旧结构图：含 boundaryState 的方向感知分流（v10.16 结构）+ 边界震动
    private func makeLegacyBoundaryGraph() -> TimelineConfig {
        let td = NodeConfig(type: .touchData, x: 0, y: 0, title: "触控板数据")
        let transform = NodeConfig(type: .transform, params: NodeParams(transform: .delta), x: 200, y: 0, title: "变换")
        let quantize = NodeConfig(type: .quantize, params: NodeParams(stepNorm: 0.02, sensitivity: 1.0, triggerMode: .discrete),
                                  x: 300, y: 0, title: "量化")
        let boundary = NodeConfig(type: .branch, x: 400, y: 0, title: "边界分流")
        let boundaryState = NodeConfig(type: .boundaryState, x: 150, y: 120, title: "边界状态")
        let consume = NodeConfig(type: .consume,
                                 params: NodeParams(action: .volume, method: .mediaKey, step: 0.0125),
                                 x: 500, y: 0, title: "执行调节")
        let cursorVar = NodeConfig(type: .varRef, params: NodeParams(initialBool: false, key: "cursorLocked"),
                                   x: 0, y: 180, title: "光标锁定")
        func cmp(_ title: String, _ threshold: Float) -> NodeConfig {
            NodeConfig(type: .compare, params: NodeParams(comparator: .gt, threshold: threshold),
                       x: 150, y: 260, title: title)
        }
        let nodes = [td, transform, quantize, boundary, boundaryState, consume, cursorVar,
                     cmp("漂移过大?", 0.05), cmp("按下超时?", 0.2),
                     cmp("间隔内?", 0.3), cmp("保持够久?", 0.2),
                     NodeConfig(type: .haptic, params: NodeParams(waveform: 2, count: 1, intervalUs: 0, async: true),
                                x: 200, y: 300, title: "进入震动"),
                     NodeConfig(type: .haptic, params: NodeParams(waveform: 4, count: 1, intervalUs: 0, async: true),
                                x: 300, y: 300, title: "刻度震动"),
                     NodeConfig(type: .haptic, params: NodeParams(waveform: 2, count: 2, intervalUs: 50000, async: true),
                                x: 400, y: 300, title: "边界震动")]
        return TimelineConfig(trigger: .onFirstTap, nodes: nodes, edges: [
            Edge(from: PortID(nodeID: td.id, portName: "normY"), to: PortID(nodeID: transform.id, portName: "value")),
            Edge(from: PortID(nodeID: transform.id, portName: "result"), to: PortID(nodeID: quantize.id, portName: "value")),
            Edge(from: PortID(nodeID: quantize.id, portName: "tick"), to: PortID(nodeID: boundary.id, portName: "value")),
            Edge(from: PortID(nodeID: boundary.id, portName: "out2"), to: PortID(nodeID: consume.id, portName: "data")),
        ], entryNodeIDs: [td.id, cursorVar.id, boundaryState.id])
    }

    func testUpgradeBoundarySplit_Removed() {
        var gesture = GestureConfig(name: "旧边界", regionID: UUID(), eventID: makeEvent().id,
                                    timeline: makeLegacyBoundaryGraph())
        gesture.upgradeBoundarySense(events: [makeEvent()])
        let tl = gesture.timeline
        // 无分流结构：boundaryState 移除，quantize.tick → consume.data 直接
        XCTAssertNil(tl.firstNode(of: .boundaryState), "boundaryState 应被移除（无边界分流）")
        XCTAssertNil(tl.nodes.first { $0.type == .branch && $0.title == "边界分流" }, "边界分流分支应被移除")
        XCTAssertFalse(tl.nodes.contains { $0.type == .haptic && $0.title == "边界震动" }, "边界震动节点应被移除")
        let consume = tl.firstNode(of: .consume)!
        XCTAssertTrue(tl.edges.contains {
            $0.from == PortID(nodeID: tl.firstNode(of: .quantize)!.id, portName: "tick")
                && $0.to == PortID(nodeID: consume.id, portName: "data")
        }, "quantize.tick → consume.data 直接")
        // 用户参数保留：识别阈值 + 震动波形（进入/刻度）
        let thresholds = tl.allNodes.compactMap { $0.params.threshold }
        XCTAssertTrue(thresholds.contains(0.05), "漂移阈值应保留")
        XCTAssertTrue(thresholds.contains(Float(0.3)), "间隔阈值应保留")
        XCTAssertTrue(tl.allNodes.contains { $0.type == .haptic && $0.params.waveform == 2 && $0.title == "进入震动" })
        XCTAssertTrue(tl.allNodes.contains { $0.type == .haptic && $0.params.waveform == 4 && $0.title == "刻度震动" })
        XCTAssertTrue(tl.allNodes.contains { $0.type == .varRef && $0.params.key == "cursorLocked" })
        // 拓扑有效
        guard case .valid = TimelineGraphValidator.topologicalOrder(of: tl, ignoreWriteEdges: true) else {
            return XCTFail("升级后拓扑非法")
        }
    }

    // MARK: - 震动跟随配置

    func testHaptic_FollowsEnabled() {
        // 默认：enter + tick 两个震动（无边界分流 → 无边界震动节点）
        let t1 = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        XCTAssertEqual(t1.nodes.filter { $0.type == .haptic }.count, 2)

        // 禁用 enter → 1 个（tick）
        var p2 = makePipeline()
        p2.hapticEnter = HapticEvent(enabled: false, waveform: 2, count: 1, intervalUs: 0)
        let t2 = TimelineMigrator.migrate(pipeline: p2, event: makeEvent())
        XCTAssertEqual(t2.nodes.filter { $0.type == .haptic }.count, 1)

        // 开启 exit → 3 个（enter + tick + exit）
        var p3 = makePipeline()
        p3.hapticExit = HapticEvent(enabled: true, waveform: 4, count: 1, intervalUs: 0)
        let t3 = TimelineMigrator.migrate(pipeline: p3, event: makeEvent())
        XCTAssertEqual(t3.nodes.filter { $0.type == .haptic }.count, 3)
    }

    // MARK: - 光标锁定（enter 写 1 / exit 写 0，变量操作）

    func testCursorLocked_FollowsDisassociateMouse() {
        // 默认：cursorLocked 有 2 条写链（enter 写 true / exit 写 false），每条 trigger+value 同源配对
        let t1 = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        let lockVar = t1.nodes.first { $0.type == .varRef && $0.params.key == "cursorLocked" }!
        XCTAssertNotNil(t1.nodes.first { $0.type == .value && $0.params.constantBool == true })
        XCTAssertNotNil(t1.nodes.first { $0.type == .value && $0.params.constantBool == false })
        let lockTriggers = t1.edges.filter { $0.to == PortID(nodeID: lockVar.id, portName: "trigger") }
        XCTAssertEqual(lockTriggers.count, 2, "enter/exit 两条写链")
        for t in lockTriggers {
            XCTAssertTrue(t1.edges.contains {
                $0.from == t.from && $0.to == PortID(nodeID: lockVar.id, portName: "value")
            }, "写链 trigger 与 value 必须同源")
        }

        // 关闭 disassociateMouse → cursorLocked 无任何写链
        var p2 = makePipeline()
        p2.disassociateMouse = false
        let t2 = TimelineMigrator.migrate(pipeline: p2, event: makeEvent())
        let lockVar2 = t2.nodes.first { $0.type == .varRef && $0.params.key == "cursorLocked" }!
        XCTAssertTrue(t2.edges.filter { $0.to.nodeID == lockVar2.id && $0.to.portName == "trigger" }.isEmpty)
    }

    // MARK: - v8 升级（旧黑盒图 → 展开图）

    func testUpgradeStateMachineGraph_ReplacesRecognizer() {
        // 构造 v7 旧图：touchData + recognizer（黑盒）+ set(cursorLocked) + haptic（进入震动）
        let rec = NodeConfig(type: .recognizer, params: NodeParams(
            source: .normX, tapMaxDuration: 0.35, tapMaxDrift: 0.08, tapMaxGap: 0.5,
            holdMinDuration: 0.25, stepNorm: 0.03),
            x: 0, y: 0, title: "识别器")
        let td = NodeConfig(type: .touchData, x: -300, y: 0, title: "触控板数据")
        let set = NodeConfig(type: .set, params: NodeParams(key: "cursorLocked"), x: 200, y: 0, title: "设置锁定")
        let haptic = NodeConfig(type: .haptic, params: NodeParams(waveform: 2, count: 1, intervalUs: 0, async: true),
                                x: 300, y: 0, title: "进入震动")
        let v7 = TimelineConfig(trigger: .onFirstTap,
                                nodes: [td, rec, set, haptic],
                                edges: [Edge(from: PortID(nodeID: td.id, portName: "fingers"),
                                             to: PortID(nodeID: rec.id, portName: "fingers"))],
                                entryNodeIDs: [td.id])
        XCTAssertNotNil(v7.firstNode(of: .recognizer))
        var gesture = GestureConfig(name: "旧手势", regionID: UUID(), eventID: UUID(),
                                    timeline: v7)
        gesture.upgradeStateMachineGraph(events: [makeEvent()])
        XCTAssertNil(gesture.timeline.firstNode(of: .recognizer), "黑盒识别器应被替换")
        XCTAssertNotNil(gesture.timeline.allNodes.first { $0.type == .varRef }, "展开图应有变量")
        XCTAssertNotNil(gesture.timeline.firstNode(of: .finger), "展开图应有物理层")
        // 识别参数固化为图上 threshold（0.35 按下超时 / 0.5 间隔；阈值节点在模块子图内）
        let thresholds = gesture.timeline.allNodes.compactMap { $0.params.threshold }
        XCTAssertTrue(thresholds.contains(Float(0.35)))
        XCTAssertEqual(thresholds.filter { $0 == Float(0.5) }.count, 2)
        // 图形状必须拓扑有效（忽略写边）
        switch TimelineGraphValidator.topologicalOrder(of: gesture.timeline, ignoreWriteEdges: true) {
        case .valid(let order):
            XCTAssertEqual(Set(order), Set(gesture.timeline.nodes.map(\.id)))
        case let result:
            XCTFail("升级后拓扑无效: \(result)")
        }
    }

    // MARK: - 状态机端到端模拟（双击保持 → 退出，图上纯节点驱动）

    /// 构造手指帧（size 0.4 在有效范围内）
    private func finger(_ frame: Int32, state: Int32, x: Float, y: Float) -> mt_touch_t {
        var f = mt_touch_t()
        f.frame = frame
        f.timestamp = Double(frame) * 0.02
        f.pathIndex = 7
        f.state = state
        f.norm_x = x
        f.norm_y = y
        f.size = 0.4
        return f
    }

    func testStateMachine_RunsFullGestureSequence() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        guard let evaluator = GraphEvaluator(timeline: graph) else {
            XCTFail("迁移图拓扑非法"); return
        }
        var store: StateStore = [:]
        let effects = MockEffects()
        var now: Double = 0

        func step(_ touches: [mt_touch_t]) {
            now += 0.02
            let first = touches.first
            let frame = FrameContext(
                rawSignals: [.normY: first?.norm_y ?? 0, .normX: first?.norm_x ?? 0,
                             .size: first?.size ?? 0, .pressure: 0],
                now: now, touches: touches)
            evaluator.evaluate(frame: frame, state: &store, effects: effects, entryIDs: nil)
        }

        // 帧1：手指按下 → idle → firstTapDown
        step([finger(1, state: 4, x: 0.5, y: 0.5)])
        XCTAssertEqual(store["phase"]?.intValue, 1, "按下应进入 firstTapDown")

        // 帧2-10：保持按下（0.18s < tapMaxDuration 0.2），无漂移 → 仍 firstTapDown
        for i in 2...10 {
            step([finger(Int32(i), state: 4, x: 0.5, y: 0.5)])
        }
        XCTAssertEqual(store["phase"]?.intValue, 1, "未超时未漂移应停留 firstTapDown")

        // 帧11-15：抬起（无手指持续 <100ms，容错 MT 采样间隙）→ 仍 firstTapDown
        for _ in 11...15 { step([]) }
        XCTAssertEqual(store["phase"]?.intValue, 1, "无手指不足 100ms 不应触发抬起")
        // 帧16：无手指持续 >100ms → up 确认 → firstTapUp
        step([])
        XCTAssertEqual(store["phase"]?.intValue, 2, "持续无手指 100ms 应确认抬起进入 firstTapUp")

        // 帧17-18：间隔 0.04s < tapMaxGap 0.3，不超时
        for _ in 17...18 {
            step([])
        }
        XCTAssertEqual(store["phase"]?.intValue, 2, "间隔内应停留 firstTapUp")

        // 帧19：第二次按下 → firstTapUp → secondTapDown（holdElapsed 重置）
        step([finger(19, state: 4, x: 0.5, y: 0.5)])
        XCTAssertEqual(store["phase"]?.intValue, 3, "间隔内再按下应进入 secondTapDown")

        // 帧20-29：保持 0.2s（还差一点）
        for i in 20...29 {
            step([finger(Int32(i), state: 4, x: 0.5, y: 0.5)])
        }
        XCTAssertEqual(store["phase"]?.intValue, 3, "0.2s 未到保持阈值")

        // 帧30：holdElapsed > 0.2 → secondTapDown → holding + 锁光标 + 进入震动
        step([finger(30, state: 4, x: 0.5, y: 0.5)])
        XCTAssertEqual(store["phase"]?.intValue, 4, "保持够久应进入 holding")
        XCTAssertEqual(store["cursorLocked"]?.boolValue, true, "进入 holding 应锁定光标")
        XCTAssertTrue(effects.hapticCalls.contains { $0.waveform == HapticEvent.enter.waveform },
                      "进入 holding 应触发进入震动")

        // 帧31-35：抬起（无手指持续 <100ms）→ 仍 holding
        for _ in 31...35 { step([]) }
        XCTAssertEqual(store["phase"]?.intValue, 4, "无手指不足 100ms 仍 holding")
        // 帧36：无手指持续 >100ms → up 确认 → idle + 解锁
        step([])
        XCTAssertEqual(store["phase"]?.intValue, 0, "抬起应回到 idle")
        XCTAssertEqual(store["cursorLocked"]?.boolValue, false, "退出 holding 应解锁光标")
    }

    func testStateMachine_DriftCancelsGesture() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        guard let evaluator = GraphEvaluator(timeline: graph) else {
            XCTFail("迁移图拓扑非法"); return
        }
        var store: StateStore = [:]
        let effects = MockEffects()
        var now: Double = 0

        func step(_ touches: [mt_touch_t]) {
            now += 0.02
            let first = touches.first
            let frame = FrameContext(
                rawSignals: [.normY: first?.norm_y ?? 0, .normX: first?.norm_x ?? 0,
                             .size: first?.size ?? 0, .pressure: 0],
                now: now, touches: touches)
            evaluator.evaluate(frame: frame, state: &store, effects: effects, entryIDs: nil)
        }

        // 按下后大幅移动（漂移 > tapMaxDrift 0.05）→ firstTapDown → cooldown
        step([finger(1, state: 4, x: 0.5, y: 0.5)])
        XCTAssertEqual(store["phase"]?.intValue, 1)
        step([finger(2, state: 4, x: 0.9, y: 0.9)])   // Δ = 0.8 > 0.05
        XCTAssertEqual(store["phase"]?.intValue, 5, "漂移过大应进入 cooldown")
        // 手指离开 → cooldown → idle
        step([])
        XCTAssertEqual(store["phase"]?.intValue, 0, "冷却后手指离开应回 idle")
        XCTAssertFalse(effects.hapticCalls.contains { $0.waveform == HapticEvent.enter.waveform },
                       "未进入 holding 不应触发进入震动")
    }

    // MARK: - 行为修复验证（2026-08-02：elapsed 计时 / 模块写延迟 / finger 尺寸）

    /// 修复验证 1：elapsed 计时——down/up 是 bool 边沿（false 帧也有效），
    /// 修复前 elapsed 被 bool(false) 每帧重置 → 间隔超时（gapTimeout）永不触发；
    /// 修复后计时正常 → 抬起间隔 > tapMaxGap 应回 idle，再按下是全新第一次轻点
    func testStateMachine_GapTimeoutResetsAfterLongGap() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        guard let evaluator = GraphEvaluator(timeline: graph) else {
            XCTFail("迁移图拓扑非法"); return
        }
        var store: StateStore = [:]
        let effects = MockEffects()
        var now: Double = 0

        func step(_ touches: [mt_touch_t]) {
            now += 0.02
            let first = touches.first
            let frame = FrameContext(
                rawSignals: [.normY: first?.norm_y ?? 0, .normX: first?.norm_x ?? 0,
                             .size: first?.size ?? 0, .pressure: 0],
                now: now, touches: touches)
            evaluator.evaluate(frame: frame, state: &store, effects: effects, entryIDs: nil)
        }

        // 第一下轻点：按下 → firstTapDown，抬起（无手指持续 100ms）→ firstTapUp
        step([finger(1, state: 4, x: 0.5, y: 0.5)])
        XCTAssertEqual(store["phase"]?.intValue, 1)
        for _ in 2...6 { step([]) }
        XCTAssertEqual(store["phase"]?.intValue, 1, "无手指不足 100ms 不应触发抬起")
        step([])
        XCTAssertEqual(store["phase"]?.intValue, 2, "抬起应进入 firstTapUp")

        // 空手到帧23 = 0.32s > tapMaxGap 0.3 → 间隔超时 → 回 idle
        for _ in 8...23 { step([]) }
        XCTAssertEqual(store["phase"]?.intValue, 0, "间隔超时应回 idle（修复前恒停留 firstTapUp）")

        // 再按下 → 全新 firstTapDown（修复前误判 secondTapDown）
        step([finger(24, state: 4, x: 0.5, y: 0.5)])
        XCTAssertEqual(store["phase"]?.intValue, 1, "超时后按下应重新从第一次轻点开始")
    }

    /// 修复验证 2：模块子图写请求延迟 flush——进入 holding 的当帧主图 tick 链不激活，
    /// 下一帧（建立 delta 基线）才开始调节；修复前当帧 tick 立即激活 → 进 holding 瞬间误调节
    func testModuleWrites_Deferred_TickStartsAfterBaseline() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        guard let evaluator = GraphEvaluator(timeline: graph) else {
            XCTFail("迁移图拓扑非法"); return
        }
        var store: StateStore = [:]
        let effects = MockEffects()
        var now: Double = 0

        func step(_ touches: [mt_touch_t]) {
            now += 0.02
            let first = touches.first
            let frame = FrameContext(
                rawSignals: [.normY: first?.norm_y ?? 0, .normX: first?.norm_x ?? 0,
                             .size: first?.size ?? 0, .pressure: 0],
                now: now, touches: touches)
            evaluator.evaluate(frame: frame, state: &store, effects: effects, entryIDs: nil)
        }

        // 双击进入 holding（间隔 < tapMaxGap 0.3）：
        // 帧1 按 → 帧6 抬 → 帧7-12 空手(0.12s) → 帧13 第二下按 → 帧23 保持 0.2s 进 holding
        step([finger(1, state: 4, x: 0.5, y: 0.5)])
        for i in 2...5 { step([finger(Int32(i), state: 4, x: 0.5, y: 0.5)]) }
        step([])   // 帧6 抬起
        for _ in 7...12 { step([]) }   // 帧7-12 空手
        step([finger(13, state: 4, x: 0.5, y: 0.5)])   // 帧13 第二下按下
        for i in 14...22 { step([finger(Int32(i), state: 4, x: 0.5, y: 0.5)]) }
        step([finger(23, state: 4, x: 0.5, y: 0.5)])   // 帧23：holdElapsed 0.2s 进 holding
        XCTAssertEqual(store["phase"]?.intValue, 4, "保持够久应进入 holding")
        effects.consumeOutputs.removeAll()

        // 帧24：holding 中第一次滑动——本帧建立 transform delta 基线（进 holding 帧 tick 链不激活）→ 不调节
        step([finger(24, state: 4, x: 0.5, y: 0.55)])
        XCTAssertEqual(effects.consumeOutputs.count, 0,
                       "进 holding 后首帧滑动只建立 delta 基线，不应调节（修复前进 holding 帧 tick 已激活建基线 → 无干净起点）")
        // 帧25：滑动 0.02（浮点 0.01999998）→ 容差后 1 格
        step([finger(25, state: 4, x: 0.5, y: 0.57)])
        XCTAssertEqual(effects.consumeOutputs.count, 1, "滑动 0.02 应调节 1 格（浮点容差：严格 >= 会漏 tick）")
        // 帧26：继续滑动 0.02 → 累计 2 格
        step([finger(26, state: 4, x: 0.5, y: 0.59)])
        XCTAssertEqual(effects.consumeOutputs.count, 2, "继续滑动应累计 2 格")
        for output in effects.consumeOutputs {
            guard case .tick(_, let count) = output else {
                XCTFail("应为 tick 输出"); return
            }
            XCTAssertEqual(count, 1, "每格 tick count=1（多档由多次 tick 表达）")
        }
    }

    /// 修复验证 3：finger 尺寸过滤跟随全局配置（迁移器不再硬编码 1.0）
    func testMigrate_FingerSizeFollowsGlobal() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent(),
                                             touchSizeMin: 0.2, touchSizeMax: 1.5)
        let fingerNode = graph.firstNode(of: .finger)
        XCTAssertEqual(fingerNode?.params.touchSizeMin, 0.2)
        XCTAssertEqual(fingerNode?.params.touchSizeMax, 1.5)
    }

    // MARK: - Force 按压保持手势（v10.14：压力 ≥ 阈值持续 holdMinDuration 才进入；全程保持压力才能滑动）

    /// Force 帧构造（zPressure 压力可配）
    private func forceFinger(_ frame: Int32, pressure: Float, y: Float = 0.5) -> mt_touch_t {
        var f = finger(frame, state: 4, x: 0.5, y: y)
        f.zPressure = pressure
        return f
    }

    private func runForce(_ graph: TimelineConfig, sequence: [(Int32, Float, Float)],
                          store: inout StateStore, effects: MockEffects,
                          now: inout Double) {
        guard let evaluator = GraphEvaluator(timeline: graph) else {
            XCTFail("迁移图拓扑非法"); return
        }
        for (frame, pressure, y) in sequence {
            now += 0.02   // 每帧 20ms（50Hz 模拟）
            let f = forceFinger(frame, pressure: pressure, y: y)
            let fc = FrameContext(
                rawSignals: [.normY: f.norm_y, .normX: f.norm_x,
                             .size: f.size, .pressure: f.zPressure],
                now: now, touches: [f])
            evaluator.evaluate(frame: fc, state: &store, effects: effects, entryIDs: nil)
        }
    }

    /// 轻触（压力 < 阈值 0.8）保持 1 秒：绝不进入 holding
    func testForcePress_LightTouch_NeverEnters() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent(),
                                             useForcePress: (0.8, 0.3))
        var store: StateStore = [:]
        let effects = MockEffects()
        var now: Double = 0
        // 50 帧 ≈ 1 秒轻触保持
        var seq: [(Int32, Float, Float)] = []
        for i in 1...50 { seq.append((Int32(i), 0.5, 0.5)) }
        runForce(graph, sequence: seq, store: &store, effects: effects, now: &now)
        XCTAssertEqual(store["phase"]?.intValue ?? 0, 0, "轻触压力不足阈值，绝不能进入 holding")
        XCTAssertNil(store["cursorLocked"]?.boolValue, "未进入 holding 不应锁定光标")
        XCTAssertFalse(effects.hapticCalls.contains { $0.waveform == HapticEvent.enter.waveform },
                       "未进入 holding 不应触发进入震动")
    }

    /// v10.17 压力来源：pressure 必须来自 finger.pressure（区域内+尺寸有效 = 用户手指）——
    /// touchData.pressure = touches.first 可能是手掌（zP 虚高 1.1~1.3 → 手掌轻放就触发"很轻很轻都触发"）
    /// 区域约束 + T5 退出 + T4 滞回 保留
    func testForcePress_PressureFromUserFinger() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent(),
                                             useForcePress: (1.2, 0.3))
        let module = graph.nodes.first { $0.type == .module && $0.title == "Force按压识别" }!
        let touchData = graph.firstNode(of: .touchData)!
        let fingerNode = graph.firstNode(of: .finger)!
        // pressure 来自 finger（区域内用户手指）
        XCTAssertTrue(graph.edges.contains {
            $0.from == PortID(nodeID: fingerNode.id, portName: "pressure")
                && $0.to == PortID(nodeID: module.id, portName: "pressure")
        }, "pressure 必须来自 finger.pressure（区域内用户手指）")
        XCTAssertFalse(graph.edges.contains {
            $0.from == PortID(nodeID: touchData.id, portName: "pressure")
                && $0.to == PortID(nodeID: module.id, portName: "pressure")
        }, "pressure 不得来自 touchData（touches.first 可能是手掌，zP 虚高）")
        // touching 连入模块（区域约束载体）
        XCTAssertTrue(graph.edges.contains {
            $0.from == PortID(nodeID: fingerNode.id, portName: "touching")
                && $0.to == PortID(nodeID: module.id, portName: "touching")
        }, "touching（区域内手指）必须连入模块")
        // 子图含 T5 区域退出：lastTouchTime 变量 + 离开超时判定
        let sub = module.subgraph!
        XCTAssertTrue(sub.nodes.contains { $0.type == .varRef && $0.params.key == "lastTouchTime" },
                      "应有 lastTouchTime 变量（T5 滑出区域退出）")
        XCTAssertTrue(sub.nodes.contains { $0.type == .compare && $0.title == "离开够久?" },
                      "应有区域离开超时判定（0.1s 去抖）")
        // T4 滞回退出：独立"压力不足?" 阈值（低于进入阈值 0.3）——按住力度波动不反复进出
        XCTAssertTrue(sub.nodes.contains { $0.type == .compare && $0.title == "压力不足?" },
                      "应有滞回退出阈值（压力不足?）")
    }

    /// Force 升级：旧结构（进入震动 click 2）→ 升级后进入震动 buzz(3)（与系统触控板点击区分）
    func testUpgradeForcePress_EnterHapticBecomesBuzz() {
        // 构造 v10.16 结构但进入震动仍为 click 波形 2（旧默认）——只有 oldEnterWave 触发升级
        var pipeline = makePipeline()
        pipeline.hapticEnter = HapticEvent(enabled: true, waveform: 2, count: 1, intervalUs: 0)
        let graph = TimelineMigrator.migrate(pipeline: pipeline, event: makeEvent(),
                                             regionID: UUID(), eventID: UUID(),
                                             useForcePress: (1.2, 0.3))
        var gesture = GestureConfig(name: "左侧Force", regionID: UUID(), eventID: makeEvent().id,
                                    timeline: graph)
        gesture.upgradeForcePress(events: [makeEvent()])
        let enterHaptic = gesture.timeline.nodes.first { $0.type == .haptic && $0.title == "进入震动" }
        XCTAssertEqual(enterHaptic?.params.waveform, 3, "升级后 Force 进入震动应为 buzz（区分系统点击）")
        // 其余参数保留（滞回退出 + normY 信号源）
        XCTAssertTrue(gesture.tickSignalSource == SignalSource.normY, "升级后 tick 信号源应保持 normY")
    }

    /// 迟滞（hysteresis）：进入阈值 1.4 / 退出阈值 1.1——进入后按住压力 1.2（介于两者之间）不退出，
    /// 压力降到 <1.1 才退出（修复"按住时力度波动反复进出 → 音量乱动 + 不停震动"）
    func testForcePress_Hysteresis_StableHold_BetweenThresholds() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent(),
                                             useForcePress: (1.4, 0.3))
        var store: StateStore = [:]
        let effects = MockEffects()
        var now: Double = 0
        var seq: [(Int32, Float, Float)] = [(1, 0.3, 0.5), (2, 1.5, 0.5)]
        // 段A：区域内高压 1.5（≥1.4）保持 0.4s → 进入 holding
        for i in 3...21 { seq.append((Int32(i), 1.5, 0.5)) }
        runForce(graph, sequence: seq, store: &store, effects: effects, now: &now)
        XCTAssertEqual(store["phase"]?.intValue, 4, "压力 1.5（≥进入阈值 1.4）保持应进入 holding")
        effects.hapticCalls.removeAll()
        // 段B：压力降到 1.2（<进入阈值 1.4 但 >退出阈值 1.1）保持 1 秒 → **不得退出**（滞回）
        for i in 22...72 { seq.append((Int32(i), 1.2, 0.5)) }
        runForce(graph, sequence: seq, store: &store, effects: effects, now: &now)
        XCTAssertEqual(store["phase"]?.intValue, 4, "按住 1.2（迟滞区间 1.1~1.4）不得退出——否则力度波动反复进出")
        // 段C：压力降到 0.8（<退出阈值 1.1）→ 退出
        for i in 73...80 { seq.append((Int32(i), 0.8, 0.5)) }
        runForce(graph, sequence: seq, store: &store, effects: effects, now: &now)
        XCTAssertEqual(store["phase"]?.intValue, 0, "压力 <1.1（退出阈值）应退出")
    }

    /// T5：holding 中手指滑出区域（touching=false）持续 0.1s → 退出（时间基准去抖，容忍 1-2 帧闪断）
    func testForcePress_SlideOutOfRegion_Exits() {
        let region = RegionConfig.defaultLeft   // x 0~0.2
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent(),
                                             regionID: region.id, useForcePress: (1.2, 0.3))
        guard let evaluator = GraphEvaluator(timeline: graph) else {
            XCTFail("迁移图拓扑非法"); return
        }
        var store: StateStore = [:]
        let effects = MockEffects()
        var now: Double = 0
        func step(_ pressure: Float, _ x: Float) {
            now += 0.02
            var f = finger(Int32(now * 50), state: 4, x: x, y: 0.5)
            f.zPressure = pressure
            let fc = FrameContext(
                rawSignals: [.normY: f.norm_y, .normX: f.norm_x,
                             .size: f.size, .pressure: f.zPressure],
                now: now, touches: [f], region: region)
            evaluator.evaluate(frame: fc, state: &store, effects: effects, entryIDs: nil)
        }
        // 段A：低压 1 帧 + 区域内（x=0.1）高压保持 0.4s → 进入 holding
        step(0.3, 0.1)
        for _ in 0..<20 { step(1.3, 0.1) }
        XCTAssertEqual(store["phase"]?.intValue, 4, "区域内高压保持应进入 holding")
        // 段B：滑出区域（x=0.9，区域外）保持压力，0.08s 内（去抖中）→ 仍 holding
        for _ in 0..<4 { step(1.3, 0.9) }
        XCTAssertEqual(store["phase"]?.intValue, 4, "滑出区域 0.08s 内（去抖）应仍 holding")
        // 段C：继续滑出区域超 0.1s → 退出
        for _ in 0..<4 { step(1.3, 0.9) }
        XCTAssertEqual(store["phase"]?.intValue, 0, "滑出区域超 0.1s 应退出 holding（T5 区域约束）")
        XCTAssertEqual(store["cursorLocked"]?.boolValue, false, "退出应解锁光标")
    }

    /// 高压必须持续 holdMinDuration(0.3s) 才进入 holding；压力不足立即退出
    func testForcePress_HeavyHold_EntersAfterDuration_ExitsOnRelease() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent(),
                                             useForcePress: (0.8, 0.3))
        var store: StateStore = [:]
        let effects = MockEffects()
        var now: Double = 0

        // 段A：低压 1 帧 + 高压 14 帧（帧2-15，0.28s < 0.3s）→ 绝不能进入
        var seq: [(Int32, Float, Float)] = [(1, 0.3, 0.5), (2, 1.0, 0.5)]
        for i in 3...15 { seq.append((Int32(i), 1.0, 0.5)) }
        runForce(graph, sequence: seq, store: &store, effects: effects, now: &now)
        XCTAssertEqual(store["phase"]?.intValue ?? 0, 0,
                       "高压保持不足 0.3s 绝不能进入 holding（pressStart 必须被正确记录——若写入失败 heldCmp=now-0 恒真，一碰即进）")

        // 段B：继续高压（帧16-30，累计 >0.3s）→ 进入 holding + 进入震动 + 光标锁定
        for i in 16...30 { seq.append((Int32(i), 1.0, 0.5)) }
        runForce(graph, sequence: seq, store: &store, effects: effects, now: &now)
        XCTAssertEqual(store["phase"]?.intValue ?? 0, 4, "高压保持超过 0.3s 应进入 holding")
        XCTAssertTrue(effects.hapticCalls.contains { $0.waveform == HapticEvent.enter.waveform },
                      "进入 holding 应触发进入震动")
        XCTAssertEqual(store["cursorLocked"]?.boolValue, true, "进入 holding 应锁定光标")

        // 段C：压力不足（0.3 < 退出阈值 0.5）→ 退出 holding + 解锁光标
        for i in 31...40 { seq.append((Int32(i), 0.3, 0.5)) }
        runForce(graph, sequence: seq, store: &store, effects: effects, now: &now)
        XCTAssertEqual(store["phase"]?.intValue ?? 0, 0, "压力不足应退出 holding")
        XCTAssertEqual(store["cursorLocked"]?.boolValue, false, "退出 holding 应解锁光标")
    }

    /// 进入 holding 后滑动：信号链（transform/quantize）正常调节
    func testForcePress_SlideAfterEnter_Adjusts() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent(),
                                             useForcePress: (0.8, 0.3))
        var store: StateStore = [:]
        let effects = MockEffects()
        var now: Double = 0
        var seq: [(Int32, Float, Float)] = [(1, 0.3, 0.5), (2, 1.0, 0.5)]
        // 高压保持 0.4s 进入 holding
        for i in 3...21 { seq.append((Int32(i), 1.0, 0.5)) }
        // 进入后保持高压滑动：normY 从 0.5 → 0.7（滑动 0.2 = 10 格）
        for i in 22...32 {
            let y = 0.5 + Float(i - 21) * 0.02
            seq.append((Int32(i), 1.0, y))
        }
        runForce(graph, sequence: seq, store: &store, effects: effects, now: &now)
        XCTAssertEqual(store["phase"]?.intValue ?? 0, 4, "高压保持后应进入 holding")
        XCTAssertFalse(effects.consumeOutputs.isEmpty, "holding 中滑动应执行调节")
        for output in effects.consumeOutputs {
            guard case .tick = output else {
                XCTFail("应为 tick 输出"); return
            }
        }
    }
}
