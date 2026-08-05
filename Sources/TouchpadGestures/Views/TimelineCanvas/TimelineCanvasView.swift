import SwiftUI
// 显式导入：消除与 SwiftUI.Edge 的同名歧义
import struct GestureEngine.Edge
import GestureEngine

/// 拖拽中节点的偏移状态（连线跟随用）
/// 关键设计：**只有连线 Canvas 层订阅它**（@ObservedObject）→ 拖动中只有连线层重绘；
/// 画布层/节点层不订阅 → 零重算 → 不闪烁。节点自身视觉跟随由节点内部 @GestureState 驱动。
final class DragState: ObservableObject {
    @Published var nodeID: UUID?
    @Published var offset: CGSize = .zero
    func start(_ id: UUID, _ o: CGSize) { nodeID = id; offset = o }
    func clear() { nodeID = nil; offset = .zero }
}

/// 核心画布（v5 单图版）：一张自由节点图
/// - 节点定位/拖拽/缩放平移/贝塞尔连线/删除
/// - Trigger 节点黄色强调；Group 节点渲染为批注框（拖拽整体移动框内节点）
/// - 触控板：两指滑动平移（scrollWheel）、捏合缩放（MagnifyGesture）
struct TimelineCanvasView: View {
    @Binding var timeline: TimelineConfig
    @Binding var zoom: CGFloat
    @Binding var pan: CGSize
    /// 选中节点集（多选：单击替换 / 框选批量 / Cmd+A 全选）
    @Binding var selectedNodeIDs: Set<UUID>
    /// 触控板事件排除区域（window 坐标）：该区域内的滑动/捏合不拦截（放行给左侧栏滚动等）
    @Binding var excludeRect: CGRect
    /// 绑定可选项（region/event 节点参数 Picker 数据源）
    let events: [EventConfig]
    let regions: [RegionConfig]
    /// 打开模块内部（嵌套画布导航：双击 module 或「打开内部…」按钮）
    let onOpenModule: (UUID) -> Void
    /// 导航令牌：进入/返回模块时外层 +1，画布重置视图（居中/适应内容）
    let resetToken: Int
    /// 右键菜单回调（复制/粘贴/适应画布/自动整理/添加节点——剪贴板与布局状态在 GraphView 持有）
    let onCopy: () -> Void
    let onPaste: () -> Void
    let onFit: () -> Void
    let onLayout: () -> Void
    let onAddNode: (NodeType) -> Void

    /// 进行中的连线（起点节点 + 输出端口名 + 当前端点，画布坐标）
    @State private var connecting: (from: NodeConfig, fromPort: String, current: CGPoint)?
    /// 拖拽偏移状态（AppKit DragMonitor 增量驱动；节点订阅渲染 + 连线层订阅跟随）
    @StateObject private var dragState = DragState()
    /// 当前拖拽累计偏移（屏幕像素，AppKit delta 增量累加——单调无振荡）
    @State private var dragOffset: CGSize = .zero
    /// 组框拖拽起点（防 translation 漂移）
    @State private var groupDragOrigin: (id: UUID, x: Double, y: Double)?
    /// 框选状态：起点 + 当前点（画布坐标，nil = 未框选）
    @State private var selectionStart: CGPoint?
    @State private var selectionCurrent: CGPoint?
    /// 重命名弹窗目标节点（非 nil 时弹 alert）
    @State private var renameTarget: NodeConfig?
    /// 头部最近一次点击（双击进模块检测）
    @State private var lastHeaderTap: (id: UUID, time: Date)?
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
            return node.y + Double(displayHeight(node))
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

