import SwiftUI
import GestureEngine

/// 手势 tab 内容区（v3 节点化）：绑定 + Timeline 画布编辑器主体 + 波形对照
/// 全部手势行为参数都在节点图上编辑（识别/信号/触觉/鼠标），编辑即写回 config
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
                    // 绑定事件
                    Card(title: L10n.tr("绑定事件", "Bound Event")) {
                        HStack {
                            Text(L10n.tr("事件", "Event")).frame(width: 150, alignment: .leading)
                            Picker(L10n.tr("事件", "Event"), selection: Binding(
                                get: { config.gestures[idx].eventID },
                                set: { config.gestures[idx].eventID = $0 }
                            )) {
                                ForEach(config.events) { event in
                                    Text(event.name).tag(event.id)
                                }
                            }
                            .pickerStyle(.menu)
                            Spacer()
                        }
                    }

                    // 触发区域
                    Card(title: L10n.tr("触发区域", "Trigger Region")) {
                        HStack {
                            Text(L10n.tr("区域", "Region")).frame(width: 150, alignment: .leading)
                            Picker(L10n.tr("区域", "Region"), selection: Binding(
                                get: { config.gestures[idx].regionID },
                                set: { config.gestures[idx].regionID = $0 }
                            )) {
                                ForEach(config.regions) { region in
                                    Text(region.name).tag(region.id)
                                }
                            }
                            .pickerStyle(.menu)
                            Spacer()
                        }
                    }

                    // ---------- 节点化主体：Timeline 画布编辑器 ----------
                    Card(title: L10n.tr("手势节点图", "Gesture Node Graph")) {
                        TimelineEditorSection(timelines: Binding(
                            get: { config.gestures[idx].timelines },
                            set: { config.gestures[idx].timelines = $0 }
                        ))
                    }

                    // 触觉波形对照（从图读 haptic 节点）
                    Card(title: L10n.tr("触觉波形对照", "Haptic Waveform Reference")) {
                        HapticWaveformReference(gesture: config.gestures[idx])
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}
