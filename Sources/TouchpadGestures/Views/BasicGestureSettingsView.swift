import SwiftUI
import GestureEngine

/// 基础设置视图（v10.19）：卡片式高层配置——读写节点图参数，无需理解节点图。
/// 与高级画布并存（GestureTabView 切换）；编辑立即写回 config 生效。
/// 覆盖：绑定（区域/事件）+ 触发识别（双击阈值 / Force 压力）+ 信号处理（信号源/变换/量化）+ 触觉反馈（波形/次数/间隔）
struct BasicGestureSettingsView: View {
    @Binding var gesture: GestureConfig
    /// 手势启用开关（与高级画布共用同一状态——v10.20 补齐：基础设置页此前漏了启用开关）
    @Binding var enabled: Bool
    let events: [EventConfig]
    let regions: [RegionConfig]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                enableCard
                bindingCard
                recognizeCard
                signalCard
                hapticCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - 启用开关

    private var enableCard: some View {
        Card(title: L10n.tr("启用", "Enable")) {
            HStack {
                Text(L10n.tr("手势启用", "Gesture Enabled")).frame(width: 150, alignment: .leading)
                Toggle(isOn: $enabled) { EmptyView() }
                    .labelsHidden()
                    .toggleStyle(.switch)
                Text(enabled ? L10n.tr("已启用", "Enabled") : L10n.tr("已禁用（引擎跳过此手势）", "Disabled (engine skips)"))
                    .font(.caption)
                    .foregroundStyle(enabled ? Color.secondary : Color.red)
                Spacer()
            }
        }
    }

    // MARK: - 绑定

    private var bindingCard: some View {
        Card(title: L10n.tr("绑定", "Binding")) {
            HStack {
                Text(L10n.tr("触发区域", "Region")).frame(width: 150, alignment: .leading)
                Picker(L10n.tr("触发区域", "Region"), selection: Binding(
                    get: { gesture.boundRegionID },
                    set: { newID in
                        guard let newID else { return }
                        gesture.updateNodeParams(.region, title: "触发区域") { $0.regionID = newID }
                    }
                )) {
                    ForEach(regions) { region in
                        Text(region.name).tag(Optional(region.id))
                    }
                }
                .pickerStyle(.menu)
                Spacer()
            }
            HStack {
                Text(L10n.tr("绑定事件", "Event")).frame(width: 150, alignment: .leading)
                Picker(L10n.tr("绑定事件", "Event"), selection: Binding(
                    get: { gesture.boundEventID },
                    set: { newID in
                        guard let newID else { return }
                        gesture.updateNodeParams(.event, title: "绑定事件") { $0.eventID = newID }
                    }
                )) {
                    ForEach(events) { event in
                        Text(event.name).tag(Optional(event.id))
                    }
                }
                .pickerStyle(.menu)
                Spacer()
            }
        }
    }

    // MARK: - 触发识别

    private var recognizeCard: some View {
        Card(title: L10n.tr("触发识别", "Trigger Recognition")) {
            if gesture.isForceGesture {
                sliderRow(
                    label: L10n.tr("压力阈值", "Pressure Threshold"),
                    value: Binding(
                        get: { Double(gesture.recognizeParams.pressureThreshold ?? 1.4) },
                        set: { gesture.setRecognizeThreshold("压力足够?", Float($0)) }
                    ),
                    range: 0.5...2.0,
                    format: "%.2f")
                sliderRow(
                    label: L10n.tr("保持时长 (s)", "Hold Duration (s)"),
                    value: Binding(
                        get: { gesture.recognizeParams.forceHold ?? 0.3 },
                        set: { gesture.setRecognizeThreshold("按够久?", Float($0)) }
                    ),
                    range: 0.1...0.6,
                    format: "%.2f")
            } else {
                sliderRow(
                    label: L10n.tr("最长轻点时长 (s)", "Max Tap Duration (s)"),
                    value: Binding(
                        get: { gesture.recognizeParams.tapMaxDuration ?? 0.2 },
                        set: { gesture.setRecognizeThreshold("按下超时?", Float($0)) }
                    ),
                    range: 0.1...0.5,
                    format: "%.2f")
                sliderRow(
                    label: L10n.tr("最大位移容差", "Max Drift"),
                    value: Binding(
                        get: { Double(gesture.recognizeParams.tapMaxDrift ?? 0.05) },
                        set: { gesture.setRecognizeThreshold("漂移过大?", Float($0)) }
                    ),
                    range: 0.01...0.15,
                    format: "%.3f")
                sliderRow(
                    label: L10n.tr("两次轻点间隔 (s)", "Tap Gap (s)"),
                    value: Binding(
                        get: { gesture.recognizeParams.tapMaxGap ?? 0.3 },
                        set: { gesture.setRecognizeThreshold("间隔内?", Float($0)) }
                    ),
                    range: 0.1...0.6,
                    format: "%.2f")
                sliderRow(
                    label: L10n.tr("保持确认时长 (s)", "Hold Confirm (s)"),
                    value: Binding(
                        get: { gesture.recognizeParams.holdMinDuration ?? 0.2 },
                        set: { gesture.setRecognizeThreshold("保持够久?", Float($0)) }
                    ),
                    range: 0.1...0.5,
                    format: "%.2f")
            }
        }
    }

    // MARK: - 信号处理

