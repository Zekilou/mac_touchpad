import Foundation

/// 手势 = 绑定（区域/事件）+ Timeline 图集（v3 节点化）
///
/// 全部行为参数（轻点识别/信号处理/触觉/鼠标）都在 timelines 的节点图上：
///   - onFirstTap：RecognizeNode（轻点识别参数）
///   - onEnterHolding / onTick / onExitHolding：执行图
/// 旧 v2 配置在 AppConfig 解码层自动迁移为图集。
public struct GestureConfig: Codable, Identifiable, Equatable, Hashable {
    // MARK: - 稳定 ID（不随版本变）

    public let id: UUID
    public var name: String
    public var regionID: UUID
    public var eventID: UUID

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

    /// 便捷：用默认管线 + 指定事件生成图集
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
        self.timelines = TimelineMigrator.migrate(pipeline: pipeline, event: event)
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
