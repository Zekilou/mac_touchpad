import XCTest
@testable import GestureEngine

final class TimelineRuntimeTests: XCTestCase {

    private var effects: MockEffects!

    override func setUp() {
        super.setUp()
        effects = MockEffects()
    }

    private func makeEvent() -> EventConfig {
        EventConfig(name: "音量", actionType: .volume,
                    step: 0.0125, boundaryThreshold: 0.001)
    }

    private func makeRuntime() -> TimelineRuntime {
        let timelines = TimelineMigrator.migrate(pipeline: LegacyPipelineConfig(), event: makeEvent())
        return TimelineRuntime(timelines: timelines, effects: effects)
    }

    // MARK: - 结构

    func testRuntimeLoadsAllTriggers() {
        let runtime = makeRuntime()
        XCTAssertTrue(runtime.hasTimeline(for: .onFirstTap))
        XCTAssertTrue(runtime.hasTimeline(for: .onEnterHolding))
        XCTAssertTrue(runtime.hasTimeline(for: .onTick))
        XCTAssertTrue(runtime.hasTimeline(for: .onExitHolding))
        XCTAssertEqual(Set(runtime.triggers),
                       Set([.onFirstTap, .onEnterHolding, .onTick, .onExitHolding]))
    }

    // MARK: - 完整流程（enter → tick → exit）

    func testEnterTimelineLocksMouseRecordsBaselineAndHaptics() {
        let runtime = makeRuntime()
        runtime.handle(.onEnterHolding,
                       frame: FrameContext(rawSignals: [.normY: 0.8], directionRule: .positiveDecrease))

        // baseline 记录起始信号
        XCTAssertEqual(runtime.state["startRaw"]?.floatValue, 0.8)
        // 鼠标锁定（disassociateMouse 默认 true）
        XCTAssertEqual(effects.lockCount, 1)
        // 进入震动（hapticEnter 默认开，波形 2）
        XCTAssertEqual(effects.hapticCalls.first?.waveform, 2)
    }

    func testTickTimelineConsumesOnSecondFrame() {
        let runtime = makeRuntime()

        // 进入 holding：基线 0.5
        runtime.handle(.onEnterHolding,
                       frame: FrameContext(rawSignals: [.normY: 0.5], directionRule: .positiveDecrease))

        // tick 第一帧：delta=0 → 无输出
        runtime.handle(.onTick,
                       frame: FrameContext(rawSignals: [.normY: 0.5], directionRule: .positiveDecrease))
        XCTAssertTrue(effects.consumeOutputs.isEmpty)

        // tick 第二帧：delta=0.05 → tick(-1, 2) → consume + tick 震动
        runtime.handle(.onTick,
                       frame: FrameContext(rawSignals: [.normY: 0.55], directionRule: .positiveDecrease))
        XCTAssertEqual(effects.consumeOutputs, [.tick(direction: -1, count: 2)])
        // tick 震动（波形 4）在 consume 后触发
        XCTAssertTrue(effects.hapticCalls.contains { $0.waveform == 4 })
    }

    func testTickTimelineAtBoundaryFreezes() {
        let runtime = makeRuntime()
        runtime.handle(.onEnterHolding,
                       frame: FrameContext(rawSignals: [.normY: 0.5], directionRule: .positiveDecrease))

        // 第一帧：建立 transform.last 基线（delta=0 → 无刻度）
        runtime.handle(.onTick,
                       frame: FrameContext(rawSignals: [.normY: 0.5], directionRule: .positiveDecrease))

        // 边界状态：branch.notAtBoundary=false → false 分支 → 边界震动(波形2) + freeze
        runtime.handle(.onTick,
                       frame: FrameContext(rawSignals: [.normY: 0.55],
                                           directionRule: .positiveDecrease,
                                           isAtBoundary: true))
        XCTAssertEqual(effects.freezeCount, 1)
        XCTAssertTrue(effects.consumeOutputs.isEmpty)
        // 边界震动（hapticBoundary 波形 2，count 2）
        XCTAssertTrue(effects.hapticCalls.contains { $0.waveform == 2 && $0.count == 2 })
    }

    func testExitTimelineUnlocksMouse() {
        let runtime = makeRuntime()
        runtime.handle(.onExitHolding, frame: FrameContext())
        XCTAssertEqual(effects.unlockCount, 1)
    }

    // MARK: - 状态生命周期

    func testResetClearsState() {
        let runtime = makeRuntime()
        runtime.handle(.onEnterHolding,
                       frame: FrameContext(rawSignals: [.normY: 0.8], directionRule: .positiveDecrease))
        XCTAssertEqual(runtime.state["startRaw"]?.floatValue, 0.8)

        runtime.reset()
        XCTAssertTrue(runtime.state.isEmpty)

        // reset 后重新进入 → 重新记录基线
        runtime.handle(.onEnterHolding,
                       frame: FrameContext(rawSignals: [.normY: 0.3], directionRule: .positiveDecrease))
        XCTAssertEqual(runtime.state["startRaw"]?.floatValue, 0.3)
    }

    /// 关闭 disassociateMouse / hapticEnter 后 enter 时间线不产生对应副作用
    func testMigratedTimelineFollowsConfigSwitches() {
        var pipeline = LegacyPipelineConfig()
        pipeline.disassociateMouse = false
        pipeline.hapticEnter = HapticEvent(enabled: false, waveform: 2, count: 1, intervalUs: 0)
        let runtime = TimelineRuntime(
            timelines: TimelineMigrator.migrate(pipeline: pipeline, event: makeEvent()),
            effects: effects)

        runtime.handle(.onEnterHolding,
                       frame: FrameContext(rawSignals: [.normY: 0.8], directionRule: .positiveDecrease))
        XCTAssertEqual(effects.lockCount, 0)
        XCTAssertTrue(effects.hapticCalls.isEmpty)
        // 基线记录不受开关影响
        XCTAssertEqual(runtime.state["startRaw"]?.floatValue, 0.8)
    }
}
