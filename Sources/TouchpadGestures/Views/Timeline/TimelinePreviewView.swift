import SwiftUI
import GestureEngine

/// Timeline 图预览（M4-C 数据层）：v2 配置 → 迁移器生成的 3 条图
/// 展示：trigger 切换 + 拓扑验证状态 + 节点列表 + 边列表 + 节点属性面板
/// 下一轮（Canvas 画布）将替换为拖放连线编辑
struct TimelinePreviewView: View {
    let gesture: GestureConfig
    let event: EventConfig?

    /// 迁移器实时生成（v2 配置变化 → 图联动更新）
    private var timelines: [TimelineConfig] {
        guard let event else { return [] }
        return TimelineMigrator.migrate(gesture: gesture, event: event)
    }

    @State private var selectedTrigger: TriggerEvent = .onEnterHolding
    @State private var selectedNodeID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if timelines.isEmpty {
                Text(L10n.tr("未绑定事件，无法生成 Timeline", "Bind an event to preview timelines"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                // trigger 切换
                Picker("", selection: $selectedTrigger) {
                    ForEach(timelines, id: \.trigger) { tl in
                        Text(tl.trigger.displayName).tag(tl.trigger)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if let timeline = timelines.first(where: { $0.trigger == selectedTrigger }) {
                    validationRow(timeline)
                    nodeList(timeline)
                    edgeList(timeline)
                    if let node = timeline.nodes.first(where: { $0.id == selectedNodeID }) {
                        TimelineNodeInspector(node: node, usedPorts: ports(of: node.id, in: timeline))
                    }
                }
            }
        }
    }

    // MARK: - 拓扑验证状态

    private func validationRow(_ timeline: TimelineConfig) -> some View {
        HStack(spacing: 6) {
            switch TimelineGraphValidator.topologicalOrder(of: timeline) {
            case .valid(let order):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(L10n.tr("拓扑有效 · \(order.count) 节点", "Valid · \(order.count) nodes"))
                    .font(.caption).foregroundStyle(.secondary)
            case .cycle:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(L10n.tr("存在环", "Cycle detected")).font(.caption).foregroundStyle(.red)
            case .danglingEdge:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(L10n.tr("存在悬挂边", "Dangling edge")).font(.caption).foregroundStyle(.red)
            case .noEntry:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(L10n.tr("无入口节点", "No entry node")).font(.caption).foregroundStyle(.red)
            }
            Text(L10n.tr("边 \(timeline.edges.count)", "\(timeline.edges.count) edges"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - 节点列表

    private func nodeList(_ timeline: TimelineConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr("节点", "Nodes"))
                .font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(timeline.nodes) { node in
                Button {
                    selectedNodeID = node.id
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: node.type.symbolName)
                            .foregroundStyle(node.type.tintColor)
                            .frame(width: 16)
                        Text(node.title ?? node.type.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Text(node.paramsSummary)
                            .font(.caption2).monospaced()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selectedNodeID == node.id ? Color.accentColor.opacity(0.15) : .clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 边列表

    private func edgeList(_ timeline: TimelineConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !timeline.edges.isEmpty {
                Text(L10n.tr("连线", "Edges"))
                    .font(.caption.bold()).foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            ForEach(timeline.edges, id: \.self) { edge in
                HStack(spacing: 6) {
                    Text(title(of: edge.from, in: timeline))
                        .font(.caption).foregroundStyle(.primary)
                    Image(systemName: "arrow.right")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(edge.from.portName)
                        .font(.caption2).monospaced().foregroundStyle(.teal)
                    Image(systemName: "arrow.right")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(edge.to.portName)
                        .font(.caption2).monospaced().foregroundStyle(.orange)
                    Image(systemName: "arrow.right")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(title(of: edge.to, in: timeline))
                        .font(.caption).foregroundStyle(.primary)
                    Spacer()
                }
            }
        }
    }

    // MARK: - 辅助

    private func title(of port: PortID, in timeline: TimelineConfig) -> String {
        timeline.nodes.first { $0.id == port.nodeID }?.title
            ?? timeline.nodes.first { $0.id == port.nodeID }?.type.displayName
            ?? L10n.tr("未知节点", "Unknown")
    }

    /// 该节点在图中实际使用的端口（输入+输出）
    private func ports(of nodeID: UUID, in timeline: TimelineConfig) -> Set<String> {
        var result: Set<String> = []
        for edge in timeline.edges {
            if edge.from.nodeID == nodeID { result.insert(edge.from.portName) }
            if edge.to.nodeID == nodeID { result.insert(edge.to.portName) }
        }
        return result
    }
}
