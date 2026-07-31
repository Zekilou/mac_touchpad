import Foundation

/// 单个手势的状态机
/// v2：holding 升级为 startRaw（起始信号值）+ lastTriggerVal（上次触发信号值），不再绑死 Y 轴
public enum GestureState: Equatable {
    case idle
    case firstTapDown(pathIndex: Int32, startTime: Double, startPos: (Float, Float), maxDrift: Float)
    case firstTapUp(pathIndex: Int32, endTime: Double)
    case secondTapDown(pathIndex: Int32, startTime: Double, startPos: (Float, Float), maxDrift: Float)
    /// holding 状态（v2：信号源无关）
    /// - Parameters:
    ///   - pathIndex: 手指追踪 ID
    ///   - startRaw: 进入 holding 瞬间的信号值（= gesture.signalSource.extract(from:)）
    ///   - lastTriggerVal: 最近一次触发 tick/调节时的信号值（用于下一帧算 delta）
    ///   - ticks: 已触发的累计 tick 次数（调试用）
    ///   - frozen: 是否冻结中（到达边界后，等待反向滑动解冻）
    ///   - startValue: 进入 holding 瞬间的系统值（0~1，用于判定 frozen 解冻方向）
    case holding(pathIndex: Int32, startRaw: Float, lastTriggerVal: Float, ticks: Int, frozen: Bool, startValue: Float)
    case cooldown(pathIndex: Int32)

    public static func == (lhs: GestureState, rhs: GestureState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.firstTapDown(let a1, let a2, _, let a4), .firstTapDown(let b1, let b2, _, let b4)):
            return a1 == b1 && a2 == b2 && a4 == b4
        case (.firstTapUp(let a1, let a2), .firstTapUp(let b1, let b2)):
            return a1 == b1 && a2 == b2
        case (.secondTapDown(let a1, let a2, _, let a4), .secondTapDown(let b1, let b2, _, let b4)):
            return a1 == b1 && a2 == b2 && a4 == b4
        case (.holding(let a1, let a2, let a3, let a4, let a5, let a6),
              .holding(let b1, let b2, let b3, let b4, let b5, let b6)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4 && a5 == b5 && a6 == b6
        case (.cooldown(let a1), .cooldown(let b1)):
            return a1 == b1
        default:
            return false
        }
    }
}
