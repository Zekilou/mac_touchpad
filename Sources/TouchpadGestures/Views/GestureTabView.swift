import SwiftUI
import GestureEngine

/// 手势 tab 内容区：绑定事件/区域 + 触发参数 + 信号处理 + 结构化触觉
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
                    }

                    // ---------- 新增：信号处理卡片（v2 管线）----------
                    Card(title: L10n.tr("信号处理管线", "Signal Pipeline")) {
                        // 信号源
                        HStack {
                            Text(L10n.tr("信号源", "Signal Source"))
                                .frame(width: 150, alignment: .leading)
                            Picker(L10n.tr("信号源", "Signal Source"), selection: Binding(
                                get: { config.gestures[idx].signalSource },
                                set: { config.gestures[idx].signalSource = $0 }
                            )) {
                                ForEach(SignalSource.allCases, id: \.self) { s in
                                    Text(s.displayName).tag(s)
                                }
                            }
                            .pickerStyle(.segmented)
                            Spacer()
                        }
                        // 变换方式
                        HStack {
                            Text(L10n.tr("变换方式", "Transform"))
                                .frame(width: 150, alignment: .leading)
                            Picker(L10n.tr("变换方式", "Transform"), selection: Binding(
                                get: { config.gestures[idx].transformMode },
                                set: { config.gestures[idx].transformMode = $0 }
                            )) {
                                ForEach(TransformMode.allCases, id: \.self) { t in
                                    Text(t.displayName).tag(t)
                                }
                            }
                            .pickerStyle(.segmented)
                            Spacer()
                        }
                        // 量化模式
                        HStack {
                            Text(L10n.tr("量化模式", "Trigger Mode"))
                                .frame(width: 150, alignment: .leading)
                            Picker(L10n.tr("量化模式", "Trigger Mode"), selection: Binding(
                                get: { config.gestures[idx].triggerMode },
                                set: { config.gestures[idx].triggerMode = $0 }
                            )) {
                                ForEach(TriggerMode.allCases, id: \.self) { t in
                                    Text(t.displayName).tag(t)
                                }
                            }
                            .pickerStyle(.segmented)
                            Spacer()
                        }
                        // stepNorm（离散模式显示）
                        if config.gestures[idx].triggerMode == .discrete {
                            HStack {
                                Text(L10n.tr("步进间距 (stepNorm)", "Step (norm)"))
                                    .frame(width: 150, alignment: .leading)
                                Slider(value: Binding(
                                    get: { Double(config.gestures[idx].stepNorm) },
                                    set: { config.gestures[idx].stepNorm = Float($0) }
                                ), in: 0.005...0.05)
                                Text(String(format: "%.3f", config.gestures[idx].stepNorm))
                                    .monospacedDigit().frame(width: 50, alignment: .trailing)
                            }
                        }
                        // sensitivity（连续模式显示）
                        if config.gestures[idx].triggerMode == .continuous {
                            HStack {
                                Text(L10n.tr("灵敏度", "Sensitivity"))
                                    .frame(width: 150, alignment: .leading)
                                Slider(value: Binding(
                                    get: { Double(config.gestures[idx].sensitivity) },
                                    set: { config.gestures[idx].sensitivity = Float($0) }
                                ), in: 0.1...10.0)
                                Text(String(format: "%.1fx", config.gestures[idx].sensitivity))
                                    .monospacedDigit().frame(width: 50, alignment: .trailing)
                            }
                        }
                    }

                    // ---------- 新增：Timeline 图预览（迁移器生成，只读）----------
                    Card(title: L10n.tr("Timeline 图预览", "Timeline Preview")) {
                        TimelinePreviewView(
                            gesture: config.gestures[idx],
                            event: config.events.first { $0.id == config.gestures[idx].eventID }
                        )
                    }

                    // ---------- 重构：结构化触觉反馈（4 行）----------
                    Card(title: L10n.tr("触觉反馈", "Haptic Feedback")) {
                        HapticRow(
                            label: L10n.tr("进入 holding", "Enter Holding"),
                            event: Binding(
                                get: { config.gestures[idx].hapticEnter },
                                set: { config.gestures[idx].hapticEnter = $0 }
                            ),
                            reset: { config.gestures[idx].hapticEnter = .enter }
                        )
                        HapticRow(
                            label: L10n.tr("滑动刻度", "Tick"),
                            event: Binding(
                                get: { config.gestures[idx].hapticTick },
                                set: { config.gestures[idx].hapticTick = $0 }
                            ),
                            reset: { config.gestures[idx].hapticTick = .tick }
                        )
                        HapticRow(
                            label: L10n.tr("到达边界", "Boundary"),
                            event: Binding(
                                get: { config.gestures[idx].hapticBoundary },
                                set: { config.gestures[idx].hapticBoundary = $0 }
                            ),
                            reset: { config.gestures[idx].hapticBoundary = .boundary }
                        )
                        HapticRow(
                            label: L10n.tr("退出 holding", "Exit Holding"),
                            event: Binding(
                                get: { config.gestures[idx].hapticExit },
                                set: { config.gestures[idx].hapticExit = $0 }
                            ),
                            reset: { config.gestures[idx].hapticExit = .exit }
                        )
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

// MARK: - 触觉单行：开关 + 波形 + 次数 + 间隔(可选) + 重置

/// 单行 HapticEvent 编辑组件
private struct HapticRow: View {
    let label: String
    @Binding var event: HapticEvent
    let reset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // 开关 + 标签
                Toggle(isOn: Binding(
                    get: { event.enabled },
                    set: { event.enabled = $0 }
                )) {
                    Text(label).frame(width: 130, alignment: .leading)
                }
                .toggleStyle(.switch)
                .disabled(false)

                // 波形 Stepper
                Text(L10n.tr("波形", "Wave"))
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: Binding(
                    get: { Int(event.waveform) },
                    set: { event.waveform = Int32(max(1, min(16, $0))) }
                ), in: 1...16) {
                    Text("\(event.waveform)").monospacedDigit().frame(width: 22)
                }
                .disabled(!event.enabled)

                // 次数 Stepper
                Text(L10n.tr("次", "×"))
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: Binding(
                    get: { event.count },
                    set: { event.count = max(1, min(5, $0)) }
                ), in: 1...5) {
                    Text("\(event.count)").monospacedDigit().frame(width: 18)
                }
                .disabled(!event.enabled)

                Spacer()

                // 重置按钮
                Button {
                    reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise.circle")
                }
                .buttonStyle(.borderless)
                .help(L10n.tr("恢复默认", "Reset to default"))
            }

            // 间隔（仅 count > 1 时显示）
            if event.enabled && event.count > 1 {
                HStack {
                    Spacer().frame(width: 160)
                    Text(L10n.tr("间隔 (ms)", "Interval (ms)"))
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(event.intervalUs) / 1000.0 },
                        set: { event.intervalUs = Int32(max(0, min(200000, Int32($0 * 1000)))) }
                    ), in: 0...200)
                    .frame(maxWidth: 240)
                    Text(String(format: "%.0f", Double(event.intervalUs) / 1000.0))
                        .monospacedDigit().frame(width: 36, alignment: .trailing)
                        .font(.caption)
                }
            }
        }
        .opacity(event.enabled ? 1.0 : 0.55)
    }
}
