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
    /// 触控板事件排除区域（window 坐标）：该区域内的滑动/捏合不拦截（放行给左侧栏滚动等）
    @Binding var excludeRect: CGRect
    /// 绑定可选项（region/event 节点参数 Picker 数据源）
    let events: [EventConfig]
    let regions: [RegionConfig]

    /// 进行中的连线（起点节点 + 输出端口名 + 当前端点，画布坐标）
    @State private var connecting: (from: NodeConfig, fromPort: String, current: CGPoint)?
    /// 节点拖拽起点（防 translation 漂移）
    @State private var dragOrigin: (id: UUID, x: Double, y: Double)?
    /// 手势起点快照
    @State private var panOrigin: CGSize?
    @State private var didFit = false

    private var groupNodes: [NodeConfig] { timeline.nodes.filter { $0.type == .group } }
    private var regularNodes: [NodeConfig] { timeline.nodes.filter { $0.type != .group } }

    /// 全部节点（含组框）的内容包围盒（画布坐标）；空图返回 nil
    private var contentBounds: CGRect? {
        guard !timeline.nodes.isEmpty else { return nil }
        let w = TimelineCanvasMetrics.nodeWidth
        let minX = timeline.nodes.map(\.x).min()!
        let maxX = timeline.nodes.map { node -> Double in
            node.type == .group ? node.x + (node.params.groupWidth ?? 300) : node.x + Double(w)
        }.max()!
        let minY = timeline.nodes.map(\.y).min()!
        let maxY = timeline.nodes.map { node -> Double in
            if node.type == .group {
                return node.y + (node.params.groupHeight ?? 200)
            }
            let portRows = max(NodeTypeDef.inputSockets(of: node.type).count,
                               NodeTypeDef.outputSockets(of: node.type).count)
            return node.y + Double(TimelineCanvasMetrics.nodeBaseHeight(portRows: portRows))
        }.max()!
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 最底层：触控板事件捕获（两指滑动平移 / 捏合缩放），窗口级监听
                ScrollWheelCatcher(
                    onScroll: { dx, dy in
                        // 内容跟随手指：两指上滑内容上移（与系统滚动方向相反）
                        pan.width += dx
                        pan.height += dy
                    },
                    onMagnify: { m, center in
                        // 以手势位置为锚点缩放：保持指针下的内容点不动
                        let oldZoom = zoom
                        zoom = min(max(zoom * m, 0.3), 3.0)
                        let scale = zoom / oldZoom
                        pan = CGSize(
                            width: center.x - (center.x - pan.width) * scale,
                            height: center.y - (center.y - pan.height) * scale
                        )
                    },
                    excludeRect: excludeRect
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 背景（承载拖拽平移 + 点击取消选中）
                Rectangle()
                    .fill(Color.primary.opacity(0.03))
                    .contentShape(Rectangle())
                    .gesture(panGesture)
                    .onTapGesture { selectedNodeID = nil }

                // 组框层（在节点下方）
                ForEach(groupNodes) { node in
                    groupFrame(node)
                        .position(x: node.x + groupWidth(node) / 2,
                                  y: node.y + groupHeight(node) / 2)
                        .onTapGesture { selectedNodeID = node.id }
                        .gesture(dragGroup(node))
                }

                // 连线层（固定边 + 进行中虚线）——画布坐标绘制，由外层 scaleEffect+offset 统一变换
                // 注意：Canvas 会裁剪绘制到自身 bounds，尺寸必须覆盖整个内容包围盒（否则窗口外连线不渲染）
                if let bounds = contentBounds {
                    Canvas { context, _ in
                        // 内容原点 → 画布本地原点（本地原点对齐内容包围盒左上角）
                        context.translateBy(x: -(bounds.minX - 20), y: -(bounds.minY - 20))
                        for edge in timeline.edges { drawEdge(edge, in: &context) }
                        if let c = connecting { drawConnectingLine(c, in: &context) }
                    }
                    .frame(width: bounds.width + 40, height: bounds.height + 40)
                    .offset(x: bounds.minX - 20, y: bounds.minY - 20)
                    .allowsHitTesting(false)
                }

                // 节点层
                ForEach(regularNodes) { node in
                    nodeView(node)
                        .position(x: node.x + TimelineCanvasMetrics.nodeWidth / 2,
                                  y: node.y + expandedHeight(node) / 2)
                        .onTapGesture { selectedNodeID = node.id }
                        .gesture(dragNode(node))
                }
            }
            .scaleEffect(zoom, anchor: .topLeading)
            .offset(x: pan.width, y: pan.height)
            // 首次布局完成（尺寸非零）时居中内容（节点 1:1 显示，画布无限、平移浏览）
            .onAppear { tryCenterIfNeeded(geo.size) }
            .onChange(of: geo.size) { tryCenterIfNeeded($0) }
            .onDeleteCommand { deleteSelection() }
        }
    }

    private func tryCenterIfNeeded(_ size: CGSize) {
        if !didFit, size.width > 0, size.height > 0 {
            centerContent(size)
            didFit = true
        }
    }

    /// 节点卡片总高度（基础 = 头部+端口行；选中展开 += 内联编辑器行数）
    private func expandedHeight(_ node: NodeConfig) -> CGFloat {
        let portRows = max(NodeTypeDef.inputSockets(of: node.type).count,
                           NodeTypeDef.outputSockets(of: node.type).count)
        return TimelineCanvasMetrics.nodeHeight(
            portRows: portRows,
            paramRows: node.params.typedRows.count,
            edgeRows: timeline.incomingEdges(to: node.id).count + timeline.outgoingEdges(from: node.id).count,
            expanded: node.id == selectedNodeID)
    }

    /// 初始视图：zoom 保持 1:1，内容包围盒中心对准视口中心
    private func centerContent(_ size: CGSize) {
        guard !timeline.nodes.isEmpty else { return }
        zoom = 1
        let minX = timeline.nodes.map(\.x).min()!
        let maxX = timeline.nodes.map { node -> Double in
            node.type == .group ? node.x + (node.params.groupWidth ?? 300) : node.x + Double(TimelineCanvasMetrics.nodeWidth)
        }.max()!
        let minY = timeline.nodes.map(\.y).min()!
        let maxY = timeline.nodes.map { node -> Double in
            if node.type == .group { return node.y + (node.params.groupHeight ?? 200) }
            let portRows = max(NodeTypeDef.inputSockets(of: node.type).count,
                               NodeTypeDef.outputSockets(of: node.type).count)
            return node.y + Double(TimelineCanvasMetrics.nodeBaseHeight(portRows: portRows))
        }.max()!
        pan = CGSize(width: size.width / 2 - (minX + maxX) / 2,
                     height: size.height / 2 - (minY + maxY) / 2)
    }

    // MARK: - 组框

    /// 单个节点卡片视图（含内联参数编辑；找不到索引时返回空视图）
    private func nodeView(_ node: NodeConfig) -> some View {
        guard let idx = timeline.nodes.firstIndex(where: { $0.id == node.id }) else {
            return AnyView(EmptyView())
        }
        return AnyView(
            TimelineNodeView(
                node: node,
                isSelected: node.id == selectedNodeID,
                zoom: zoom,
                events: events,
                regions: regions,
                params: Binding(
                    get: { timeline.nodes[idx].params },
                    set: { timeline.nodes[idx].params = $0 }
                ),
                edges: timeline.incomingEdges(to: node.id) + timeline.outgoingEdges(from: node.id),
                onDeleteEdge: { edge in
                    timeline.edges.removeAll { $0 == edge }
                },
                onConnectDrag: { n, port, p in connecting = (n, port, p) },
                onConnectEnd: { n, port, p in finishConnect(from: n, fromPort: port, at: p) }
            )
        )
    }

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
                    let rows = max(NodeTypeDef.inputSockets(of: n.type).count,
                                   NodeTypeDef.outputSockets(of: n.type).count)
                    let cy = n.y + Double(TimelineCanvasMetrics.nodeBaseHeight(portRows: rows)) / 2
                    if cx >= origin.x, cx <= origin.x + Double(w),
                       cy >= origin.y, cy <= origin.y + Double(h) {
                        timeline.nodes[i].x = n.x + dx
                        timeline.nodes[i].y = n.y + dy
                    }
                }
            }
            .onEnded { _ in dragOrigin = nil }
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

    // MARK: - 连线

    /// 完成连线：命中目标输入端口且形状匹配才连接
    private func finishConnect(from: NodeConfig, fromPort: String, at point: CGPoint) {
        defer { connecting = nil }
        guard let fromType = NodeTypeDef.outputSockets(of: from.type).first(where: { $0.name == fromPort })?.type else { return }
        guard let target = hitTestInputPort(at: point, fromType: fromType), target.node.id != from.id else { return }
        let edge = Edge(from: PortID(nodeID: from.id, portName: fromPort),
                        to: PortID(nodeID: target.node.id, portName: target.port))
        guard !timeline.edges.contains(edge) else { return }
        timeline.edges.append(edge)
    }

    /// 命中检测：目标节点的输入 socket 位置命中 + 形状匹配（返回节点与端口名）
    private func hitTestInputPort(at point: CGPoint, fromType: SocketType) -> (node: NodeConfig, port: String)? {
        let r = TimelineCanvasMetrics.portHitRadius
        for node in regularNodes where connecting?.from.id != node.id {
            let sockets = NodeTypeDef.inputSockets(of: node.type)
            for (i, socket) in sockets.enumerated() {
                let p = node.inputPortPoint(index: i)
                let dx = p.x - point.x
                let dy = p.y - point.y
                if dx * dx + dy * dy <= r * r, NodeTypeDef.canConnect(from: fromType, to: socket.type) {
                    return (node, socket.name)
                }
            }
        }
        return nil
    }

    private func drawEdge(_ edge: Edge, in context: inout GraphicsContext) {
        guard let from = node(edge.from.nodeID), let to = node(edge.to.nodeID),
              from.type != .group, to.type != .group else { return }
        // 输出端口：按 from.portName 找注册表索引；输入端口：按 to.portName 找索引（找不到=入口注入边，画到节点头部）
        guard let fromIdx = NodeTypeDef.outputSockets(of: from.type).firstIndex(where: { $0.name == edge.from.portName }) else { return }
        let start = from.outputPortPoint(index: fromIdx)
        let end: CGPoint
        if let toIdx = NodeTypeDef.inputSockets(of: to.type).firstIndex(where: { $0.name == edge.to.portName }) {
            end = to.inputPortPoint(index: toIdx)
        } else {
            end = CGPoint(x: to.x, y: to.y + TimelineCanvasMetrics.headerHeight / 2)
        }
        let dx = max(abs(end.x - start.x), 40) * TimelineCanvasMetrics.curveFactor
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end,
                      control1: CGPoint(x: start.x + dx, y: start.y),
                      control2: CGPoint(x: end.x - dx, y: end.y))
        context.stroke(path, with: .color(.teal.opacity(0.8)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private func drawConnectingLine(_ c: (from: NodeConfig, fromPort: String, current: CGPoint),
                                    in context: inout GraphicsContext) {
        guard let idx = NodeTypeDef.outputSockets(of: c.from.type).firstIndex(where: { $0.name == c.fromPort }) else { return }
        var path = Path()
        path.move(to: c.from.outputPortPoint(index: idx))
        path.addLine(to: c.current)
        context.stroke(path, with: .color(.teal),
                       style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
    }

    // MARK: - 适应画布 / 删除

    /// 「适应画布」按钮：缩放平移使全部内容（含组框）可见（无下限，可缩很小看全貌）
    func fitToContent(_ canvasSize: CGSize) {
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
