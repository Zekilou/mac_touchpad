import SwiftUI
import GestureEngine

/// 多 Timeline 编辑器（手势页面节点化主体）
/// - 顶部 trigger 切换（识别/进入/刻度/退出 4 条图）
/// - 主体：画布（拖拽/连线/缩放）+ 右侧栏（参数编辑/工具箱）
/// - 编辑实时写回 config（编辑即生效）
struct TimelineEditorSection: View {
    @Binding var timelines: [TimelineConfig]
    /// 绑定可选项（region/event 引用节点参数面板数据源）
    let events: [EventConfig]
    let regions: [RegionConfig]

    @State private var selectedTrigger: TriggerEvent = .onFirstTap
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var selectedNodeID: UUID?

    private var triggers: [TriggerEvent] {
        timelines.map(\.trigger)
    }

    /// 当前 trigger 对应图的 Binding（切换 trigger 时重置选中）
    private var timelineBinding: Binding<TimelineConfig> {
        Binding(
            get: {
                timelines.first { $0.trigger == selectedTrigger }
                    ?? timelines.first ?? TimelineConfig(trigger: selectedTrigger)
            },
            set: { newValue in
                if let idx = timelines.firstIndex(where: { $0.trigger == selectedTrigger }) {
                    timelines[idx] = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if triggers.isEmpty {
                Text(L10n.tr("该手势暂无 Timeline 图", "No timelines for this gesture"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                // trigger 切换
                Picker("", selection: $selectedTrigger) {
                    ForEach(triggers, id: \.self) { trigger in
                        Text(trigger.displayName).tag(trigger)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: selectedTrigger) { selectedNodeID = nil }

                // 画布 + 侧栏
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        TimelineCanvasView(timeline: timelineBinding,
                                           zoom: $zoom,
                                           pan: $pan,
                                           selectedNodeID: $selectedNodeID)
                        NodePaletteView(timeline: timelineBinding,
                                        selectedNodeID: $selectedNodeID,
                                        zoom: $zoom,
                                        pan: $pan,
                                        canvasSize: geo.size,
                                        events: events,
                                        regions: regions)
                    }
                }
                .frame(minHeight: 420)
            }
        }
    }
}
