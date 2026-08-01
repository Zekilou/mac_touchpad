import SwiftUI
import GestureEngine

/// 手势 tab 内容区（v5 完全配置化）：整窗节点图画布
/// 手势的全部配置（绑定区域/事件、触发时机、轻点识别、信号处理、触觉、鼠标）都在一张图上，
/// 编辑即写回 config 并立即生效。
struct GestureTabView: View {
    @Binding var config: AppConfig
    @Binding var selectedGestureID: UUID?

    private var selectedGesture: GestureConfig? {
        config.gestures.first { $0.id == selectedGestureID } ?? config.gestures.first
    }

    var body: some View {
        if let gesture = selectedGesture, let idx = config.gestures.firstIndex(where: { $0.id == gesture.id }) {
            TimelineGraphView(timeline: Binding(
                get: { config.gestures[idx].timeline },
                set: { config.gestures[idx].timeline = $0 }
            ), events: config.events, regions: config.regions)
        } else {
            Text(L10n.tr("无手势", "No gesture"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
