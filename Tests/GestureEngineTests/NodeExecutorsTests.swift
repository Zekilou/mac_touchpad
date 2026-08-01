import XCTest
// 显式导入：消除与 Foundation.Predicate(macOS 14+) 的同名歧义
import enum GestureEngine.Predicate
@testable import GestureEngine

final class NodeExecutorsTests: XCTestCase {

    private var state: StateStore = [:]
    private var effects = MockEffects()
    private var frame: FrameContext {
        FrameContext(rawSignals: [.normY: 0.5, .normX: 0.3], now: 0,
                     directionRule: .positiveDecrease, isAtBoundary: false)
    }

    override func setUp() {
        super.setUp()
        state = [:]
        effects = MockEffects()
    }

    private func exec(_ node: NodeConfig, inputs: [String: NodeValue] = [:],
                      frame: FrameContext? = nil) -> NodeExecutionResult {
        NodeExecutors.execute(node: node, inputs: inputs,
                              frame: frame ?? self.frame,
                              state: &state, effects: effects)
    }

    private func floatNode(_ type: NodeType, _ params: NodeParams) -> NodeConfig {
        NodeConfig(type: type, params: params)
    }

    // MARK: 数据源

    func testSignalReadsRawValue() {
        let r = exec(floatNode(.signal, NodeParams(source: .normY)))
        XCTAssertEqual(r.outputs?["output"]?.floatValue, 0.5)
    }

    func testValueReturnsConstant() {
        let r = exec(floatNode(.value, NodeParams(constant: 3.5)))
        XCTAssertEqual(r.outputs?["output"]?.floatValue, 3.5)
    }

    // MARK: 数学/变换

    func testTransformDeltaUsesLastValue() {
        let node = floatNode(.transform, NodeParams(transform: .delta))
        // 第一帧：last 不存在 → delta 0
        XCTAssertEqual(exec(node, inputs: ["input": .float(0.3)]).outputs?["output"]?.floatValue ?? 0, 0)
        // 第二帧：delta = 0.4 - 0.3（Float 精度，用 accuracy）
        let second = exec(node, inputs: ["input": .float(0.4)]).outputs?["output"]?.floatValue ?? 0
        XCTAssertEqual(second, 0.1, accuracy: 0.0001)
    }

    func testTransformAbsoluteUsesBaseline() {
        state["startRaw"] = .float(0.2)
        let r = exec(floatNode(.transform, NodeParams(transform: .absolute)),
                     inputs: ["input": .float(0.5)])
        XCTAssertEqual(r.outputs?["output"]?.floatValue, 0.3)
    }

    func testScaleMultiplierAndOffset() {
        let r = exec(floatNode(.scale, NodeParams(multiplier: 3, offset: 1)),
                     inputs: ["input": .float(2)])
        XCTAssertEqual(r.outputs?["output"]?.floatValue, 7)
    }

    func testClampBounds() {
        let node = floatNode(.clamp, NodeParams(min: 0, max: 1))
        XCTAssertEqual(exec(node, inputs: ["input": .float(5)]).outputs?["output"]?.floatValue, 1)
        XCTAssertEqual(exec(node, inputs: ["input": .float(-2)]).outputs?["output"]?.floatValue, 0)
    }

    func testAbsAndSign() {
        XCTAssertEqual(exec(floatNode(.abs, .init()), inputs: ["input": .float(-2.5)]).outputs?["output"]?.floatValue, 2.5)
        XCTAssertEqual(exec(floatNode(.sign, .init()), inputs: ["input": .float(-2.5)]).outputs?["output"]?.floatValue, -1)
    }

    // MARK: 量化/门控

    func testQuantizeDiscrete() {
        // positiveDecrease：信号增大 → direction -1；|0.05|/0.02 = 2
        let node = floatNode(.quantize, NodeParams(stepNorm: 0.02, triggerMode: .discrete))
        let r = exec(node, inputs: ["input": .float(0.05)])
        XCTAssertEqual(r.outputs?["output"]?.outputValue, .tick(direction: -1, count: 2))
    }

    func testQuantizeDiscreteBelowStepNoOutput() {
        let node = floatNode(.quantize, NodeParams(stepNorm: 0.02, triggerMode: .discrete))
        let r = exec(node, inputs: ["input": .float(0.01)])
        XCTAssertNil(r.outputs)
    }

    func testQuantizeContinuousScalesSensitivity() {
        let node = floatNode(.quantize, NodeParams(sensitivity: 2, triggerMode: .continuous))
        let r = exec(node, inputs: ["input": .float(0.5)])
        XCTAssertEqual(r.outputs?["output"]?.outputValue, .continuous(delta: -1.0))
    }

    func testGatePassesAndBlocks() {
        let node = floatNode(.gate, NodeParams(threshold: 0.5, comparator: .gte))
        XCTAssertEqual(exec(node, inputs: ["input": .float(0.6)]).outputs?["output"]?.floatValue, 0.6)
        XCTAssertNil(exec(node, inputs: ["input": .float(0.4)]).outputs)
    }

    func testDebounceBlocksWithinInterval() {
        let node = floatNode(.debounce, NodeParams(minIntervalMs: 100))
        XCTAssertNotNil(exec(node, inputs: ["input": .float(1)], frame: FrameContext(now: 0)).outputs)
        // 50ms 内 → 拦截
        XCTAssertNil(exec(node, inputs: ["input": .float(1)], frame: FrameContext(now: 0.05)).outputs)
        // 超过 100ms → 放行
        XCTAssertNotNil(exec(node, inputs: ["input": .float(1)], frame: FrameContext(now: 0.11)).outputs)
    }

