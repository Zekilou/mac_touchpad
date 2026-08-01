import Foundation

/// Timeline 运行时：一个手势的全部触发时间线 + 共享状态
/// - 按 TriggerEvent 路由到对应 GraphEvaluator
/// - stateStore 跨 Timeline 共享（如 enter 记录的 "startRaw" 供 tick 的 absolute 变换读取）
public final class TimelineRuntime {
    public typealias StateStore = [String: NodeValue]

    /// 跨 Timeline 共享状态
    public private(set) var state: StateStore = [:]
    /// 副作用派发目标（引擎实现：震动/调节/鼠标/冻结）
    public let effects: TimelineEffects

    private var evaluators: [TriggerEvent: GraphEvaluator]

    /// - Parameter timelines: 一个手势的全部 Timeline（通常来自 TimelineMigrator 或用户配置）
    /// - Parameter effects: 副作用实现
    public init(timelines: [TimelineConfig], effects: TimelineEffects) {
        self.effects = effects
        var evals: [TriggerEvent: GraphEvaluator] = [:]
        for timeline in timelines {
            if let evaluator = GraphEvaluator(timeline: timeline) {
                evals[timeline.trigger] = evaluator
            }
        }
        self.evaluators = evals
    }

    /// 触发一次事件（如 onEnterHolding / onTick / onExitHolding）
    public func handle(_ event: TriggerEvent, frame: FrameContext) {
        evaluators[event]?.evaluate(frame: frame, state: &state, effects: effects)
    }

    /// 是否存在该触发事件的时间线
    public func hasTimeline(for event: TriggerEvent) -> Bool {
        evaluators[event] != nil
    }

    /// 全部时间线的触发事件列表
    public var triggers: [TriggerEvent] {
        Array(evaluators.keys)
    }

    /// 重置跨帧状态（新手势开始时调用）
    public func reset() {
        state.removeAll(keepingCapacity: true)
        evaluators.values.forEach { $0.reset() }
    }
}
