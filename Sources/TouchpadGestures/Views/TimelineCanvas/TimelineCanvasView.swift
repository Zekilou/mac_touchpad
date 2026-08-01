import SwiftUI
// 显式导入：消除与 SwiftUI.Edge 的同名歧义
import struct GestureEngine.Edge
import GestureEngine

/// 核心画布（v5 单图版）：一张自由节点图
/// - 节点定位/拖拽/缩放平移/贝塞尔连线/删除
/// - Trigger 节点黄色强调；Group 节点渲染为批注框（拖拽整体移动框内节点）
/// - 触控板：两指滑动平移（scrollWheel）、捏合缩放（MagnifyGesture）
struct TimelineCanvasView: View {
    @Binding var timeline: TimelineConfig
    @Binding var zoom: CGFloat
    @Binding var pan: CGSize
    @Binding var selectedNodeID: UUID?

    /// 进行中的连线（起点节点 + 当前端点，画布坐标）
    @State private var connecting: (from: NodeConfig, current: CGPoint)?
    /// 节点拖拽起点（防 translation 漂移）
    @State private var dragOrigin: (id: UUID, x: Double, y: Double)?
    /// 手势起点快照
    @State private var panOrigin: CGSize?
    @State private var zoomOrigin: CGFloat?
    @State private var didFit = false

    private var groupNodes: [NodeConfig] { timeline.nodes.filter { $0.type == .group } }
    private var regularNodes: [NodeConfig] { timeline.nodes.filter { $0.type != .group } }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 背景（承载平移/缩放/触控板手势）
                Rectangle()
                    .fill(Color.primary.opacity(0.03))
                    .contentShape(Rectangle())
                    .gesture(panGesture)
                    .gesture(magnifyGesture)
                    .onTapGesture { selectedNodeID = nil }
                    .background(
                        ScrollWheelCatcher { dx, dy in
                            pan.width -= dx
                            pan.height -= dy
                        }
                    )

                // 组框层（在节点下方）
                ForEach(groupNodes) { node in
                    groupFrame(node)
                        .position(x: node.x + groupWidth(node) / 2,
                                  y: node.y + groupHeight(node) / 2)
                        .onTapGesture { selectedNodeID = node.id }
                        .gesture(dragGroup(node))
                }

                // 连线层（固定边 + 进行中虚线）
                Canvas { context, _ in
                    for edge in timeline.edges { drawEdge(edge, in: &context) }
                    if let c = connecting { drawConnectingLine(c, in: &context) }
                }
                .transformEffect(canvasTransform)
                .allowsHitTesting(false)

