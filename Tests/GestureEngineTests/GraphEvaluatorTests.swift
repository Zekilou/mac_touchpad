import XCTest
@testable import GestureEngine

final class GraphEvaluatorTests: XCTestCase {

    private var state: StateStore = [:]
    private var effects = MockEffects()

    override func setUp() {
        super.setUp()
        state = [:]
        effects = MockEffects()
    }

    private func edge(_ from: NodeConfig, _ to: NodeConfig,
                      fromPort: String, toPort: String = "value") -> Edge {
        Edge(from: PortID(nodeID: from.id, portName: fromPort),
             to: PortID(nodeID: to.id, portName: toPort))
    }

    // MARK: - init 验证

    func testInitFailsOnCycle() {
        let a = NodeConfig(type: .state, params: NodeParams(key: "a"))
        let b = NodeConfig(type: .state, params: NodeParams(key: "b"))
        let timeline = TimelineConfig(trigger: .onTick,
                                      nodes: [a, b],
                                      edges: [edge(a, b, fromPort: "value"), edge(b, a, fromPort: "value")],
                                      entryNodeIDs: [a.id])
        XCTAssertNil(GraphEvaluator(timeline: timeline))
    }

    func testInitSucceedsOnValidGraph() {
        let a = NodeConfig(type: .value, params: NodeParams(constant: 5))
        let timeline = TimelineConfig(trigger: .onTick, nodes: [a], edges: [], entryNodeIDs: [a.id])
        XCTAssertNotNil(GraphEvaluator(timeline: timeline))
    }

    // MARK: - 数据链执行

    func testLinearChainValueScaleGate() {
        // value(5) → scale(×2) → gate(≥10) → state 记录
        let value = NodeConfig(type: .value, params: NodeParams(constant: 5))
        let scale = NodeConfig(type: .scale, params: NodeParams(multiplier: 2))
        let gate = NodeConfig(type: .gate, params: NodeParams(comparator: .gte, threshold: 10))
        let store = NodeConfig(type: .state, params: NodeParams(key: "result"))
        let timeline = TimelineConfig(trigger: .onTick,
                                      nodes: [value, scale, gate, store],
                                      edges: [edge(value, scale, fromPort: "value"),
                                              edge(scale, gate, fromPort: "result"),
                                              edge(gate, store, fromPort: "pass")],
                                      entryNodeIDs: [value.id])
        guard let evaluator = GraphEvaluator(timeline: timeline) else {
            return XCTFail("init 失败")
        }
        evaluator.evaluate(frame: FrameContext(), state: &state, effects: effects)
        // gate 输出 pass(bool) → state 记录 bool
        XCTAssertEqual(state["result"]?.boolValue, true)
    }

    /// M1 等价链路：touchData → transform(delta) → quantize → branch(路由器) → consume/freeze
    func testMigratedChainConsumeGetsTickOnSecondFrame() {
        let touchData = NodeConfig(type: .touchData)
        let transform = NodeConfig(type: .transform, params: NodeParams(transform: .delta))
        let quantize = NodeConfig(type: .quantize,
                                  params: NodeParams(stepNorm: 0.02, triggerMode: .discrete))
        let branch = NodeConfig(type: .branch, params: NodeParams(predicate: .notAtBoundary))
        let consume = NodeConfig(type: .consume,
                                 params: NodeParams(action: .volume, method: .mediaKey, step: 0.01))
        let freeze = NodeConfig(type: .freeze, params: NodeParams(unfreeze: .reverseSlide))

        let timeline = TimelineConfig(
            trigger: .onTick,
            nodes: [touchData, transform, quantize, branch, consume, freeze],
            edges: [edge(touchData, transform, fromPort: "normY"),
                    edge(transform, quantize, fromPort: "result"),
                    edge(quantize, branch, fromPort: "tick"),
                    edge(branch, consume, fromPort: "out1", toPort: "data"),
                    edge(branch, freeze, fromPort: "out2", toPort: "trigger")],
            entryNodeIDs: [touchData.id])
        guard let evaluator = GraphEvaluator(timeline: timeline) else {
            return XCTFail("init 失败")
        }

        // 第一帧：delta=0 → 无刻度 → tick invalid → 整链冻结
        evaluator.evaluate(frame: FrameContext(rawSignals: [.normY: 0.5],
                                               directionRule: .positiveDecrease),
                           state: &state, effects: effects)
        XCTAssertTrue(effects.consumeOutputs.isEmpty)

        // 第二帧：delta=0.05 → tick(-1,2) → notAtBoundary=true → out1 消费
        evaluator.evaluate(frame: FrameContext(rawSignals: [.normY: 0.55],
                                               directionRule: .positiveDecrease),
                           state: &state, effects: effects)
        XCTAssertEqual(effects.consumeOutputs, [.tick(direction: -1, count: 2)])
        XCTAssertEqual(effects.freezeCount, 0) // out1 有效，out2 invalid
    }