                // AppKit 级鼠标拖拽（节点拖动）：增量事件流，无 SwiftUI 手势取消重启 → 不横跳
                // delta/total 为屏幕像素，此处统一换算为画布坐标（/zoom）供内容层使用
                DragMonitor(
                    hitTestNode: { hitTestNode(atView: $0) },
                    onDragStart: { id in
                        dragState.nodeID = id
                        dragOffset = .zero
                    },
                    onDragDelta: { delta in
                        dragOffset.width += delta.width / zoom
                        dragOffset.height += delta.height / zoom
                        dragState.offset = dragOffset
                    },
                    onDragEnd: { total in
                        commitDrag(CGSize(width: total.width / zoom, height: total.height / zoom))
                        dragOffset = .zero
                        dragState.clear()
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // ===== 内容层：统一画布坐标系 =====
                // 缩放/平移作用于整个内容层最外层（scaleEffect + offset）——所有元素（背景/组框/
                // 曲线/节点/端口）一起变换，相对位置永不改变（用户要求：手势操作 canvas 最外层）
                // 各元素只用画布坐标（node.x/node.y），不做任何 ×zoom/pan 换算
                ZStack(alignment: .topLeading) {
                    // 背景（空白处拖动 = 框选；点击取消选中；右键 = 画布菜单；画布平移由触控板两指负责）
                    Rectangle()
                        .fill(Color.primary.opacity(0.03))
                        .contentShape(Rectangle())
                        .gesture(selectionGesture)
                        .onTapGesture { selectedNodeIDs = [] }
                        .contextMenu { canvasContextMenu }

                    // 组框层（在节点下方）
                    ForEach(groupNodes) { node in
                        groupFrame(node)
                            .position(x: node.x + groupWidth(node) / 2,
                                      y: node.y + groupHeight(node) / 2)
                            .onTapGesture { selectedNodeIDs = [node.id] }
                            .gesture(dragGroup(node))
                    }

                    // 下层连线层（曲线主体）：渲染在卡片**之下**（穿过无关卡片时被卡片盖住）
                    // 曲线终点 = 卡片边缘线；端口端头（边缘→端口中心）由上层 PortStub 补画覆盖在卡片上
                    if let bounds = contentBounds {
                        EdgeCanvasView(timeline: timeline,
                                       dragState: dragState,
                                       bounds: bounds,
                                       connecting: connecting)
                    }

                    // 节点层：节点在内部用画布坐标定位（position = screenCenter 画布坐标）
                    ForEach(regularNodes) { node in
                        nodeView(node)
                            .contextMenu { nodeContextMenu(node) }
                    }

                    // 上层连线层（端口端头短段）：渲染在**卡片之上**（曲线直达端口圆点中心）
                    if let bounds = contentBounds {
                        PortStubCanvasView(timeline: timeline,
                                           dragState: dragState,
                                           bounds: bounds,
                                           connecting: connecting)
                    }

                    // 框选矩形（最上层）：画布坐标，内容层统一变换自动缩放平移
                    if let s = selectionStart, let c = selectionCurrent {
                        selectionRectView(from: s, to: c)
                    }
                }
                // 统一变换：缩放（topLeading 锚点）+ 平移——作用于整个画布内容
                .scaleEffect(zoom, anchor: .topLeading)
                .offset(x: pan.width, y: pan.height)
            }
            // 首次布局完成（尺寸非零）时居中内容（节点 1:1 显示，画布无限、平移浏览）
            .onAppear { tryCenterIfNeeded(geo.size) }
            .onChange(of: geo.size) { tryCenterIfNeeded($0) }
            // 嵌套导航切换：重置视图（didFit 归零 → 重新居中/适应内容）
            .onChange(of: resetToken) { _ in
                didFit = false
                tryCenterIfNeeded(geo.size)
            }
            // Delete 键删除（隐藏按钮 keyboardShortcut 兜底——onDeleteCommand 依赖焦点，不一定触发）
            .overlay(
                Button { deleteSelection() } label: { EmptyView() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            )
            .onDeleteCommand { deleteSelection() }
            // 重命名弹窗（节点右键菜单触发）
            .alert(L10n.tr("重命名节点", "Rename Node"), isPresented: renameAlertBinding) {
                TextField(L10n.tr("名称", "Name"), text: renameTitleBinding)
                Button(L10n.tr("确定", "OK")) { renameTarget = nil }
                Button(L10n.tr("取消", "Cancel"), role: .cancel) { renameTarget = nil }
            }
        }
    }

    // MARK: - 右键菜单（二级分栏：一级 = 操作类目，二级 = 具体项）

