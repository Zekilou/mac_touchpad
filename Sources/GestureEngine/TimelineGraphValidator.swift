import Foundation

// MARK: - 图验证结果

/// dry-run 验证结果：拓扑排序成功或失败原因
public enum GraphValidationResult: Equatable {
    /// 通过，返回拓扑执行顺序（先依赖后依赖者）
    case valid(order: [UUID])
    /// 存在环：列出环上的节点 ID
    case cycle([UUID])
    /// 边的端口引用了不存在的节点
    case danglingEdge(Edge)
    /// 入边为 0 的节点数不足（无入口）
    case noEntry
}

// MARK: - TimelineGraphValidator

/// Timeline 图的静态验证器（dry-run）
/// - 检测环（Kahn 拓扑排序）
/// - 检测悬挂边（引用不存在的节点）
/// - 校验入口节点存在且可达所有节点
public enum TimelineGraphValidator {

    /// 判断是否为"帧尾写边"：进入 varRef/set/toggle 节点的边，或进入模块**写类输入端口**的边
    /// （写请求帧尾生效，不参与拓扑排序）
    /// 摩尔状态机语义：varRef 读 state 旧值（不依赖本帧写方），写请求帧尾 flush → 跨帧无环
    /// 模块写类端口（ModulePort.isWrite）：模块输出→tick 链→写类输入的跨模块环在拓扑中忽略，
    /// 执行器在帧末延迟注入（见 GraphEvaluator 第二遍 module 处理）
    public static func isWriteEdge(_ edge: Edge, nodes: [UUID: NodeConfig]) -> Bool {
        guard let node = nodes[edge.to.nodeID] else { return false }
        switch node.type {
        case .varRef, .set, .toggle:
            return true
        case .module:
            if let inputs = node.params.moduleInputs,
               inputs.contains(where: { $0.name == edge.to.portName && $0.isWrite }) {
                return true
            }
            return false
        default:
            return false
        }
    }

    /// 执行拓扑排序，返回执行顺序（无环才返回 .valid）
    /// - Parameter ignoreWriteEdges: 忽略帧尾写边（varRef 写请求），用于状态机展开图（读旧值 → 转移 → 帧尾写）
    public static func topologicalOrder(of timeline: TimelineConfig,
                                        ignoreWriteEdges: Bool = false) -> GraphValidationResult {
        // 0. 节点 ID 集合 + 节点表（写边判定用）
        let nodeIDs = Set(timeline.nodes.map(\.id))
        guard !nodeIDs.isEmpty else { return .valid(order: []) }
        let nodes = Dictionary(uniqueKeysWithValues: timeline.nodes.map { ($0.id, $0) })
        let isIgnored: (Edge) -> Bool = ignoreWriteEdges ? { isWriteEdge($0, nodes: nodes) } : { _ in false }

        // 1. 校验悬挂边（所有边都查，含写边）
        for edge in timeline.edges {
            if !nodeIDs.contains(edge.from.nodeID) || !nodeIDs.contains(edge.to.nodeID) {
                return .danglingEdge(edge)
            }
        }

        // 2. Kahn 算法：入度统计（忽略写边）
        var inDegree: [UUID: Int] = [:]
        for node in timeline.nodes { inDegree[node.id] = 0 }
        var adjacency: [UUID: [UUID]] = [:]
        for node in timeline.nodes { adjacency[node.id] = [] }
        for edge in timeline.edges where !isIgnored(edge) {
            inDegree[edge.to.nodeID, default: 0] += 1
            adjacency[edge.from.nodeID, default: []].append(edge.to.nodeID)
        }

        // 3. 从入度 0 的节点开始
        var queue: [UUID] = timeline.nodes.filter { inDegree[$0.id] == 0 }.map(\.id)
        var order: [UUID] = []

        while !queue.isEmpty {
            let current = queue.removeFirst()
            order.append(current)
            for next in adjacency[current, default: []] {
                inDegree[next, default: 0] -= 1
                if inDegree[next, default: 0] == 0 {
                    queue.append(next)
                }
            }
        }

        // 4. 有剩余未处理节点 → 存在环
        if order.count < timeline.nodes.count {
            let remaining = Set(timeline.nodes.map(\.id)).subtracting(order)
            // 提取环的近似表示（remaining 中任一节点沿出边走）
            var cyclePath: [UUID] = []
            var current = remaining.first!
            var seen: Set<UUID> = []
            while !seen.contains(current) {
                seen.insert(current)
                cyclePath.append(current)
                guard let next = adjacency[current, default: []].first(where: { remaining.contains($0) }) else {
                    break
                }
                current = next
            }
            return .cycle(cyclePath)
        }

        // 5. 入口校验：entryNodeIDs 必须非空且都在节点集合中
        guard !timeline.entryNodeIDs.isEmpty else { return .noEntry }
        for entry in timeline.entryNodeIDs where !nodeIDs.contains(entry) {
            return .danglingEdge(Edge(from: PortID(nodeID: entry, portName: "entry"),
                                      to: PortID(nodeID: entry, portName: "entry")))
        }

        return .valid(order: order)
    }

    /// 可达性：从 entry 出发能到达哪些节点（用于检查"孤立节点"）
    public static func reachableNodes(from timeline: TimelineConfig) -> Set<UUID> {
        var adjacency: [UUID: [UUID]] = [:]
        for node in timeline.nodes { adjacency[node.id] = [] }
        for edge in timeline.edges {
            adjacency[edge.from.nodeID, default: []].append(edge.to.nodeID)
        }
        var visited: Set<UUID> = []
        var stack = timeline.entryNodeIDs
        while let current = stack.popLast() {
            guard !visited.contains(current) else { continue }
            visited.insert(current)
            stack.append(contentsOf: adjacency[current, default: []])
        }
        return visited
    }
}
