import Foundation

/// Timeline 运行时：一张自由节点图 + 共享状态（v5 完全配置化）
/// - 引擎按 Trigger 节点路由：handle(event) 找出图上 params.trigger == event 的节点作为入口，
///   GraphEvaluator 只执行该入口可达的链
/// - stateStore 跨 Trigger 共享（如 enter 记录的 "startRaw" 供 tick 的 absolute 变换读取）
public final class TimelineRuntime {
    public typealias StateStore = [String: NodeValue]

    /// 跨 Trigger 共享状态
    public private(set) var state: StateStore = [:]
    /// 副作用派发目标（引擎实现：震动/调节/鼠标/冻结）
    public let effects: TimelineEffects

    private let evaluator: GraphEvaluator
    private let timeline: TimelineConfig

    /// - Parameter timeline: 手势的单张节点图
    /// - Parameter effects: 副作用实现
    /// - Returns: 图有环/悬挂边时返回 nil
    public init?(timeline: TimelineConfig, effects: TimelineEffects) {
        guard let evaluator = GraphEvaluator(timeline: timeline) else { return nil }
        self.effects = effects
        self.evaluator = evaluator
        self.timeline = timeline
    }

    /// 触发一次事件（如 onEnterHolding / onTick / onExitHolding）
    public func handle(_ event: TriggerEvent, frame: FrameContext) {
        let entries = timeline.nodes
            .filter { $0.type == .trigger && $0.params.trigger == event }
            .map(\.id)
        guard !entries.isEmpty else { return }
        evaluator.evaluate(frame: frame, state: &state, effects: effects, entryIDs: entries)
    }

    /// 图上是否存在该触发事件
    public func hasTimeline(for event: TriggerEvent) -> Bool {
        timeline.nodes.contains { $0.type == .trigger && $0.params.trigger == event }
    }

    /// 图上全部 Trigger 事件列表
    public var triggers: [TriggerEvent] {
        var set = Set<TriggerEvent>()
        for node in timeline.nodes where node.type == .trigger {
            if let t = node.params.trigger { set.insert(t) }
        }
        return Array(set)
    }

    /// 重置跨帧状态（新手势开始时调用）
    public func reset() {
        state.removeAll(keepingCapacity: true)
        evaluator.reset()
    }
}