    /// 节点右键菜单：编辑（复制/重命名）/（module）打开内部 / 删除
    @ViewBuilder
    private func nodeContextMenu(_ node: NodeConfig) -> some View {
        Menu {
            Button {
                selectedNodeIDs = [node.id]
                onCopy()
            } label: {
                Label(L10n.tr("复制", "Copy"), systemImage: "doc.on.doc")
            }
            Button {
                renameTarget = node
            } label: {
                Label(L10n.tr("重命名…", "Rename…"), systemImage: "pencil")
            }
        } label: {
            Label(L10n.tr("编辑", "Edit"), systemImage: "pencil")
        }
        if node.type == .module {
            Button {
                onOpenModule(node.id)
            } label: {
                Label(L10n.tr("打开内部…", "Open Inside…"), systemImage: "folder")
            }
        }
        Button {
            deleteNode(node.id)
        } label: {
            Label(L10n.tr("删除", "Delete"), systemImage: "trash")
        }
    }

    /// 画布空白右键菜单：编辑（全选/粘贴）/ 添加节点（按大类分栏）/ 视图（适应画布/自动整理）
    @ViewBuilder
    private var canvasContextMenu: some View {
        Menu {
            Button {
                selectedNodeIDs = Set(regularNodes.map(\.id))
            } label: {
                Label(L10n.tr("全选", "Select All"), systemImage: "square.dashed")
            }
            Button {
                onPaste()
            } label: {
                Label(L10n.tr("粘贴", "Paste"), systemImage: "doc.on.clipboard")
            }
        } label: {
            Label(L10n.tr("编辑", "Edit"), systemImage: "pencil")
        }
        Menu {
            addNodeSubmenus
        } label: {
            Label(L10n.tr("添加节点", "Add Node"), systemImage: "plus.circle")
        }
        Menu {
            Button {
                onFit()
            } label: {
                Label(L10n.tr("适应画布", "Fit Canvas"), systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Button {
                onLayout()
            } label: {
                Label(L10n.tr("自动整理", "Auto Layout"), systemImage: "wand.and.stars")
            }
        } label: {
            Label(L10n.tr("视图", "View"), systemImage: "eye")
        }
    }

    /// 添加节点二级分栏：按大类分组列出全部可用节点类型（与工具箱同规则隐藏废弃/连接器/简化实现）
    @ViewBuilder
    private var addNodeSubmenus: some View {
        let hidden: Set<NodeType> = [.recognizer, .set, .toggle, .mouse, .freeze, .moduleInput, .moduleOutput, .switch, .hud]
        let visible = NodeType.allCases.filter { !hidden.contains($0) }
        let grouped = Dictionary(grouping: visible) { $0.category }
        ForEach(NodeCategory.allCases, id: \.self) { cat in
            if let types = grouped[cat], !types.isEmpty {
                Menu {
                    ForEach(types, id: \.self) { type in
                        Button {
                            onAddNode(type)
                        } label: {
                            Text(type.displayName)
                        }
                    }
                } label: {
                    Text(cat.displayName)
                }
            }
        }
    }

    // MARK: - 重命名弹窗

    /// 弹窗显隐（由 renameTarget 驱动）
    private var renameAlertBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
    }

    /// 重命名输入（实时写回节点 title；清空 = 恢复默认名）
    private var renameTitleBinding: Binding<String> {
        Binding(get: { renameTarget?.title ?? "" },
                set: { v in
                    guard let t = renameTarget,
                          let idx = timeline.nodes.firstIndex(where: { $0.id == t.id }) else { return }
                    timeline.nodes[idx].title = v.isEmpty ? nil : v
                })
    }

    /// 删除单个节点及其边（右键菜单用）
    private func deleteNode(_ id: UUID) {
        timeline.nodes.removeAll { $0.id == id }
        timeline.edges.removeAll { $0.from.nodeID == id || $0.to.nodeID == id }
        timeline.entryNodeIDs.removeAll { $0 == id }
        selectedNodeIDs.remove(id)
    }

    private func tryCenterIfNeeded(_ size: CGSize) {
        if !didFit, size.width > 0, size.height > 0 {
            centerContent(size)
            didFit = true
        }
    }

    /// 节点卡片估算高度（画布包围盒/居中/端口对齐用；卡片实际渲染高度自适应内容）
    /// 说明：不用 GeometryReader 实测——实测的 preference 上报会导致 screenCenter 用"上一帧实测值"
    /// 渲染（与端口坐标/拖拽命中的数据坐标不一致 → 曲线错位 + 拖不动）；估算在 100% 下接近实际
    private func displayHeight(_ node: NodeConfig) -> CGFloat {
        timeline.nodeDisplayHeight(node)
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
            return node.y + Double(displayHeight(node))
        }.max()!
        pan = CGSize(width: size.width / 2 - (minX + maxX) / 2,
                     height: size.height / 2 - (minY + maxY) / 2)
    }

