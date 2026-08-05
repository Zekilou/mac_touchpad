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
        case .fingers: return .teal
        case .region:  return .green
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
        case .generic: return L10n.tr("泛型（任意类型，可连任何形状）", "Generic (any type)")
        case .fingers: return L10n.tr("手指帧", "Fingers")
        case .region:  return L10n.tr("区域", "Region")
        }
    }

    /// 端口行内联短名（窄卡片空间有限，用短名标注类型，一眼看出形状代表什么类型）
    var shortName: String {
        switch self {
        case .float:   return "float"
        case .int:     return "int"
        case .bool:    return "bool"
        case .output:  return "out"
        case .unit:    return "pulse"
        case .generic: return "any"
        case .fingers: return "fingers"
        case .region:  return "region"
        }
    }
}

/// 单个 socket 的视觉形状（10pt 区）——形状 = 类型，同形状才能连
/// float=实心圆● / int=方块■ / bool=菱形◆ / output=三角▲ / unit=空心圆○ / region=圆角矩形▭ / fingers=三圆点
/// generic=**空心六边形线框**，内部叠加当前透传的实际类型小形状（branch 输入 float → out1/out2 显示「六边形+圆●」）
struct SocketShapeView: View {
    let type: SocketType
    /// generic 端口当前可确定的透传类型（nil = 未知，仅显示空心六边形）
    var passthrough: SocketType? = nil

    var body: some View {
        ZStack {
            if type == .generic {
                // 透传：空心六边形线框（六角星填充改线框——用户要求"透传是空心的形状"）
                HexagonShape()
                    .stroke(type.socketColor, lineWidth: 1.0)
                if let pt = passthrough {
                    // 内部叠加当前实际透传类型的形状（0.6 缩放 ≈ 6pt，略小于六边形内切圆）
                    socketGlyph(pt)
                        .scaleEffect(0.6)
                }
            } else {
                socketGlyph(type)
            }
        }
        .frame(width: 10, height: 10)
        .help(type.displayName)
    }

    /// 具体类型形状（无 frame，由调用方决定尺寸）
    @ViewBuilder
    private func socketGlyph(_ t: SocketType) -> some View {
        switch t {
        case .float:
            Circle().fill(t.socketColor)
        case .int:
            // 方块（无圆角）——区别于 region 圆角矩形
            Rectangle().fill(t.socketColor)
        case .bool:
            DiamondShape().fill(t.socketColor)
        case .output:
            TriangleShape().fill(t.socketColor)
        case .unit:
            Circle().strokeBorder(t.socketColor, lineWidth: 1.4)
        case .generic:
            // 内嵌时理论上不会出现 generic（调用方已解析），兜底空心六边形
            HexagonShape().stroke(type.socketColor, lineWidth: 1.0)
        case .fingers:
            // 多指：三个小圆点
            HStack(spacing: 1.5) {
                Circle().fill(t.socketColor).frame(width: 3, height: 3)
                Circle().fill(t.socketColor).frame(width: 3, height: 3)
                Circle().fill(t.socketColor).frame(width: 3, height: 3)
            }
        case .region:
            // 区域：圆角矩形（区别于 int 方块）
            RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(t.socketColor)
        }
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
