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

/// 方向映射规则：信号变化方向 ↔ 目标值增减方向
/// v2 语义升级：信号源无关（不再绑定 normY 的"上/下"物理方向）
///   positiveIncrease → 信号增大 = 目标值增加
///   positiveDecrease → 信号增大 = 目标值减少
/// 对于历史 normY：信号增大 = 下滑，所以 positiveIncrease 等价于旧的 upIncrease（上滑=normY 减小=目标减小... 等一下，旧 upIncrease 是上滑（normY 减小）= 值增加 → 意味着"信号减小=值增加"，映射到新语义就是 positiveDecrease）
/// 为了和旧配置行为完全一致，旧 DirectionRule 值保留但 decode 时重映射：
///   旧 upIncrease → 新 positiveDecrease（normY↓ → value↑）
///   旧 upDecrease → 新 positiveIncrease（normY↓ → value↓）
public enum DirectionRule: String, Codable, CaseIterable {
    /// 信号增大 → 值增加（默认，适合 normX/面积/压力等信号源）
    case positiveIncrease
    /// 信号增大 → 值减少（对于 normY：等价于旧「上滑增加」）
    case positiveDecrease

    // --- 兼容用：保留旧字符串常量，decode 时自动转换 ---
    private static let legacyUpIncrease = "upIncrease"
    private static let legacyUpDecrease = "upDecrease"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case Self.legacyUpIncrease:
            // 旧 upIncrease = 上滑(normY减小) = 值增加 → 信号减小=增加 → positiveDecrease
            self = .positiveDecrease
        case Self.legacyUpDecrease:
            // 旧 upDecrease = 上滑(normY减小) = 值减少 → 信号减小=减少 → positiveIncrease
            self = .positiveIncrease
        case Self.positiveIncrease.rawValue:
            self = .positiveIncrease
        case Self.positiveDecrease.rawValue:
            self = .positiveDecrease
        default:
            self = .positiveDecrease // 默认对齐旧 upIncrease 行为
        }
    }

    public var displayName: String {
        switch self {
        case .positiveIncrease:
            return L10n.tr("信号增大 → 值增加", "Signal ↑ = Value ↑")
        case .positiveDecrease:
            return L10n.tr("信号增大 → 值减少", "Signal ↑ = Value ↓")
        }
    }

    /// 把「信号 delta」映射为「目标值增减方向」
    /// - Parameter signalDelta: 信号变化量（>0 = 信号增大，<0 = 信号减小）
    /// - Returns: +1 = 目标值增加，-1 = 目标值减少
    public func mapSignalDirection(_ signalDelta: Float) -> Int {
        switch self {
        case .positiveIncrease:
            return signalDelta >= 0 ? 1 : -1
        case .positiveDecrease:
            return signalDelta >= 0 ? -1 : 1
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
    /// 方向映射规则（v2：信号源无关语义；旧 upIncrease/upDecrease decode 时自动重映射）
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
                directionRule: DirectionRule = .positiveDecrease, // 默认对齐旧 upIncrease（normY 上滑=增加）
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
        // DirectionRule：用自定义 init 处理旧 upIncrease/upDecrease
        directionRule = try container.decodeIfPresent(DirectionRule.self, forKey: .directionRule) ?? .positiveDecrease
        executionMethod = try container.decodeIfPresent(ExecutionMethod.self, forKey: .executionMethod) ?? .mediaKey
    }

    // MARK: - 默认事件

    /// 默认音量事件：媒体键模式 + positiveDecrease（对应旧 upIncrease：normY 上滑=音量加）
    public static let defaultVolume = EventConfig(
        name: L10n.tr("音量", "Volume"),
        actionType: .volume,
        step: 0.0125,
        boundaryThreshold: 0.001,
        directionRule: .positiveDecrease,
        executionMethod: .mediaKey
    )

    /// 默认亮度事件：媒体键模式 + positiveDecrease（对应旧 upIncrease：normY 上滑=亮度加）
    public static let defaultBrightness = EventConfig(
        name: L10n.tr("亮度", "Brightness"),
        actionType: .brightness,
        step: 0.0125,
        boundaryThreshold: 0.001,
        directionRule: .positiveDecrease,
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

    // MARK: - 边界（内部辅助）

    /// 判断当前值是否在「目标方向」的边界上
    /// - Parameter targetDirection: ±1（= 目标值增减方向，已应用 directionRule）
    private func isAtBoundary(targetDirection: Int, value: Float) -> Bool {
        if targetDirection < 0 && value <= boundaryThreshold { return true }
        if targetDirection > 0 && value >= 1.0 - boundaryThreshold { return true }
        return false
    }

    /// 判断当前值是否在任一边界（用于进入 holding 时唤起 HUD）
    public func isAtAnyBoundary() -> Bool {
        let value = currentValue()
        return value <= boundaryThreshold || value >= 1.0 - boundaryThreshold
    }

    // MARK: - v2 主入口：消费 GestureOutput

    /// 消费手势引擎的输出，执行系统调节并返回边界结果
    ///
    /// 流程：
    /// 1. 根据 output 算出目标变化方向/幅度（tick 用 direction×count，continuous 用 delta 符号）
    /// 2. 边界预检：如果当前已在边界且继续朝外 → .frozen
    /// 3. 实际执行：根据 executionMethod 走 mediaKey 或 direct 分支
    /// 4. 边界后检：如果本次执行后贴边了 → 发 HUD + .hitBoundary，否则 .normal
    ///
    /// - Parameter output: 引擎输出（.tick 或 .continuous）
    /// - Returns: 边界结果（.normal / .hitBoundary / .frozen），供引擎决定震动和下一帧状态
    @discardableResult
    public mutating func consume(output: GestureOutput) -> BoundaryResult {
        // --- 步骤1：解析 output → 目标增减方向 + 变化总量 ---
        let targetDir: Int       // ±1（= 目标值这一次应该增还是减）
        let totalDelta: Float    // 目标值本次变化量（仅 direct+continuous 直接用这个值）
        let tickCount: Int       // discrete 模式：tick 次数；mediaKey 发几次

        switch output {
        case .tick(let d, let c):
            targetDir = d
            tickCount = max(1, c)
            totalDelta = Float(targetDir) * step * Float(tickCount)
        case .continuous(let d):
            targetDir = d >= 0 ? 1 : -1
            tickCount = 1
            totalDelta = d
        }

        // --- 步骤2：边界预检 ---
        let current = currentValue()
        let alreadyAtBoundary = isAtBoundary(targetDirection: targetDir, value: current)
        if alreadyAtBoundary {
            // 已经在边界且继续朝外：冻结，不执行
            return .frozen
        }

        // --- 步骤3：执行调节 ---
        switch (actionType, executionMethod) {
        // mediaKey：按 tickCount 发按键；continuous 退化：delta>0 发 1 次 up，<0 发 1 次 down
        case (.volume, .mediaKey):
            let n = (output.isTick) ? tickCount : 1
            for _ in 0..<n {
                if targetDir > 0 { SystemControl.volumeUp() }
                else { SystemControl.volumeDown() }
            }
        case (.brightness, .mediaKey):
            let n = (output.isTick) ? tickCount : 1
            for _ in 0..<n {
                if targetDir > 0 { SystemControl.brightnessUp() }
                else { SystemControl.brightnessDown() }
            }
        // direct：精确赋值
        case (.volume, .direct):
            let target = max(0.0, min(1.0, current + totalDelta))
            SystemControl.setVolume(target)
        case (.brightness, .direct):
            let target = max(0.0, min(1.0, current + totalDelta))
            SystemControl.setBrightness(target)
        }

        // --- 步骤4：边界后检（调节后是否首次贴边）---
        let after = currentValue()
        let hitBoundary = isAtBoundary(targetDirection: targetDir, value: after)
        if hitBoundary {
            postBoundaryKeyIfNeeded()
            return .hitBoundary
        }
        return .normal
    }

    // MARK: - HUD 唤起辅助

    /// 到达边界时，发送朝边界外的媒体键唤起 HUD（值不变，仅让系统弹出 HUD 指示框）
    private func postBoundaryKeyIfNeeded() {
        let value = currentValue()
        if value >= 1.0 - boundaryThreshold {
            // 在上边界，发送「增大」的媒体键
            switch actionType {
            case .volume: SystemControl.volumeUp()
            case .brightness: SystemControl.brightnessUp()
            }
        } else if value <= boundaryThreshold {
            // 在下边界，发送「减小」的媒体键
            switch actionType {
            case .volume: SystemControl.volumeDown()
            case .brightness: SystemControl.brightnessDown()
            }
        }
    }

    /// 进入 holding 时如果当前值已在边界，立即发一次 HUD（值不变）
    public func postBoundaryKeyOnEnterIfNeeded() {
        guard isAtAnyBoundary() else { return }
        postBoundaryKeyIfNeeded()
    }

    // MARK: - frozen 解冻判定（引擎调用）

    /// frozen 状态下，给定当前信号 delta，判断是否应该解冻（方向朝「边界内」滑动）
    /// - Parameters:
    ///   - signalDelta: 当前帧信号变化量（>0 = 信号增大，<0 = 信号减小）
    ///   - startValue: 进入 holding 时的系统值（用于判定"哪边是边界内"）
    /// - Returns: true = 应解除 frozen，恢复正常调节
    public func shouldUnfreeze(signalDelta: Float, startValue: Float) -> Bool {
        // 目标值应该朝哪个方向才是"回到边界内"
        // startValue <= boundaryThreshold → 在下边界 → 目标要增加 → targetDir = +1
        // startValue >= 1.0 - boundaryThreshold → 在上边界 → 目标要减少 → targetDir = -1
        let inwardTargetDir: Int
        if startValue <= boundaryThreshold {
            inwardTargetDir = 1
        } else if startValue >= 1.0 - boundaryThreshold {
            inwardTargetDir = -1
        } else {
            return true // 根本不在边界，当然解冻
        }
        // 把 signalDelta 按 directionRule 映射成目标增减方向，如果和 inward 同向则解冻
        let actualDir = directionRule.mapSignalDirection(signalDelta)
        return actualDir == inwardTargetDir
    }

    // MARK: - 旧 API（已废弃，保留给历史编译过的调用者）

    /// 已废弃：请使用 consume(output:)
    @available(*, deprecated, message: "Use consume(output:) instead")
    public func isAtBoundary(direction: Int) -> Bool {
        isAtBoundary(targetDirection: direction, value: currentValue())
    }

    /// 已废弃：映射物理 dy → 方向（请使用 directionRule.mapSignalDirection）
    @available(*, deprecated, message: "Use directionRule.mapSignalDirection(_:) instead")
    public func mapSlidingDirection(dy: Float) -> Int {
        // 旧 API：dy>0=normY增大=下滑，返回 ±1（目标增减）
        // 直接转发给 v2 语义函数：对于 normY，signalDelta=dy
        return directionRule.mapSignalDirection(dy)
    }

    /// 已废弃：请使用 consume(output:)
    @available(*, deprecated, message: "Use consume(output:) instead")
    public func perform(direction: Int) {
        let o: GestureOutput = .tick(direction: direction, count: 1)
        var mutable = self
        _ = mutable.consume(output: o)
    }

    /// 已废弃：请使用 postBoundaryKeyOnEnterIfNeeded
    @available(*, deprecated, message: "Use postBoundaryKeyOnEnterIfNeeded() instead")
    public func postBoundaryKey() {
        postBoundaryKeyIfNeeded()
    }
}

// MARK: - GestureOutput 辅助属性

extension GestureOutput {
    /// 是否是 discrete tick（而非 continuous delta）
    public var isTick: Bool {
        if case .tick = self { return true }
        return false
    }
}