    // MARK: - 组框

    /// 单个节点卡片视图（含内联参数编辑）
    /// @ViewBuilder 条件返回（不用 AnyView）——AnyView 类型擦除会破坏 ForEach 的 node.id diff，
    /// 导致拖动中每帧重建整个子树 → 闪烁
    /// 节点内部自行定位（screenCenter = 数据位置×zoom + pan；拖拽偏移来自 dragState 订阅）
    /// 节点拖动由 AppKit DragMonitor 处理（非 SwiftUI 手势，无取消重启 → 不横跳）
    @ViewBuilder
    private func nodeView(_ node: NodeConfig) -> some View {
        if let idx = timeline.nodes.firstIndex(where: { $0.id == node.id }) {
            TimelineNodeView(
                node: node,
                isSelected: selectedNodeIDs.contains(node.id),
                zoom: zoom,
                dragState: dragState,
                // 进行中连线的输出类型：端口行据此高亮可连端口 / 变灰不可连端口
                activeConnectType: connecting.map { c in
                    NodeTypeDef.outputSockets(of: c.from).first(where: { $0.name == c.fromPort })?.type
                } ?? nil,
                timeline: timeline,
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
                onConnectEnd: { n, port, p in finishConnect(from: n, fromPort: port, at: p) },
                onOpenModule: { onOpenModule(node.id) },
                // 节点原点 = (node.x, node.y) 画布坐标；节点内部用 transformEffect 渲染平移定位
                // （顶部恒等于 node.y，与卡片总高度无关——position 中心定位会使顶部偏移导致端口错位）
                screenOrigin: CGPoint(x: node.x, y: node.y),
                onTapNode: { handleHeaderTap(node) }
            )
        }
    }

    /// 拖拽结束提交：屏幕像素总位移 → 画布坐标，一次性写入数据（拖动中不写数据 → 不抖动）
    private func commitDrag(_ total: CGSize) {
        guard let id = dragState.nodeID,
              let idx = timeline.nodes.firstIndex(where: { $0.id == id }) else { return }
        timeline.nodes[idx].x += Double(total.width / zoom)
        timeline.nodes[idx].y += Double(total.height / zoom)
        selectedNodeIDs = [id]
    }

