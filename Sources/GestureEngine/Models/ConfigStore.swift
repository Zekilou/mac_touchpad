import Foundation

/// 配置持久化 + v1→v2 迁移
public enum ConfigStore {
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

    /// 加载配置（自动迁移 v1）
    public static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: configURL) else {
            return AppConfig()
        }
        // 先尝试 v2
        if let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return cfg
        }
        // v1 迁移
        if let v1 = try? JSONDecoder().decode(V1Config.self, from: data) {
            let migrated = migrate(v1: v1)
            try? JSONEncoder().encode(migrated).write(to: configURL, options: .atomic)
            return migrated
        }
        return AppConfig()
    }

    /// 保存配置
    public static func save(_ config: AppConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: configURL, options: .atomic)
    }

    /// v1 → v2 迁移
    static func migrate(v1: V1Config) -> AppConfig {
        let left = RegionConfig(name: "左边缘", xMin: 0, xMax: v1.edgeLeftThreshold, yMin: 0, yMax: 1)
        let right = RegionConfig(name: "右边缘", xMin: v1.edgeRightThreshold, xMax: 1, yMin: 0, yMax: 1)
        let volume = EventConfig(name: "音量", actionType: .volume, step: v1.volumeStep, boundaryThreshold: v1.boundaryThreshold)
        let brightness = EventConfig(name: "亮度", actionType: .brightness, step: v1.brightnessStep, boundaryThreshold: v1.boundaryThreshold)
        let global = GlobalSettings(frameRateLimit: v1.frameRateLimit, touchSizeMin: v1.touchSizeMin, touchSizeMax: v1.touchSizeMax)
        let leftGesture = GestureConfig(
            name: "左侧", regionID: left.id, eventID: brightness.id,
            tapMaxDuration: v1.tapMaxDuration, tapMaxDrift: v1.tapMaxDrift,
            tapMaxGap: v1.tapMaxGap, holdMinDuration: v1.holdMinDuration,
            slideStepNorm: v1.brightnessStepNorm,
            disassociateMouse: v1.disassociateMouse,
            hapticEnter: v1.hapticEnter, hapticTick: v1.hapticTick,
            hapticBoundary: v1.hapticBoundary, boundaryHapticInterval: v1.boundaryHapticInterval)
        let rightGesture = GestureConfig(
            name: "右侧", regionID: right.id, eventID: volume.id,
            tapMaxDuration: v1.tapMaxDuration, tapMaxDrift: v1.tapMaxDrift,
            tapMaxGap: v1.tapMaxGap, holdMinDuration: v1.holdMinDuration,
            slideStepNorm: v1.volumeStepNorm,
            disassociateMouse: v1.disassociateMouse,
            hapticEnter: v1.hapticEnter, hapticTick: v1.hapticTick,
            hapticBoundary: v1.hapticBoundary, boundaryHapticInterval: v1.boundaryHapticInterval)
        return AppConfig(version: 2, global: global, regions: [left, right], gestures: [leftGesture, rightGesture], events: [volume, brightness])
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
