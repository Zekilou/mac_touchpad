import Foundation

/// 顶层配置聚合（v3 格式：手势 = 绑定 + Timeline 图集）
/// @ai: do not change field names (Codable 合同)
public struct AppConfig: Codable, Equatable {
    public var version: Int
    public var global: GlobalSettings
    public var regions: [RegionConfig]
    public var gestures: [GestureConfig]
    public var events: [EventConfig]
    /// 用户自定义波形库（haptic 节点通过 customWaveformID 引用）
    /// @ai 新增于自定义波形功能；旧配置无此键 → 解码回退空数组
    public var customWaveforms: [CustomWaveform]

    public init() {
        self.version = 3
        self.global = .default
        let left = RegionConfig.defaultLeft
        let right = RegionConfig.defaultRight
        let top = RegionConfig.defaultTop
        let bottom = RegionConfig.defaultBottom
        let volume = EventConfig.defaultVolume
        let brightness = EventConfig.defaultBrightness
        let seek = EventConfig.defaultSeek
        self.regions = [left, right, top, bottom]
        self.events = [volume, brightness, seek]
        self.customWaveforms = []
        // 上下边缘为横向滑动（normX）→ 控制焦点 app 媒体进度
        let horizontal = LegacyPipelineConfig(signalSource: .normX)
        self.gestures = [
            GestureConfig(name: "左侧", regionID: left.id, eventID: brightness.id,
                          pipeline: LegacyPipelineConfig(), event: brightness),
            GestureConfig(name: "右侧", regionID: right.id, eventID: volume.id,
                          pipeline: LegacyPipelineConfig(), event: volume),
            GestureConfig(name: "上边缘", regionID: top.id, eventID: seek.id,
                          pipeline: horizontal, event: seek),
            // 下边缘：默认配置但不启用（预留）
            GestureConfig(name: "下边缘", regionID: bottom.id, eventID: seek.id,
                          pipeline: horizontal, event: seek, enabled: false),
        ]
    }

    public init(version: Int, global: GlobalSettings, regions: [RegionConfig], gestures: [GestureConfig], events: [EventConfig]) {
        self.version = version
        self.global = global
        self.regions = regions
        self.gestures = gestures
        self.events = events
        self.customWaveforms = []
    }

    // MARK: - Codable（customWaveforms 为后加字段，需向后兼容）

    private enum CodingKeys: String, CodingKey {
        case version, global, regions, gestures, events, customWaveforms
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        global = try c.decode(GlobalSettings.self, forKey: .global)
        regions = try c.decode([RegionConfig].self, forKey: .regions)
        gestures = try c.decode([GestureConfig].self, forKey: .gestures)
        events = try c.decode([EventConfig].self, forKey: .events)
        // 旧配置无此键 → 空库（不视为损坏）
        customWaveforms = try c.decodeIfPresent([CustomWaveform].self, forKey: .customWaveforms) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(global, forKey: .global)
        try c.encode(regions, forKey: .regions)
        try c.encode(gestures, forKey: .gestures)
        try c.encode(events, forKey: .events)
        try c.encode(customWaveforms, forKey: .customWaveforms)
    }

    // MARK: - 波形库查询

    /// 按 ID 查自定义波形
    public func customWaveform(id: UUID?) -> CustomWaveform? {
        guard let id else { return nil }
        return customWaveforms.first { $0.id == id }
    }

    /// 删除波形并解绑所有引用它的 haptic 节点（回退为预设波形）
    /// - Returns: 被解绑的手势数量（供 UI 提示）
    @discardableResult
    public mutating func deleteCustomWaveform(id: UUID) -> Int {
        customWaveforms.removeAll { $0.id == id }
        var affected = 0
        for i in gestures.indices {
            let count = gestures[i].unbindCustomWaveform(id: id)
            if count > 0 { affected += 1 }
        }
        return affected
    }
}