    /// 命中检测：画布视图坐标点（y 向下，DragMonitor isFlipped+convert 保证）→ 节点 id
    /// 命中头部+端口区；nil = 空白/编辑器控件区/端口行，放行
    /// （头部+端口区 = 节点可拖动区域；端口行是连线把手放行给 SwiftUI 连线手势，编辑器是控件区放行）
    private func hitTestNode(atView p: CGPoint) -> UUID? {
        // 画布视图坐标 → 画布坐标
        let canvas = CGPoint(x: (p.x - pan.width) / zoom,
                             y: (p.y - pan.height) / zoom)
        let w = TimelineCanvasMetrics.nodeWidth
        for node in regularNodes {
            let portRows = max(NodeTypeDef.inputSockets(of: node).count,
                               NodeTypeDef.outputSockets(of: node).count)
            let hitH = TimelineCanvasMetrics.headerHeight + CGFloat(portRows) * TimelineCanvasMetrics.portRowHeight
            if canvas.x >= node.x, canvas.x <= node.x + w,
               canvas.y >= node.y, canvas.y <= node.y + hitH {
                return node.id
            }
        }
        return nil
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
                        .strokeBorder(selectedNodeIDs.contains(node.id) ? Color.accentColor : Color.primary.opacity(0.25),
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
                if groupDragOrigin?.id != node.id { groupDragOrigin = (node.id, node.x, node.y) }
                guard let origin = groupDragOrigin else { return }
                let dx = Double(value.translation.width / zoom)
                let dy = Double(value.translation.height / zoom)
                let w = groupWidth(node)
                let h = groupHeight(node)
                timeline.nodes[idx].x = origin.x + dx
                timeline.nodes[idx].y = origin.y + dy
                for i in timeline.nodes.indices where i != idx {
                    let n = timeline.nodes[i]
                    let cx = n.x + TimelineCanvasMetrics.nodeWidth / 2
                    let cy = n.y + Double(displayHeight(n)) / 2
                    if cx >= origin.x, cx <= origin.x + Double(w),
                       cy >= origin.y, cy <= origin.y + Double(h) {
                        timeline.nodes[i].x = n.x + dx
                        timeline.nodes[i].y = n.y + dy
                    }
                }
            }
            .onEnded { _ in groupDragOrigin = nil }
    }

    // MARK: - 手势

    /// 头部/空白点击：选中节点 + 双击（<0.3s）module 进入内部
    private func handleHeaderTap(_ node: NodeConfig) {
        selectedNodeIDs = [node.id]
        if let last = lastHeaderTap, last.id == node.id,
           Date().timeIntervalSince(last.time) < 0.3 {
            lastHeaderTap = nil
            if node.type == .module { onOpenModule(node.id) }
        } else {
            lastHeaderTap = (node.id, Date())
        }
    }

    // MARK: - 框选（空白处拖动拉矩形，松开选中框内节点）

    /// 框选手势：DragGesture 的 location 是内容层本地坐标 = 画布坐标（scaleEffect 是渲染变换，
    /// 不影响布局坐标系；hit-test 已按缩放/平移逆变换回画布坐标）
    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if selectionStart == nil { selectionStart = value.location }
                selectionCurrent = value.location
            }
            .onEnded { _ in
                defer { selectionStart = nil; selectionCurrent = nil }
                guard let s = selectionStart, let c = selectionCurrent else { return }
                let rect = CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                                  width: abs(c.x - s.x), height: abs(c.y - s.y))
                selectedNodeIDs = timeline.nodes(in: rect,
                                                 nodeWidth: CGFloat(TimelineCanvasMetrics.nodeWidth))
            }
    }

    /// 框选矩形（虚线框 + 半透明填充），画布坐标
    private func selectionRectView(from s: CGPoint, to c: CGPoint) -> some View {
        let x = min(s.x, c.x), y = min(s.y, c.y)
        let w = abs(c.x - s.x), h = abs(c.y - s.y)
        return Rectangle()
            .fill(Color.accentColor.opacity(0.12))
            .overlay(
                Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .frame(width: w, height: h)
            .position(x: x + w / 2, y: y + h / 2)
            .allowsHitTesting(false)
    }

    // MARK: - 连线

    /// 完成连线：命中目标输入端口且形状匹配才连接
    private func finishConnect(from: NodeConfig, fromPort: String, at point: CGPoint) {
        defer { connecting = nil }
        guard let fromType = NodeTypeDef.outputSockets(of: from).first(where: { $0.name == fromPort })?.type else { return }
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
            let sockets = NodeTypeDef.inputSockets(of: node)
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
            return node.y + Double(displayHeight(node))
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
        guard !selectedNodeIDs.isEmpty else { return }
        timeline.nodes.removeAll { selectedNodeIDs.contains($0.id) }
        timeline.edges.removeAll { selectedNodeIDs.contains($0.from.nodeID) || selectedNodeIDs.contains($0.to.nodeID) }
        timeline.entryNodeIDs.removeAll { selectedNodeIDs.contains($0) }
        selectedNodeIDs = []
    }

    private func node(_ id: UUID) -> NodeConfig? {
        timeline.nodes.first { $0.id == id }
    }
}

