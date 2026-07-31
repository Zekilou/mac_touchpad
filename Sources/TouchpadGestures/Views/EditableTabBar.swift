import SwiftUI

/// 可编辑二级 tab 条：显示 tab 名 + 编辑模式下增删/重命名
/// 通用组件，手势/事件/区域 tab 共用
struct EditableTabBar<T: Identifiable & Hashable>: View where T.ID == UUID {
    let items: [T]
    @Binding var selection: UUID?
    let nameKeyPath: KeyPath<T, String>
    @Binding var isEditing: Bool
    let onAdd: () -> Void
    let onDelete: (T) -> Void
    let onRename: (T, String) -> Void
    let canDelete: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { item in
                TabChip(
                    name: item[keyPath: nameKeyPath],
                    isSelected: selection == item.id,
                    isEditing: isEditing,
                    canDelete: canDelete,
                    onSelect: { selection = item.id },
                    onDelete: { onDelete(item) },
                    onRename: { newName in onRename(item, newName) }
                )
            }
            if isEditing {
                Button(action: onAdd) {
                    Image(systemName: "plus.circle")
                        .imageScale(.medium)
                }
                .buttonStyle(.borderless)
                .help(L10n.tr("新增", "Add"))
            }
            Spacer()
            Button(isEditing ? L10n.tr("完成", "Done") : L10n.tr("编辑", "Edit")) {
                isEditing.toggle()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

private struct TabChip: View {
    let name: String
    let isSelected: Bool
    let isEditing: Bool
    let canDelete: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onRename: (String) -> Void

    @State private var isRenaming = false
    @State private var renameText = ""

    var body: some View {
        if isRenaming {
            TextField("", text: $renameText, onCommit: {
                if !renameText.isEmpty { onRename(renameText) }
                isRenaming = false
            })
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
        } else {
            HStack(spacing: 2) {
                Text(name)
                    .onTapGesture(count: 2) {
                        if isEditing {
                            renameText = name
                            isRenaming = true
                        }
                    }
                if isEditing && canDelete {
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .imageScale(.small)
                            .foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 0.5)
            )
            .onTapGesture { onSelect() }
        }
    }
}
