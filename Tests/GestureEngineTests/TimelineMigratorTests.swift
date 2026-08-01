import XCTest
@testable import GestureEngine

final class TimelineMigratorTests: XCTestCase {

    private var regionID: UUID { UUID() }
    private var eventID: UUID { UUID() }

    /// 默认配置手势（v2 全默认：normY + delta + discrete + 全部震动开）
    private func makeGesture() -> GestureConfig {
        GestureConfig(name: "测试手势", regionID: regionID, eventID: eventID)
    }

    /// 音量事件（mediaKey 模式）
    private func makeEvent() -> EventConfig {
        EventConfig(name: "音量", actionType: .volume,
                    step: 0.0125, boundaryThreshold: 0.001)
    }

    // MARK: - 总体结构

    func testMigrate_ProducesThreeTimelinesInOrder() {
        let timelines = TimelineMigrator.migrate(gesture: makeGesture(), event: makeEvent())
        XCTAssertEqual(timelines.map(\.trigger), [.onEnterHolding, .onTick, .onExitHolding])
    }

    func testMigrate_EachTimelinePassesTopologicalValidation() {
        let timelines = TimelineMigrator.migrate(gesture: makeGesture(), event: makeEvent())
        for timeline in timelines {
            switch TimelineGraphValidator.topologicalOrder(of: timeline) {
            case .valid(let order):
                XCTAssertEqual(Set(order), Set(timeline.nodes.map(\.id)), "\(timeline.trigger) 拓扑排序节点不完整")
            case let result:
                XCTFail("\(timeline.trigger) 验证失败: \(result)")
            }
        }
    }

    // MARK: - onEnterHolding

    func testEnterTimeline_ContainsBaselineNode() {
        let timeline = TimelineMigrator.migrate(gesture: makeGesture(), event: makeEvent())[0]
        let baseline = timeline.firstNode(of: .baseline)
        XCTAssertNotNil(baseline)
        XCTAssertEqual(baseline?.params.key, "startRaw")
        XCTAssertEqual(baseline?.params.source, .normY)
        XCTAssertTrue(timeline.entryNodeIDs.contains(baseline!.id))
    }

    func testEnterTimeline_MouseNodeFollowsDisassociate() {
        // disassociateMouse = true → 有 lockPosition 节点
        let withMouse = makeGesture()
        XCTAssertTrue(withMouse.disassociateMouse)
        let t1 = TimelineMigrator.migrate(gesture: withMouse, event: makeEvent())[0]
        XCTAssertEqual(t1.firstNode(of: .mouse)?.params.mouseMode, .lockPosition)

        // disassociateMouse = false → 无 mouse 节点
        var noMouse = withMouse
        noMouse.disassociateMouse = false
        let t2 = TimelineMigrator.migrate(gesture: noMouse, event: makeEvent())[0]
        XCTAssertNil(t2.firstNode(of: .mouse))
    }

    func testEnterTimeline_HapticFollowsEnabled() {
        // enabled → 有 haptic 节点
        let t1 = TimelineMigrator.migrate(gesture: makeGesture(), event: makeEvent())[0]
        XCTAssertNotNil(t1.firstNode(of: .haptic))
        XCTAssertEqual(t1.firstNode(of: .haptic)?.params.waveform, HapticEvent.enter.waveform)

        // disabled → 无 haptic 节点
        var gesture = makeGesture()
        gesture.hapticEnter = HapticEvent(enabled: false, waveform: 2, count: 1, intervalUs: 0)
        let t2 = TimelineMigrator.migrate(gesture: gesture, event: makeEvent())[0]
        XCTAssertNil(t2.firstNode(of: .haptic))
    }

    // MARK: - onTick

    func testTickTimeline_CoreChain() {
        let timeline = TimelineMigrator.migrate(gesture: makeGesture(), event: makeEvent())[1]

        // 核心 5 节点都存在
        let signal = timeline.firstNode(of: .signal)
        let transform = timeline.firstNode(of: .transform)
        let quantize = timeline.firstNode(of: .quantize)
        let branch = timeline.firstNode(of: .branch)
        let consume = timeline.firstNode(of: .consume)
        let freeze = timeline.firstNode(of: .freeze)
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
        XCTAssertEqual(consume?.params.action, .volume)
        XCTAssertEqual(consume?.params.method, .mediaKey)
        XCTAssertEqual(consume?.params.step, 0.0125)

        // 边：signal→transform→quantize→branch
        func connected(_ from: NodeConfig?, _ to: NodeConfig?, port: String) -> Bool {
            guard let from, let to else { return false }
            return timeline.edges.contains {
                $0.from == PortID(nodeID: from.id, portName: "output")
                    && $0.to == PortID(nodeID: to.id, portName: "input")
            }
        }
        XCTAssertTrue(connected(signal, transform, port: "input"))
        XCTAssertTrue(connected(transform, quantize, port: "input"))
        XCTAssertTrue(connected(quantize, branch, port: "input"))
        // branch 的 true → consume
        XCTAssertTrue(timeline.edges.contains {
            $0.from == PortID(nodeID: branch!.id, portName: "true")
                && $0.to == PortID(nodeID: consume!.id, portName: "input")
        })
        // branch 的 false → freeze
        XCTAssertTrue(timeline.edges.contains {
            $0.from == PortID(nodeID: branch!.id, portName: "false")
                && $0.to == PortID(nodeID: freeze!.id, portName: "input")
        })
    }

    func testTickTimeline_HapticTickFollowsEnabled() {
        // 默认：tick 震动 + 边界震动 两个 haptic 节点
        let t1 = TimelineMigrator.migrate(gesture: makeGesture(), event: makeEvent())[1]
        XCTAssertEqual(t1.nodes.filter { $0.type == .haptic }.count, 2)

        // 禁用 tick 震动 → 仅剩边界震动
        var gesture = makeGesture()
        gesture.hapticTick = HapticEvent(enabled: false, waveform: 4, count: 1, intervalUs: 0)
        let t2 = TimelineMigrator.migrate(gesture: gesture, event: makeEvent())[1]
        XCTAssertEqual(t2.nodes.filter { $0.type == .haptic }.count, 1)
    }

    // MARK: - onExitHolding

    func testExitTimeline_UnlocksMouse() {
        let t1 = TimelineMigrator.migrate(gesture: makeGesture(), event: makeEvent())[2]
        XCTAssertEqual(t1.firstNode(of: .mouse)?.params.mouseMode, .unlockPosition)

        var gesture = makeGesture()
        gesture.disassociateMouse = false
        let t2 = TimelineMigrator.migrate(gesture: gesture, event: makeEvent())[2]
        XCTAssertNil(t2.firstNode(of: .mouse))
    }

    func testExitTimeline_HapticExitDefaultsDisabled() {
        // 默认 hapticExit 关闭 → exit timeline 无 haptic 节点
        let t1 = TimelineMigrator.migrate(gesture: makeGesture(), event: makeEvent())[2]
        XCTAssertNil(t1.firstNode(of: .haptic))

        // 开启后 → 有 haptic 节点
        var gesture = makeGesture()
        gesture.hapticExit = HapticEvent(enabled: true, waveform: 4, count: 1, intervalUs: 0)
        let t2 = TimelineMigrator.migrate(gesture: gesture, event: makeEvent())[2]
        XCTAssertNotNil(t2.firstNode(of: .haptic))
    }
}
