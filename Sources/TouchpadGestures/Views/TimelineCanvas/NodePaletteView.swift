import SwiftUI
// 显式导入：消除与 SwiftUI.Edge 的同名歧义
import struct GestureEngine.Edge
import GestureEngine

/// 画布左侧栏（overlay）：缩放控制 + 节点工具箱
/// 节点属性编辑/连线管理已内嵌到节点卡片内（无外部属性编辑器）
struct NodePaletteView: View {
    @Binding var timeline: TimelineConfig
    @Binding var selectedNodeID: UUID?
    @Binding var zoom: CGFloat
    @Binding var pan: CGSize
    /// 画布可视尺寸（用于「适应画布」）
    let canvasSize: CGSize
    /// 适应画布（由外层持有画布状态，此处回调）
    let onFit: () -> Void

    /// 新节点自动排列计数（对角线排布避免重叠）
    @State private var addCount: Int = 0
    /// 工具箱折叠状态（默认收起，省空间）
    @State private var isPaletteExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 缩放控制
            HStack(spacing: 8) {
                zoomButton(systemImage: "minus.magnifyingglass") { zoom = max(zoom / 1.2, 0.3) }
                Text("\(Int(zoom * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 42, alignment: .center)
                zoomButton(systemImage: "plus.magnifyingglass") { zoom = min(zoom * 1.2, 3.0) }
                zoomButton(systemImage: "arrow.up.left.and.arrow.down.right") { onFit() }
                    .help(L10n.tr("适应画布", "Fit canvas"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05)))

            // 工具箱（可折叠，默认收起）
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isPaletteExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isPaletteExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("节点工具箱", "Node Palette"))
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(timeline.nodes.count)")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isPaletteExpanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        // 专有行为卡片已废弃（mouse/freeze 改由 set/toggle 变量操作表达），工具箱隐藏
                        ForEach(NodeType.allCases.filter { $0 != .mouse && $0 != .freeze }, id: \.self) { type in
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
                .frame(maxHeight: 300)
            }
        }
        .padding(10)
        .frame(width: 230)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        )
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
}
