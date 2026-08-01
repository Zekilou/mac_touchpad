import SwiftUI
import GestureEngine

/// 手势节点图主视图（v5 完全配置化）
/// - 画布盛满整个窗口
/// - 左侧工具栏 overlay 悬浮在画布上（不占布局空间）
/// - 触控板两指滑动平移 / 捏合缩放 / 节点拖拽 / 端口连线
struct TimelineGraphView: View {
    @Binding var timeline: TimelineConfig
    /// 绑定可选项（region/event 引用节点参数面板数据源）
    let events: [EventConfig]
    let regions: [RegionConfig]

    @State private var zoom: CGFloat = 0.6
    @State private var pan: CGSize = .zero
    @State private var selectedNodeID: UUID?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 画布盛满窗口
                TimelineCanvasView(timeline: $timeline,
                                   zoom: $zoom,
                                   pan: $pan,
                                   selectedNodeID: $selectedNodeID)

                // 左侧 overlay 工具栏（悬浮在画布上）
                NodePaletteView(timeline: $timeline,
                                selectedNodeID: $selectedNodeID,
                                zoom: $zoom,
                                pan: $pan,
                                canvasSize: geo.size,
                                events: events,
                                regions: regions,
                                onFit: { fitToContent(geo.size) })
                    .padding(10)
            }
        }
    }

    // MARK: - 适应画布（与 CanvasView 内算法一致，含组框）

    private func fitToContent(_ canvasSize: CGSize) {
        guard !timeline.nodes.isEmpty else { zoom = 1; pan = .zero; return }
        let w = TimelineCanvasMetrics.nodeWidth
        let h = TimelineCanvasMetrics.nodeHeight
        let minX = timeline.nodes.map(\.x).min()!
        let maxX = timeline.nodes.map { node -> Double in
            node.type == .group ? node.x + (node.params.groupWidth ?? 300) : node.x + Double(w)
        }.max()!
        let minY = timeline.nodes.map(\.y).min()!
        let maxY = timeline.nodes.map { node -> Double in
            node.type == .group ? node.y + (node.params.groupHeight ?? 200) : node.y + Double(h)
        }.max()!
        let contentW = maxX - minX + 160
        let contentH = maxY - minY + 160
        zoom = min(canvasSize.width / contentW, canvasSize.height / contentH, 1.0)
        pan = CGSize(
            width: (canvasSize.width - (maxX + minX) * Double(zoom)) / 2 - 80,
            height: (canvasSize.height - (maxY + minY) * Double(zoom)) / 2 - 80
        )
    }
}
