import Foundation

/// 手势 = Timeline 图集（v3+ 节点化，绑定也进图）
///
/// 全部行为参数都在 timelines 的节点图上（区域/事件引用、轻点识别、信号处理、触觉、鼠标）：
///   - onFirstTap：RegionRef + EventRef + RecognizeNode（绑定 + 轻点识别参数）
///   - onEnterHolding / onTick / onExitHolding：执行图
/// 旧配置（v1/v2/v3 顶层 regionID/eventID）在解码层自动迁移进图；regionID/eventID 存储字段
/// 仅作旧文件兼容回退（图节点优先）。
public struct GestureConfig: Codable, Identifiable, Equatable, Hashable {
    // MARK: - 稳定 ID（不随版本变）

    public let id: UUID
    public var name: String

    /// 旧 v3 顶层绑定（v4 迁移后置 nil；仅作解码回退，权威在图节点）
    public var regionID: UUID?
    public var eventID: UUID?

    /// 全部 Timeline 图（识别 1 条 + 执行 3 条）
    public var timelines: [TimelineConfig]

    public init(id: UUID = UUID(),
                name: String,
                regionID: UUID,
                eventID: UUID,
                timelines: [TimelineConfig]) {
        self.id = id
        self.name = name
        self.regionID = regionID
        self.eventID = eventID
        self.timelines = timelines
    }

    /// 便捷：用默认管线 + 指定事件/区域生成图集（含绑定 ref 节点）
    public init(id: UUID = UUID(),
                name: String,
                regionID: UUID,
                eventID: UUID,
                pipeline: LegacyPipelineConfig = LegacyPipelineConfig(),
                event: EventConfig = .defaultVolume) {
        self.id = id
        self.name = name
        self.regionID = regionID
        self.eventID = eventID
        self.timelines = TimelineMigrator.migrate(pipeline: pipeline, event: event,
                                                  regionID: regionID, eventID: eventID)
    }

    // MARK: - 绑定（图节点权威，存储字段回退）

    /// onFirstTap 图中的绑定引用节点
    private func refNode(of type: NodeType) -> NodeConfig? {
        timelines.first { $0.trigger == .onFirstTap }?.nodes.first { $0.type == type }
    }

    /// 绑定的区域（图 RegionRef 优先，旧 v3 顶层字段回退）
    public var boundRegionID: UUID? {
        refNode(of: .region)?.params.regionID ?? regionID
    }

    /// 绑定的事件（图 EventRef 优先，旧 v3 顶层字段回退）
    public var boundEventID: UUID? {
        refNode(of: .event)?.params.eventID ?? eventID
    }

    /// 旧 v3 文件迁移：把顶层 regionID/eventID 补入 onFirstTap 图的 ref 节点（缺失时），并清空顶层字段。
    /// 之后图是唯一事实来源，保存的 JSON 不再含顶层绑定。
    public mutating func ensureBindingsInGraph() {
        guard let idx = timelines.firstIndex(where: { $0.trigger == .onFirstTap }) else { return }
        var tl = timelines[idx]
        var didChange = false
        if let regionID, tl.firstNode(of: .region) == nil {
            let node = NodeConfig(type: .region, params: NodeParams(regionID: regionID),
                                  x: 0, y: 0, title: "触发区域")
            tl.nodes.append(node)
            tl.entryNodeIDs.append(node.id)
            didChange = true
        }
        if let eventID, tl.firstNode(of: .event) == nil {
            let node = NodeConfig(type: .event, params: NodeParams(eventID: eventID),
                                  x: 200, y: 0, title: "绑定事件")
            tl.nodes.append(node)
            tl.entryNodeIDs.append(node.id)
            didChange = true
        }
        if didChange {
            timelines[idx] = tl
            regionID = nil
            eventID = nil
        }
    }

    // MARK: - 识别参数（从 onFirstTap 图的 RecognizeNode 提取）

    public var recognizeParams: NodeParams? {
        timelines.first { $0.trigger == .onFirstTap }?
            .nodes.first { $0.type == .recognize }?.params
    }

    /// 第一次轻点最大持续时间（秒）
    public var tapMaxDuration: Double { recognizeParams?.tapMaxDuration ?? 0.20 }
    /// 第一次轻点最大位移容差
    public var tapMaxDrift: Float { recognizeParams?.tapMaxDrift ?? 0.05 }
    /// 两次轻点最大间隔（秒）
    public var tapMaxGap: Double { recognizeParams?.tapMaxGap ?? 0.30 }
    /// 第二次轻点最小保持时长（秒）
    public var holdMinDuration: Double { recognizeParams?.holdMinDuration ?? 0.20 }

    // MARK: - Timeline 访问

    /// 取某触发事件的时间线
    public func timeline(for trigger: TriggerEvent) -> TimelineConfig? {
        timelines.first { $0.trigger == trigger }
    }

    /// 图中全部 haptic 节点的（标题, 参数）—— 波形对照表用途标注用
    public var hapticNodes: [(label: String, params: NodeParams)] {
        var result: [(String, NodeParams)] = []
        for tl in timelines {
            for node in tl.nodes where node.type == .haptic {
                result.append((node.title ?? node.type.displayName, node.params))
            }
        }
        return result
    }
}