/// 下层连线层（曲线主体）：渲染在卡片之下；画布坐标绘制，缩放/平移由外层内容层统一 scaleEffect+offset 负责
/// 仅订阅 dragState（拖拽跟随）。Canvas 会裁剪到自身 bounds，尺寸须覆盖内容包围盒
private struct EdgeCanvasView: View {
    let timeline: TimelineConfig
    @ObservedObject var dragState: DragState
    let bounds: CGRect
    let connecting: (from: NodeConfig, fromPort: String, current: CGPoint)?

    var body: some View {
        Canvas { context, _ in
            // 画布坐标 → Canvas 本地坐标（本地原点 = 内容包围盒左上角）
            context.translateBy(x: -(bounds.minX - 20), y: -(bounds.minY - 20))
            for edge in timeline.edges { drawEdge(edge, in: &context) }
            if let c = connecting { drawConnectingLine(c, in: &context) }
        }
        .frame(width: bounds.width + 40, height: bounds.height + 40)
        .offset(x: bounds.minX - 20, y: bounds.minY - 20)
        .allowsHitTesting(false)
    }

    private func node(_ id: UUID) -> NodeConfig? {
        timeline.nodes.first { $0.id == id }
    }

    /// 端口实际画布坐标：正在拖拽的节点端口叠加偏移（画布坐标，与节点/上层一致）
    private func portPoint(_ node: NodeConfig, _ base: CGPoint) -> CGPoint {
        guard dragState.nodeID == node.id else { return base }
        return CGPoint(x: base.x + dragState.offset.width,
                       y: base.y + dragState.offset.height)
    }

