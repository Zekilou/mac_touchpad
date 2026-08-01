import SwiftUI
// 显式导入：消除与 SwiftUI.Edge 的同名歧义
import struct GestureEngine.Edge
import GestureEngine

/// 核心画布：节点定位 + 拖拽 + 缩放平移 + 贝塞尔连线 + 删除
/// 状态（timeline/zoom/pan/选中）由容器持有，便于侧栏联动
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

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 背景（承载平移/缩放手势）
                Rectangle()
                    .fill(Color.primary.opacity(0.03))
                    .contentShape(Rectangle())
                    .gesture(panGesture)
                    .gesture(magnifyGesture)
                    .onTapGesture { selectedNodeID = nil }

                // 连线层（固定边 + 进行中虚线）
                Canvas { context, _ in
                    for edge in timeline.edges { drawEdge(edge, in: &context) }
                    if let c = connecting { drawConnectingLine(c, in: &context) }
                }
                .transformEffect(canvasTransform)
                .allowsHitTesting(false)

                // 节点层
                ForEach(timeline.nodes) { node in
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
            .onDeleteCommand { deleteSelection() }
        }
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
        for node in timeline.nodes where connecting?.from.id != node.id {
            let p = node.inputPortPoint
            if (p.x - point.x) * (p.x - point.x) + (p.y - point.y) * (p.y - point.y) <= r * r {
                return node
            }
        }
        return nil
    }

    private func drawEdge(_ edge: Edge, in context: inout GraphicsContext) {
        guard let from = node(edge.from.nodeID), let to = node(edge.to.nodeID) else { return }
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

    // MARK: - 删除

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
