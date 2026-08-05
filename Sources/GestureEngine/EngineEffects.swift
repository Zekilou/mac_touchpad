import Foundation

/// EventConfig 的 class 包装：consume 是 mutating 方法，需通过引用传递跨帧追踪值
final class EventBox {
    var value: EventConfig
    init(_ value: EventConfig) { self.value = value }
}

/// Timeline 副作用 → 手势引擎桥接（GraphEvaluator 的 effects 参数）
/// 把节点的副作用派发到真实系统：震动/调节/鼠标/冻结
final class EngineEffects: TimelineEffects {
    weak var engine: GestureEngine?
    /// 当前 holding 手势的事件引用（consume 的 mutating 状态跨帧保留）
    var eventBox: EventBox?

    func triggerHaptic(waveform: Int32, count: Int, intervalUs: Int32, async: Bool) {
        engine?.triggerHaptic(waveform: waveform, count: count, intervalUs: intervalUs, async: async)
    }

    func consume(_ output: GestureOutput) -> BoundaryResult {
        guard let box = eventBox else { return .normal }
        return box.value.consume(output: output)
    }

    func showHUD(direction: Int) {
        // 边界 HUD 已由 EventConfig.consume 内部处理（postBoundaryKey）
        // 独立 HUDNode 使用场景：预留
    }

    func lockMouse() { engine?.disassociateMouse() }
    func unlockMouse() { engine?.associateMouse() }

    /// 旧 freeze 卡片兼容（已废弃）：冻结现在通过 set(frozen=1) 变量操作表达
    func freeze() {}

    func notify(label: String) {
        // 预留：UI 通知（M6 调试工具使用）
    }
}