    /// 边界场景：notAtBoundary=false → out2 路由 → freeze 执行，consume 不执行
    func testBranchFalsePathFreezes() {
        let touchData = NodeConfig(type: .touchData)
        let transform = NodeConfig(type: .transform, params: NodeParams(transform: .delta))
        let quantize = NodeConfig(type: .quantize,
                                  params: NodeParams(stepNorm: 0.02, triggerMode: .discrete))
        let branch = NodeConfig(type: .branch, params: NodeParams(predicate: .notAtBoundary))
        let consume = NodeConfig(type: .consume, params: NodeParams(action: .volume))
        let freeze = NodeConfig(type: .freeze, params: NodeParams(unfreeze: .reverseSlide))

        let timeline = TimelineConfig(
            trigger: .onTick,
            nodes: [touchData, transform, quantize, branch, consume, freeze],
            edges: [edge(touchData, transform, fromPort: "normY"),
                    edge(transform, quantize, fromPort: "result"),
                    edge(quantize, branch, fromPort: "tick"),
                    edge(branch, consume, fromPort: "out1", toPort: "data"),
                    edge(branch, freeze, fromPort: "out2", toPort: "trigger")],
            entryNodeIDs: [touchData.id])
        guard let evaluator = GraphEvaluator(timeline: timeline) else {
            return XCTFail("init 失败")
        }

        // 第一帧：建立 transform.last 基线（delta=0 → 无刻度）
        evaluator.evaluate(frame: FrameContext(rawSignals: [.normY: 0.5],
                                               directionRule: .positiveDecrease),
                           state: &state, effects: effects)

        // 边界中（isAtBoundary=true）：notAtBoundary=false → out2 → freeze
        evaluator.evaluate(frame: FrameContext(rawSignals: [.normY: 0.55],
                                               directionRule: .positiveDecrease,
                                               isAtBoundary: true),
                           state: &state, effects: effects)
        XCTAssertEqual(effects.freezeCount, 1)
        XCTAssertTrue(effects.consumeOutputs.isEmpty)
    }