    private var signalCard: some View {
        Card(title: L10n.tr("信号处理", "Signal Processing")) {
            HStack {
                Text(L10n.tr("信号源", "Signal Source")).frame(width: 150, alignment: .leading)
                Picker(L10n.tr("信号源", "Signal Source"), selection: Binding(
                    get: { gesture.tickSignalSource },
                    set: { gesture.setSignalSource($0) }
                )) {
                    ForEach(SignalSource.allCases, id: \.self) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .pickerStyle(.menu)
                // Force 手势滑动信号恒为 normY（压力只做进入/退出判定）——禁用选择避免被自动纠正
                .disabled(gesture.isForceGesture)
                Spacer()
            }
            if gesture.isForceGesture {
                Text(L10n.tr("Force 手势滑动信号固定为 Y 轴坐标（压力仅用于进入/退出判定）。",
                             "Force gestures use Y-axis as the slide signal (pressure only gates enter/exit)."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(L10n.tr("变换方式", "Transform")).frame(width: 150, alignment: .leading)
                Picker(L10n.tr("变换方式", "Transform"), selection: Binding(
                    get: { gesture.timeline.firstNode(of: .transform)?.params.transform ?? .delta },
                    set: { gesture.setTransformMode($0) }
                )) {
                    Text(L10n.tr("差值", "Delta")).tag(TransformMode.delta)
                    Text(L10n.tr("绝对值", "Absolute")).tag(TransformMode.absolute)
                }
                .pickerStyle(.segmented)
                Spacer()
            }
            HStack {
                Text(L10n.tr("量化模式", "Trigger Mode")).frame(width: 150, alignment: .leading)
                Picker(L10n.tr("量化模式", "Trigger Mode"), selection: Binding(
                    get: { gesture.timeline.firstNode(of: .quantize)?.params.triggerMode ?? .discrete },
                    set: { gesture.setQuantize(triggerMode: $0) }
                )) {
                    Text(L10n.tr("离散刻度", "Discrete")).tag(TriggerMode.discrete)
                    Text(L10n.tr("连续比例", "Continuous")).tag(TriggerMode.continuous)
                }
                .pickerStyle(.segmented)
                Spacer()
            }
            if gesture.timeline.firstNode(of: .quantize)?.params.triggerMode == .continuous {
                sliderRow(
                    label: L10n.tr("灵敏度", "Sensitivity"),
                    value: Binding(
                        get: { Double(gesture.timeline.firstNode(of: .quantize)?.params.sensitivity ?? 1.0) },
                        set: { gesture.setQuantize(sensitivity: Float($0)) }
                    ),
                    range: 0.1...10.0,
                    format: "%.1f")
            } else {
                sliderRow(
                    label: L10n.tr("步进间距", "Step Norm"),
                    value: Binding(
                        get: { Double(gesture.timeline.firstNode(of: .quantize)?.params.stepNorm ?? 0.02) },
                        set: { gesture.setQuantize(stepNorm: Float($0)) }
                    ),
                    range: 0.005...0.1,
                    format: "%.3f")
            }
        }
    }

    // MARK: - 触觉反馈

    private var hapticCard: some View {
        Card(title: L10n.tr("触觉反馈", "Haptic Feedback")) {
            hapticRow(label: L10n.tr("进入反馈", "Enter"), title: "进入震动")
            hapticRow(label: L10n.tr("滑动刻度", "Tick"), title: "刻度震动")
            hapticRow(label: L10n.tr("退出反馈", "Exit"), title: "退出震动")
        }
    }

    /// 实时读图的 haptic 节点参数（v10.20 修复：原实现闭包捕获 let params 快照，
    /// 用户点 Stepper 改值后 set 更新了图，但 get 仍返回旧快照 → 显示不回显）
    private func currentHaptic(_ title: String) -> NodeParams? {
        gesture.timeline.nodes.first { $0.type == .haptic && $0.title == title }?.params
    }

    /// 单个震动时机：波形 + 次数 + 间隔（读根图 haptic 节点；节点不存在则跳过该行）
    private func hapticRow(label: String, title: String) -> some View {
        guard currentHaptic(title) != nil else {
            return AnyView(EmptyView())
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(L10n.tr("波形", "Waveform")).frame(width: 150, alignment: .leading)
                    Stepper(value: Binding(
                        get: { Int(currentHaptic(title)?.waveform ?? 1) },
                        set: { gesture.setHaptic(title, waveform: Int32($0)) }
                    ), in: 1...16) {
                        Text("\(currentHaptic(title)?.waveform ?? 1)").monospacedDigit()
                    }
                    Spacer()
                }
                HStack {
                    Text(L10n.tr("次数", "Count")).frame(width: 150, alignment: .leading)
                    Stepper(value: Binding(
                        get: { currentHaptic(title)?.count ?? 1 },
                        set: { gesture.setHaptic(title, count: $0) }
                    ), in: 1...5) {
                        Text("\(currentHaptic(title)?.count ?? 1)").monospacedDigit()
                    }
                    Spacer()
                }
                if (currentHaptic(title)?.count ?? 1) > 1 {
                    HStack {
                        Text(L10n.tr("间隔 (ms)", "Interval (ms)")).frame(width: 150, alignment: .leading)
                        Slider(value: Binding(
                            get: { Double(currentHaptic(title)?.intervalUs ?? 50000) / 1000.0 },
                            set: { gesture.setHaptic(title, intervalUs: Int32($0 * 1000)) }
                        ), in: 0...200)
                        Text("\(Int((currentHaptic(title)?.intervalUs ?? 50000) / 1000))").monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        )
    }

    /// 统一滑块行：label 150pt + Slider + 数值
    private func sliderRow(label: String, value: Binding<Double>, range: ClosedRange<Double>,
                           format: String) -> some View {
        HStack {
            Text(label).frame(width: 150, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue)).monospacedDigit()
                .frame(width: 60, alignment: .trailing)
        }
    }
}
