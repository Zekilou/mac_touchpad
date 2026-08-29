import SwiftUI
// 显式导入：消除与 SwiftUI.Edge 的同名歧义
import struct GestureEngine.Edge
import GestureEngine

/// 手势节点图主视图（v5 完全配置化 + 模块嵌套画布）
/// - 画布盛满整个窗口；左侧工具栏 overlay 悬浮
/// - 模块（module）节点：双击或「打开内部…」进入嵌套子图画布，顶部面包屑返回
/// - 触控板两指滑动平移 / 捏合缩放 / 节点拖拽 / 端口连线
struct TimelineGraphView: View {
    @Binding var timeline: TimelineConfig
    /// 绑定可选项（region/event 引用节点参数面板数据源）
    let events: [EventConfig]
    let regions: [RegionConfig]
    /// 手势启用开关（图的全局设置）
    @Binding var enabled: Bool

    @State private var zoom: CGFloat = 0.6
    @State private var pan: CGSize = .zero
    /// 选中节点集（多选：单击替换 / 框选批量 / Cmd+A 全选）
    @State private var selectedNodeIDs: Set<UUID> = []
    /// 复制剪贴板：选中节点 + 内部边（Cmd+C 存，Cmd+V 粘贴偏移）
    @State private var clipboard: (nodes: [NodeConfig], edges: [Edge])?
    /// 新节点自动排列计数（对角线排布避免重叠；工具箱与右键菜单共用）
    @State private var addCount = 0
    /// 左侧栏在窗口中的位置（触控板事件排除区域）
    @State private var paletteFrame: CGRect = .zero
    /// 嵌套画布导航栈：模块节点 ID（空 = 根图；[A,B] = A.subgraph 里的 B.subgraph）
    @State private var modulePath: [UUID] = []
    /// 导航切换令牌（+1 → 画布重置视图）
    @State private var resetToken = 0

