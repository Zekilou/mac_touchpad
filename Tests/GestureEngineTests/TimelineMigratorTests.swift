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

    // MARK: - 总体结构（单图 + Trigger 入口）

    func testMigrate_ProducesSingleGraphWithFourTriggers() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        // 4 个 Trigger 入口节点（不再分 4 条 timeline）
        let triggers = graph.nodes
            .filter { $0.type == .trigger }
            .compactMap { $0.params.trigger }
        XCTAssertEqual(Set(triggers),
                       Set([.onFirstTap, .onEnterHolding, .onTick, .onExitHolding]))
        // 拓扑验证通过
        switch TimelineGraphValidator.topologicalOrder(of: graph) {
        case .valid(let order):
            XCTAssertEqual(Set(order), Set(graph.nodes.map(\.id)))
        case let result:
            XCTFail("拓扑验证失败: \(result)")
        }
    }

    func testMigrate_TriggerConnectsToBlockEntries() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        // onTick 的 Trigger → signal（tick 链入口）
        let tickTrigger = graph.nodes.first { $0.type == .trigger && $0.params.trigger == .onTick }!
        let signal = graph.firstNode(of: .signal)!
        XCTAssertTrue(graph.edges.contains {
            $0.from == PortID(nodeID: tickTrigger.id, portName: "output")
                && $0.to == PortID(nodeID: signal.id, portName: "input")
        })
        // onFirstTap 的 Trigger → recognize（识别入口）
        let tapTrigger = graph.nodes.first { $0.type == .trigger && $0.params.trigger == .onFirstTap }!
        let recognize = graph.firstNode(of: .recognize)!
        XCTAssertTrue(graph.edges.contains {
            $0.from == PortID(nodeID: tapTrigger.id, portName: "output")
                && $0.to == PortID(nodeID: recognize.id, portName: "input")
        })
    }

    // MARK: - onFirstTap（触发识别 + 绑定）

    func testRecognizeNode_CarriesTapParams() {
        var pipeline = makePipeline()
        pipeline.tapMaxDuration = 0.35
        pipeline.tapMaxDrift = 0.08
        pipeline.tapMaxGap = 0.5
        pipeline.holdMinDuration = 0.25

        let graph = TimelineMigrator.migrate(pipeline: pipeline, event: makeEvent())
        let recognize = graph.firstNode(of: .recognize)
        XCTAssertNotNil(recognize)
        XCTAssertEqual(recognize?.params.tapMaxDuration, 0.35)
        XCTAssertEqual(recognize?.params.tapMaxDrift, 0.08)
        XCTAssertEqual(recognize?.params.tapMaxGap, 0.5)
        XCTAssertEqual(recognize?.params.holdMinDuration, 0.25)
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

    func testEnterBlock_MouseAndHapticFollowConfig() {
        // 默认：lockPosition mouse + enter haptic
        let t1 = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        XCTAssertEqual(t1.firstNode(of: .mouse)?.params.mouseMode, .lockPosition)
        XCTAssertEqual(t1.firstNode(of: .haptic)?.params.waveform, HapticEvent.enter.waveform)

        // 关闭：无 mouse（enter/exit 都无）
        var pipeline = makePipeline()
        pipeline.disassociateMouse = false
        pipeline.hapticEnter = HapticEvent(enabled: false, waveform: 2, count: 1, intervalUs: 0)
        let t2 = TimelineMigrator.migrate(pipeline: pipeline, event: makeEvent())
        XCTAssertNil(t2.firstNode(of: .mouse))
        // 剩余 haptic = tick 震动 + 边界震动
        XCTAssertEqual(t2.nodes.filter { $0.type == .haptic }.count, 2)
    }

    // MARK: - onTick（核心调节链路）

    func testTickChain_CoreNodesAndEdges() {
        let graph = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())

        let signal = graph.firstNode(of: .signal)
        let transform = graph.firstNode(of: .transform)
        let quantize = graph.firstNode(of: .quantize)
        let branch = graph.firstNode(of: .branch)
        let consume = graph.firstNode(of: .consume)
        let freeze = graph.firstNode(of: .freeze)
        XCTAssertNotNil(signal)
        XCTAssertNotNil(transform)
        XCTAssertNotNil(quantize)
        XCTAssertNotNil(branch)
        XCTAssertNotNil(consume)
        XCTAssertNotNil(freeze)

        // 参数透传
        XCTAssertEqual(signal?.params.source, .normY)
        XCTAssertEqual(transform?.params.transform, .delta)
        XCTAssertEqual(quantize?.params.stepNorm, 0.02)
        XCTAssertEqual(quantize?.params.triggerMode, .discrete)
        XCTAssertEqual(consume?.params.action, .volume)
        XCTAssertEqual(consume?.params.method, .mediaKey)
        XCTAssertEqual(consume?.params.step, 0.0125)

        // 边：signal→transform→quantize→branch；true→consume；false→freeze
        func connected(_ from: NodeConfig?, _ to: NodeConfig?, port: String) -> Bool {
            guard let from, let to else { return false }
            return graph.edges.contains {
                $0.from == PortID(nodeID: from.id, portName: "output")
                    && $0.to == PortID(nodeID: to.id, portName: "input")
            }
        }
        XCTAssertTrue(connected(signal, transform, port: "input"))
        XCTAssertTrue(connected(transform, quantize, port: "input"))
        XCTAssertTrue(connected(quantize, branch, port: "input"))
        XCTAssertTrue(graph.edges.contains {
            $0.from == PortID(nodeID: branch!.id, portName: "true")
                && $0.to == PortID(nodeID: consume!.id, portName: "input")
        })
        XCTAssertTrue(graph.edges.contains {
            $0.from == PortID(nodeID: branch!.id, portName: "false")
                && $0.to == PortID(nodeID: freeze!.id, portName: "input")
        })
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

    func testExitBlock_UnlocksMouse() {
        let t1 = TimelineMigrator.migrate(pipeline: makePipeline(), event: makeEvent())
        // 图上第一个 mouse 是 enter 的 lock；exit 的 unlock 节点存在
        XCTAssertNotNil(t1.nodes.first {
            $0.type == .mouse && $0.params.mouseMode == .unlockPosition
        })
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
