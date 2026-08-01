import SwiftUI
import GestureEngine

// MARK: - Socket 形状（Blender 风格：形状 = 类型，同形状才能连）

/// Socket 类型 → 形状（可连性由形状决定）+ 颜色（辅助识别）
/// float=圆 ● / int=方 ■ / bool=菱 ◆ / output=三角 ▲ / unit=空心 ○ / generic=六边形 ⬡
extension SocketType {
    /// 形状填充色（unit 空心无填充）
    var socketColor: Color {
        switch self {
        case .float:   return .gray
        case .int:     return .cyan
        case .bool:    return .pink
        case .output:  return .orange
        case .unit:    return .secondary
        case .generic: return .purple
        }
    }

    /// UI 类型名（tooltip）
    var displayName: String {
        switch self {
        case .float:   return L10n.tr("浮点", "Float")
        case .int:     return L10n.tr("整数", "Integer")
        case .bool:    return L10n.tr("布尔", "Boolean")
        case .output:  return L10n.tr("量化输出", "Gesture Output")
        case .unit:    return L10n.tr("事件脉冲", "Event Pulse")
        case .generic: return L10n.tr("泛型", "Generic")
        }
    }
}

/// 单个 socket 的视觉形状（8pt 圆点区）
struct SocketShapeView: View {
    let type: SocketType
    var body: some View {
        ZStack {
            switch type {
            case .float:
                Circle().fill(type.socketColor)
            case .int:
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(type.socketColor)
            case .bool:
                DiamondShape().fill(type.socketColor)
            case .output:
                TriangleShape().fill(type.socketColor)
            case .unit:
                Circle().strokeBorder(type.socketColor, lineWidth: 1.2)
            case .generic:
                HexagonShape().fill(type.socketColor)
            }
        }
        .frame(width: 9, height: 9)
        .help(type.displayName)
    }
}

// MARK: - 形状 Path

/// 菱形（bool）
struct DiamondShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.closeSubpath()
        return p
    }
}

/// 三角形（output）
struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// 六边形（generic）
struct HexagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width / 2
        let h = rect.height / 2
        let points: [CGPoint] = [
            CGPoint(x: 0, y: -h), CGPoint(x: w * 0.866, y: -h * 0.5),
            CGPoint(x: w * 0.866, y: h * 0.5), CGPoint(x: 0, y: h),
            CGPoint(x: -w * 0.866, y: h * 0.5), CGPoint(x: -w * 0.866, y: -h * 0.5),
        ]
        p.move(to: CGPoint(x: rect.midX + points[0].x, y: rect.midY + points[0].y))
        for pt in points.dropFirst() {
            p.addLine(to: CGPoint(x: rect.midX + pt.x, y: rect.midY + pt.y))
        }
        p.closeSubpath()
        return p
    }
}
