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

    /// 执行拓扑排序，返回执行顺序（无环才返回 .valid）
    public static func topologicalOrder(of timeline: TimelineConfig) -> GraphValidationResult {
        // 0. 节点 ID 集合
        let nodeIDs = Set(timeline.nodes.map(\.id))
        guard !nodeIDs.isEmpty else { return .valid(order: []) }

        // 1. 校验悬挂边
        for edge in timeline.edges {
            if !nodeIDs.contains(edge.from.nodeID) || !nodeIDs.contains(edge.to.nodeID) {
                return .danglingEdge(edge)
            }
        }

        // 2. Kahn 算法：入度统计
        var inDegree: [UUID: Int] = [:]
        for node in timeline.nodes { inDegree[node.id] = 0 }
        var adjacency: [UUID: [UUID]] = [:]
        for node in timeline.nodes { adjacency[node.id] = [] }
        for edge in timeline.edges {
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