    // MARK: 条件分支

    func testBranchPredicatePositive() {
        let node = floatNode(.branch, NodeParams(predicate: .positive))
        let r = exec(node, inputs: ["input": .float(3)])
        XCTAssertEqual(r.branchResult, true)
        XCTAssertEqual(r.outputs?["true"]?.floatValue, 3)
        XCTAssertEqual(r.outputs?["false"]?.floatValue, 3)
    }

    func testBranchAtBoundary() {
        let node = floatNode(.branch, NodeParams(predicate: .notAtBoundary))
        let r = exec(node, frame: FrameContext(isAtBoundary: true))
        XCTAssertEqual(r.branchResult, false)
    }

    // MARK: 副作用

    func testConsumeDispatchesOutput() {
        let node = floatNode(.consume, NodeParams(action: .volume, method: .mediaKey, step: 0.01))
        let r = exec(node, inputs: ["input": .output(.tick(direction: 1, count: 2))])
        XCTAssertEqual(effects.consumeOutputs, [.tick(direction: 1, count: 2)])
        XCTAssertNotNil(r.outputs) // 写 .unit 供后续节点激活
    }

    func testHapticDispatchesEffect() {
        let node = floatNode(.haptic, NodeParams(waveform: 4, count: 2, intervalUs: 50000, async: true))
        _ = exec(node)
        XCTAssertEqual(effects.hapticCalls.count, 1)
        XCTAssertEqual(effects.hapticCalls[0].waveform, 4)
        XCTAssertEqual(effects.hapticCalls[0].count, 2)
    }

    func testMouseLockAndUnlock() {
        _ = exec(floatNode(.mouse, NodeParams(mouseMode: .lockPosition)))
        _ = exec(floatNode(.mouse, NodeParams(mouseMode: .unlockPosition)))
        XCTAssertEqual(effects.lockCount, 1)
        XCTAssertEqual(effects.unlockCount, 1)
    }

    // MARK: 流控制

    func testSplitCopiesToBothPorts() {
        let r = exec(floatNode(.split, .init()), inputs: ["input": .float(7)])
        XCTAssertEqual(r.outputs?["output1"]?.floatValue, 7)
        XCTAssertEqual(r.outputs?["output2"]?.floatValue, 7)
    }

    func testMergeModes() {
        let sum = exec(floatNode(.merge, NodeParams(mergeMode: .sum)), inputs: ["input1": .float(1), "input2": .float(2)])
        XCTAssertEqual(sum.outputs?["output"]?.floatValue, 3)
        let max = exec(floatNode(.merge, NodeParams(mergeMode: .max)), inputs: ["input1": .float(1), "input2": .float(2)])
        XCTAssertEqual(max.outputs?["output"]?.floatValue, 2)
    }

    func testBaselineStoresAndPassesThrough() {
        // 无输入：从 frame 读信号源
        let r = exec(floatNode(.baseline, NodeParams(source: .normY, key: "startRaw")))
        XCTAssertEqual(r.outputs?["output"]?.floatValue, 0.5)
        XCTAssertEqual(state["startRaw"]?.floatValue, 0.5)
        // 有输入：用输入值
        let r2 = exec(floatNode(.baseline, NodeParams(key: "k2")), inputs: ["input": .float(9)])
        XCTAssertEqual(r2.outputs?["output"]?.floatValue, 9)
        XCTAssertEqual(state["k2"]?.floatValue, 9)
    }

    func testStateReadAndWrite() {
        // 无输入：读
        state["x"] = .float(5)
        let read = exec(floatNode(.state, NodeParams(key: "x")))
        XCTAssertEqual(read.outputs?["output"]?.floatValue, 5)
        // 有输入：写
        let write = exec(floatNode(.state, NodeParams(key: "x")), inputs: ["input": .float(6)])
        XCTAssertEqual(write.outputs?["output"]?.floatValue, 6)
        XCTAssertEqual(state["x"]?.floatValue, 6)
    }

    // MARK: - Predicate 求值

    func testPredicateFirstTimeOnlyOnce() {
        let node = floatNode(.branch, NodeParams(predicate: .firstTime))
        XCTAssertEqual(exec(node).branchResult, true)
        XCTAssertEqual(exec(node).branchResult, false)
    }

    func testPredicateCompare() {
        let p: Predicate = .compare(.gte, 0.5)
        XCTAssertTrue(PredicateEvaluator.evaluate(p, input: .float(0.8), frame: frame, state: &state, nodeID: UUID()))
        XCTAssertFalse(PredicateEvaluator.evaluate(p, input: .float(0.2), frame: frame, state: &state, nodeID: UUID()))
    }

    func testPredicateAndOrNot() {
        let frame = FrameContext(isAtBoundary: true)
        // notAtBoundary && atBoundary = false
        XCTAssertFalse(PredicateEvaluator.evaluate(
            Predicate.and(.notAtBoundary, .atBoundary),
            input: .unit, frame: frame, state: &state, nodeID: UUID()))
        // atBoundary || notAtBoundary = true
        XCTAssertTrue(PredicateEvaluator.evaluate(
            Predicate.or(.atBoundary, .notAtBoundary),
            input: .unit, frame: frame, state: &state, nodeID: UUID()))
        // not(atBoundary) = false
        XCTAssertFalse(PredicateEvaluator.evaluate(
            Predicate.not(.atBoundary),
            input: .unit, frame: frame, state: &state, nodeID: UUID()))
    }
}
