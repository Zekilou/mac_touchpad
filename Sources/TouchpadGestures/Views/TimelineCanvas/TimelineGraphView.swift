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
    /// 左侧栏在窗口中的位置（触控板事件排除区域）
    @State private var paletteFrame: CGRect = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 画布盛满窗口
                TimelineCanvasView(timeline: $timeline,
                                   zoom: $zoom,
                                   pan: $pan,
                                   selectedNodeID: $selectedNodeID,
                                   excludeRect: $paletteFrame,
                                   events: events,
                                   regions: regions)

                // 左侧 overlay 工具栏（悬浮在画布上）；上报自身 frame 供画布排除触控板事件
                NodePaletteView(timeline: $timeline,
                                selectedNodeID: $selectedNodeID,
                                zoom: $zoom,
                                pan: $pan,
                                canvasSize: geo.size,
                                onFit: { fitToContent(geo.size) })
                    .padding(10)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { paletteFrame = proxy.frame(in: .global) }
                                .onChange(of: proxy.frame(in: .global)) { paletteFrame = $0 }
                        }
                    )
            }
        }
    }

    // MARK: - 适应画布（与 CanvasView 内算法一致，含组框）

    private func fitToContent(_ canvasSize: CGSize) {
        guard !timeline.nodes.isEmpty else { zoom = 1; pan = .zero; return }
        let w = TimelineCanvasMetrics.nodeWidth
        let minX = timeline.nodes.map(\.x).min()!
        let maxX = timeline.nodes.map { node -> Double in
            node.type == .group ? node.x + (node.params.groupWidth ?? 300) : node.x + Double(w)
        }.max()!
        let minY = timeline.nodes.map(\.y).min()!
        let maxY = timeline.nodes.map { node -> Double in
            if node.type == .group { return node.y + (node.params.groupHeight ?? 200) }
            let portRows = max(NodeTypeDef.inputSockets(of: node.type).count,
                               NodeTypeDef.outputSockets(of: node.type).count)
            return node.y + Double(TimelineCanvasMetrics.nodeBaseHeight(portRows: portRows))
        }.max()!
        let contentW = maxX - minX + 160
        let contentH = maxY - minY + 160
        // 无下限：可缩到很小看全貌（画布大小不设限制）
        zoom = min(canvasSize.width / contentW, canvasSize.height / contentH, 1.0)
        pan = CGSize(
            width: (canvasSize.width - (maxX + minX) * Double(zoom)) / 2 - 80,
            height: (canvasSize.height - (maxY + minY) * Double(zoom)) / 2 - 80
        )
    }
}
