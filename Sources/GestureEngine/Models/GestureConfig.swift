import Foundation

/// 手势 = 一张完全自由的节点图（v5 完全配置化）
///
/// 不存在「四个阶段」——整张图就是一个可自由连线的节点画布：
///   - Trigger 节点（params.trigger）：执行入口，引擎在该时机执行其下游链
///     （onFirstTap / onEnterHolding / onTick / onExitHolding ...）
///   - 逻辑节点：信号/变换/量化/分支/副作用等，任意连线到任意 Trigger 下游
///   - Group 节点：批注组框，纯视觉分组，不参与执行
///   - RegionRef / EventRef：手势绑定的区域/事件（也是图节点）
/// 旧 v3 配置（4 条独立 timeline）解码时自动合并为单图（每个阶段补 Trigger 入口）。
public struct GestureConfig: Codable, Identifiable, Equatable, Hashable {
    // MARK: - 稳定 ID（不随版本变）

    public let id: UUID
    /// 手势名 = 图的名字（UI 顶部 tab 显示）
    public var name: String

    /// 旧 v3 顶层绑定（v4 迁移后置 nil；仅作解码回退，权威在图节点）
    public var regionID: UUID?
    public var eventID: UUID?

    /// 单张节点图（v5；旧文件里的 timelines 数组解码时合并进来）
    public var timeline: TimelineConfig

    // MARK: - Init

    public init(id: UUID = UUID(),
                name: String,
                regionID: UUID,
                eventID: UUID,
                timeline: TimelineConfig) {
        self.id = id
        self.name = name
        self.regionID = regionID
        self.eventID = eventID
        self.timeline = timeline
    }

    /// 便捷：用默认管线 + 指定事件/区域生成单图（含 Trigger 入口 + 绑定 ref 节点）
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
        self.timeline = TimelineMigrator.migrate(pipeline: pipeline, event: event,
                                                 regionID: regionID, eventID: eventID)
    }

    // MARK: - Codable（v3 timelines 数组 → 单图合并）

    private enum CodingKeys: String, CodingKey { case id, name, regionID, eventID, timeline, timelines }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        regionID = try c.decodeIfPresent(UUID.self, forKey: .regionID)
        eventID = try c.decodeIfPresent(UUID.self, forKey: .eventID)
        if let tl = try c.decodeIfPresent(TimelineConfig.self, forKey: .timeline) {
            timeline = tl
        } else if let tls = try c.decodeIfPresent([TimelineConfig].self, forKey: .timelines) {
            timeline = Self.mergeTimelines(tls)
        } else {
            timeline = TimelineConfig(trigger: .onFirstTap)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(regionID, forKey: .regionID)
        try c.encodeIfPresent(eventID, forKey: .eventID)
        try c.encode(timeline, forKey: .timeline)
    }

    /// v3 多 timeline → 单图：每阶段生成 Trigger 入口节点，阶段垂直堆叠，入口连到 Trigger。
    static func mergeTimelines(_ timelines: [TimelineConfig]) -> TimelineConfig {
        var nodes: [NodeConfig] = []
        var edges: [Edge] = []
        var entries: [UUID] = []
        let yOffsets: [TriggerEvent: Double] = [
            .onFirstTap: 0, .onEnterHolding: 400, .onSecondTap: 400,
            .onTick: 800, .onBoundaryHit: 800, .onExitHolding: 1200,
        ]
        for tl in timelines {
            let dy = yOffsets[tl.trigger] ?? 0
            // Trigger 入口节点
            let trigger = NodeConfig(type: .trigger,
                                     params: NodeParams(trigger: tl.trigger),
                                     x: -240, y: dy + 20,
                                     title: tl.trigger.displayName)
            nodes.append(trigger)
            entries.append(trigger.id)
            // 阶段节点垂直堆叠
            for node in tl.nodes {
                var n = node
                n.y += dy
                nodes.append(n)
            }
            edges.append(contentsOf: tl.edges)
            // 入口节点连到 Trigger
            for entryID in tl.entryNodeIDs where tl.nodes.contains(where: { $0.id == entryID }) {
                edges.append(Edge(from: PortID(nodeID: trigger.id, portName: "output"),
                                  to: PortID(nodeID: entryID, portName: "input")))
            }
        }
        return TimelineConfig(trigger: .onFirstTap, nodes: nodes, edges: edges, entryNodeIDs: entries)
    }

    // MARK: - 绑定（图节点权威，存储字段回退）

    private func refNode(of type: NodeType) -> NodeConfig? {
        timeline.nodes.first { $0.type == type }
    }

    /// 绑定的区域（图 RegionRef 优先，旧 v3 顶层字段回退）
    public var boundRegionID: UUID? {
        refNode(of: .region)?.params.regionID ?? regionID
    }

    /// 绑定的事件（图 EventRef 优先，旧 v3 顶层字段回退）
    public var boundEventID: UUID? {
        refNode(of: .event)?.params.eventID ?? eventID
    }

    /// 旧 v3 文件迁移：把顶层 regionID/eventID 补入图的 ref 节点（缺失时），并清空顶层字段。
    /// 之后图是唯一事实来源，保存的 JSON 不再含顶层绑定。
    public mutating func ensureBindingsInGraph() {
        var tl = timeline
        var didChange = false
        if let regionID, tl.firstNode(of: .region) == nil {
            tl.nodes.append(NodeConfig(type: .region, params: NodeParams(regionID: regionID),
                                       x: 0, y: 0, title: "触发区域"))
            didChange = true
        }
        if let eventID, tl.firstNode(of: .event) == nil {
            tl.nodes.append(NodeConfig(type: .event, params: NodeParams(eventID: eventID),
                                       x: 200, y: 0, title: "绑定事件"))
            didChange = true
        }
        if didChange {
            timeline = tl
            regionID = nil
            eventID = nil
        }
    }

    // MARK: - 识别参数（从图的 RecognizeNode 提取）

    public var recognizeParams: NodeParams? {
        timeline.firstNode(of: .recognize)?.params
    }

    /// 第一次轻点最大持续时间（秒）
    public var tapMaxDuration: Double { recognizeParams?.tapMaxDuration ?? 0.20 }
    /// 第一次轻点最大位移容差
    public var tapMaxDrift: Float { recognizeParams?.tapMaxDrift ?? 0.05 }
    /// 两次轻点最大间隔（秒）
    public var tapMaxGap: Double { recognizeParams?.tapMaxGap ?? 0.30 }
    /// 第二次轻点最小保持时长（秒）
    public var holdMinDuration: Double { recognizeParams?.holdMinDuration ?? 0.20 }

    // MARK: - 信号源/步长（引擎从单图读取）

    /// onTick 链的信号源（图中唯一 signal 节点）
    public var tickSignalSource: SignalSource {
        timeline.firstNode(of: .signal)?.params.source ?? .normY
    }

    /// onTick 链的量化步长（图中唯一 quantize 节点）
    public var tickStepNorm: Float {
        timeline.firstNode(of: .quantize)?.params.stepNorm ?? 0.02
    }

    /// 图中全部 haptic 节点的（标题, 参数）—— 波形用途标注用
    public var hapticNodes: [(label: String, params: NodeParams)] {
        timeline.nodes
            .filter { $0.type == .haptic }
            .map { ($0.title ?? $0.type.displayName, $0.params) }
    }
}
