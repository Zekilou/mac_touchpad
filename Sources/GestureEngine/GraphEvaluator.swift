import Foundation

/// 单张节点图的执行器（v6 数据流语义）
/// - 构造时做拓扑排序验证（环/悬挂边 → init 失败）
/// - evaluate 按拓扑序执行：从给定入口（Trigger 节点）出发的可达子图
/// - 纯数据流：节点从上游输出端口读 SocketValue（含 valid），算输出；无"激活/跳过"机制
/// - 副作用经 TimelineEffects 派发
public final class GraphEvaluator {
    public let timeline: TimelineConfig

    /// 拓扑执行顺序（先依赖后依赖者）
    private let order: [UUID]
    /// 每个节点输出端口值：nodeID → [portName: SocketValue]（invalid 也保留，显式传播）
    private var portValues: [UUID: [String: SocketValue]] = [:]

    /// - Returns: 图有环/悬挂边时返回 nil
    public init?(timeline: TimelineConfig) {
        guard case .valid(let order) = TimelineGraphValidator.topologicalOrder(of: timeline) else {
            return nil
        }
        self.timeline = timeline
        self.order = order
    }

    /// 执行一次 evaluate（一帧/一次触发事件）
    /// - Parameter entryIDs: 本次执行入口（Trigger 节点）。nil = 执行整张图（dry-run）。
    public func evaluate(frame: FrameContext, state: inout StateStore, effects: TimelineEffects,
                         entryIDs: [UUID]? = nil) {
        portValues.removeAll(keepingCapacity: true)
        let nodesByID = Dictionary(uniqueKeysWithValues: timeline.nodes.map { ($0.id, $0) })

        // 入口可达集：只执行从 Trigger 出发可达的链，不同 Trigger 互不干扰
        let reachable: Set<UUID>
        if let entryIDs {
            reachable = reachableSet(from: entryIDs)
        } else {
            reachable = Set(order)
        }

        for nodeID in order where reachable.contains(nodeID) {
            guard let node = nodesByID[nodeID] else { continue }

            // 收集输入（按 to.portName；多个入边同端口取第一个）
            var inputs: [String: SocketValue] = [:]
            for edge in timeline.incomingEdges(to: nodeID) {
                if inputs[edge.to.portName] == nil,
                   let v = portValues[edge.from.nodeID]?[edge.from.portName] {
                    inputs[edge.to.portName] = v
                }
            }

            // 数据流执行：节点内部处理必需输入 invalid → 输出全 invalid（显式传播）
            let result = NodeExecutors.execute(node: node, inputs: inputs,
                                               frame: frame, state: &state, effects: effects)
            if let outputs = result.outputs, !outputs.isEmpty {
                portValues[nodeID] = outputs
            }
        }
    }

    /// 清空执行期状态（跨帧的 transform.last/debounce 等保留在 stateStore，不在本类）
    public func reset() {
        portValues.removeAll(keepingCapacity: true)
    }

    // MARK: - 可达集

    /// 从入口节点沿出边 BFS 收集可达节点集合（含入口自身）
    private func reachableSet(from entries: [UUID]) -> Set<UUID> {
        var visited: Set<UUID> = []
        var stack = entries
        while let id = stack.popLast() {
            guard visited.insert(id).inserted else { continue }
            for edge in timeline.outgoingEdges(from: id) {
                stack.append(edge.to.nodeID)
            }
        }
        return visited
    }
}
