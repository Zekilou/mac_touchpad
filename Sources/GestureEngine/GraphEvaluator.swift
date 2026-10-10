import Foundation

/// module 子图 evaluator 缓存：module 节点每帧执行都会执行其子图，
/// 若每次新建 GraphEvaluator 会重复做拓扑校验 + NodeConfig 深拷贝（120Hz 下的主要 CPU 热点）。
/// 生命周期跟随宿主 GraphEvaluator：根 evaluator 重建时缓存一并失效。
public final class ModuleEvaluatorCache {
    /// 缓存项：evaluator + 其对应的子图快照
    private struct Entry {
        var evaluator: GraphEvaluator
        /// 构建该 evaluator 时的子图。用于检测"子图被编辑"——见下方 evaluator(forNodeID:subgraph:)
        var subgraph: TimelineConfig
    }
    private var entries: [UUID: Entry] = [:]

    public init() {}

    /// 取某 module 节点的子图 evaluator（子图未变则复用缓存）；子图非法返回 nil。
    ///
    /// **必须比对子图内容**：默认手势图里「进入震动 / 刻度震动」等 haptic 节点就在模块子图内，
    /// 用户在 UI 改 count / 波形 / 阈值后，若仅按 nodeID 命中缓存就会继续执行旧子图 ——
    /// 表现为"参数改了不生效"（用户反馈 count 改不动）。故缓存同时保存子图快照，
    /// 用精确相等判断；不同则重建。
    func evaluator(forNodeID id: UUID, subgraph: TimelineConfig) -> GraphEvaluator? {
        if let cached = entries[id], cached.subgraph == subgraph {
            return cached.evaluator
        }
        guard let created = GraphEvaluator(timeline: subgraph) else { return nil }
        entries[id] = Entry(evaluator: created, subgraph: subgraph)
        return created
    }
}

/// 单张节点图的执行器（v6 数据流语义）
/// - 构造时做拓扑排序验证（环/悬挂边 → init 失败）
/// - evaluate 按拓扑序执行：从给定入口（Trigger 节点）出发的可达子图
/// - 纯数据流：节点从上游输出端口读 SocketValue（含 valid），算输出；无"激活/跳过"机制
/// - 副作用经 TimelineEffects 派发
public final class GraphEvaluator {
    public let timeline: TimelineConfig

    /// 拓扑执行顺序（先依赖后依赖者）
    private let order: [UUID]
    /// 预计算入边索引：nodeID → 该节点的入边（保持 timeline.edges 原顺序）
    /// timeline 在 evaluator 生命周期内不可变 → 避免每帧 O(E) filter + Edge 深拷贝（120Hz 热点）
    private let incomingByNode: [UUID: [Edge]]
    /// 预计算出边索引：nodeID → 该节点的出边
    private let outgoingByNode: [UUID: [Edge]]
    /// 预计算节点表：nodeID → 节点（避免每帧重建字典）
    private let nodesByID: [UUID: NodeConfig]
    /// 每个节点输出端口值：nodeID → [portName: SocketValue]（invalid 也保留，显式传播）
    private var portValues: [UUID: [String: SocketValue]] = [:]
    /// 每个节点本帧收到的输入端口值（module 收集 moduleOutput 连接器输入用）
    private var nodeInputs: [UUID: [String: SocketValue]] = [:]
    /// module 子图 evaluator 缓存（避免每帧重建子图执行器——120Hz 主要热点）
    private let moduleCache = ModuleEvaluatorCache()