    /// 当前正在编辑的图（按 modulePath 解析；解析失败——路径上 module 无子图——回退根图）
    private var currentTimeline: TimelineConfig {
        timeline.subgraph(at: modulePath) ?? timeline
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 画布盛满窗口（编辑当前图）
                TimelineCanvasView(timeline: canvasBinding,
                                   zoom: $zoom,
                                   pan: $pan,
                                   selectedNodeIDs: $selectedNodeIDs,
                                   excludeRect: $paletteFrame,
                                   events: events,
                                   regions: regions,
                                   onOpenModule: { id in openModule(id) },
                                   resetToken: resetToken,
                                   onCopy: { copySelection() },
                                   onPaste: { pasteSelection() },
                                   onFit: { fitToContent(geo.size) },
                                   onLayout: { autoLayout() },
                                   onAddNode: { addNode($0) })

                // 面包屑导航（进入模块后显示）：根 → 模块… → 当前
                if !modulePath.isEmpty {
                    breadcrumbBar(geo: geo)
                }

                // 左侧 overlay 工具栏（悬浮在画布上）；上报自身 frame 供画布排除触控板事件
                NodePaletteView(timeline: canvasBinding,
                                selectedNodeIDs: $selectedNodeIDs,
                                zoom: $zoom,
                                pan: $pan,
                                enabled: $enabled,
                                canvasSize: geo.size,
                                onFit: { fitToContent(geo.size) },
                                onLayout: { autoLayout() },
                                onAddNode: { addNode($0) })
                    .padding(10)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { paletteFrame = proxy.frame(in: .global) }
                                .onChange(of: proxy.frame(in: .global)) { paletteFrame = $0 }
                        }
                    )

                // 快捷键（隐藏按钮）：Cmd+A 全选 / Cmd+C 复制 / Cmd+V 粘贴
                hiddenShortcutButton("a") { selectAll() }
                hiddenShortcutButton("c") { copySelection() }
                hiddenShortcutButton("v") { pasteSelection() }
            }
        }
    }

    // MARK: - 嵌套导航

    /// 画布 Binding：get 解析当前图，set 递归写回根图
    private var canvasBinding: Binding<TimelineConfig> {
        Binding(
            get: { currentTimeline },
            set: { newValue in
                timeline = timeline.updatingSubgraph(at: modulePath, to: newValue)
            }
        )
    }

    /// 进入模块内部子图（防御：模块缺失 / 非 module / 无子图时拒绝进入，避免根图自引用）
    private func openModule(_ id: UUID) {
        guard let node = currentTimeline.nodes.first(where: { $0.id == id }),
              node.type == .module,
              node.subgraph != nil else { return }
        modulePath.append(id)
        resetToken += 1
        selectedNodeIDs = []
    }

    /// 面包屑点击返回：截断到该层级（点根 → 清空）
    private func popTo(_ index: Int) {
        guard index >= 0, index < modulePath.count else {
            modulePath.removeAll()
            resetToken += 1
            selectedNodeIDs = []
            return
        }
        modulePath.removeSubrange((index + 1)..<modulePath.count)
        resetToken += 1
        selectedNodeIDs = []
    }

    /// 面包屑栏（右上角）：根名称 → 各模块标题，可点击返回
    private func breadcrumbBar(geo: GeometryProxy) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    // 返回根
                    Button {
                        popTo(-1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.tr("返回根图", "Back to root"))
                    crumb(label: L10n.tr("根", "Root"), index: -1)
                    ForEach(Array(modulePath.enumerated()), id: \.element) { i, id in
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        if let node = nodeAt(id) {
                            crumb(label: node.title ?? node.type.displayName, index: i)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 1))
            .frame(maxWidth: min(geo.size.width - 300, 560))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(10)
        .allowsHitTesting(true)
    }

    private func crumb(label: String, index: Int) -> some View {
        Button {
            popTo(index)
        } label: {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(index == modulePath.count - 1 ? Color.accentColor : .secondary)
                .lineLimit(1)
        }
        .buttonStyle(.borderless)
        .help(L10n.tr("返回该层", "Jump here"))
    }

    /// 按 ID 找当前图里的模块节点（面包屑标题用）
    private func nodeAt(_ id: UUID) -> NodeConfig? {
        currentTimeline.nodes.first { $0.id == id }
    }

    // MARK: - 快捷键（Cmd+A 全选 / Cmd+C 复制 / Cmd+V 粘贴）

    /// 隐藏快捷键按钮：SwiftUI keyboardShortcut 注册窗口级快捷键（不渲染视觉，不挡交互）
    private func hiddenShortcutButton(_ key: Character, action: @escaping () -> Void) -> some View {
        Button(action: action) { EmptyView() }
            .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }

    /// Cmd+A：全选当前图所有节点（含组框）
    private func selectAll() {
        selectedNodeIDs = Set(currentTimeline.nodes.map(\.id))
    }

    /// Cmd+C：复制选中节点 + 两端都在选中集内的边
    private func copySelection() {
        let clip = currentTimeline.clipSelection(selectedNodeIDs)
        guard !clip.nodes.isEmpty else { return }
        clipboard = clip
    }

    /// Cmd+V：粘贴剪贴板（整体偏移 +24,+24，新 UUID，选中粘贴结果）
    private func pasteSelection() {
        guard let clip = clipboard else { return }
        var t = currentTimeline
        let (newNodes, newEdges) = t.pasteClip(clip.nodes, clip.edges, dx: 24, dy: 24)
        t.nodes.append(contentsOf: newNodes)
        t.edges.append(contentsOf: newEdges)
        // 只把无入边的新节点补为 entry（有入边的由边驱动，避免重复执行）
        let hasIncoming = Set(newEdges.map(\.to.nodeID))
        t.entryNodeIDs.append(contentsOf: newNodes.map(\.id).filter { !hasIncoming.contains($0) })
        canvasBinding.wrappedValue = t
        selectedNodeIDs = Set(newNodes.map(\.id))
    }

    /// 添加节点（工具箱 / 右键菜单共用）：对角线排布 + 补 entry + 选中
    private func addNode(_ type: NodeType) {
        let col = addCount % 8
        let row = addCount / 8
        var t = currentTimeline
        // module 节点初始化空子图：避免双击进入后把根图写进子图 → 执行期无限递归（H2）
        let node = NodeConfig(type: type,
                              x: Double(col * 220),
                              y: Double(row * 120),
                              subgraph: type == .module ? TimelineConfig(trigger: .onTick) : nil)
        t.nodes.append(node)
        t.entryNodeIDs.append(node.id)
        canvasBinding.wrappedValue = t
        addCount += 1
        selectedNodeIDs = [node.id]
    }

    // MARK: - 自动整理（数据流从左到右分层，group 保持原位；作用于当前编辑图）

    private func autoLayout() {
        // 传入节点显示高度：层内垂直按实际高度累计排布，卡片展开后不重叠
        let tl = currentTimeline
        let heights = Dictionary(uniqueKeysWithValues: tl.nodes
            .filter { $0.type != .group }
            .map { ($0.id, tl.nodeDisplayHeight($0)) })
        let positions = TimelineLayout.layoutPositions(of: tl, heights: heights)
        withAnimation(.easeInOut(duration: 0.3)) {
            var t = tl
            TimelineLayout.apply(positions, to: &t)
            canvasBinding.wrappedValue = t
        }
    }

    // MARK: - 适应画布（与 CanvasView 内算法一致，含组框；作用于当前编辑图）

    private func fitToContent(_ canvasSize: CGSize) {
        let nodes = currentTimeline.nodes
        guard !nodes.isEmpty else { zoom = 1; pan = .zero; return }
        let w = TimelineCanvasMetrics.nodeWidth
        let minX = nodes.map(\.x).min()!
        let maxX = nodes.map { node -> Double in
            node.type == .group ? node.x + (node.params.groupWidth ?? 300) : node.x + Double(w)
        }.max()!
        let minY = nodes.map(\.y).min()!
        let maxY = nodes.map { node -> Double in
            if node.type == .group { return node.y + (node.params.groupHeight ?? 200) }
            return node.y + Double(currentTimeline.nodeDisplayHeight(node))
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
