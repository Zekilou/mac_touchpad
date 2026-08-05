import Foundation
import CoreGraphics

// MARK: - 自动布局（多根森林：根分组 + 组内从左到右分层）

/// 节点图自动整理：每个**根节点**（无数据入边）是一个独立组，组内从根出发按数据流一层层从左到右展开。
///
/// 规则（视觉符合"几个独立流程，每个从左流到右"）：
/// 1. **找根分组**：无数据入边的节点（触控板数据/常量/变量）是根；多源 BFS 从根同时扩散，
///    节点归属"最先到达它的根"（最近根）→ 每个根及其可达子树 = 一个独立组，组垂直堆叠、互不干扰。
/// 2. **组内分层（从左到右）**：根在层 0，其输出连到的节点是下一层，逐层展开；
///    节点若还有别的输入，**从输入反向找回去**——层 = 所有父节点层 + 1（保证排在所有父之后）。
/// 3. **忽略 varRef 写边**：写请求是帧尾回写（摩尔状态机），不是数据流，参与分层会成环；
///    变量位置由"读"边决定，反馈写线从右回左（状态机本质，视觉可接受）。
/// 4. **层内垂直排列**：同层节点上下排布，按"父节点平均位置"排序减少交叉；间距足够大。
/// 5. **group 不参与**：批注组是纯视觉框，保留用户摆放位置。
public enum TimelineLayout {

    /// 层间距（x 方向）
    public static let horizontalSpacing: Double = 280
    /// 层内垂直行距（y 方向，节点实际高度之上再留的间隔）
    public static let verticalSpacing: Double = 40
    /// 组间距（垂直方向，组与组之间）
    public static let groupGap: Double = 140

    /// 布局完整结果（测试用）：坐标 + 分组 + 层号
    struct LayoutResult {
        let positions: [UUID: CGPoint]
        let groupOf: [UUID: Int]
        let layer: [UUID: Int]
    }

    /// 计算每个节点的目标坐标（画布坐标）；group 节点不返回（保持原位）
    /// - Parameter heights: 节点实际显示高度（卡片自适应内容后由 UI 层实测传入）；缺省按 100 估算
    public static func layoutPositions(of timeline: TimelineConfig,
                                       heights: [UUID: CGFloat] = [:]) -> [UUID: CGPoint] {
        computeLayout(of: timeline, heights: heights).positions
    }