    /// - Returns: 图有环/悬挂边时返回 nil
    /// - Note: 忽略帧尾写边（varRef 写请求）做拓扑排序——状态机展开图的"读→转移→写"跨帧环不参与静态排序
    public init?(timeline: TimelineConfig) {
        guard case .valid(let order) = TimelineGraphValidator.topologicalOrder(of: timeline,
                                                                               ignoreWriteEdges: true) else {
            return nil
        }
        self.timeline = timeline
        self.order = order
        var incoming: [UUID: [Edge]] = [:]
        var outgoing: [UUID: [Edge]] = [:]
        for edge in timeline.edges {
            incoming[edge.to.nodeID, default: []].append(edge)
            outgoing[edge.from.nodeID, default: []].append(edge)
        }
        self.incomingByNode = incoming
        self.outgoingByNode = outgoing
        // 用 uniquingKeysWith 而非 uniqueKeysWithValues：后者遇重复 id 会 Fatal error。
        // TimelineConfig.sanitized() 已在解码处去重，此处是纵深防御。
        self.nodesByID = Dictionary(timeline.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// 执行一次 evaluate（一帧/一次触发事件）
    /// - Parameter entryIDs: 本次执行入口（Trigger 节点）。nil = 执行整张图（dry-run）。
    /// - Parameter injected: 预置端口值（module 子图执行：moduleInput 连接器输出 = 组输入端口值）
    /// - Parameter deferFlush: true = 不把写请求 flush 到 state，改为返回值返回（module 子图用——
    ///   子图写请求需延迟到主图帧尾统一 flush，否则主图后续节点本帧读到新状态）
    /// - Returns: 本帧收集的写请求（deferFlush=false 时已 flush，返回值可忽略）
    /// 两遍执行（摩尔状态机语义）：
    ///   第一遍：按拓扑序执行全部节点——varRef 读 state 旧值（写输入在本帧尚未产生），分支链算转移条件
    ///   第二遍：收集 varRef/set/toggle 的写请求（trigger 来自第一遍分支输出）→ 帧尾 flush
    /// 这样"判断用旧状态、写入下帧生效"，静态图上无环
    @discardableResult
    public func evaluate(frame: FrameContext, state: inout StateStore, effects: TimelineEffects,
                         entryIDs: [UUID]? = nil,
                         injected: [UUID: [String: SocketValue]]? = nil,
                         deferFlush: Bool = false) -> [String: NodeValue] {
        portValues.removeAll(keepingCapacity: true)
        nodeInputs.removeAll(keepingCapacity: true)
        var pendingWrites: [String: NodeValue] = [:]

        // 注入端口值（moduleInput 连接器输出，先于拓扑执行，供内部节点读取）
        if let injected {
            for (id, ports) in injected {
                for (name, v) in ports { portValues[id, default: [:]][name] = v }
            }
        }

        // 入口可达集：只执行从 Trigger 出发可达的链，不同 Trigger 互不干扰
        let reachable: Set<UUID>
        if let entryIDs {
            reachable = reachableSet(from: entryIDs)
        } else {
            reachable = Set(order)
        }

        // 第一遍：拓扑序执行（varRef 写输入此刻为空 → 读旧值；分支产生转移脉冲）
        for nodeID in order where reachable.contains(nodeID) {
            guard let node = nodesByID[nodeID] else { continue }
            let inputs = collectInputs(of: nodeID, nodesByID: nodesByID)
            nodeInputs[nodeID] = inputs
            // 数据流执行：节点内部处理必需输入 invalid → 输出全 invalid（显式传播）
            let result = NodeExecutors.execute(node: node, inputs: inputs,
                                               frame: frame, state: &state, effects: effects,
                                               moduleCache: moduleCache)
            if let outputs = result.outputs, !outputs.isEmpty {
                portValues[nodeID] = outputs
            }
            // 收集 module 子图写请求（延迟到帧尾统一 flush；varRef 的写请求除外——
            // 它在第二遍做严格同源配对，第一遍收集会绕过防错配）
            if node.type == .module {
                for (k, v) in result.writes { pendingWrites[k] = v }
            }
        }

        // 第二遍：写节点收集写请求（trigger/value 输入来自第一遍分支输出；帧尾统一生效）
        for nodeID in order where reachable.contains(nodeID) {
            guard let node = nodesByID[nodeID] else { continue }
            let inputs = collectInputs(of: nodeID, nodesByID: nodesByID)
            switch node.type {
            case .varRef:
                // 多写源：任一 trigger 入边有效即写；value 优先取同源入边（转移链 out1 同时连 trigger+value），
                // 无同源时退化任一有效 value（附带变量：值节点恒有效、trigger 来自转移脉冲）
                let key = node.params.key ?? "var"
                if let triggerEdge = firstValidTrigger(of: nodeID),
                   let value = matchingWriteValue(of: nodeID, trigger: triggerEdge) {
                    pendingWrites[key] = value
                }
            case .set:
                if inputs["trigger"]?.valid == true, let v = inputs["value"], v.valid {
                    pendingWrites[node.params.key ?? "var"] = v.value
                }
            case .toggle:
                if inputs["trigger"]?.valid == true {
                    let key = node.params.key ?? "var"
                    let cur = state[key]?.boolValue ?? false
                    pendingWrites[key] = .bool(!cur)
                }
            case .module:
                // 写类输入端口（ModulePort.isWrite）本帧有效 → 帧末延迟重跑模块：
                // 注入写类输入（read 输入由第一遍已执行），子图内产生写请求 → 也延迟到帧尾 flush
                if hasValidWriteInput(of: nodeID, node: node) {
                    let result = NodeExecutors.execute(node: node, inputs: inputs, frame: frame,
                                                       state: &state, effects: effects, writePass: true,
                                                       moduleCache: moduleCache)
                    for (k, v) in result.writes { pendingWrites[k] = v }
                }
            default: break
            }
        }

        // 帧尾 flush：var 写请求统一写入 state（摩尔状态机语义：转移条件用旧状态，新状态下一帧生效）
        // deferFlush（module 子图）：不写 state，写请求返回给调用方（主图）统一帧尾 flush
        if !deferFlush {
            for (key, value) in pendingWrites {
                state[key] = value
            }
        }
        return pendingWrites
    }

    /// 找 varRef 节点第一个有效的 trigger 入边（任一转移链脉冲）
    private func firstValidTrigger(of nodeID: UUID) -> Edge? {
        for edge in incomingByNode[nodeID] ?? [] where edge.to.portName == "trigger" {
            if portValues[edge.from.nodeID]?[edge.from.portName]?.valid == true {
                return edge
            }
        }
        return nil
    }

    /// 匹配写值：**严格要求 trigger 同源入边**（迁移器所有写源都是独立写链：out1 同时连 trigger+value）
    /// 无同源不写——避免多写源变量的 value 入边（如 trueConst/falseConst 恒有效）被错配
    private func matchingWriteValue(of nodeID: UUID, trigger: Edge) -> NodeValue? {
        for edge in incomingByNode[nodeID] ?? [] where edge.to.portName == "value" {
            if edge.from == trigger.from,
               let v = portValues[edge.from.nodeID]?[edge.from.portName], v.valid {
                return v.value
            }
        }
        return nil
    }

    /// 模块节点的写类输入端口（isWrite=true）本帧是否有有效值（决定是否 writePass 重跑）
    private func hasValidWriteInput(of nodeID: UUID, node: NodeConfig) -> Bool {
        guard node.type == .module else { return false }
        let writePorts = Set((node.params.moduleInputs ?? []).filter(\.isWrite).map(\.name))
        guard !writePorts.isEmpty else { return false }
        for edge in incomingByNode[nodeID] ?? [] where writePorts.contains(edge.to.portName) {
            if portValues[edge.from.nodeID]?[edge.from.portName]?.valid == true {
                return true
            }
        }
        return false
    }

    /// 收集某节点的所有入边输入值（从第一遍产出的 portValues 读取）
    /// 同端口多入边（如 moduleOutput 的 value 被 T4/T5 两条退出链共连）：**优先保留有效值**——
    /// 否则先执行的分支输出 invalid 堵住端口，后执行分支的有效值被忽略（exitPulse 丢失）
    private func collectInputs(of nodeID: UUID, nodesByID: [UUID: NodeConfig]) -> [String: SocketValue] {
        var inputs: [String: SocketValue] = [:]
        for edge in incomingByNode[nodeID] ?? [] {
            if let v = portValues[edge.from.nodeID]?[edge.from.portName] {
                if inputs[edge.to.portName] == nil || !inputs[edge.to.portName]!.valid {
                    inputs[edge.to.portName] = v
                }
            }
        }
        return inputs
    }

    /// 查询某节点某输入端口本帧收到的值（module 收集 moduleOutput 连接器输入用；未执行帧返回 nil）
    public func inputValue(of nodeID: UUID, port: String) -> SocketValue? {
        nodeInputs[nodeID]?[port]
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
            for edge in outgoingByNode[id] ?? [] {
                stack.append(edge.to.nodeID)
            }
        }
        return visited
    }
}
