import Foundation

/// 单条 Timeline 的图执行器
/// - 构造时做拓扑排序验证（环/悬挂边 → init 失败）
/// - evaluate 按拓扑序执行所有节点：读入边端口值 → 分支激活检查 → 执行 → 写输出端口值
/// - 纯计算节点可重复执行（dry-run）；副作用经 TimelineEffects 派发
public final class GraphEvaluator {
    public let timeline: TimelineConfig

    /// 拓扑执行顺序（先依赖后依赖者）
    private let order: [UUID]
    /// 每个节点输出端口值：nodeID → [portName: NodeValue]
    private var portValues: [UUID: [String: NodeValue]] = [:]
    /// branch 节点结果：nodeID → predicate 求值结果（true/false 下游据此激活）
    private var branchResults: [UUID: Bool] = [:]

    /// - Returns: 图有环/悬挂边时返回 nil
    public init?(timeline: TimelineConfig) {
        guard case .valid(let order) = TimelineGraphValidator.topologicalOrder(of: timeline) else {
            return nil
        }
        self.timeline = timeline
        self.order = order
    }

    /// 执行一次 evaluate（一帧/一次触发事件）
    public func evaluate(frame: FrameContext, state: inout StateStore, effects: TimelineEffects) {
        portValues.removeAll(keepingCapacity: true)
        branchResults.removeAll(keepingCapacity: true)
        let nodesByID = Dictionary(uniqueKeysWithValues: timeline.nodes.map { ($0.id, $0) })

        for nodeID in order {
            guard let node = nodesByID[nodeID] else { continue }
            let incoming = timeline.incomingEdges(to: nodeID)

            // 分支激活检查：若入边来自 branch 的 true/false 端口，结果必须匹配
            var activated = true
            for edge in incoming {
                if edge.from.portName == "true" || edge.from.portName == "false" {
                    if branchResults[edge.from.nodeID] != (edge.from.portName == "true") {
                        activated = false
                        break
                    }
                }
            }
            guard activated else { continue }

            // 收集输入（按 to.portName 分类；多个入边同端口取第一个）
            var inputs: [String: NodeValue] = [:]
            for edge in incoming {
                if inputs[edge.to.portName] == nil,
                   let v = portValues[edge.from.nodeID]?[edge.from.portName] {
                    inputs[edge.to.portName] = v
                }
            }

            // 有入边但未收到任何上游数据 → 链路断开，跳过（如 quantize 无输出时下游全部冻结）
            if !incoming.isEmpty && inputs.isEmpty { continue }

            let result = NodeExecutors.execute(node: node, inputs: inputs,
                                               frame: frame, state: &state, effects: effects)
            if let branchResult = result.branchResult {
                branchResults[node.id] = branchResult
            }
            if let outputs = result.outputs, !outputs.isEmpty {
                portValues[node.id] = outputs
            }
        }
    }

    /// 清空执行期状态（跨帧的 transform.last/debounce 等保留在 stateStore，不在本类）
    public func reset() {
        portValues.removeAll(keepingCapacity: true)
        branchResults.removeAll(keepingCapacity: true)
    }
}
