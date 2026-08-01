import SwiftUI
// 显式导入：消除与 SwiftUI.Edge 的同名歧义
import struct GestureEngine.Edge
import GestureEngine

/// 画布右侧栏：缩放控制 + 选中节点 Inspector（含边管理）+ 节点工具箱
struct NodePaletteView: View {
    @Binding var timeline: TimelineConfig
    @Binding var selectedNodeID: UUID?
    @Binding var zoom: CGFloat
    @Binding var pan: CGSize
    /// 画布可视尺寸（用于「适应画布」）
    let canvasSize: CGSize

    /// 新节点自动排列计数（对角线排布避免重叠）
    @State private var addCount: Int = 0

    private var selectedNode: NodeConfig? {
        timeline.nodes.first { $0.id == selectedNodeID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 缩放控制
            HStack(spacing: 8) {
                zoomButton(systemImage: "minus.magnifyingglass") { zoom = max(zoom / 1.2, 0.3) }
                Text("\(Int(zoom * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 42, alignment: .center)
                zoomButton(systemImage: "plus.magnifyingglass") { zoom = min(zoom * 1.2, 3.0) }
                zoomButton(systemImage: "arrow.up.left.and.arrow.down.right") { fitCanvas() }
                    .help(L10n.tr("适应画布", "Fit canvas"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05)))

            if let node = selectedNode {
                // 选中节点 Inspector
                TimelineNodeInspector(node: node, usedPorts: ports(of: node.id))
                nodeEdgeList(node)
                Divider()
            }

            // 工具箱
            Text(L10n.tr("节点工具箱", "Node Palette"))
                .font(.caption.bold()).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(NodeType.allCases, id: \.self) { type in
                        Button {
                            addNode(type)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: type.symbolName)
                                    .foregroundStyle(type.tintColor)
                                    .frame(width: 16)
                                Text(type.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 230)
        .background(Color.primary.opacity(0.02))
    }

    // MARK: - 缩放按钮

    private func zoomButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
    }

    // MARK: - 添加节点

    private func addNode(_ type: NodeType) {
        // 对角线排布：每添加 8 个换一行
        let col = addCount % 8
        let row = addCount / 8
        let node = NodeConfig(type: type, x: Double(col * 220), y: Double(row * 120))
        timeline.nodes.append(node)
        timeline.entryNodeIDs.append(node.id)
        addCount += 1
        selectedNodeID = node.id
    }

    // MARK: - 节点边管理

    private func nodeEdgeList(_ node: NodeConfig) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            let incoming = timeline.incomingEdges(to: node.id)
            let outgoing = timeline.outgoingEdges(from: node.id)
            if incoming.isEmpty && outgoing.isEmpty {
                Text(L10n.tr("无连线", "No connections"))
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(incoming, id: \.self) { edge in
                    edgeRow(edge, direction: L10n.tr("入", "IN"))
                }
                ForEach(outgoing, id: \.self) { edge in
                    edgeRow(edge, direction: L10n.tr("出", "OUT"))
                }
            }
        }
    }

    private func edgeRow(_ edge: Edge, direction: String) -> some View {
        HStack(spacing: 6) {
            Text(direction)
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            Text(edge.from.portName + " → " + edge.to.portName)
                .font(.caption2.monospaced())
                .lineLimit(1)
            Spacer()
            Button {
                timeline.edges.removeAll { $0 == edge }
            } label: {
                Image(systemName: "minus.circle")
                    .font(.caption2).foregroundStyle(.red.opacity(0.8))
            }
            .buttonStyle(.borderless)
            .help(L10n.tr("删除连线", "Remove edge"))
        }
    }

    private func ports(of nodeID: UUID) -> Set<String> {
        var result: Set<String> = []
        for edge in timeline.edges {
            if edge.from.nodeID == nodeID { result.insert(edge.from.portName) }
            if edge.to.nodeID == nodeID { result.insert(edge.to.portName) }
        }
        return result
    }

    // MARK: - 适应画布

    private func fitCanvas() {
        guard !timeline.nodes.isEmpty else { zoom = 1; pan = .zero; return }
        let w = TimelineCanvasMetrics.nodeWidth
        let h = TimelineCanvasMetrics.nodeHeight
        let minX = timeline.nodes.map(\.x).min()!
        let maxX = timeline.nodes.map { $0.x + w }.max()!
        let minY = timeline.nodes.map(\.y).min()!
        let maxY = timeline.nodes.map { $0.y + h }.max()!
        let contentW = maxX - minX + 120
        let contentH = maxY - minY + 120
        zoom = min(canvasSize.width / contentW, canvasSize.height / contentH, 1.0)
        pan = CGSize(
            width: (canvasSize.width - (maxX + minX) * zoom) / 2 - 60,
            height: (canvasSize.height - (maxY + minY) * zoom) / 2 - 60
        )
    }
}