                // 节点层
                ForEach(regularNodes) { node in
                    TimelineNodeView(
                        node: node,
                        isSelected: node.id == selectedNodeID,
                        onConnectDrag: { n, p in connecting = (n, p) },
                        onConnectEnd: { n, p in finishConnect(from: n, at: p) }
                    )
                    .position(x: node.x + TimelineCanvasMetrics.nodeWidth / 2,
                              y: node.y + TimelineCanvasMetrics.nodeHeight / 2)
                    .onTapGesture { selectedNodeID = node.id }
                    .gesture(dragNode(node))
                }
            }
            .scaleEffect(zoom, anchor: .topLeading)
            .offset(x: pan.width, y: pan.height)
            .onAppear {
                if !didFit { fitToContent(geo.size); didFit = true }
            }
            .onDeleteCommand { deleteSelection() }
        }
    }

    // MARK: - 组框

    private func groupWidth(_ node: NodeConfig) -> CGFloat {
        CGFloat(node.params.groupWidth ?? 300)
    }
    private func groupHeight(_ node: NodeConfig) -> CGFloat {
        CGFloat(node.params.groupHeight ?? 200)
    }

    /// 批注组框：虚线框 + 标题，尺寸在属性面板调
    private func groupFrame(_ node: NodeConfig) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(node.id == selectedNodeID ? Color.accentColor : Color.primary.opacity(0.25),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                )
            HStack(spacing: 4) {
                Image(systemName: "square.dashed").font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(node.title ?? L10n.tr("批注组", "Group"))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .frame(width: groupWidth(node), height: groupHeight(node))
        .contentShape(Rectangle())
    }

    /// 拖拽组框：移动组框本身 + 框内节点（几何包含判定，用拖前位置快照）
    private func dragGroup(_ node: NodeConfig) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard let idx = timeline.nodes.firstIndex(where: { $0.id == node.id }) else { return }
                if dragOrigin?.id != node.id { dragOrigin = (node.id, node.x, node.y) }
                guard let origin = dragOrigin else { return }
                let dx = Double(value.translation.width / zoom)
                let dy = Double(value.translation.height / zoom)
                let w = groupWidth(node)
                let h = groupHeight(node)
                timeline.nodes[idx].x = origin.x + dx
                timeline.nodes[idx].y = origin.y + dy
                for i in timeline.nodes.indices where i != idx {
                    let n = timeline.nodes[i]
                    let cx = n.x + TimelineCanvasMetrics.nodeWidth / 2
                    let cy = n.y + TimelineCanvasMetrics.nodeHeight / 2
                    if cx >= origin.x, cx <= origin.x + Double(w),
                       cy >= origin.y, cy <= origin.y + Double(h) {
                        timeline.nodes[i].x = n.x + dx
                        timeline.nodes[i].y = n.y + dy
                    }
                }
            }
            .onEnded { _ in dragOrigin = nil }
    }

    // MARK: - 坐标变换（与 scaleEffect(topLeading)+offset 一致）

    private var canvasTransform: CGAffineTransform {
        CGAffineTransform(scaleX: zoom, y: zoom)
            .concatenating(CGAffineTransform(translationX: pan.width, y: pan.height))
    }

    // MARK: - 手势

    private func dragNode(_ node: NodeConfig) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard let idx = timeline.nodes.firstIndex(where: { $0.id == node.id }) else { return }
                if dragOrigin?.id != node.id {
                    dragOrigin = (node.id, node.x, node.y)
                }
                guard let origin = dragOrigin else { return }
                timeline.nodes[idx].x = origin.x + Double(value.translation.width / zoom)
                timeline.nodes[idx].y = origin.y + Double(value.translation.height / zoom)
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if panOrigin == nil { panOrigin = pan }
                guard let origin = panOrigin else { return }
                pan = CGSize(width: origin.width + value.translation.width,
                             height: origin.height + value.translation.height)
            }
            .onEnded { _ in panOrigin = nil }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomOrigin == nil { zoomOrigin = zoom }
                guard let origin = zoomOrigin else { return }
                zoom = min(max(origin * value.magnification, 0.3), 3.0)
            }
            .onEnded { _ in zoomOrigin = nil }
    }

    // MARK: - 连线

    private func finishConnect(from: NodeConfig, at point: CGPoint) {
        defer { connecting = nil }
        guard let target = hitTestInputPort(at: point), target.id != from.id else { return }
        let edge = Edge(from: PortID(nodeID: from.id, portName: "output"),
                        to: PortID(nodeID: target.id, portName: "input"))
        guard !timeline.edges.contains(edge) else { return }
        timeline.edges.append(edge)
    }

    private func hitTestInputPort(at point: CGPoint) -> NodeConfig? {
        let r = TimelineCanvasMetrics.portHitRadius
        for node in regularNodes where connecting?.from.id != node.id {
            let p = node.inputPortPoint
            if (p.x - point.x) * (p.x - point.x) + (p.y - point.y) * (p.y - point.y) <= r * r {
                return node
            }
        }
        return nil
    }

    private func drawEdge(_ edge: Edge, in context: inout GraphicsContext) {
        guard let from = node(edge.from.nodeID), let to = node(edge.to.nodeID),
              from.type != .group, to.type != .group else { return }
        let start = from.outputPortPoint
        let end = to.inputPortPoint
        let dx = max(abs(end.x - start.x), 40) * TimelineCanvasMetrics.curveFactor
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end,
                      control1: CGPoint(x: start.x + dx, y: start.y),
                      control2: CGPoint(x: end.x - dx, y: end.y))
        context.stroke(path, with: .color(.teal.opacity(0.8)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private func drawConnectingLine(_ c: (from: NodeConfig, current: CGPoint),
                                    in context: inout GraphicsContext) {
        var path = Path()
        path.move(to: c.from.outputPortPoint)
        path.addLine(to: c.current)
        context.stroke(path, with: .color(.teal),
                       style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
    }

    // MARK: - 适应画布 / 删除

    /// 初始/手动：缩放平移使全部内容（含组框）可见
    func fitToContent(_ canvasSize: CGSize) {
        guard !timeline.nodes.isEmpty else { zoom = 1; pan = .zero; return }
        let w = TimelineCanvasMetrics.nodeWidth
        let h = TimelineCanvasMetrics.nodeHeight
        let minX = timeline.nodes.map { min($0.x, $0.x) }.min()!
        let maxX = timeline.nodes.map { node -> Double in
            if node.type == .group {
                return node.x + (node.params.groupWidth ?? 300)
            }
            return node.x + Double(w)
        }.max()!
        let minY = timeline.nodes.map(\.y).min()!
        let maxY = timeline.nodes.map { node -> Double in
            if node.type == .group {
                return node.y + (node.params.groupHeight ?? 200)
            }
            return node.y + Double(h)
        }.max()!
        let contentW = maxX - minX + 160
        let contentH = maxY - minY + 160
        zoom = min(canvasSize.width / contentW, canvasSize.height / contentH, 1.0)
        pan = CGSize(
            width: (canvasSize.width - (maxX + minX) * Double(zoom)) / 2 - 80,
            height: (canvasSize.height - (maxY + minY) * Double(zoom)) / 2 - 80
        )
    }

    private func deleteSelection() {
        guard let id = selectedNodeID else { return }
        timeline.nodes.removeAll { $0.id == id }
        timeline.edges.removeAll { $0.from.nodeID == id || $0.to.nodeID == id }
        timeline.entryNodeIDs.removeAll { $0 == id }
        selectedNodeID = nil
    }

    private func node(_ id: UUID) -> NodeConfig? {
        timeline.nodes.first { $0.id == id }
    }
}
