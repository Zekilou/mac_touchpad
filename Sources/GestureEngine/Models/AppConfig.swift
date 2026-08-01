import Foundation

/// 顶层配置聚合（v3 格式：手势 = 绑定 + Timeline 图集）
/// @ai: do not change field names (Codable 合同)
public struct AppConfig: Codable, Equatable {
    public var version: Int
    public var global: GlobalSettings
    public var regions: [RegionConfig]
    public var gestures: [GestureConfig]
    public var events: [EventConfig]

    public init() {
        self.version = 3
        self.global = .default
        let left = RegionConfig.defaultLeft
        let right = RegionConfig.defaultRight
        let volume = EventConfig.defaultVolume
        let brightness = EventConfig.defaultBrightness
        self.regions = [left, right]
        self.events = [volume, brightness]
        self.gestures = [
            GestureConfig(name: "左侧", regionID: left.id, eventID: brightness.id,
                          pipeline: LegacyPipelineConfig(), event: brightness),
            GestureConfig(name: "右侧", regionID: right.id, eventID: volume.id,
                          pipeline: LegacyPipelineConfig(), event: volume),
        ]
    }

    public init(version: Int, global: GlobalSettings, regions: [RegionConfig], gestures: [GestureConfig], events: [EventConfig]) {
        self.version = version
        self.global = global
        self.regions = regions
        self.gestures = gestures
        self.events = events
    }
}
