import Foundation

/// 配置持久化 + v1/v2 → v3 迁移
public enum ConfigStore {

    /// v2 顶层配置（仅用于解码旧 JSON 并迁移）
    struct AppConfigV2: Codable {
        var version: Int
        var global: GlobalSettings
        var regions: [RegionConfig]
        var gestures: [GestureConfigV2]
        var events: [EventConfig]
    }

    /// 用户当前配置
    public static var configURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TouchpadGestures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    /// 用户自定义默认配置
    public static var userDefaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TouchpadGestures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("default.json")
    }

    // MARK: - v1 旧格式（扁平 GestureConfig）
    /// v1 扁平配置结构，仅用于迁移解码
    struct V1Config: Codable {
        var frameRateLimit: Double = 0
        var touchSizeMax: Float = 1.0
        var touchSizeMin: Float = 0.1
        var edgeRightThreshold: Float = 0.80
        var edgeLeftThreshold: Float = 0.20
        var tapMaxDuration: Double = 0.20
        var tapMaxDrift: Float = 0.05
        var tapMaxGap: Double = 0.30
        var holdMinDuration: Double = 0.20
        var hapticEnter: Int32 = 2
        var volumeStepNorm: Float = 0.02
        var volumeStep: Float = 0.0125
        var brightnessStepNorm: Float = 0.02
        var brightnessStep: Float = 0.0125
        var hapticTick: Int32 = 4
        var boundaryThreshold: Float = 0.001
        var hapticBoundary: Int32 = 2
        var boundaryHapticInterval: Int32 = 50000
        var disassociateMouse: Bool = true
    }

    /// 加载配置（自动迁移 v1 / v2 → v3）
    public static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: configURL) else {
            return AppConfig()
        }
        // 先尝试 v3（当前格式）；旧 v3 文件顶层绑定补入图并保存（图成为唯一事实来源）
        if var cfg = try? JSONDecoder().decode(AppConfig.self, from: data) {
            var didChange = false
            for i in cfg.gestures.indices {
                var gesture = cfg.gestures[i]
                gesture.ensureBindingsInGraph()
                if gesture != cfg.gestures[i] {
                    cfg.gestures[i] = gesture
                    didChange = true
                }
            }
            if didChange { save(cfg) }
            return cfg
        }
        // v2 迁移
        if let v2 = try? JSONDecoder().decode(AppConfigV2.self, from: data) {
            let migrated = migrate(v2: v2)
            save(migrated)
            return migrated
        }
        // v1 迁移
        if let v1 = try? JSONDecoder().decode(V1Config.self, from: data) {
            let migrated = migrate(v1: v1)
            save(migrated)
            return migrated
        }
        return AppConfig()
    }

    /// 保存配置
    public static func save(_ config: AppConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: configURL, options: .atomic)
    }

    // MARK: - 迁移

    /// v2 → v3：每个 v2 手势用迁移器生成 Timeline 图集
    static func migrate(v2: AppConfigV2) -> AppConfig {
        let gestures = v2.gestures.map { g2 -> GestureConfig in
            let event = v2.events.first { $0.id == g2.eventID } ?? EventConfig.defaultVolume
            let pipeline = LegacyPipelineConfig(
                signalSource: g2.signalSource,
                transformMode: g2.transformMode,
                triggerMode: g2.triggerMode,
                stepNorm: g2.stepNorm,
                sensitivity: g2.sensitivity,
                hapticEnter: g2.hapticEnter,
                hapticTick: g2.hapticTick,
                hapticBoundary: g2.hapticBoundary,
                hapticExit: g2.hapticExit,
                disassociateMouse: g2.disassociateMouse,
                tapMaxDuration: g2.tapMaxDuration,
                tapMaxDrift: g2.tapMaxDrift,
                tapMaxGap: g2.tapMaxGap,
                holdMinDuration: g2.holdMinDuration)
            return GestureConfig(id: g2.id, name: g2.name,
                                 regionID: g2.regionID, eventID: g2.eventID,
                                 timeline: TimelineMigrator.migrate(pipeline: pipeline, event: event,
                                                                    regionID: g2.regionID, eventID: g2.eventID))
        }
        return AppConfig(version: 3, global: v2.global, regions: v2.regions,
                         gestures: gestures, events: v2.events)
    }

    /// v1 → v3（经过 v2 语义中间层，一步生成图集）
    static func migrate(v1: V1Config) -> AppConfig {
        let left = RegionConfig(name: "左边缘", xMin: 0, xMax: v1.edgeLeftThreshold, yMin: 0, yMax: 1)
        let right = RegionConfig(name: "右边缘", xMin: v1.edgeRightThreshold, xMax: 1, yMin: 0, yMax: 1)
        let volume = EventConfig(name: "音量", actionType: .volume, step: v1.volumeStep, boundaryThreshold: v1.boundaryThreshold)
        let brightness = EventConfig(name: "亮度", actionType: .brightness, step: v1.brightnessStep, boundaryThreshold: v1.boundaryThreshold)
        let global = GlobalSettings(frameRateLimit: v1.frameRateLimit, touchSizeMin: v1.touchSizeMin, touchSizeMax: v1.touchSizeMax)

        let basePipeline = LegacyPipelineConfig(
            hapticEnter: HapticEvent(enabled: true, waveform: v1.hapticEnter, count: 1, intervalUs: 0),
            hapticTick: HapticEvent(enabled: true, waveform: v1.hapticTick, count: 1, intervalUs: 0),
            hapticBoundary: HapticEvent(enabled: true, waveform: v1.hapticBoundary, count: 2, intervalUs: v1.boundaryHapticInterval),
            hapticExit: .exit,
            disassociateMouse: v1.disassociateMouse,
            tapMaxDuration: v1.tapMaxDuration, tapMaxDrift: v1.tapMaxDrift,
            tapMaxGap: v1.tapMaxGap, holdMinDuration: v1.holdMinDuration)

        var leftPipeline = basePipeline
        leftPipeline.stepNorm = v1.brightnessStepNorm
        leftPipeline.signalSource = .normY
        var rightPipeline = basePipeline
        rightPipeline.stepNorm = v1.volumeStepNorm

        let leftGesture = GestureConfig(name: "左侧", regionID: left.id, eventID: brightness.id,
                                        timeline: TimelineMigrator.migrate(pipeline: leftPipeline, event: brightness,
                                                                           regionID: left.id, eventID: brightness.id))
        let rightGesture = GestureConfig(name: "右侧", regionID: right.id, eventID: volume.id,
                                         timeline: TimelineMigrator.migrate(pipeline: rightPipeline, event: volume,
                                                                            regionID: right.id, eventID: volume.id))
        return AppConfig(version: 3, global: global, regions: [left, right],
                         gestures: [leftGesture, rightGesture], events: [volume, brightness])
    }

    // MARK: - 用户默认配置
    public static func saveAsDefault(_ config: AppConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: userDefaultURL, options: .atomic)
    }

    public static func loadDefault() -> AppConfig {
        if let data = try? Data(contentsOf: userDefaultURL),
           let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return cfg
        }
        return AppConfig()
    }

    public static func clearUserDefault() {
        try? FileManager.default.removeItem(at: userDefaultURL)
    }
}