    /// 布局主流程（含分组/层，供测试断言同组数据边方向）
    static func computeLayout(of timeline: TimelineConfig,
                              heights: [UUID: CGFloat] = [:]) -> LayoutResult {
        let types = Dictionary(uniqueKeysWithValues: timeline.nodes.map { ($0.id, $0) })
        func isWrite(_ e: Edge) -> Bool { TimelineGraphValidator.isWriteEdge(e, nodes: types) }
        let isGroup: (UUID) -> Bool = { types[$0]?.type == .group }

        // 数据边子图（忽略 varRef/set/toggle 写边与 group）
        var children: [UUID: [UUID]] = [:]
        var parents: [UUID: [UUID]] = [:]
        for n in timeline.nodes where n.type != .group {
            children[n.id] = []
        }
        for e in timeline.edges where !isWrite(e) {
            guard !isGroup(e.from.nodeID), !isGroup(e.to.nodeID) else { continue }
            children[e.from.nodeID]?.append(e.to.nodeID)
            parents[e.to.nodeID, default: []].append(e.from.nodeID)
        }

        // 根列表（无数据入边，按节点原始顺序编号）
        let roots = timeline.nodes
            .filter { $0.type != .group && (parents[$0.id] ?? []).isEmpty }
            .map(\.id)

        // 归属：多源 BFS 从根同时扩散，先到先得（最近根）
        var groupOf: [UUID: Int] = [:]
        var bfsOrder: [UUID] = []
        var queue: [(id: UUID, g: Int)] = []
        for (i, r) in roots.enumerated() {
            groupOf[r] = i
            queue.append((r, i))
        }
        var head = 0
        while head < queue.count {
            let cur = queue[head]; head += 1
            bfsOrder.append(cur.id)
            for c in children[cur.id] ?? [] where groupOf[c] == nil {
                groupOf[c] = cur.g
                queue.append((c, cur.g))
            }
        }
        // 兜底：无根可达的节点（异常图）归组 0
        for n in timeline.nodes where n.type != .group && groupOf[n.id] == nil {
            groupOf[n.id] = 0
            bfsOrder.append(n.id)
        }

        // 小组并入主组（迭代直到稳定）：组节点数 ≤ 阈值的组并入"数据父所在的最大组"
        // （根组无父时并入最大子组）。解决"最近根归属"把转移链 branch 抢到状态常量组、
        // 产生大量小撮组的问题；辅助常量/变量/写链最终归入主流程，出现在流程最左。
        let mergeThreshold = 12
        var merged: [Int: [UUID]] = [:]
        for (id, g) in groupOf { merged[g, default: []].append(id) }
        var changed = true
        while changed {
            changed = false
            var curGroupOf: [UUID: Int] = [:]
            for (g, ids) in merged { for id in ids { curGroupOf[id] = g } }
            let groups = merged.keys.sorted()
            for g in groups {
                let ids = merged[g] ?? []
                guard ids.count <= mergeThreshold else { continue }
                var parentCount: [Int: Int] = [:]
                var childCount: [Int: Int] = [:]
                var writeSourceCount: [Int: Int] = [:]
                for id in ids {
                    for p in parents[id] ?? [] where curGroupOf[p] != g {
                        parentCount[curGroupOf[p] ?? 0, default: 0] += 1
                    }
                    for c in children[id] ?? [] where curGroupOf[c] != g {
                        childCount[curGroupOf[c] ?? 0, default: 0] += 1
                    }
                }
                // 孤立组（无数据边）：并入"写它的组"（纯写入变量跟随其写入链所在主流程）
                for e in timeline.edges where isWrite(e) && curGroupOf[e.to.nodeID] == g {
                    if let sg = curGroupOf[e.from.nodeID], sg != g {
                        writeSourceCount[sg, default: 0] += 1
                    }
                }
                let target = parentCount.max(by: { $0.value < $1.value })?.key
                    ?? childCount.max(by: { $0.value < $1.value })?.key
                    ?? writeSourceCount.max(by: { $0.value < $1.value })?.key
                guard let target else { continue }
                merged[target]?.append(contentsOf: ids)
                merged[g] = nil
                changed = true
                break   // 组映射已变，重新迭代
            }
        }
        groupOf = [:]
        for (g, ids) in merged { for id in ids { groupOf[id] = g } }

        // 层：全局数据深度（所有数据边都算，跨组父也约束——保证任何数据边 from→to 都 to 层 ≥ from 层+1）
        // 用拓扑序（忽略写边）做 DP：拓扑序保证父先于子（BFS 归属序不保证，多父共享节点会算错层）
        var layer: [UUID: Int] = [:]
        for n in timeline.nodes where n.type != .group { layer[n.id] = 0 }
        let topoOrder: [UUID]
        if case .valid(let order) = TimelineGraphValidator.topologicalOrder(of: timeline, ignoreWriteEdges: true) {
            topoOrder = order
        } else {
            topoOrder = bfsOrder   // 异常回退
        }
        for id in topoOrder {
            for c in children[id] ?? [] {
                layer[c] = max(layer[c] ?? 0, (layer[id] ?? 0) + 1)
            }
        }

        // 组内层内排序（父均值升序减少交叉；无父的根按原始顺序，主源在上）
        let orderIndex = Dictionary(uniqueKeysWithValues: timeline.nodes.enumerated().map { ($0.element.id, $0.offset) })
        var inLayerIndex: [UUID: Int] = [:]
        var groupNodes: [Int: [UUID]] = [:]
        for (id, g) in groupOf { groupNodes[g, default: []].append(id) }
        for (g, ids) in groupNodes {
            let byLayer = Dictionary(grouping: ids, by: { layer[$0] ?? 0 })
            for l in byLayer.keys.sorted() {
                let sorted = byLayer[l]!.sorted { a, b in
                    let ka = (avgParentIndex(a, parents: parents, inLayerIndex: inLayerIndex),
                              orderIndex[a] ?? 0)
                    let kb = (avgParentIndex(b, parents: parents, inLayerIndex: inLayerIndex),
                              orderIndex[b] ?? 0)
                    return ka < kb
                }
                for (i, id) in sorted.enumerated() { inLayerIndex[id] = i }
            }
        }

        // 组排序：节点多的组在前（主流程在上，辅助常量在下）
        let groupOrder = groupNodes.keys.sorted { a, b in
            let ca = groupNodes[a]!.count, cb = groupNodes[b]!.count
            if ca != cb { return ca > cb }
            return a < b
        }

        // 坐标：组垂直堆叠（每组一条横向流程带）；组内 x = 层 * 水平间距；
        // 同层节点按层内序号垂直累计排布（y = 前一个节点底 + 行距），避免卡片高度大时重叠
        var positions: [UUID: CGPoint] = [:]
        var cursorY: Double = 0
        for g in groupOrder {
            let ids = groupNodes[g] ?? []
            let sorted = ids.sorted { a, b in
                let la = layer[a] ?? 0, lb = layer[b] ?? 0
                if la != lb { return la < lb }
                return (inLayerIndex[a] ?? 0) < (inLayerIndex[b] ?? 0)
            }
            var layerCursor: [Int: Double] = [:]   // 每层当前垂直游标（相对组起点）
            var maxBottom: Double = cursorY
            for id in sorted {
                let l = layer[id] ?? 0
                let y = cursorY + (layerCursor[l] ?? 0)
                positions[id] = CGPoint(x: Double(l) * horizontalSpacing, y: y)
                let h = Double(heights[id] ?? 100)
                layerCursor[l, default: 0] += h + verticalSpacing
                maxBottom = max(maxBottom, y + h)
            }
            cursorY = maxBottom + groupGap
        }
        return LayoutResult(positions: positions, groupOf: groupOf, layer: layer)
    }

    /// 应用布局：原地更新节点坐标（group 不动）
    public static func apply(_ positions: [UUID: CGPoint], to timeline: inout TimelineConfig) {
        for i in timeline.nodes.indices where timeline.nodes[i].type != .group {
            if let p = positions[timeline.nodes[i].id] {
                timeline.nodes[i].x = Double(p.x)
                timeline.nodes[i].y = Double(p.y)
            }
        }
    }

    /// 父节点平均层内序号（无父 → 正无穷，排最后）
    private static func avgParentIndex(_ id: UUID, parents: [UUID: [UUID]],
                                       inLayerIndex: [UUID: Int]) -> Double {
        let ps = parents[id] ?? []
        guard !ps.isEmpty else { return .greatestFiniteMagnitude }
        let sum = ps.reduce(0) { $0 + Double(inLayerIndex[$1] ?? 0) }
        return sum / Double(ps.count)
    }
}
