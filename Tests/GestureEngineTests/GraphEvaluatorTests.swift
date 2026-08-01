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
                      fromPort: String = "output", toPort: String = "input") -> Edge {
        Edge(from: PortID(nodeID: from.id, portName: fromPort),
             to: PortID(nodeID: to.id, portName: toPort))
    }

    // MARK: - init 验证

    func testInitFailsOnCycle() {
        let a = NodeConfig(type: .state, params: NodeParams(key: "a"))
        let b = NodeConfig(type: .state, params: NodeParams(key: "b"))
        let timeline = TimelineConfig(trigger: .onTick,
                                      nodes: [a, b],
                                      edges: [edge(a, b), edge(b, a)],
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
        let gate = NodeConfig(type: .gate, params: NodeParams(threshold: 10, comparator: .gte))
        let store = NodeConfig(type: .state, params: NodeParams(key: "result"))
        let timeline = TimelineConfig(trigger: .onTick,
                                      nodes: [value, scale, gate, store],
                                      edges: [edge(value, scale), edge(scale, gate), edge(gate, store)],
                                      entryNodeIDs: [value.id])
        guard let evaluator = GraphEvaluator(timeline: timeline) else {
            return XCTFail("init 失败")
        }
        evaluator.evaluate(frame: FrameContext(), state: &state, effects: effects)
        XCTAssertEqual(state["result"]?.floatValue, 10)
    }

    /// M1 等价链路：signal → transform(delta) → quantize → branch → consume
    func testMigratedChainConsumeGetsTickOnSecondFrame() {
        let signal = NodeConfig(type: .signal, params: NodeParams(source: .normY))
        let transform = NodeConfig(type: .transform, params: NodeParams(transform: .delta))
        let quantize = NodeConfig(type: .quantize,
                                  params: NodeParams(stepNorm: 0.02, triggerMode: .discrete))
        let branch = NodeConfig(type: .branch, params: NodeParams(predicate: .notAtBoundary))
        let consume = NodeConfig(type: .consume,
                                 params: NodeParams(action: .volume, method: .mediaKey, step: 0.01))
        let freeze = NodeConfig(type: .freeze, params: NodeParams(unfreeze: .reverseSlide))

        let timeline = TimelineConfig(
            trigger: .onTick,
            nodes: [signal, transform, quantize, branch, consume, freeze],
            edges: [edge(signal, transform), edge(transform, quantize), edge(quantize, branch),
                    edge(branch, consume, fromPort: "true"),
                    edge(branch, freeze, fromPort: "false")],
            entryNodeIDs: [signal.id])
        guard let evaluator = GraphEvaluator(timeline: timeline) else {
            return XCTFail("init 失败")
        }

        // 第一帧：delta=0 → 无刻度 → 不消费
        evaluator.evaluate(frame: FrameContext(rawSignals: [.normY: 0.5],
                                               directionRule: .positiveDecrease),
                           state: &state, effects: effects)
        XCTAssertTrue(effects.consumeOutputs.isEmpty)

        // 第二帧：delta=0.05 → tick(-1,2) → true 分支消费
        evaluator.evaluate(frame: FrameContext(rawSignals: [.normY: 0.55],
                                               directionRule: .positiveDecrease),
                           state: &state, effects: effects)
        XCTAssertEqual(effects.consumeOutputs, [.tick(direction: -1, count: 2)])
        XCTAssertEqual(effects.freezeCount, 0) // true 分支，不冻结
    }

    /// 边界场景：notAtBoundary=false → false 分支执行 freeze，consume 不执行
    func testBranchFalsePathFreezes() {
        let signal = NodeConfig(type: .signal, params: NodeParams(source: .normY))
        let transform = NodeConfig(type: .transform, params: NodeParams(transform: .delta))
        let quantize = NodeConfig(type: .quantize,
                                  params: NodeParams(stepNorm: 0.02, triggerMode: .discrete))
        let branch = NodeConfig(type: .branch, params: NodeParams(predicate: .notAtBoundary))
        let consume = NodeConfig(type: .consume, params: NodeParams(action: .volume))
        let freeze = NodeConfig(type: .freeze, params: NodeParams(unfreeze: .reverseSlide))

        let timeline = TimelineConfig(
            trigger: .onTick,
            nodes: [signal, transform, quantize, branch, consume, freeze],
            edges: [edge(signal, transform), edge(transform, quantize), edge(quantize, branch),
                    edge(branch, consume, fromPort: "true"),
                    edge(branch, freeze, fromPort: "false")],
            entryNodeIDs: [signal.id])
        guard let evaluator = GraphEvaluator(timeline: timeline) else {
            return XCTFail("init 失败")
        }

        // 第一帧：建立 transform.last 基线（delta=0 → 无刻度）
        evaluator.evaluate(frame: FrameContext(rawSignals: [.normY: 0.5],
                                               directionRule: .positiveDecrease),
                           state: &state, effects: effects)

        // 边界中（isAtBoundary=true）：notAtBoundary=false → freeze
        evaluator.evaluate(frame: FrameContext(rawSignals: [.normY: 0.55],
                                               directionRule: .positiveDecrease,
                                               isAtBoundary: true),
                           state: &state, effects: effects)
        XCTAssertEqual(effects.freezeCount, 1)
        XCTAssertTrue(effects.consumeOutputs.isEmpty)
    }

    /// 副作用链：haptic 在 consume 之后 → 执行（写 .unit 激活后续）
    func testSideEffectChainActivates() {
        let signal = NodeConfig(type: .signal, params: NodeParams(source: .normY))
        let transform = NodeConfig(type: .transform, params: NodeParams(transform: .delta))
        let quantize = NodeConfig(type: .quantize,
                                  params: NodeParams(stepNorm: 0.02, triggerMode: .discrete))
        let branch = NodeConfig(type: .branch, params: NodeParams(predicate: .notAtBoundary))
        let consume = NodeConfig(type: .consume, params: NodeParams(action: .volume))
        let haptic = NodeConfig(type: .haptic, params: NodeParams(waveform: 4))

        let timeline = TimelineConfig(
            trigger: .onTick,
            nodes: [signal, transform, quantize, branch, consume, haptic],
            edges: [edge(signal, transform), edge(transform, quantize), edge(quantize, branch),
                    edge(branch, consume, fromPort: "true"),
                    edge(consume, haptic)],
            entryNodeIDs: [signal.id])
        guard let evaluator = GraphEvaluator(timeline: timeline) else {
            return XCTFail("init 失败")
        }

        // 第一帧：建立 transform.last 基线（delta=0 → 无刻度）
        evaluator.evaluate(frame: FrameContext(rawSignals: [.normY: 0.5],
                                               directionRule: .positiveDecrease),
                           state: &state, effects: effects)
        XCTAssertTrue(effects.consumeOutputs.isEmpty)
        XCTAssertTrue(effects.hapticCalls.isEmpty)

        // 第二帧：delta=0.05 → tick → consume 后 haptic 激活
        evaluator.evaluate(frame: FrameContext(rawSignals: [.normY: 0.55],
                                               directionRule: .positiveDecrease),
                           state: &state, effects: effects)
        XCTAssertEqual(effects.consumeOutputs.count, 1)
        XCTAssertEqual(effects.hapticCalls.count, 1) // consume 后 haptic 激活
    }

    /// 无刻度（第一帧）→ consume 和 haptic 都不执行
    func testNoOutputChainInactive() {
        let signal = NodeConfig(type: .signal, params: NodeParams(source: .normY))
        let transform = NodeConfig(type: .transform, params: NodeParams(transform: .delta))
        let quantize = NodeConfig(type: .quantize,
                                  params: NodeParams(stepNorm: 0.02, triggerMode: .discrete))
        let consume = NodeConfig(type: .consume, params: NodeParams(action: .volume))
        let haptic = NodeConfig(type: .haptic, params: NodeParams(waveform: 4))

        let timeline = TimelineConfig(
            trigger: .onTick,
            nodes: [signal, transform, quantize, consume, haptic],
            edges: [edge(signal, transform), edge(transform, quantize),
                    edge(quantize, consume), edge(consume, haptic)],
            entryNodeIDs: [signal.id])
        guard let evaluator = GraphEvaluator(timeline: timeline) else {
            return XCTFail("init 失败")
        }

        evaluator.evaluate(frame: FrameContext(rawSignals: [.normY: 0.5],
                                               directionRule: .positiveDecrease),
                           state: &state, effects: effects)
        XCTAssertTrue(effects.consumeOutputs.isEmpty)
        XCTAssertTrue(effects.hapticCalls.isEmpty)
    }

    /// baseline → transform(absolute)：跨节点状态传递
    func testBaselineFeedsAbsoluteTransform() {
        let baseline = NodeConfig(type: .baseline,
                                  params: NodeParams(source: .normY, key: "startRaw"))
        let transform = NodeConfig(type: .transform, params: NodeParams(transform: .absolute))
        let timeline = TimelineConfig(trigger: .onEnterHolding,
                                      nodes: [baseline, transform],
                                      edges: [edge(baseline, transform)],
                                      entryNodeIDs: [baseline.id])
        guard let evaluator = GraphEvaluator(timeline: timeline) else {
            return XCTFail("init 失败")
        }
        evaluator.evaluate(frame: FrameContext(rawSignals: [.normY: 0.2]),
                           state: &state, effects: effects)
        XCTAssertEqual(state["startRaw"]?.floatValue, 0.2)
        // absolute 变换：input(0.2) - baseline(0.2) = 0
        XCTAssertTrue(effects.consumeOutputs.isEmpty) // 无副作用
    }
}
