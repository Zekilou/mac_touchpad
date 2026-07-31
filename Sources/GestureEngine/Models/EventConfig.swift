import Foundation

/// 行为目标：控制什么系统功能
/// @ai: do not remove existing cases
public enum ActionType: String, Codable, CaseIterable {
    case volume
    case brightness

    /// 中文 + 英文展示名（描述模拟的是什么系统按键/功能）
    public var displayName: String {
        switch self {
        case .volume:
            return L10n.tr("系统音量键（F10/F11/F12）", "System Volume Keys (F10/F11/F12)")
        case .brightness:
            return L10n.tr("系统亮度键（F1/F2）", "System Brightness Keys (F1/F2)")
        }
    }

    /// 简短名（用于 Tab / Picker 紧凑位置）
    public var shortName: String {
        switch self {
        case .volume: return L10n.tr("音量", "Volume")
        case .brightness: return L10n.tr("亮度", "Brightness")
        }
    }
}

/// 执行方式：用什么手段改变系统值
public enum ExecutionMethod: String, Codable, CaseIterable {
    /// 模拟系统媒体键 — 系统自动调值 + 右上角 HUD 弹出 + 档位是系统固定的（约 16 档）
    case mediaKey
    /// 直接调用系统 API — 精确赋值到 step 级别，无 HUD，档位可任意细分
    case direct

    public var displayName: String {
        switch self {
        case .mediaKey:
            return L10n.tr("系统媒体键（带 HUD）", "Media Key (with HUD)")
        case .direct:
            return L10n.tr("直接 API（精确值）", "Direct API (Precise)")
        }
    }

    public var shortName: String {
        switch self {
        case .mediaKey: return L10n.tr("媒体键", "Media Key")
        case .direct: return L10n.tr("直接 API", "Direct")
        }
    }
}

/// 方向映射规则：手指滑动方向 ↔ 值增减方向
/// 注：等价于 `invertDirection ? upDecrease : upIncrease`，这里用枚举语义更清晰
public enum DirectionRule: String, Codable, CaseIterable {
    /// 上滑（norm_y 减小）= 值增加，下滑=值减少（默认）
    case upIncrease
    /// 上滑=值减少，下滑=值增加（取反）
    case upDecrease