    /// 副作用链：consume 输出 unit 脉冲 → haptic 触发
    func testSideEffectChainActivates() {
        let touchData = NodeConfig(type: .touchData)
        let transform = NodeConfig(type: .transform, params: NodeParams(transform: .delta))
        let quantize = NodeConfig(type: .quantize,
                                  params: NodeParams(stepNorm: 0.02, triggerMode: .discrete))
        let branch = NodeConfig(type: .branch, params: NodeParams(predicate: .notAtBoundary))
        let consume = NodeConfig(type: .consume, params: NodeParams(action: .volume))
        let haptic = NodeConfig(type: .haptic, params: NodeParams(waveform: 4))

        let timeline = TimelineConfig(
            trigger: .onTick,
            nodes: [touchData, transform, quantize, branch, consume, haptic],
            edges: [edge(touchData, transform, fromPort: "normY"),
                    edge(transform, quantize, fromPort: "result"),
                    edge(quantize, branch, fromPort: "tick"),
                    edge(branch, consume, fromPort: "out1", toPort: "data"),
                    edge(consume, haptic, fromPort: "result", toPort: "trigger")],
            entryNodeIDs: [touchData.id])
        guard let evaluator = GraphEvaluator(timeline: timeline) else {
            return XCTFail("init 失败")
        }

        // 第一帧：建立 transform.last 基线（delta=0 → 无刻度）
        evaluator.evaluate(frame: FrameContext(rawSignals: [.normY: 0.5],
                                               directionRule: .positiveDecrease),
                           state: &state, effects: effects)
        XCTAssertTrue(effects.consumeOutputs.isEmpty)
        XCTAssertTrue(effects.hapticCalls.isEmpty)

        // 第二帧：delta=0.05 → tick → consume → haptic 触发
        evaluator.evaluate(frame: FrameContext(rawSignals: [.normY: 0.55],
                                               directionRule: .positiveDecrease),
                           state: &state, effects: effects)
        XCTAssertEqual(effects.consumeOutputs.count, 1)
        XCTAssertEqual(effects.hapticCalls.count, 1) // consume 的 unit 脉冲激活 haptic
    }

    /// 无刻度（第一帧）→ consume 和 haptic 都不执行
    func testNoOutputChainInactive() {
        let touchData = NodeConfig(type: .touchData)
        let transform = NodeConfig(type: .transform, params: NodeParams(transform: .delta))
        let quantize = NodeConfig(type: .quantize,
                                  params: NodeParams(stepNorm: 0.02, triggerMode: .discrete))
        let consume = NodeConfig(type: .consume, params: NodeParams(action: .volume))
        let haptic = NodeConfig(type: .haptic, params: NodeParams(waveform: 4))

        let timeline = TimelineConfig(
            trigger: .onTick,
            nodes: [touchData, transform, quantize, consume, haptic],
            edges: [edge(touchData, transform, fromPort: "normY"),
                    edge(transform, quantize, fromPort: "result"),
                    edge(quantize, consume, fromPort: "tick", toPort: "data"),
                    edge(consume, haptic, fromPort: "result", toPort: "trigger")],
            entryNodeIDs: [touchData.id])
        guard let evaluator = GraphEvaluator(timeline: timeline) else {
            return XCTFail("init 失败")
        }

        evaluator.evaluate(frame: FrameContext(rawSignals: [.normY: 0.5],
                                               directionRule: .positiveDecrease),
                           state: &state, effects: effects)
        XCTAssertTrue(effects.consumeOutputs.isEmpty)
        XCTAssertTrue(effects.hapticCalls.isEmpty)
    }

    /// state(unit 脉冲) → baseline（记录 startRaw）→ transform(absolute)：跨节点状态传递
    func testBaselineFeedsAbsoluteTransform() {
        // state 节点持有 unit 脉冲（模拟识别器 enterHolding 脉冲）
        let pulse = NodeConfig(type: .state, params: NodeParams(key: "pulse"))
        state["pulse"] = .unit
        let baseline = NodeConfig(type: .baseline,
                                  params: NodeParams(source: .normY, key: "startRaw"))
        let transform = NodeConfig(type: .transform, params: NodeParams(transform: .absolute))
        let timeline = TimelineConfig(trigger: .onEnterHolding,
                                      nodes: [pulse, baseline, transform],
                                      edges: [edge(pulse, baseline, fromPort: "value", toPort: "trigger"),
                                              edge(baseline, transform, fromPort: "result")],
                                      entryNodeIDs: [pulse.id])
        guard let evaluator = GraphEvaluator(timeline: timeline) else {
            return XCTFail("init 失败")
        }
        evaluator.evaluate(frame: FrameContext(rawSignals: [.normY: 0.2]),
                           state: &state, effects: effects)
        XCTAssertEqual(state["startRaw"]?.floatValue, 0.2)
    }
}
