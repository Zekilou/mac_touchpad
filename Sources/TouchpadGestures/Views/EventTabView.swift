import SwiftUI
import GestureEngine

/// 事件 tab 内容区：动作目标 + 方向映射 + 执行方式 + step + 边界阈值
struct EventTabView: View {
    @Binding var config: AppConfig
    @Binding var selectedEventID: UUID?

    private var selectedEvent: EventConfig? {
        config.events.first { $0.id == selectedEventID } ?? config.events.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let event = selectedEvent, let idx = config.events.firstIndex(where: { $0.id == event.id }) {

                    // 1. 动作目标：控制什么 + 模拟什么按键
                    Card(title: L10n.tr("动作目标", "Action Target")) {
                        rowWithReset(tooltip: L10n.tr("恢复动作类型", "Reset action type")) {
                            let def = defaultFor(actionType: config.events[idx].actionType)
                            config.events[idx].actionType = def.actionType
                        } content: {
                            Text(L10n.tr("模拟系统按键", "Simulate Key"))
                                .frame(width: 150, alignment: .leading)
                            Picker(L10n.tr("动作", "Action"), selection: Binding(
                                get: { config.events[idx].actionType },
                                set: { config.events[idx].actionType = $0 }
                            )) {
                                ForEach(ActionType.allCases, id: \.self) { type in
                                    Text(type.displayName).tag(type)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }

                    // 2. 方向映射：上滑增 or 上滑减
                    Card(title: L10n.tr("方向映射", "Direction Mapping")) {
                        VStack(alignment: .leading, spacing: 8) {
                            rowWithReset(tooltip: L10n.tr("恢复方向（上滑增加）", "Reset to Swipe-Up-Increase")) {
                                config.events[idx].directionRule = .upIncrease
                            } content: {
                                Text(L10n.tr("滑动方向", "Swipe Rule"))
                                    .frame(width: 150, alignment: .leading)
                                Picker(L10n.tr("方向规则", "Direction Rule"), selection: Binding(
                                    get: { config.events[idx].directionRule },
                                    set: { config.events[idx].directionRule = $0 }
                                )) {
                                    ForEach(DirectionRule.allCases, id: \.self) { rule in
                                        Text(rule.displayName).tag(rule)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                            }
                            Text(L10n.tr("触控板物理方向：向上滑动 = norm_y 减小，向下滑动 = norm_y 增大。",
                                        "Trackpad physics: swipe up = norm_y decreases, swipe down = norm_y increases."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    // 3. 执行方式：媒体键 HUD / 直接 API 精确
                    Card(title: L10n.tr("执行方式", "Execution Method")) {
                        VStack(alignment: .leading, spacing: 8) {
                            rowWithReset(tooltip: L10n.tr("恢复媒体键模式", "Reset to Media Key mode")) {
                                config.events[idx].executionMethod = .mediaKey
                            } content: {
                                Text(L10n.tr("控制方式", "Control Method"))
                                    .frame(width: 150, alignment: .leading)
                                Picker(L10n.tr("执行方式", "Execution Method"), selection: Binding(
                                    get: { config.events[idx].executionMethod },
                                    set: { config.events[idx].executionMethod = $0 }
                                )) {
                                    ForEach(ExecutionMethod.allCases, id: \.self) { method in
                                        Text(method.displayName).tag(method)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                            }
                            Text(executionHint(for: config.events[idx].executionMethod))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    // 4. 调节参数：步长（数值在上方）
                    Card(title: L10n.tr("调节参数", "Adjustment")) {
                        VStack(alignment: .leading, spacing: 8) {
                            // 数值显示在 Slider 上方
                            HStack {
                                Text(L10n.tr("每次变化量", "Step"))
                                    .frame(width: 150, alignment: .leading)
                                Text(String(format: "%.3f (%.1f%%)",
                                            config.events[idx].step,
                                            config.events[idx].step * 100))
                                    .monospacedDigit()
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                resetBtn(tooltip: L10n.tr("恢复步长", "Reset step")) {
                                    let def = defaultFor(actionType: config.events[idx].actionType)
                                    config.events[idx].step = def.step
                                }
                            }
                            // Slider 独占一行，宽度不受标签挤压
                            Slider(value: Binding(
                                get: { Double(config.events[idx].step) },
                                set: { config.events[idx].step = Float($0) }
                            ), in: stepRange(for: config.events[idx].executionMethod))
                            Text(stepHint(for: config.events[idx].executionMethod))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    // 5. 边界检测（数值在上方）
                    Card(title: L10n.tr("边界检测", "Boundary Detection")) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(L10n.tr("边界判定阈值", "Boundary Threshold"))
                                    .frame(width: 150, alignment: .leading)
                                Text(String(format: "%.3f", config.events[idx].boundaryThreshold))
                                    .monospacedDigit()
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                resetBtn(tooltip: L10n.tr("恢复阈值", "Reset threshold")) {
                                    let def = defaultFor(actionType: config.events[idx].actionType)
                                    config.events[idx].boundaryThreshold = def.boundaryThreshold
                                }
                            }
                            Slider(value: Binding(
                                get: { Double(config.events[idx].boundaryThreshold) },
                                set: { config.events[idx].boundaryThreshold = Float($0) }
                            ), in: 0.001...0.05)
                            Text(L10n.tr("当前值 ≤ 阈值视为 0%，≥ 1-阈值视为 100%。阈值越大越保守。",
                                        "Value ≤ threshold = 0%, ≥ 1-threshold = 100%. Larger = more conservative."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Helpers

    /// 标准行布局：label(150pt) + control(flexible) + reset button
    @ViewBuilder
    private func rowWithReset<C: View>(
        tooltip: String,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> C
    ) -> some View {
        HStack(spacing: 8) {
            content()
            resetBtn(tooltip: tooltip, action: action)
        }
    }

    /// 单项重置按钮（borderless + tooltip）
    @ViewBuilder
    private func resetBtn(tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(tooltip)
    }

    /// step 范围：媒体键模式建议对齐系统档位（1/16 起）；direct 可任意细
    private func stepRange(for method: ExecutionMethod) -> ClosedRange<Double> {
        switch method {
        case .mediaKey:  return 0.03125...0.125   // 约 1/32 ~ 1/8
        case .direct:    return 0.001...0.10       // 精确到千分之一
        }
    }

    /// 执行方式说明文字
    private func executionHint(for method: ExecutionMethod) -> String {
        switch method {
        case .mediaKey:
            return L10n.tr("模拟 F1/F2/F10/F11/F12 等系统媒体键，触发系统右上角 HUD，档位固定约 16 级。",
                            "Simulates F1/F2/F10~F12 media keys → system HUD pops up, ~16 fixed levels.")
        case .direct:
            return L10n.tr("直接写 CoreAudio / IOKit 寄存器，支持任意精度步长，无 HUD。接外接显示器时可能只改内置屏。",
                            "Writes CoreAudio/IOKit directly, arbitrary precision, no HUD. External displays may be skipped.")
        }
    }

    /// step 说明文字
    private func stepHint(for method: ExecutionMethod) -> String {
        switch method {
        case .mediaKey:
            return L10n.tr("系统档位约 1/16 = 0.0625；步长会影响「累积几帧才触发一次按键」。",
                            "System step ≈ 1/16 = 0.0625; this value tunes how many frames accumulate per key-press.")
        case .direct:
            return L10n.tr("每帧直接加减此值到系统寄存器；0.005 对应一次滑动 200 档，手感细腻。",
                            "Value is added/subtracted directly each tick; 0.005 = 200 levels per full swipe.")
        }
    }

    /// 取该 actionType 对应的默认事件，用于单项重置
    private func defaultFor(actionType: ActionType) -> EventConfig {
        switch actionType {
        case .volume: return .defaultVolume
        case .brightness: return .defaultBrightness
        }
    }
}
