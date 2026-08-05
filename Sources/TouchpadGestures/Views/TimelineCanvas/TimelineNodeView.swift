import SwiftUI
// 显式导入：消除与 SwiftUI.Edge 的同名歧义
import struct GestureEngine.Edge
import GestureEngine

// MARK: - 画布常量

enum TimelineCanvasMetrics {
    /// 节点头部高度（icon + 标题 + 摘要）
    static let headerHeight: CGFloat = 42
    /// 端口行高（每个 socket 一行）
    static let portRowHeight: CGFloat = 18
    /// 节点宽度（端口位置由此推导）
    static let nodeWidth: CGFloat = 170
    /// 端口圆点半径
    static let portRadius: CGFloat = 5
    /// 连线命中检测半径（画布坐标）
    static let portHitRadius: CGFloat = 24
    /// 连线曲率（水平控制点偏移比例）
    static let curveFactor: CGFloat = 0.5
    /// 内联编辑器每行高度
    static let paramRowHeight: CGFloat = 36
    /// 端口圆点中心到卡片边缘的水平距离（portArea padding 6 + SocketShapeView 半宽 4.5）
    /// 曲线端点必须对齐这里（而非卡片边缘线），否则曲线"停在边缘、连不到端口圆点"
    static let portInset: CGFloat = 6 + 4.5

    /// 节点基础高度（头部 + 端口区；无端口节点 = 头部）
    static func nodeBaseHeight(portRows: Int) -> CGFloat {
        headerHeight + CGFloat(max(portRows, 0)) * portRowHeight + 6
    }

    /// 节点卡片总高度：未选中 = 基础高度；选中展开 = 基础 + 参数/连线行数
    static func nodeHeight(portRows: Int, paramRows: Int, edgeRows: Int, expanded: Bool) -> CGFloat {
        let base = nodeBaseHeight(portRows: portRows)
        guard expanded else { return base }
        let rows = max(paramRows + edgeRows, 1)
        return base + 12 + CGFloat(rows) * paramRowHeight + 8
    }
}

extension NodeConfig {
    /// 节点左上角画布坐标
    var canvasPoint: CGPoint { CGPoint(x: x, y: y) }
    /// 输入端口（左侧）画布坐标：第 index 个输入 socket 的位置（对齐端口圆点中心，非卡片边缘线）
    func inputPortPoint(index: Int) -> CGPoint {
        CGPoint(x: x + TimelineCanvasMetrics.portInset, y: y + TimelineCanvasMetrics.headerHeight
            + CGFloat(index) * TimelineCanvasMetrics.portRowHeight
            + TimelineCanvasMetrics.portRowHeight / 2)
    }
    /// 输出端口（右侧）画布坐标：第 index 个输出 socket 的位置（对齐端口圆点中心，非卡片边缘线）
    func outputPortPoint(index: Int) -> CGPoint {
        CGPoint(x: x + TimelineCanvasMetrics.nodeWidth - TimelineCanvasMetrics.portInset,
                y: y + TimelineCanvasMetrics.headerHeight
                    + CGFloat(index) * TimelineCanvasMetrics.portRowHeight
                    + TimelineCanvasMetrics.portRowHeight / 2)
    }
    /// 输出端口在卡片边缘线上的点（曲线主体终点；上层再补画「边缘→端口中心」短段）
    func outputEdgePoint(index: Int) -> CGPoint {
        CGPoint(x: x + TimelineCanvasMetrics.nodeWidth, y: y + TimelineCanvasMetrics.headerHeight
            + CGFloat(index) * TimelineCanvasMetrics.portRowHeight
            + TimelineCanvasMetrics.portRowHeight / 2)
    }
    /// 输入端口在卡片边缘线上的点（曲线主体终点）
    func inputEdgePoint(index: Int) -> CGPoint {
        CGPoint(x: x, y: y + TimelineCanvasMetrics.headerHeight
            + CGFloat(index) * TimelineCanvasMetrics.portRowHeight
            + TimelineCanvasMetrics.portRowHeight / 2)
    }
}

