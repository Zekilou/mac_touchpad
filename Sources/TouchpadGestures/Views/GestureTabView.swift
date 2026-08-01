import SwiftUI
import GestureEngine

/// 手势 tab 内容区（v4 全节点化）：只有 Timeline 画布编辑器
/// 手势的全部配置（绑定区域/事件、轻点识别、信号处理、触觉、鼠标）都在节点图上编辑，
/// 编辑即写回 config 并立即生效。
struct GestureTabView: View {
    @Binding var config: AppConfig
    @Binding var selectedGestureID: UUID?

    private var selectedGesture: GestureConfig? {
        config.gestures.first { $0.id == selectedGestureID } ?? config.gestures.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let gesture = selectedGesture, let idx = config.gestures.firstIndex(where: { $0.id == gesture.id }) {
                    // 唯一卡片：节点图编辑器（含 region/event 绑定引用节点 + 识别 + 3 条执行图）
                    Card(title: L10n.tr("手势节点图", "Gesture Node Graph")) {
                        TimelineEditorSection(timelines: Binding(
                            get: { config.gestures[idx].timelines },
                            set: { config.gestures[idx].timelines = $0 }
                        ), events: config.events, regions: config.regions)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}
