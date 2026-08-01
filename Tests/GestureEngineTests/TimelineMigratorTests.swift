import XCTest
@testable import GestureEngine

final class TimelineMigratorTests: XCTestCase {

    /// 默认管线（v5 迁移输入，等价 v2 全默认）
    private func makePipeline() -> LegacyPipelineConfig {
        LegacyPipelineConfig()
    }

    /// 音量事件（mediaKey 模式）
    private func makeEvent() -> EventConfig {
        EventConfig(name: "音量", actionType: .volume,
                    step: 0.0125, boundaryThreshold: 0.001)
    }

    // MARK: - 总体结构（单图 + touchData 数据源 + recognizer + 4 个管道出口）

    func testMigrate_ProducesSingleGraphWithFourPipeOuts() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        // 4 个管道出口入口节点（每个 TriggerEvent 一个）
        let pipes = graph.nodes
            .filter { $0.type == .pipeOut }
            .compactMap { $0.params.trigger }
        XCTAssertEqual(Set(pipes),
                       Set([.onFirstTap, .onEnterHolding, .onTick, .onExitHolding]))
        // recognizer 根节点存在 + touchData 数据源存在
        XCTAssertNotNil(graph.firstNode(of: .recognizer))
        XCTAssertNotNil(graph.firstNode(of: .touchData))
        // 拓扑验证通过
        switch TimelineGraphValidator.topologicalOrder(of: graph) {
        case .valid(let order):
            XCTAssertEqual(Set(order), Set(graph.nodes.map(\.id)))
        case let result:
            XCTFail("拓扑验证失败: \(result)")
        }
    }

    func testMigrate_DataFlowExplicit() {
        let region = UUID()
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent(),
                                             regionID: region)
        let recognizer = graph.firstNode(of: .recognizer)!
        let touchData = graph.firstNode(of: .touchData)!
        let regionRef = graph.firstNode(of: .region)!
        // 显式数据流：touchData.fingers → recognizer.fingers；regionRef.region → recognizer.region
        XCTAssertTrue(graph.edges.contains {
            $0.from == PortID(nodeID: touchData.id, portName: "fingers")
                && $0.to == PortID(nodeID: recognizer.id, portName: "fingers")
        })
        XCTAssertTrue(graph.edges.contains {
            $0.from == PortID(nodeID: regionRef.id, portName: "region")
                && $0.to == PortID(nodeID: recognizer.id, portName: "region")
        })
    }

    func testMigrate_RecognizerPulseConnectsToPipeOuts() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        let recognizer = graph.firstNode(of: .recognizer)!
        // 每个触发时机：recognizer.<pulse> → pipeOut.trigger
        let pulses: [(TriggerEvent, String)] = [
            (.onFirstTap, "firstTap"),
            (.onEnterHolding, "enterHolding"),
            (.onTick, "tick"),
            (.onExitHolding, "exitHolding"),
        ]
        for (triggerEvent, pulse) in pulses {
            let pipe = graph.nodes.first { $0.type == .pipeOut && $0.params.trigger == triggerEvent }!
            XCTAssertTrue(graph.edges.contains {
                $0.from == PortID(nodeID: recognizer.id, portName: pulse)
                    && $0.to == PortID(nodeID: pipe.id, portName: "trigger")
            }, "缺少 \(triggerEvent) 脉冲连线")
        }
    }

    // MARK: - recognizer（识别参数在节点卡片内）

    func testRecognizerNode_CarriesTapParamsAndSignalSource() {
        var pipeline = makePipeline()
        pipeline.tapMaxDuration = 0.35
        pipeline.tapMaxDrift = 0.08
        pipeline.tapMaxGap = 0.5
        pipeline.holdMinDuration = 0.25
        pipeline.signalSource = .normX
        pipeline.stepNorm = 0.03

        let graph = TimelineMigrator.migrate(pipeline: pipeline, event: makeEvent())
        let recognizer = graph.firstNode(of: .recognizer)
        XCTAssertNotNil(recognizer)
        XCTAssertEqual(recognizer?.params.tapMaxDuration, 0.35)
        XCTAssertEqual(recognizer?.params.tapMaxDrift, 0.08)
        XCTAssertEqual(recognizer?.params.tapMaxGap, 0.5)
        XCTAssertEqual(recognizer?.params.holdMinDuration, 0.25)
        XCTAssertEqual(recognizer?.params.source, .normX)
        XCTAssertEqual(recognizer?.params.stepNorm, 0.03)
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

    // MARK: - onEnterHolding

    func testEnterBlock_ContainsBaselineNode() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        let baseline = graph.firstNode(of: .baseline)
        XCTAssertNotNil(baseline)
        XCTAssertEqual(baseline?.params.key, "startRaw")
        XCTAssertEqual(baseline?.params.source, .normY)
    }

    func testEnterBlock_SetCursorLockedAndHapticFollowConfig() {
        // 默认：set(cursorLocked) 变量操作 + enter haptic（替代 mouse 专有卡片）
        let t1 = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        let setLock = t1.nodes.first { $0.type == .set && $0.params.key == "cursorLocked" }
        XCTAssertNotNil(setLock)
        XCTAssertNil(t1.firstNode(of: .mouse), "mouse 专有卡片已废弃")
        XCTAssertEqual(t1.firstNode(of: .haptic)?.params.waveform, HapticEvent.enter.waveform)

        // 关闭：无 set(cursorLocked)（enter/exit 都无）
        var pipeline = makePipeline()
        pipeline.disassociateMouse = false
        pipeline.hapticEnter = HapticEvent(enabled: false, waveform: 2, count: 1, intervalUs: 0)
        let t2 = TimelineMigrator.migrate(pipeline: pipeline, event: makeEvent())
        XCTAssertNil(t2.nodes.first { $0.type == .set && $0.params.key == "cursorLocked" })
        // 剩余 haptic = tick 震动 + 边界震动
        XCTAssertEqual(t2.nodes.filter { $0.type == .haptic }.count, 2)
    }

    // MARK: - onTick（核心调节链路）

    func testTickChain_CoreNodesAndEdges() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())

        let touchData = graph.firstNode(of: .touchData)
        let transform = graph.firstNode(of: .transform)
        let quantize = graph.firstNode(of: .quantize)
        // isHolding 门控 branch（predicate .positive）与边界 branch（.notAtBoundary）是两个节点
        let gate = graph.nodes.first { $0.type == .branch && $0.params.predicate == .positive }!
        let boundaryBranch = graph.nodes.first { $0.type == .branch && $0.params.predicate == .notAtBoundary }!
        let consume = graph.firstNode(of: .consume)
        let setFrozen = graph.nodes.first { $0.type == .set && $0.params.key == "frozen" }
        XCTAssertNotNil(touchData)
        XCTAssertNotNil(transform)
        XCTAssertNotNil(quantize)
        XCTAssertNotNil(consume)
        XCTAssertNotNil(setFrozen)
        XCTAssertNil(graph.firstNode(of: .freeze), "freeze 专有卡片已废弃")

        // 参数透传
        XCTAssertEqual(transform?.params.transform, .delta)
        XCTAssertEqual(quantize?.params.stepNorm, 0.02)
        XCTAssertEqual(quantize?.params.triggerMode, .discrete)
        XCTAssertEqual(consume?.params.action, .volume)
        XCTAssertEqual(consume?.params.method, .mediaKey)
        XCTAssertEqual(consume?.params.step, 0.0125)

        // isHolding 门控：recognizer.isHolding → gate.cond；touchData.normY → gate.value
        let recognizer = graph.firstNode(of: .recognizer)!
        XCTAssertTrue(graph.edges.contains {
            $0.from == PortID(nodeID: recognizer.id, portName: "isHolding")
                && $0.to == PortID(nodeID: gate.id, portName: "cond")
        })
        XCTAssertTrue(graph.edges.contains {
            $0.from == PortID(nodeID: touchData!.id, portName: "normY")
                && $0.to == PortID(nodeID: gate.id, portName: "value")
        })

        // 边：gate.out1 → transform → quantize → boundaryBranch；out1→consume；out2→set(frozen)
        func connected(_ from: NodeConfig?, _ to: NodeConfig?, port: String, toPort: String = "value") -> Bool {
            guard let from, let to else { return false }
            return graph.edges.contains {
                $0.from == PortID(nodeID: from.id, portName: port)
                    && $0.to == PortID(nodeID: to.id, portName: toPort)
            }
        }
        XCTAssertTrue(connected(gate, transform, port: "out1"))
        XCTAssertTrue(connected(transform, quantize, port: "result"))
        XCTAssertTrue(connected(quantize, boundaryBranch, port: "tick"))
        XCTAssertTrue(connected(boundaryBranch, consume, port: "out1", toPort: "data"))
        XCTAssertTrue(connected(boundaryBranch, setFrozen, port: "out2", toPort: "trigger"))
    }

    func testTickBlock_HapticFollowsEnabled() {
        // 默认：tick 震动 + 边界震动 两个 haptic 节点
        let t1 = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        XCTAssertEqual(t1.nodes.filter { $0.type == .haptic }.count, 3)

        // 禁用 tick 震动 → 剩 enter + 边界
        var pipeline = makePipeline()
        pipeline.hapticTick = HapticEvent(enabled: false, waveform: 4, count: 1, intervalUs: 0)
        let t2 = TimelineMigrator.migrate(pipeline: pipeline, event: makeEvent())
        XCTAssertEqual(t2.nodes.filter { $0.type == .haptic }.count, 2)
    }

    // MARK: - onExitHolding

    func testExitBlock_SetCursorLockedZero() {
        let t1 = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        // exit 链：set(cursorLocked=0) 解除锁定（替代 unlockPosition mouse）
        let setLock = t1.nodes.first { $0.type == .set && $0.params.key == "cursorLocked" }
        XCTAssertNotNil(setLock)
        XCTAssertNil(t1.firstNode(of: .mouse))
    }

    func testExitBlock_HapticExitDefaultsDisabled() {
        // 默认 hapticExit 关闭 → 图上无 exit 震动（总 haptic = enter + tick + boundary = 3）
        let t1 = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        XCTAssertEqual(t1.nodes.filter { $0.type == .haptic }.count, 3)

        // 开启后 → 多一个 exit 震动（4 个）
        var pipeline = makePipeline()
        pipeline.hapticExit = HapticEvent(enabled: true, waveform: 4, count: 1, intervalUs: 0)
        let t2 = TimelineMigrator.migrate(pipeline: pipeline, event: makeEvent())
        XCTAssertEqual(t2.nodes.filter { $0.type == .haptic }.count, 4)
    }
}
