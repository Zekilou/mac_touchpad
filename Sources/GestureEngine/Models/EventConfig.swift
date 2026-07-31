import Foundation

/// 事件动作类型（未来加新动作在此加 case）
/// @ai: do not remove existing cases
public enum ActionType: String, Codable, CaseIterable {
    case volume
    case brightness

    public var displayName: String {
        switch self {
        case .volume: return "音量"
        case .brightness: return "亮度"
        }
    }
}

/// 事件 = 数据处理 + 改变系统值 + 边界判断
/// 震动不归事件（归手势）
public struct EventConfig: Codable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public var name: String
    public var actionType: ActionType
    /// 每次变化量（原 volumeStep / brightnessStep）
    public var step: Float
    /// 边界判定阈值（0~1），当前值 <= 该阈值视为已到最小，>= (1-该阈值) 视为已到最大
    public var boundaryThreshold: Float

    public init(id: UUID = UUID(), name: String, actionType: ActionType, step: Float, boundaryThreshold: Float) {
        self.id = id
        self.name = name
        self.actionType = actionType
        self.step = step
        self.boundaryThreshold = boundaryThreshold
    }

    /// 默认音量事件
    public static let defaultVolume = EventConfig(
        name: "音量", actionType: .volume, step: 0.0125, boundaryThreshold: 0.001)

    /// 默认亮度事件
    public static let defaultBrightness = EventConfig(
        name: "亮度", actionType: .brightness, step: 0.0125, boundaryThreshold: 0.001)

    /// 读取当前系统值（0~1）
    public func currentValue() -> Float {
        switch actionType {
        case .volume: return SystemControl.getVolume()
        case .brightness: return SystemControl.getBrightness()
        }
    }

    /// 判断是否在边界
    /// - Parameter direction: >0 = 增大方向, <0 = 减小方向
    /// - Returns: true 表示朝该方向已到边界
    public func isAtBoundary(direction: Int) -> Bool {
        let value = currentValue()
        if direction < 0 && value <= boundaryThreshold { return true }
        if direction > 0 && value >= 1.0 - boundaryThreshold { return true }
        return false
    }

    /// 判断当前值是否在任一边界（用于进入 holding 时唤起 HUD）
    public func isAtAnyBoundary() -> Bool {
        let value = currentValue()
        return value <= boundaryThreshold || value >= 1.0 - boundaryThreshold
    }

    /// 执行系统值改变
    /// - Parameter direction: >0 = 增大, <0 = 减小
    public func perform(direction: Int) {
        switch actionType {
        case .volume:
            if direction > 0 { SystemControl.volumeUp() }
            else { SystemControl.volumeDown() }
        case .brightness:
            if direction > 0 { SystemControl.brightnessUp() }
            else { SystemControl.brightnessDown() }
        }
    }

    /// 发送朝边界外的媒体键（用于进入 holding 时唤起 HUD，值不变）
    public func postBoundaryKey() {
        let value = currentValue()
        if value >= 1.0 - boundaryThreshold {
            perform(direction: 1)
        } else if value <= boundaryThreshold {
            perform(direction: -1)
        }
    }
}
