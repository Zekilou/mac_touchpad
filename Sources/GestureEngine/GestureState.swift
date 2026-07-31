import Foundation

/// 单个手势的状态机
public enum GestureState: Equatable {
    case idle
    case firstTapDown(pathIndex: Int32, startTime: Double, startPos: (Float, Float), maxDrift: Float)
    case firstTapUp(pathIndex: Int32, endTime: Double)
    case secondTapDown(pathIndex: Int32, startTime: Double, startPos: (Float, Float), maxDrift: Float)
    case holding(pathIndex: Int32, startY: Float, lastTickY: Float, ticks: Int, frozen: Bool, startValue: Float)
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
