import SwiftUI
// 显式导入：消除与 Foundation.Comparator 的同名歧义
import enum GestureEngine.Comparator
import GestureEngine

/// 节点卡片内联参数编辑器：按字段类型生成控件（数值/开关/文本/枚举/绑定 UUID），写入用 NodeParams.setting
/// 布局：每个参数一行（label 在上、控件在下），适配 170pt 窄卡片
/// Predicate 等复合类型暂只读展示
struct NodeParamsEditorView: View {
    @Binding var params: NodeParams
    let nodeType: NodeType
    /// 绑定可选项（region/event 节点的 Picker 数据源）
    let events: [EventConfig]
    let regions: [RegionConfig]
    /// 自定义波形库（waveform 行的自定义选择器数据源）
    var customWaveforms: [CustomWaveform] = []

    /// 参与渲染的参数行：
    /// - 隐藏 customWaveformID（由 waveform 行统一呈现，避免重复一行）
    /// - haptic 节点始终补一行 waveform：即使未设置（新建空节点）也给出
    ///   「预设/自定义 + 预览」入口，否则用户无从配置
    private var displayRows: [(String, Any)] {
        var rows = params.typedRows.filter { $0.0 != "customWaveformID" }
        if nodeType == .haptic && !rows.contains(where: { $0.0 == "waveform" }) {
            rows.insert(("waveform", Int32(params.waveform ?? 2)), at: 0)
        }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            let rows = displayRows
            if rows.isEmpty {
                Text(L10n.tr("（无参数）", "(no params)"))
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(rows, id: \.0) { key, value in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key)
                            .font(.system(size: 9)).monospaced()
                            .foregroundStyle(.tertiary)
                        control(key: key, value: value)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func control(key: String, value: Any) -> some View {
        switch value {
        case let v as Float:      floatField(key: key, value: v)
        case let v as Double:     doubleField(key: key, value: v)
        case let v as Int32:
            if key == "waveform" {
                // 波形选择：预设 / 自定义 + 缩略预览
                WaveformPickerRow(
                    presetID: Binding(
                        get: { v },
                        set: { params = params.setting(key: key, $0) }
                    ),
                    customWaveformID: Binding(
                        get: { params.customWaveformID },
                        set: { params.customWaveformID = $0 }
                    ),
                    customWaveforms: customWaveforms,
                    compact: true)
            } else {
                int32Stepper(key: key, value: v)
            }
        case let v as Int:        intStepper(key: key, value: v)
        case let v as Bool:       boolToggle(key: key, value: v)
        case let v as String:     stringField(key: key, value: v)
        case let v as UUID:
            if key == "customWaveformID" {
                // 已由 waveform 行统一呈现，避免重复一行
                EmptyView()
            } else {
                uuidPicker(key: key, value: v)
            }
        case let v as SignalSource:   enumPicker(key: key, value: v, allCases: SignalSource.allCases) { $0.displayName }
        case let v as TransformMode:  enumPicker(key: key, value: v, allCases: TransformMode.allCases) { $0.displayName }
        case let v as TriggerMode:    enumPicker(key: key, value: v, allCases: TriggerMode.allCases) { $0.displayName }
        case let v as Comparator:     enumPicker(key: key, value: v, allCases: Comparator.allCases) { $0.symbol }
        case let v as MouseMode:      enumPicker(key: key, value: v, allCases: MouseMode.allCases) { $0.rawValue }
        case let v as UnfreezeMode:   enumPicker(key: key, value: v, allCases: UnfreezeMode.allCases) { $0.rawValue }
        case let v as MergeMode:      enumPicker(key: key, value: v, allCases: MergeMode.allCases) { $0.rawValue }
        case let v as ActionType:     enumPicker(key: key, value: v, allCases: ActionType.allCases) { $0.displayName }
        case let v as ExecutionMethod: enumPicker(key: key, value: v, allCases: ExecutionMethod.allCases) { $0.displayName }
        case let v as TriggerEvent:   enumPicker(key: key, value: v, allCases: TriggerEvent.allCases) { $0.displayName }
        default:
            // Predicate 等复合类型：只读展示
            Text(String(describing: value))
                .font(.caption.monospaced())
                .lineLimit(1)
        }
    }

    // MARK: - 绑定 UUID（region/event 节点 → 名称 Picker）

    @ViewBuilder
    private func uuidPicker(key: String, value: UUID) -> some View {
        if key == "eventID", !events.isEmpty {
            Picker("", selection: Binding(
                get: { value },
                set: { params = params.setting(key: key, $0) }
            )) {
                ForEach(events) { event in
                    Text(event.name).tag(event.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.mini)
        } else if key == "regionID", !regions.isEmpty {
            Picker("", selection: Binding(
                get: { value },
                set: { params = params.setting(key: key, $0) }
            )) {
                ForEach(regions) { region in
                    Text(region.name).tag(region.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.mini)
        } else {
            Text(String(describing: value))
                .font(.caption.monospaced())
                .lineLimit(1)
        }
    }

    // MARK: - 数值

    private func floatField(key: String, value: Float) -> some View {
        TextField("", text: Binding(
            get: { String(value) },
            set: { if let v = Float($0) { params = params.setting(key: key, v) } }
        ))
        .textFieldStyle(.roundedBorder)
        .font(.caption.monospacedDigit())
        .frame(width: 90)
        .multilineTextAlignment(.trailing)
    }

    private func doubleField(key: String, value: Double) -> some View {
        TextField("", text: Binding(
            get: { String(value) },
            set: { if let v = Double($0) { params = params.setting(key: key, v) } }
        ))
        .textFieldStyle(.roundedBorder)
        .font(.caption.monospacedDigit())
        .frame(width: 90)
        .multilineTextAlignment(.trailing)
    }

    private func int32Stepper(key: String, value: Int32) -> some View {
        Stepper(value: Binding(
            get: { Int(value) },
            set: { params = params.setting(key: key, Int32($0)) }
        ), in: -10000...10000) {
            Text("\(value)").font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
        }
        .fixedSize()
    }

    private func intStepper(key: String, value: Int) -> some View {
        Stepper(value: Binding(
            get: { value },
            set: { params = params.setting(key: key, $0) }
        ), in: 0...100) {
            Text("\(value)").font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
        }
        .fixedSize()
    }

    // MARK: - 开关 / 文本

    private func boolToggle(key: String, value: Bool) -> some View {
        Toggle("", isOn: Binding(
            get: { value },
            set: { params = params.setting(key: key, $0) }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
    }

    private func stringField(key: String, value: String) -> some View {
        TextField("", text: Binding(
            get: { value },
            set: { params = params.setting(key: key, $0) }
        ))
        .textFieldStyle(.roundedBorder)
        .font(.caption)
        .frame(width: 120)
    }

    // MARK: - 枚举

    private func enumPicker<T: Hashable>(key: String, value: T, allCases: [T],
                                         label: @escaping (T) -> String) -> some View {
        Picker("", selection: Binding(
            get: { value },
            set: { params = params.setting(key: key, $0) }
        )) {
            ForEach(allCases, id: \.self) { item in
                Text(label(item)).tag(item)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.mini)
    }
}