    public var displayName: String {
        switch self {
        case .upIncrease: return L10n.tr("上滑增加", "Swipe Up = Increase")
        case .upDecrease: return L10n.tr("上滑减少", "Swipe Up = Decrease")
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
    /// mediaKey 模式下建议为 1/16 ≈ 0.0625（与系统档位对齐），direct 模式下可任意细
    public var step: Float
    /// 边界判定阈值（0~1），当前值 <= 该阈值视为已到最小，>= (1-该阈值) 视为已到最大
    public var boundaryThreshold: Float
    /// 方向映射规则：上滑加 or 上滑减
    public var directionRule: DirectionRule
    /// 执行方式：媒体键（HUD）or 直接 API（精确值）
    public var executionMethod: ExecutionMethod

    /// Codable 兼容：旧 JSON 缺 directionRule / executionMethod 时填默认值
    enum CodingKeys: String, CodingKey {
        case id, name, actionType, step, boundaryThreshold
        case directionRule, executionMethod
    }

    public init(id: UUID = UUID(),
                name: String,
                actionType: ActionType,
                step: Float,
                boundaryThreshold: Float,
                directionRule: DirectionRule = .upIncrease,
                executionMethod: ExecutionMethod = .mediaKey) {
        self.id = id
        self.name = name
        self.actionType = actionType
        self.step = step
        self.boundaryThreshold = boundaryThreshold
        self.directionRule = directionRule
        self.executionMethod = executionMethod
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        actionType = try container.decode(ActionType.self, forKey: .actionType)
        step = try container.decode(Float.self, forKey: .step)
        boundaryThreshold = try container.decode(Float.self, forKey: .boundaryThreshold)
        // 新增字段缺省值：保持旧行为（默认媒体键 + 上滑增加）
        directionRule = try container.decodeIfPresent(DirectionRule.self, forKey: .directionRule) ?? .upIncrease
        executionMethod = try container.decodeIfPresent(ExecutionMethod.self, forKey: .executionMethod) ?? .mediaKey
    }

    // MARK: - 默认事件

    /// 默认音量事件：媒体键模式 + 上滑增加（对应原右手势）
    public static let defaultVolume = EventConfig(
        name: L10n.tr("音量", "Volume"),
        actionType: .volume,
        step: 0.0125,
        boundaryThreshold: 0.001,
        directionRule: .upIncrease,
        executionMethod: .mediaKey
    )

    /// 默认亮度事件：媒体键模式 + 上滑增加（对应原左手势）
    public static let defaultBrightness = EventConfig(
        name: L10n.tr("亮度", "Brightness"),
        actionType: .brightness,
        step: 0.0125,
        boundaryThreshold: 0.001,
        directionRule: .upIncrease,
        executionMethod: .mediaKey
    )

    // MARK: - 读值

    /// 读取当前系统值（0~1）
    public func currentValue() -> Float {
        switch actionType {
        case .volume: return SystemControl.getVolume()
        case .brightness: return SystemControl.getBrightness()
        }
    }

    // MARK: - 边界

    /// 判断是否在边界
    /// - Parameter direction: >0 = 增大方向, <0 = 减小方向（**已应用 directionRule 之后的方向**）
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

    // MARK: - 方向映射

    /// 把原始 dy（触控板 norm_y 变化）转成「值增减方向」
    /// dy > 0 表示手指下滑（norm_y 增大），dy < 0 表示上滑
    /// 返回 +1 = 值增加，-1 = 值减少
    public func mapSlidingDirection(dy: Float) -> Int {
        let rawUp = dy < 0  // 是否是「上滑」（按触控板物理方向）
        switch directionRule {
        case .upIncrease: return rawUp ? 1 : -1
        case .upDecrease: return rawUp ? -1 : 1
        }
    }

    // MARK: - 执行调节

    /// 执行系统值改变
    /// - Parameter direction: >0 = 增大, <0 = 减小（应用 directionRule 之后的方向）
    public func perform(direction: Int) {
        let sign: Float = direction > 0 ? 1.0 : -1
        switch (actionType, executionMethod) {
        case (.volume, .mediaKey):
            if direction > 0 { SystemControl.volumeUp() }
            else { SystemControl.volumeDown() }
        case (.volume, .direct):
            let current = SystemControl.getVolume()
            let target = max(0.0, min(1.0, current + sign * step))
            SystemControl.setVolume(target)
        case (.brightness, .mediaKey):
            if direction > 0 { SystemControl.brightnessUp() }
            else { SystemControl.brightnessDown() }
        case (.brightness, .direct):
            let current = SystemControl.getBrightness()
            let target = max(0.0, min(1.0, current + sign * step))
            SystemControl.setBrightness(target)
        }
    }

    /// 发送朝边界外的媒体键（用于进入 holding 时唤起 HUD，值不变）
    /// direct 模式下退化：如果在边界，也发一次媒体键（只用于 HUD，不指望它调值），因为 direct API 本身没有 HUD
    public func postBoundaryKey() {
        let value = currentValue()
        if value >= 1.0 - boundaryThreshold {
            // 在上边界，发送「增大」的媒体键，值保持不变，仅为唤起 HUD
            boundaryMediaKeyUp()
        } else if value <= boundaryThreshold {
            boundaryMediaKeyDown()
        }
    }

    /// 边界时发「增大」媒体键（HUD 唤起专用，不管执行方式）
    private func boundaryMediaKeyUp() {
        switch actionType {
        case .volume: SystemControl.volumeUp()
        case .brightness: SystemControl.brightnessUp()
        }
    }

    /// 边界时发「减小」媒体键（HUD 唤起专用，不管执行方式）
    private func boundaryMediaKeyDown() {
        switch actionType {
        case .volume: SystemControl.volumeDown()
        case .brightness: SystemControl.brightnessDown()
        }
    }
}