extension TimelineConfig {
    /// 节点卡片近似显示高度（恒展开）——画布包围盒/适应画布/自动布局的估算值
    /// 卡片实际高度自适应内容（VStack + fixedSize），此处仅用于布局估算：
    /// module 按端口行数算（备注+输入+输出+按钮），普通节点按参数行算，无参数紧凑显示
    func nodeDisplayHeight(_ node: NodeConfig) -> CGFloat {
        let portRows = max(NodeTypeDef.inputSockets(of: node).count,
                           NodeTypeDef.outputSockets(of: node).count)
        let base = TimelineCanvasMetrics.nodeBaseHeight(portRows: portRows)
        let edgeRows = incomingEdges(to: node.id).count + outgoingEdges(from: node.id).count
        let editorH: CGFloat
        if node.type == .module {
            // ModuleEditorView：备注 + 输入标题 + 端口n + 输出标题 + 端口m + 打开按钮
            let editorRows = 4 + (node.params.moduleInputs?.count ?? 0) + (node.params.moduleOutputs?.count ?? 0)
            editorH = CGFloat(editorRows) * 22
        } else {
            let rows = node.params.typedRows.count
            editorH = rows == 0 ? 22 : CGFloat(rows) * 34
        }
        return base + 12 + editorH + CGFloat(edgeRows) * 18 + 8
    }
}

// MARK: - 节点视图

/// 画布上的单个节点卡片（Blender 风格）：
/// - 头部（icon + 标题 + 摘要）+ 左右两侧按注册表列出多 socket 端口（形状 = 类型）
/// - 选中时卡片下方展开内联参数编辑 + 连线管理（编辑选项都在卡片内）
/// - 连线从输出 socket 拖出，目标 socket 形状匹配才能连
///
/// 定位与拖拽（官方推荐模式）：
/// - `screenCenter` 由画布层换算（数据位置×zoom + pan，不含拖拽偏移）
/// - 内部 `@GestureState dragOffset` 随手势生命周期自动重置——拖动中只有**本视图**重算
///   （position 跟随），不触发画布层重算 → 其他节点/编辑器/连线层不动 → 不闪烁
struct TimelineNodeView: View {
    let node: NodeConfig
    let isSelected: Bool
    /// 画布缩放（拖拽连线端点的屏幕位移需换算回画布坐标；节点自身按 zoom 缩放）
    let zoom: CGFloat
    /// 拖拽偏移状态（AppKit DragMonitor 增量驱动；仅被拖节点用 offset 渲染平移，连线层用其跟随）
    @ObservedObject var dragState: DragState
    /// 进行中连线的输出类型（非 nil 表示正在拖拽连线）——端口行据此高亮可连端口 / 变灰不可连端口
    let activeConnectType: SocketType?
    /// 全图配置（generic 端口沿数据流推导实际透传类型的依据）
    let timeline: TimelineConfig
    /// 绑定可选项（region/event 参数 Picker 数据源）
    let events: [EventConfig]
    let regions: [RegionConfig]
    /// 参数编辑绑定（写回 timeline）
    @Binding var params: NodeParams
    /// 本节点的入/出边（展开时列出并支持删除）
    let edges: [Edge]
    let onDeleteEdge: (Edge) -> Void
    /// 输出端口拖拽中：报告起点节点 + 端口名 + 当前端点（画布坐标）
    let onConnectDrag: (NodeConfig, String, CGPoint) -> Void
    /// 输出端口拖拽结束：画布侧做命中检测（形状匹配才连接）
    let onConnectEnd: (NodeConfig, String, CGPoint) -> Void
    /// 打开模块内部（进入嵌套画布编辑子图）
    let onOpenModule: () -> Void
    /// 节点原点（node.x, node.y）画布坐标——节点用 transformEffect 渲染平移定位，
    /// 顶部恒等于 node.y（与卡片总高度无关，端口坐标基于 node.y + header + index*row 精确对齐）
    let screenOrigin: CGPoint
    /// 点击（无位移按下-抬起）：选中 + 双击进模块
    let onTapNode: () -> Void

