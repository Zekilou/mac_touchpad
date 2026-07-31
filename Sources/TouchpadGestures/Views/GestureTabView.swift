import SwiftUI
import GestureEngine

/// 手势 tab 内容区：绑定事件/区域 + 触发参数 + 所有震动
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

                    // 第一次轻点
                    Card(title: L10n.tr("第一次轻点", "First Tap")) {
                        HStack {
                            Text(L10n.tr("最长轻点时长 (s)", "Max Tap Duration (s)"))
                                .frame(width: 150, alignment: .leading)
                            Slider(value: Binding(
                                get: { config.gestures[idx].tapMaxDuration },
                                set: { config.gestures[idx].tapMaxDuration = $0 }
                            ), in: 0.1...0.5)
                            Text(String(format: "%.2f", config.gestures[idx].tapMaxDuration))
                                .monospacedDigit().frame(width: 50, alignment: .trailing)
                        }
                        HStack {
                            Text(L10n.tr("最大位移容差", "Max Drift"))
                                .frame(width: 150, alignment: .leading)
                            Slider(value: Binding(
                                get: { Double(config.gestures[idx].tapMaxDrift) },
                                set: { config.gestures[idx].tapMaxDrift = Float($0) }
                            ), in: 0.01...0.15)
                            Text(String(format: "%.3f", config.gestures[idx].tapMaxDrift))
                                .monospacedDigit().frame(width: 50, alignment: .trailing)
                        }
                    }

                    // 两次轻点衔接
                    Card(title: L10n.tr("两次轻点衔接", "Two-Tap Gap")) {
                        HStack {
                            Text(L10n.tr("两次轻点间隔 (s)", "Tap Gap (s)"))
                                .frame(width: 150, alignment: .leading)
                            Slider(value: Binding(
                                get: { config.gestures[idx].tapMaxGap },
                                set: { config.gestures[idx].tapMaxGap = $0 }
                            ), in: 0.1...0.6)
                            Text(String(format: "%.2f", config.gestures[idx].tapMaxGap))
                                .monospacedDigit().frame(width: 50, alignment: .trailing)
                        }
                    }

                    // 第二次轻点保持
                    Card(title: L10n.tr("第二次轻点保持", "Second Tap Hold")) {
                        HStack {
                            Text(L10n.tr("保持确认时长 (s)", "Hold Confirm (s)"))
                                .frame(width: 150, alignment: .leading)
                            Slider(value: Binding(
                                get: { config.gestures[idx].holdMinDuration },
                                set: { config.gestures[idx].holdMinDuration = $0 }
                            ), in: 0.1...0.5)
                            Text(String(format: "%.2f", config.gestures[idx].holdMinDuration))
                                .monospacedDigit().frame(width: 50, alignment: .trailing)
                        }
                        HStack {
                            Text(L10n.tr("进入反馈波形", "Enter Haptic Waveform"))
                                .frame(width: 150, alignment: .leading)
                            Stepper(value: Binding(
                                get: { config.gestures[idx].hapticEnter },
                                set: { config.gestures[idx].hapticEnter = $0 }
                            ), in: 1...16) {
                                Text("\(config.gestures[idx].hapticEnter)")
                            }
                            Spacer()
                        }
                    }

                    // 滑动调节
                    Card(title: L10n.tr("滑动调节", "Slide Adjust")) {
                        HStack {
                            Text(L10n.tr("滑动刻度", "Slide Step Norm"))
                                .frame(width: 150, alignment: .leading)
                            Slider(value: Binding(
                                get: { Double(config.gestures[idx].slideStepNorm) },
                                set: { config.gestures[idx].slideStepNorm = Float($0) }
                            ), in: 0.005...0.05)
                            Text(String(format: "%.3f", config.gestures[idx].slideStepNorm))
                                .monospacedDigit().frame(width: 50, alignment: .trailing)
                        }
                        HStack {
                            Text(L10n.tr("刻度反馈波形", "Tick Haptic Waveform"))
                                .frame(width: 150, alignment: .leading)
                            Stepper(value: Binding(
                                get: { config.gestures[idx].hapticTick },
                                set: { config.gestures[idx].hapticTick = $0 }
                            ), in: 1...16) {
                                Text("\(config.gestures[idx].hapticTick)")
                            }
                            Spacer()
                        }
                    }

                    // 边界震动
                    Card(title: L10n.tr("边界震动", "Boundary Haptic")) {
                        HStack {
                            Text(L10n.tr("边界强震动波形", "Boundary Haptic Waveform"))
                                .frame(width: 150, alignment: .leading)
                            Stepper(value: Binding(
                                get: { config.gestures[idx].hapticBoundary },
                                set: { config.gestures[idx].hapticBoundary = $0 }
                            ), in: 1...16) {
                                Text("\(config.gestures[idx].hapticBoundary)")
                            }
                            Spacer()
                        }
                        HStack {
                            Text(L10n.tr("边界震动间隔 (ms)", "Boundary Haptic Interval (ms)"))
                                .frame(width: 150, alignment: .leading)
                            Slider(value: Binding(
                                get: { Double(config.gestures[idx].boundaryHapticInterval) / 1000.0 },
                                set: { config.gestures[idx].boundaryHapticInterval = Int32($0 * 1000) }
                            ), in: 10...200)
                            Text(String(format: "%.0f", Double(config.gestures[idx].boundaryHapticInterval) / 1000.0))
                                .monospacedDigit().frame(width: 50, alignment: .trailing)
                        }
                    }

                    // 鼠标控制
                    Card(title: L10n.tr("鼠标控制", "Mouse Control")) {
                        HStack {
                            Text(L10n.tr("进入 holding 时解除鼠标关联", "Disassociate mouse on holding"))
                                .frame(width: 150, alignment: .leading)
                            Toggle("", isOn: Binding(
                                get: { config.gestures[idx].disassociateMouse },
                                set: { config.gestures[idx].disassociateMouse = $0 }
                            )).labelsHidden()
                            Spacer()
                        }
                    }

                    // 触觉波形对照
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
