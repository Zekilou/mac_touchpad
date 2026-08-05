import SwiftUI
import GestureEngine

/// 模块节点内联编辑器（选中展开）：用途备注 + 输入/输出端口管理 + 进入内部子图
/// 端口 = 模块对外的统一接口（折叠后只显示这些口子；内部用连接器节点对应）
struct ModuleEditorView: View {
    @Binding var params: NodeParams
    /// 进入内部子图画布
    let onOpenModule: () -> Void

    /// 端口名可选类型（模块接口常用）
    private let portTypes: [SocketType] = [.float, .bool, .int, .unit, .output, .generic]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 用途备注
            HStack(spacing: 4) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField(L10n.tr("用途备注", "Note"), text: noteBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10))
                    .help(L10n.tr("折叠后显示的用途说明", "Shown when collapsed"))
            }
            // 输入端口
            modulePortSection(title: L10n.tr("输入", "Inputs"), isInput: true)
            // 输出端口
            modulePortSection(title: L10n.tr("输出", "Outputs"), isInput: false)
            // 进入内部
            Button {
                onOpenModule()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 10))
                    Text(L10n.tr("打开内部…", "Open inside…"))
                        .font(.system(size: 10).bold())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.tr("编辑模块内部节点（双击模块也可）", "Edit inner nodes (double-click module too)"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// 端口编辑区：名称 + 类型 + 删除 + 添加
    private func modulePortSection(title: String, isInput: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: isInput ? "arrow.down.to.line" : "arrow.up.from.line")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 9).bold())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    addPort(isInput: isInput)
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L10n.tr("添加端口", "Add port"))
            }
            ForEach(portList(isInput: isInput).indices, id: \.self) { i in
                portRow(index: i, isInput: isInput)
            }
        }
    }

    /// 单端口行：名称 TextField + 类型 Picker + （输入端口）写类开关 + 删除
    private func portRow(index: Int, isInput: Bool) -> some View {
        HStack(spacing: 4) {
            TextField("port", text: portNameBinding(index: index, isInput: isInput))
                .textFieldStyle(.plain)
                .font(.system(size: 10))
                .frame(width: 60)
            Picker("", selection: portTypeBinding(index: index, isInput: isInput)) {
                ForEach(portTypes, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 48)
            .font(.system(size: 9))
            if isInput {
                Toggle("", isOn: isWriteBinding(index: index))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help(L10n.tr("写类端口：进入该口的连线按帧尾写处理（避免跨模块环）",
                                  "Write port: incoming edge treated as frame-end write"))
            }
            Button {
                removePort(index: index, isInput: isInput)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.red.opacity(0.8))
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Binding

    private var noteBinding: Binding<String> {
        Binding(get: { params.note ?? "" },
                set: { params.note = $0.isEmpty ? nil : $0 })
    }

    private func portList(isInput: Bool) -> [ModulePort] {
        isInput ? (params.moduleInputs ?? []) : (params.moduleOutputs ?? [])
    }

    private func portNameBinding(index: Int, isInput: Bool) -> Binding<String> {
        Binding(
            get: { portList(isInput: isInput)[index].name },
            set: { name in
                if isInput {
                    params.moduleInputs?[index].name = name
                } else {
                    params.moduleOutputs?[index].name = name
                }
            }
        )
    }

    private func portTypeBinding(index: Int, isInput: Bool) -> Binding<SocketType> {
        Binding(
            get: { portList(isInput: isInput)[index].type },
            set: { type in
                if isInput {
                    params.moduleInputs?[index].type = type
                } else {
                    params.moduleOutputs?[index].type = type
                }
            }
        )
    }

    private func isWriteBinding(index: Int) -> Binding<Bool> {
        Binding(
            get: { params.moduleInputs?[index].isWrite ?? false },
            set: { params.moduleInputs?[index].isWrite = $0 }
        )
    }

    private func addPort(isInput: Bool) {
        let n = portList(isInput: isInput).count
        let port = ModulePort(name: "port\(n)", type: .float)
        if isInput {
            params.moduleInputs = (params.moduleInputs ?? []) + [port]
        } else {
            params.moduleOutputs = (params.moduleOutputs ?? []) + [port]
        }
    }

    private func removePort(index: Int, isInput: Bool) {
        if isInput {
            params.moduleInputs?.remove(at: index)
        } else {
            params.moduleOutputs?.remove(at: index)
        }
    }
}
