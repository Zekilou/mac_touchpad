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
    /// 输入端口（左侧）画布坐标：第 index 个输入 socket 的位置
    func inputPortPoint(index: Int) -> CGPoint {
        CGPoint(x: x, y: y + TimelineCanvasMetrics.headerHeight
            + CGFloat(index) * TimelineCanvasMetrics.portRowHeight
            + TimelineCanvasMetrics.portRowHeight / 2)
    }
    /// 输出端口（右侧）画布坐标：第 index 个输出 socket 的位置
    func outputPortPoint(index: Int) -> CGPoint {
        CGPoint(x: x + TimelineCanvasMetrics.nodeWidth, y: y + TimelineCanvasMetrics.headerHeight
            + CGFloat(index) * TimelineCanvasMetrics.portRowHeight
            + TimelineCanvasMetrics.portRowHeight / 2)
    }
}

// MARK: - 节点视图

/// 画布上的单个节点卡片（Blender 风格）：
/// - 头部（icon + 标题 + 摘要）+ 左右两侧按注册表列出多 socket 端口（形状 = 类型）
/// - 选中时卡片下方展开内联参数编辑 + 连线管理（编辑选项都在卡片内）
/// - 连线从输出 socket 拖出，目标 socket 形状匹配才能连
struct TimelineNodeView: View {
    let node: NodeConfig
    let isSelected: Bool
    /// 画布缩放（拖拽连线端点的屏幕位移需换算回画布坐标）
    let zoom: CGFloat
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

    /// 注册表端口列表
    private var inputSockets: [SocketDef] { NodeTypeDef.inputSockets(of: node.type) }
    private var outputSockets: [SocketDef] { NodeTypeDef.outputSockets(of: node.type) }
    private var portRows: Int { max(inputSockets.count, outputSockets.count) }

    /// 卡片总高度（基础 + 选中展开内容）
    private var cardHeight: CGFloat {
        TimelineCanvasMetrics.nodeHeight(
            portRows: portRows,
            paramRows: node.params.typedRows.count,
            edgeRows: edges.count,
            expanded: isSelected)
    }

    var body: some View {
        // 组框由画布层渲染，不在此处画卡片
        if node.type == .group {
            EmptyView()
        } else {
            ZStack(alignment: .topLeading) {
                // 卡片背景（管道出口节点黄色强调）
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(node.type == .pipeOut
                          ? AnyShapeStyle(Color.yellow.opacity(0.15))
                          : AnyShapeStyle(.background.opacity(0.9)))
                    .shadow(color: .black.opacity(isSelected ? 0.25 : 0.12), radius: isSelected ? 4 : 2, y: 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(node.type == .pipeOut
                                          ? (isSelected ? Color.yellow : Color.yellow.opacity(0.6))
                                          : (isSelected ? Color.accentColor : Color.primary.opacity(0.15)),
                                          lineWidth: isSelected ? 2 : 1)
                    )

                // 内容：头部 + 端口区 +（选中）编辑器
                VStack(alignment: .leading, spacing: 0) {
                    // 头部（icon + 标题 + 参数摘要）
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
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(height: TimelineCanvasMetrics.headerHeight, alignment: .topLeading)

                    // 端口区：左侧输入 / 右侧输出（形状 = 类型）
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

                    // 内联编辑器（选中展开）
                    if isSelected {
                        Divider().padding(.top, 2)
                        NodeParamsEditorView(
                            params: $params,
                            nodeType: node.type,
                            events: events,
                            regions: regions
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)

                        // 连线管理（入/出边 + 删除）
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
                }
                .frame(width: TimelineCanvasMetrics.nodeWidth, height: cardHeight, alignment: .topLeading)
            }
            .frame(width: TimelineCanvasMetrics.nodeWidth, height: cardHeight)
            .contentShape(Rectangle())
        }
    }

    // MARK: - 端口行

    /// 输入端口行：形状点 + 名称（左对齐）
    private func inputPortRow(socket: SocketDef, index: Int) -> some View {
        HStack(spacing: 3) {
            SocketShapeView(type: socket.type)
            Text(socket.name)
                .font(.system(size: 8)).monospaced()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: TimelineCanvasMetrics.portRowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(socket.required ? socket.name : socket.name + " (opt)")
    }

    /// 输出端口行：名称 + 形状点（右对齐，带拖拽连线把手）
    private func outputPortRow(socket: SocketDef, index: Int) -> some View {
        HStack(spacing: 3) {
            Spacer(minLength: 0)
            Text(socket.name)
                .font(.system(size: 8)).monospaced()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            SocketShapeView(type: socket.type)
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
        .help(L10n.tr("拖拽连线", "Drag to connect") + " · " + socket.name)
    }
}
