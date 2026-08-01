import SwiftUI
import GestureEngine

// MARK: - 画布常量

enum TimelineCanvasMetrics {
    /// 节点固定尺寸（防布局抖动）
    static let nodeWidth: CGFloat = 170
    static let nodeHeight: CGFloat = 56
    /// 端口圆点半径
    static let portRadius: CGFloat = 5
    /// 连线命中检测半径（画布坐标）
    static let portHitRadius: CGFloat = 24
    /// 连线曲率（水平控制点偏移比例）
    static let curveFactor: CGFloat = 0.5
}

extension NodeConfig {
    /// 节点左上角画布坐标
    var canvasPoint: CGPoint { CGPoint(x: x, y: y) }
    /// 输入端口（左侧中部）画布坐标
    var inputPortPoint: CGPoint {
        CGPoint(x: x, y: y + TimelineCanvasMetrics.nodeHeight / 2)
    }
    /// 输出端口（右侧中部）画布坐标
    var outputPortPoint: CGPoint {
        CGPoint(x: x + TimelineCanvasMetrics.nodeWidth, y: y + TimelineCanvasMetrics.nodeHeight / 2)
    }
}

// MARK: - 节点视图

/// 画布上的单个节点卡片：图标 + 标题 + 参数摘要 + 左右端口
/// - 固定 frame 尺寸（见 Metrics），端口位置由 canvasPoint + 尺寸推导
struct TimelineNodeView: View {
    let node: NodeConfig
    let isSelected: Bool
    /// 输出端口拖拽中：报告当前连线端点（画布坐标）
    let onConnectDrag: (NodeConfig, CGPoint) -> Void
    /// 输出端口拖拽结束：画布侧做命中检测
    let onConnectEnd: (NodeConfig, CGPoint) -> Void

    var body: some View {
        // 组框由画布层渲染，不在此处画卡片
        if node.type == .group {
            EmptyView()
        } else {
            ZStack {
                // 卡片（Trigger 节点黄色强调）
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(node.type == .trigger
                          ? AnyShapeStyle(Color.yellow.opacity(0.15))
                          : AnyShapeStyle(.background.opacity(0.9)))
                    .shadow(color: .black.opacity(isSelected ? 0.25 : 0.12), radius: isSelected ? 4 : 2, y: 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(node.type == .trigger
                                          ? (isSelected ? Color.yellow : Color.yellow.opacity(0.6))
                                          : (isSelected ? Color.accentColor : Color.primary.opacity(0.15)),
                                          lineWidth: isSelected ? 2 : 1)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: node.type.symbolName)
                            .font(.system(size: 12))
                            .foregroundStyle(node.type.tintColor)
                        Text(node.title ?? node.type.displayName)
                            .font(.caption.bold())
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    Text(node.paramsSummary)
                        .font(.caption2).monospaced()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                // 端口圆点 + 连线把手（输出端口可拖拽连线）
                HStack {
                    portDot(color: .orange, isOutput: false)
                    Spacer()
                    portDot(color: .teal, isOutput: true)
                }
            }
            .frame(width: TimelineCanvasMetrics.nodeWidth,
                   height: TimelineCanvasMetrics.nodeHeight)
            .contentShape(Rectangle())
        }
    }

    /// 端口圆点：leading = 输入（橙），trailing = 输出（青，带拖拽连线把手）
    private func portDot(color: Color, isOutput: Bool) -> some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: TimelineCanvasMetrics.portRadius * 2,
                       height: TimelineCanvasMetrics.portRadius * 2)
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 0.5))
                .shadow(color: color.opacity(0.5), radius: 2)
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .gesture(
            isOutput
                ? DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        onConnectDrag(node, CGPoint(x: node.outputPortPoint.x + value.translation.width,
                                                   y: node.outputPortPoint.y + value.translation.height))
                    }
                    .onEnded { value in
                        onConnectEnd(node, CGPoint(x: node.outputPortPoint.x + value.translation.width,
                                                  y: node.outputPortPoint.y + value.translation.height))
                    }
                : nil
        )
        .help(isOutput ? L10n.tr("拖拽连线", "Drag to connect") : L10n.tr("输入", "Input"))
    }
}
