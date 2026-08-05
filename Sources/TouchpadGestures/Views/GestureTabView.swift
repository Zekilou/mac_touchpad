import SwiftUI
import GestureEngine

/// 手势 tab 内容区（v10.19）：默认「基础设置」卡片页（学习成本低），可切换「高级画布」节点图。
/// 两种模式读写同一张节点图——基础设置是高层快捷配置，画布是完整编辑，改哪边都立即生效。
struct GestureTabView: View {
    @Binding var config: AppConfig
    @Binding var selectedGestureID: UUID?

    /// 视图模式：true=基础设置（默认，简单卡片）；false=高级画布（节点图）
    @AppStorage("gestureViewMode.basic") private var basicMode = true

    private var selectedGesture: GestureConfig? {
        config.gestures.first { $0.id == selectedGestureID } ?? config.gestures.first
    }

    var body: some View {
        if let gesture = selectedGesture, let idx = config.gestures.firstIndex(where: { $0.id == gesture.id }) {
            VStack(spacing: 0) {
                Picker(L10n.tr("视图", "View"), selection: $basicMode) {
                    Text(L10n.tr("基础设置", "Basic")).tag(true)
                    Text(L10n.tr("高级画布", "Canvas")).tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                .padding(.vertical, 6)

                if basicMode {
                    BasicGestureSettingsView(
                        gesture: Binding(
                            get: { config.gestures[idx] },
                            set: { config.gestures[idx] = $0 }
                        ),
                        enabled: Binding(
                            get: { config.gestures[idx].enabled },
                            set: { config.gestures[idx].enabled = $0 }
                        ),
                        events: config.events,
                        regions: config.regions)
                } else {
                    TimelineGraphView(timeline: Binding(
                        get: { config.gestures[idx].timeline },
                        set: { config.gestures[idx].timeline = $0 }
                    ), events: config.events, regions: config.regions,
                    enabled: Binding(
                        get: { config.gestures[idx].enabled },
                        set: { config.gestures[idx].enabled = $0 }
                    ))
                }
            }
        } else {
            Text(L10n.tr("无手势", "No gesture"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
