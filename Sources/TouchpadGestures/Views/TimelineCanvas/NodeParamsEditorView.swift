import SwiftUI
// 显式导入：消除与 Foundation.Comparator 的同名歧义
import enum GestureEngine.Comparator
import GestureEngine

/// 可编辑节点参数面板：按字段类型生成控件（数值/开关/文本/枚举/绑定 UUID），写入用 NodeParams.setting
/// Predicate 等复合类型暂只读展示
struct NodeParamsEditorView: View {
    @Binding var params: NodeParams
    let nodeType: NodeType
    /// 绑定可选项（region/event 节点的 Picker 数据源）
    let events: [EventConfig]
    let regions: [RegionConfig]

    /// 波形手感描述（ID, 中文, 英文）——替代原波形对照卡片，直接显示在参数行
    private let waveformCatalog: [(Int32, String, String)] = [
        (1,  "弱 click",               "Weak click"),
        (2,  "强 click (Force Touch)", "Strong click (Force Touch)"),
        (3,  "buzz 震颤",               "Buzz"),
        (4,  "轻 tap",                 "Light tap"),
        (5,  "中 tap",                 "Medium tap"),
        (6,  "强 tap",                 "Strong tap"),
        (15, "软重击",                  "Soft hit"),
        (16, "强重击",                  "Strong hit"),
    ]

    private func waveformDescription(_ id: Int32) -> String {
        waveformCatalog.first { $0.0 == id }.map { L10n.tr($0.1, $0.2) } ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let rows = params.nonNilRows
            if rows.isEmpty {
                Text(L10n.tr("（无参数）", "(no params)"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(rows, id: \.0) { key, value in
                    paramRow(key: key, value: value)
                }
            }
        }
    }

    @ViewBuilder
    private func paramRow(key: String, value: Any) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Spacer(minLength: 4)
            control(key: key, value: value)
        }
    }

    @ViewBuilder
    private func control(key: String, value: Any) -> some View {
        switch value {
        case let v as Float:      floatField(key: key, value: v)
        case let v as Double:     doubleField(key: key, value: v)
        case let v as Int32:
            if key == "waveform" {
                HStack(spacing: 4) {
                    int32Stepper(key: key, value: v)
                    Text(waveformDescription(v))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                int32Stepper(key: key, value: v)
            }
        case let v as Int:        intStepper(key: key, value: v)
        case let v as Bool:       boolToggle(key: key, value: v)
        case let v as String:     stringField(key: key, value: v)
        case let v as UUID:       uuidPicker(key: key, value: v)
        case let v as SignalSource:   enumPicker(key: key, value: v, allCases: SignalSource.allCases) { $0.displayName }
        case let v as TransformMode:  enumPicker(key: key, value: v, allCases: TransformMode.allCases) { $0.displayName }
        case let v as TriggerMode:    enumPicker(key: key, value: v, allCases: TriggerMode.allCases) { $0.displayName }
        case let v as Comparator:     enumPicker(key: key, value: v, allCases: Comparator.allCases) { $0.symbol }
        case let v as MouseMode:      enumPicker(key: key, value: v, allCases: MouseMode.allCases) { $0.rawValue }
        case let v as UnfreezeMode:   enumPicker(key: key, value: v, allCases: UnfreezeMode.allCases) { $0.rawValue }
        case let v as MergeMode:      enumPicker(key: key, value: v, allCases: MergeMode.allCases) { $0.rawValue }
        case let v as ActionType:     enumPicker(key: key, value: v, allCases: ActionType.allCases) { $0.displayName }
        case let v as ExecutionMethod: enumPicker(key: key, value: v, allCases: ExecutionMethod.allCases) { $0.displayName }
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
