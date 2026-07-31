import Foundation

/// 手势配置（Codable，持久化到 JSON 文件）
public struct GestureConfig: Codable, Equatable {
    // 1. 触摸数据流
    /// 帧处理限频（Hz），0 = 不限频处理每一帧。降低可减少 CPU 占用
    public var frameRateLimit: Double = 0
    /// 接触面积上限（mt_touch_t.size，手指~0.3-0.8，手掌>1.0）。超过此值的触摸被忽略，防止手掌误触发
    public var touchSizeMax: Float = 1.0
    /// 接触面积下限，低于此值视为悬停/误触忽略
    public var touchSizeMin: Float = 0.1

    // 2. 第一次轻点（idle → firstTapDown → firstTapUp）
    public var edgeRightThreshold: Float = 0.80
    public var edgeLeftThreshold: Float = 0.20
    public var tapMaxDuration: Double = 0.20
    public var tapMaxDrift: Float = 0.05

    // 3. 两次轻点衔接（firstTapUp → secondTapDown）
    public var tapMaxGap: Double = 0.30

    // 4. 第二次轻点保持（secondTapDown → holding）
    public var holdMinDuration: Double = 0.20
    public var hapticEnter: Int32 = 2   // 进入 holding 时的强 click

    // 5. 滑动调节（holding 状态）
    public var volumeStepNorm: Float = 0.02
    public var volumeStep: Float = 0.0125
    public var brightnessStepNorm: Float = 0.02
    public var brightnessStep: Float = 0.0125
    public var hapticTick: Int32 = 4    // 刻度震动（轻 tap）

    // 6. 边界检测
    /// 边界判定阈值（0~1），当前值 <= 该阈值视为已到最小，>= (1-该阈值) 视为已到最大
    public var boundaryThreshold: Float = 0.001
    /// 边界强震动波形 ID
    public var hapticBoundary: Int32 = 2
    /// 边界强震动两次触发间隔（微秒）
    public var boundaryHapticInterval: Int32 = 50000

    // 7. 鼠标控制
    /// 进入 holding 时是否解除鼠标关联（保持光标原地）
    public var disassociateMouse: Bool = true

    public init() {}

    /// 配置文件路径
    public static var configURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TouchpadGestures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    /// 用户自定义默认配置路径（"保存为默认"功能写入此处）
    /// 重置时优先从此处加载，若不存在则用代码默认值 GestureConfig()
    public static var userDefaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TouchpadGestures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("default.json")
    }

    public static func load() -> GestureConfig {
        guard let data = try? Data(contentsOf: configURL),
              let cfg = try? JSONDecoder().decode(GestureConfig.self, from: data) else {
            return GestureConfig()
        }
        return cfg
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.configURL, options: .atomic)
    }

    /// 把当前配置保存为用户默认（"保存为默认"按钮调用）
    public func saveAsDefault() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.userDefaultURL, options: .atomic)
    }

    /// 加载默认配置：优先用户自定义默认，其次代码默认值
    public static func loadDefault() -> GestureConfig {
        if let data = try? Data(contentsOf: userDefaultURL),
           let cfg = try? JSONDecoder().decode(GestureConfig.self, from: data) {
            return cfg
        }
        return GestureConfig()
    }

    /// 清除用户自定义默认，恢复到代码默认值
    public static func clearUserDefault() {
        try? FileManager.default.removeItem(at: userDefaultURL)
    }
}