    /// 注册表端口列表（module 用 params 动态声明）
    private var inputSockets: [SocketDef] { NodeTypeDef.inputSockets(of: node) }
    private var outputSockets: [SocketDef] { NodeTypeDef.outputSockets(of: node) }
    private var portRows: Int { max(inputSockets.count, outputSockets.count) }

    /// 头部摘要：module 显示「端口数 + 用途备注」（折叠时一眼看出组是干嘛的）；其他节点显示参数
    private var summaryText: String {
        if node.type == .module {
            let ins = node.params.moduleInputs?.count ?? 0
            let outs = node.params.moduleOutputs?.count ?? 0
            let note = node.params.note ?? ""
            return note.isEmpty ? "\(ins)入 \(outs)出" : "\(ins)入 \(outs)出 · \(note)"
        }
        return node.paramsSummary
    }

    var body: some View {
        // 组框由画布层渲染，不在此处画卡片
        if node.type == .group {
            EmptyView()
        } else {
            // 内容：头部 + 端口区 + 编辑器（高度自适应内容，无底部空白/溢出）
            VStack(alignment: .leading, spacing: 0) {
                headerView
                portArea
                Divider().padding(.top, 2)
                if node.type == .module {
                    ModuleEditorView(params: $params, onOpenModule: onOpenModule)
                } else {
                    NodeParamsEditorView(
                        params: $params,
                        nodeType: node.type,
                        events: events,
                        regions: regions
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                edgeList
            }
            .frame(width: TimelineCanvasMetrics.nodeWidth, alignment: .topLeading)
            // 垂直方向强制用内容理想高度（VStack 默认 flexible，会填满画布全屏建议 → 卡片虚高）
            .fixedSize(horizontal: false, vertical: true)
            // 背景跟随内容尺寸（避免 ZStack flexible 背景被画布全屏建议撑满）
            .background(cardBackground)
            .contentShape(Rectangle())
            // 点击（选中 + 双击进模块）；节点拖动由 AppKit DragMonitor 处理（不在此处挂 SwiftUI 手势）
            .onTapGesture { onTapNode() }
            // 节点自身定位（渲染平移，不参与布局）：
            // ① transformEffect(screenOrigin)：顶部恒等于 node.y（卡片总高度无关，端口精确对齐）
            // ② transformEffect(拖拽偏移)：dragState.offset 已是画布坐标，外层统一缩放后视觉=屏幕像素
            // 缩放/平移由外层内容层统一 scaleEffect+offset 负责；渲染变换 hit-test 跟随
            .transformEffect(CGAffineTransform(translationX: screenOrigin.x, y: screenOrigin.y))
            .transformEffect(CGAffineTransform(
                translationX: dragState.nodeID == node.id ? dragState.offset.width : 0,
                y: dragState.nodeID == node.id ? dragState.offset.height : 0))
        }
    }

    // MARK: - 卡片结构

    /// 头部（icon + 标题 + 参数摘要）——节点拖拽把手
    private var headerView: some View {
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
            Text(summaryText)
                .font(.caption2).monospaced()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(height: TimelineCanvasMetrics.headerHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .help(L10n.tr("拖动头部移动节点", "Drag header to move"))
    }

    /// 端口区：左侧输入 / 右侧输出（形状 = 类型）
    private var portArea: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(inputSockets.indices, id: \.self) { i in
                    inputPortRow(socket: inputSockets[i], index: i)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(outputSockets.indices, id: \.self) { i in
                    outputPortRow(socket: outputSockets[i], index: i)
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(minHeight: CGFloat(portRows) * TimelineCanvasMetrics.portRowHeight,
               alignment: .top)
    }

    /// 连线管理（入/出边 + 删除）
    @ViewBuilder
    private var edgeList: some View {
        if !edges.isEmpty {
            Divider().padding(.horizontal, 10)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(edges, id: \.self) { edge in
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text(edge.from.portName + " → " + edge.to.portName)
                            .font(.system(size: 9)).monospaced()
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            onDeleteEdge(edge)
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 9))
                                .foregroundStyle(.red.opacity(0.8))
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.tr("删除连线", "Remove edge"))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(node.type == .pipeOut
                  ? AnyShapeStyle(Color.yellow.opacity(0.15))
                  : AnyShapeStyle(.background.opacity(0.9)))
            // 注意：不加 .shadow —— macOS 上 shadow 在视图移动时每帧重栅格化导致闪烁（拖拽闪烁源之一）；
            // 选中态用 accent 粗边框区分，已足够
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(node.type == .pipeOut
                                  ? (isSelected ? Color.yellow : Color.yellow.opacity(0.6))
                                  : (isSelected ? Color.accentColor : Color.primary.opacity(0.15)),
                                  lineWidth: isSelected ? 2 : 1)
            )
    }

    // MARK: - 端口行

    /// 端口在"连线中"时的可连状态：无连线中 = nil；匹配（同类型或泛型）= 高亮；不匹配 = 变灰
    private func connectState(_ socket: SocketDef) -> ConnectState {
        guard let t = activeConnectType else { return .idle }
        return NodeTypeDef.canConnect(from: t, to: socket.type) ? .match : .mismatch
    }

    /// 端口显示类型：声明为 generic 的端口沿数据流推导实际透传类型（六边形内嵌该类型）；
    /// 推导不出（无入边/环）→ 仍为 generic（纯空心六边形 any）
    private func displayType(_ socket: SocketDef, isInput: Bool) -> SocketType {
        guard socket.type == .generic else { return socket.type }
        return timeline.resolvedPortType(of: node.id, port: socket.name, isInput: isInput) ?? .generic
    }

    /// 输入端口行：形状点 + 名称 + 类型短名（左对齐）
    private func inputPortRow(socket: SocketDef, index: Int) -> some View {
        HStack(spacing: 3) {
            portShape(socket, isInput: true)
            Text(socket.name)
                .font(.system(size: 8)).monospaced()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(displayType(socket, isInput: true).shortName)
                .font(.system(size: 7))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: TimelineCanvasMetrics.portRowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(socket.name + " · " + socket.type.displayName)
    }

    /// 输出端口行：名称 + 类型短名 + 形状点（右对齐，带拖拽连线把手）
    private func outputPortRow(socket: SocketDef, index: Int) -> some View {
        HStack(spacing: 3) {
            Spacer(minLength: 0)
            Text(displayType(socket, isInput: false).shortName)
                .font(.system(size: 7))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(socket.name)
                .font(.system(size: 8)).monospaced()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            portShape(socket, isInput: false)
        }
        .frame(height: TimelineCanvasMetrics.portRowHeight, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    onConnectDrag(node, socket.name, CGPoint(
                        x: node.outputPortPoint(index: index).x + value.translation.width / zoom,
                        y: node.outputPortPoint(index: index).y + value.translation.height / zoom))
                }
                .onEnded { value in
                    onConnectEnd(node, socket.name, CGPoint(
                        x: node.outputPortPoint(index: index).x + value.translation.width / zoom,
                        y: node.outputPortPoint(index: index).y + value.translation.height / zoom))
                }
        )
        .help(L10n.tr("拖拽连线", "Drag to connect") + " · " + socket.name + " · " + socket.type.displayName)
    }

    /// 端口形状：连线中匹配 → 高亮（accent 光晕）；不匹配 → 变灰（30%）
    /// generic 端口传 passthrough（推导出的实际透传类型）→ 空心六边形内嵌该类型形状
    @ViewBuilder
    private func portShape(_ socket: SocketDef, isInput: Bool) -> some View {
        let display = displayType(socket, isInput: isInput)
        let passthrough: SocketType? = (socket.type == .generic && display != .generic) ? display : nil
        switch connectState(socket) {
        case .idle, .match:
            SocketShapeView(type: socket.type, passthrough: passthrough)
                .opacity(connectState(socket) == .match ? 1.0 : 0.9)
                .shadow(color: connectState(socket) == .match ? .accentColor : .clear,
                        radius: connectState(socket) == .match ? 3 : 0)
        case .mismatch:
            SocketShapeView(type: socket.type, passthrough: passthrough)
                .opacity(0.3)
        }
    }

    /// 端口连线状态
    private enum ConnectState { case idle, match, mismatch }
}