    private func drawEdge(_ edge: Edge, in context: inout GraphicsContext) {
        guard let from = node(edge.from.nodeID), let to = node(edge.to.nodeID),
              from.type != .group, to.type != .group else { return }
        // 输出端口：按 from.portName 找注册表索引；输入端口：按 to.portName 找索引（找不到=入口注入边，画到节点头部）
        guard let fromIdx = NodeTypeDef.outputSockets(of: from).firstIndex(where: { $0.name == edge.from.portName }) else { return }
        // 曲线主体终点 = 卡片边缘线（端口端头由上层 PortStub 补画覆盖在卡片上）
        let start = portPoint(from, from.outputEdgePoint(index: fromIdx))
        let end: CGPoint
        if let toIdx = NodeTypeDef.inputSockets(of: to).firstIndex(where: { $0.name == edge.to.portName }) {
            end = portPoint(to, to.inputEdgePoint(index: toIdx))
        } else {
            end = portPoint(to, CGPoint(x: to.x, y: to.y + TimelineCanvasMetrics.headerHeight / 2))
        }
        let dx = max(abs(end.x - start.x), 40) * TimelineCanvasMetrics.curveFactor
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end,
                      control1: CGPoint(x: start.x + dx, y: start.y),
                      control2: CGPoint(x: end.x - dx, y: end.y))
        // 连线颜色 = 输出端口类型颜色（曲线一眼看出传的是什么类型）
        context.stroke(path, with: .color(edgeTypeColor(timeline, from: from, port: edge.from.portName)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private func drawConnectingLine(_ c: (from: NodeConfig, fromPort: String, current: CGPoint),
                                    in context: inout GraphicsContext) {
        guard let idx = NodeTypeDef.outputSockets(of: c.from).firstIndex(where: { $0.name == c.fromPort }) else { return }
        var path = Path()
        path.move(to: portPoint(c.from, c.from.outputEdgePoint(index: idx)))
        path.addLine(to: c.current)
        context.stroke(path, with: .color(edgeTypeColor(timeline, from: c.from, port: c.fromPort)),
                       style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
    }
}

/// 上层连线层：端口端头短段（卡片边缘 → 端口圆点中心），渲染在**卡片之上**
/// 配合下层 EdgeCanvasView（曲线主体到卡片边缘）——视觉上曲线直达端口圆点中心，
/// 且只有相连端口的端头覆盖卡片，曲线中段穿过无关卡片时被卡片盖住
/// 画布坐标绘制，缩放/平移由外层内容层统一 scaleEffect+offset 负责
private struct PortStubCanvasView: View {
    let timeline: TimelineConfig
    @ObservedObject var dragState: DragState
    let bounds: CGRect
    let connecting: (from: NodeConfig, fromPort: String, current: CGPoint)?

    var body: some View {
        Canvas { context, _ in
            context.translateBy(x: -(bounds.minX - 20), y: -(bounds.minY - 20))
            for edge in timeline.edges { drawStubs(edge, in: &context) }
            if let c = connecting { drawConnectingStub(c, in: &context) }
        }
        .frame(width: bounds.width + 40, height: bounds.height + 40)
        .offset(x: bounds.minX - 20, y: bounds.minY - 20)
        .allowsHitTesting(false)
    }

    private func node(_ id: UUID) -> NodeConfig? {
        timeline.nodes.first { $0.id == id }
    }

    /// 端口实际画布坐标（拖拽中叠加偏移，与下层/节点一致）
    private func portPoint(_ node: NodeConfig, _ base: CGPoint) -> CGPoint {
        guard dragState.nodeID == node.id else { return base }
        return CGPoint(x: base.x + dragState.offset.width,
                       y: base.y + dragState.offset.height)
    }

    /// 端口端头短段：端口圆点中心 → 卡片边缘（覆盖在卡片上，曲线直达端口）
    private func drawStubs(_ edge: Edge, in context: inout GraphicsContext) {
        guard let from = node(edge.from.nodeID), let to = node(edge.to.nodeID),
              from.type != .group, to.type != .group else { return }
        guard let fromIdx = NodeTypeDef.outputSockets(of: from).firstIndex(where: { $0.name == edge.from.portName }) else { return }
        let style = StrokeStyle(lineWidth: 2, lineCap: .round)
        var p = Path()
        // 输出端头：端口中心 → 右边缘
        let outC = portPoint(from, from.outputPortPoint(index: fromIdx))
        let outE = portPoint(from, from.outputEdgePoint(index: fromIdx))
        p.move(to: outC)
        p.addLine(to: outE)
        // 输入端头：左边缘 → 端口中心
        if let toIdx = NodeTypeDef.inputSockets(of: to).firstIndex(where: { $0.name == edge.to.portName }) {
            let inC = portPoint(to, to.inputPortPoint(index: toIdx))
            let inE = portPoint(to, to.inputEdgePoint(index: toIdx))
            p.move(to: inE)
            p.addLine(to: inC)
        }
        // 端头颜色与曲线主体一致（输出端口类型颜色）
        context.stroke(p, with: .color(edgeTypeColor(timeline, from: from, port: edge.from.portName)), style: style)
    }

    /// 进行中连线的端头：输出端口中心 → 右边缘
    private func drawConnectingStub(_ c: (from: NodeConfig, fromPort: String, current: CGPoint),
                                    in context: inout GraphicsContext) {
        guard let idx = NodeTypeDef.outputSockets(of: c.from).firstIndex(where: { $0.name == c.fromPort }) else { return }
        var p = Path()
        let outC = portPoint(c.from, c.from.outputPortPoint(index: idx))
        let outE = portPoint(c.from, c.from.outputEdgePoint(index: idx))
        p.move(to: outC)
        p.addLine(to: outE)
        context.stroke(p, with: .color(edgeTypeColor(timeline, from: c.from, port: c.fromPort)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }
}

/// 连线颜色 = 输出端口类型颜色（曲线一眼看出传的是什么类型）
/// generic 输出沿数据流推导实际透传类型（与端口形状内嵌一致）；推导不出用泛型紫色
fileprivate func edgeTypeColor(_ timeline: TimelineConfig, from node: NodeConfig, port: String) -> Color {
    let type = timeline.resolvedPortType(of: node.id, port: port, isInput: false)
        ?? NodeTypeDef.outputSockets(of: node).first(where: { $0.name == port })?.type
        ?? .generic
    return type.socketColor
}
