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

    private func exec(_ node: NodeConfig, inputs: [String: SocketValue] = [:],
                      frame: FrameContext? = nil) -> NodeExecutionResult {
        NodeExecutors.execute(node: node, inputs: inputs,
                              frame: frame ?? self.frame,
                              state: &state, effects: effects)
    }

    private func floatNode(_ type: NodeType, _ params: NodeParams) -> NodeConfig {
        NodeConfig(type: type, params: params)
    }

    // MARK: 数据源

    func testTouchDataOutputsAllFields() {
        let r = exec(floatNode(.touchData, NodeParams()))
        XCTAssertEqual(r.outputs?["normY"]?.floatValue, 0.5)
        XCTAssertEqual(r.outputs?["normX"]?.floatValue, 0.3)
        XCTAssertEqual(r.outputs?["size"]?.floatValue, 0) // 未提供 → 0
    }

    func testValueReturnsConstant() {
        let r = exec(floatNode(.value, NodeParams(constant: 3.5)))
        XCTAssertEqual(r.outputs?["value"]?.floatValue, 3.5)
    }

    /// pipeOut 收到有效 unit 脉冲 → 透传 unit（无输入/无效 → invalid）
    func testPipeOutPassesThroughValidTrigger() {
        let r = exec(floatNode(.pipeOut, NodeParams(trigger: .onTick)), inputs: ["trigger": .unit()])
        XCTAssertEqual(r.outputs?["trigger"], .unit())
        // 无效输入 → invalid
        let bad = exec(floatNode(.pipeOut, NodeParams(trigger: .onTick)), inputs: ["trigger": .invalid()])
        XCTAssertEqual(bad.outputs?["trigger"], .invalid())
        // 无输入 → invalid
        let none = exec(floatNode(.pipeOut, NodeParams(trigger: .onTick)))
        XCTAssertEqual(none.outputs?["trigger"], .invalid())
    }

    // MARK: 数学/变换（value → result）

    func testTransformDeltaUsesLastValue() {
        let node = floatNode(.transform, NodeParams(transform: .delta))
        // 第一帧：last 不存在 → delta 0
        XCTAssertEqual(exec(node, inputs: ["value": .float(0.3)]).outputs?["result"]?.floatValue ?? 0, 0)
        // 第二帧：delta = 0.4 - 0.3（Float 精度，用 accuracy）
        let second = exec(node, inputs: ["value": .float(0.4)]).outputs?["result"]?.floatValue ?? 0
        XCTAssertEqual(second, 0.1, accuracy: 0.0001)
    }

    func testTransformAbsoluteUsesBaseline() {
        state["startRaw"] = .float(0.2)
        let r = exec(floatNode(.transform, NodeParams(transform: .absolute)),
                     inputs: ["value": .float(0.5)])
        XCTAssertEqual(r.outputs?["result"]?.floatValue, 0.3)
    }

    func testScaleMultiplierAndOffset() {
        let r = exec(floatNode(.scale, NodeParams(multiplier: 3, offset: 1)),
                     inputs: ["value": .float(2)])
        XCTAssertEqual(r.outputs?["result"]?.floatValue, 7)
    }

    func testClampBounds() {
        let node = floatNode(.clamp, NodeParams(min: 0, max: 1))
        XCTAssertEqual(exec(node, inputs: ["value": .float(5)]).outputs?["result"]?.floatValue, 1)
        XCTAssertEqual(exec(node, inputs: ["value": .float(-2)]).outputs?["result"]?.floatValue, 0)
    }

    func testAbsAndSign() {
        XCTAssertEqual(exec(floatNode(.abs, .init()), inputs: ["value": .float(-2.5)]).outputs?["result"]?.floatValue, 2.5)
        XCTAssertEqual(exec(floatNode(.sign, .init()), inputs: ["value": .float(-2.5)]).outputs?["result"]?.floatValue, -1)
    }

    /// 必需输入 invalid → 输出全 invalid（valid 传播）
    func testRequiredInputInvalidPropagates() {
        let r = exec(floatNode(.scale, NodeParams(multiplier: 2)), inputs: ["value": .invalid()])
        XCTAssertEqual(r.outputs?["result"], .invalid())
        // 无输入（未连边）同样 invalid
        let r2 = exec(floatNode(.scale, NodeParams(multiplier: 2)))
        XCTAssertEqual(r2.outputs?["result"], .invalid())
    }

    // MARK: 量化/门控

    func testQuantizeDiscrete() {
        // positiveDecrease：信号增大 → direction -1；|0.05|/0.02 = 2
        let node = floatNode(.quantize, NodeParams(stepNorm: 0.02, triggerMode: .discrete))
        let r = exec(node, inputs: ["value": .float(0.05)])
        XCTAssertEqual(r.outputs?["tick"]?.outputValue, .tick(direction: -1, count: 2))
        XCTAssertEqual(r.outputs?["tick"]?.valid, true)
    }

    /// 没到刻度 → tick invalid（整链冻结）
    func testQuantizeBelowStepOutputsInvalid() {
        let node = floatNode(.quantize, NodeParams(stepNorm: 0.02, triggerMode: .discrete))
        let r = exec(node, inputs: ["value": .float(0.01)])
        XCTAssertEqual(r.outputs?["tick"], .invalid())
    }

    func testQuantizeContinuousScalesSensitivity() {
        let node = floatNode(.quantize, NodeParams(sensitivity: 2, triggerMode: .continuous))
        let r = exec(node, inputs: ["value": .float(0.5)])
        XCTAssertEqual(r.outputs?["tick"]?.outputValue, .continuous(delta: -1.0))
    }

    /// gate 输出 pass 布尔（不是阻塞链）
    func testGateOutputsBool() {
        let node = floatNode(.gate, NodeParams(threshold: 0.5, comparator: .gte))
        XCTAssertEqual(exec(node, inputs: ["value": .float(0.6)]).outputs?["pass"]?.boolValue, true)
        XCTAssertEqual(exec(node, inputs: ["value": .float(0.4)]).outputs?["pass"]?.boolValue, false)
    }

    func testDebounceBlocksWithinInterval() {
        let node = floatNode(.debounce, NodeParams(minIntervalMs: 100))
        let t0 = exec(node, inputs: ["trigger": .unit()], frame: FrameContext(now: 0))
        XCTAssertEqual(t0.outputs?["trigger"]?.valid, true) // 首帧放行
        // 50ms 内 → 拦截（输出 invalid）
        let t1 = exec(node, inputs: ["trigger": .unit()], frame: FrameContext(now: 0.05))
        XCTAssertEqual(t1.outputs?["trigger"], .invalid())
        // 超过 100ms → 放行
        let t2 = exec(node, inputs: ["trigger": .unit()], frame: FrameContext(now: 0.11))
        XCTAssertEqual(t2.outputs?["trigger"]?.valid, true)
    }

    // MARK: 条件分支（路由器）

    /// cond 输入优先：true → value 路由到 out1，out2 invalid
    func testBranchRouterCondTrue() {
        let node = floatNode(.branch, NodeParams())
        let r = exec(node, inputs: ["cond": .bool(true), "value": .float(3)])
        XCTAssertEqual(r.outputs?["out1"], .float(3))
        XCTAssertEqual(r.outputs?["out2"], .invalid())
    }

    func testBranchRouterCondFalse() {
        let node = floatNode(.branch, NodeParams())
        let r = exec(node, inputs: ["cond": .bool(false), "value": .float(3)])
        XCTAssertEqual(r.outputs?["out1"], .invalid())
        XCTAssertEqual(r.outputs?["out2"], .float(3))
    }

    /// 无 cond 连线时回退 predicate（兼容迁移图）
    func testBranchPredicateFallback() {
        let node = floatNode(.branch, NodeParams(predicate: .positive))
        let r = exec(node, inputs: ["value": .float(3)])
        XCTAssertEqual(r.outputs?["out1"], .float(3))
        XCTAssertEqual(r.outputs?["out2"], .invalid())
    }

    /// value invalid → 输出全 invalid
    func testBranchInvalidValue() {
        let node = floatNode(.branch, NodeParams(predicate: .positive))
        let r = exec(node, inputs: ["value": .invalid()])
        XCTAssertEqual(r.outputs?["out1"], .invalid())
        XCTAssertEqual(r.outputs?["out2"], .invalid())
    }

    // MARK: 副作用（输入有效才执行；输出 result = unit 脉冲）

    func testConsumeDispatchesOutput() {
        let node = floatNode(.consume, NodeParams(action: .volume, method: .mediaKey, step: 0.01))
        let r = exec(node, inputs: ["data": .output(.tick(direction: 1, count: 2))])
        XCTAssertEqual(effects.consumeOutputs, [.tick(direction: 1, count: 2)])
        XCTAssertEqual(r.outputs?["result"], .unit()) // 事件脉冲供后续
    }

    /// consume 收到 invalid → 不执行、输出 invalid
    func testConsumeInvalidDoesNotDispatch() {
        let node = floatNode(.consume, NodeParams(action: .volume))
        let r = exec(node, inputs: ["data": .invalid()])
        XCTAssertTrue(effects.consumeOutputs.isEmpty)
        XCTAssertEqual(r.outputs?["result"], .invalid())
    }

    func testHapticNeedsValidTrigger() {
        let node = floatNode(.haptic, NodeParams(waveform: 4, count: 2, intervalUs: 50000, async: true))
        // 无输入 → 不执行
        _ = exec(node)
        XCTAssertTrue(effects.hapticCalls.isEmpty)
        // 有效 trigger → 执行并输出 unit
        let r = exec(node, inputs: ["trigger": .unit()])
        XCTAssertEqual(effects.hapticCalls.count, 1)
        XCTAssertEqual(effects.hapticCalls[0].waveform, 4)
        XCTAssertEqual(r.outputs?["result"], .unit())
    }

    func testMouseLockAndUnlock() {
        let lock = floatNode(.mouse, NodeParams(mouseMode: .lockPosition))
        let unlock = floatNode(.mouse, NodeParams(mouseMode: .unlockPosition))
        _ = exec(lock, inputs: ["trigger": .unit()])
        _ = exec(unlock, inputs: ["trigger": .unit()])
        XCTAssertEqual(effects.lockCount, 1)
        XCTAssertEqual(effects.unlockCount, 1)
        // 无效输入不执行
        _ = exec(lock, inputs: ["trigger": .invalid()])
        XCTAssertEqual(effects.lockCount, 1)
    }

    // MARK: 流控制

    func testSplitCopiesToBothPorts() {
        let r = exec(floatNode(.split, .init()), inputs: ["value": .float(7)])
        XCTAssertEqual(r.outputs?["out1"]?.floatValue, 7)
        XCTAssertEqual(r.outputs?["out2"]?.floatValue, 7)
    }

    func testMergeModes() {
        let sum = exec(floatNode(.merge, NodeParams(mergeMode: .sum)),
                       inputs: ["input1": .float(1), "input2": .float(2)])
        XCTAssertEqual(sum.outputs?["result"]?.floatValue, 3)
        let max = exec(floatNode(.merge, NodeParams(mergeMode: .max)),
                       inputs: ["input1": .float(1), "input2": .float(2)])
        XCTAssertEqual(max.outputs?["result"]?.floatValue, 2)
        // 任一输入 invalid → 输出 invalid
        let bad = exec(floatNode(.merge, NodeParams(mergeMode: .sum)),
                       inputs: ["input1": .float(1), "input2": .invalid()])
        XCTAssertEqual(bad.outputs?["result"], .invalid())
    }

    func testBaselineStoresOnValidTrigger() {
        // 触发有效时从 frame 读信号源并记录
        let r = exec(floatNode(.baseline, NodeParams(source: .normY, key: "startRaw")),
                     inputs: ["trigger": .unit()])
        XCTAssertEqual(r.outputs?["result"]?.floatValue, 0.5)
        XCTAssertEqual(state["startRaw"]?.floatValue, 0.5)
        // 无触发 → invalid，不记录
        _ = exec(floatNode(.baseline, NodeParams(source: .normY, key: "startRaw2")))
        XCTAssertNil(state["startRaw2"])
    }

    func testStateReadAndWrite() {
        // 无输入：读
        state["x"] = .float(5)
        let read = exec(floatNode(.state, NodeParams(key: "x")))
        XCTAssertEqual(read.outputs?["value"]?.floatValue, 5)
        // 有输入：写
        let write = exec(floatNode(.state, NodeParams(key: "x")), inputs: ["value": .float(6)])
        XCTAssertEqual(write.outputs?["value"]?.floatValue, 6)
        XCTAssertEqual(state["x"]?.floatValue, 6)
        // 空 state 读 → invalid
        let empty = exec(floatNode(.state, NodeParams(key: "none")))
        XCTAssertEqual(empty.outputs?["value"], .invalid())
    }

    // MARK: - Predicate 求值

    func testPredicateFirstTimeOnlyOnce() {
        let node = floatNode(.branch, NodeParams(predicate: .firstTime))
        XCTAssertEqual(exec(node, inputs: ["value": .unit()]).outputs?["out1"]?.valid, true)
        XCTAssertEqual(exec(node, inputs: ["value": .unit()]).outputs?["out2"]?.valid, true)
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
