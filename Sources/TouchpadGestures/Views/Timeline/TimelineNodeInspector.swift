import SwiftUI
import GestureEngine

// MARK: - NodeType 视觉映射（icon + 颜色）

extension NodeType {
    /// SF Symbol 图标（按功能大类分组）
    var symbolName: String {
        switch self {
        case .signal:     return "waveform.path.ecg"
        case .value:      return "number"
        case .transform:  return "arrow.triangle.2.circlepath"
        case .scale:      return "arrow.up.left.and.arrow.down.right"
        case .clamp:      return "rectangle.compress.vertical"
        case .abs:        return "abs"
        case .sign:       return "plus.forwardslash.minus"
        case .quantize:   return "slider.horizontal.3"
        case .gate:       return "arrow.turn.down.right"
        case .debounce:   return "timer"
        case .branch:     return "point.topleft.down.to.point.bottomright.curvepath"
        case .`switch`:   return "arrow.triangle.branch"
        case .consume:    return "speaker.wave.2"
        case .haptic:     return "iphone.radiowaves.left.and.right"
        case .hud:        return "rectangle.inset.filled.and.person.filled"
        case .mouse:      return "cursorarrow.motionlines"
        case .freeze:     return "snowflake"
        case .notify:     return "bell"
        case .split:      return "arrow.branch"
        case .merge:      return "arrow.merge"
        case .baseline:   return "bookmark"
        case .state:      return "internaldrive"
        }
    }

    /// 大类配色
    var tintColor: Color {
        switch self {
        case .signal, .value:                       return .blue
        case .transform, .scale, .clamp, .abs, .sign: return .purple
        case .quantize, .gate, .debounce:           return .orange
        case .branch, .`switch`:                    return .red
        case .consume, .haptic, .hud, .mouse, .freeze, .notify: return .green
        case .split, .merge, .baseline, .state:     return .teal
        }
    }
}

// MARK: - 节点属性摘要

extension NodeConfig {
    /// 单行参数摘要（如 "source=normY · step=0.02"）
    var paramsSummary: String {
        let rows = params.nonNilRows
        if rows.isEmpty { return "—" }
        return rows.map { "\($0.0)=\($0.1)" }.joined(separator: " · ")
    }
}

extension NodeParams {
    /// 用 Mirror 遍历出所有非 nil 参数（key=值 文本）
    var nonNilRows: [(String, String)] {
        Mirror(reflecting: self).children.compactMap { label, value in
            guard let label else { return nil }
            let mirror = Mirror(reflecting: value)
            // Optional 为空（nil）→ 跳过
            if mirror.displayStyle == .optional, mirror.children.isEmpty { return nil }
            return (label, String(describing: value))
        }
    }
}

// MARK: - 节点属性面板（只读展示全部已设置参数）

/// 选中节点的 Inspector：类型、标题、全部参数、端口
struct TimelineNodeInspector: View {
    let node: NodeConfig
    /// 该节点在图中实际用到的端口（由边推断）
    let usedPorts: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 标题行
            HStack(spacing: 6) {
                Image(systemName: node.type.symbolName)
                    .foregroundStyle(node.type.tintColor)
                Text(node.title ?? node.type.displayName)
                    .font(.subheadline.bold())
                Text(node.type.displayName)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }

            // 参数列表
            let rows = node.params.nonNilRows
            if rows.isEmpty {
                Text(L10n.tr("（无参数）", "(no params)"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(rows, id: \.0) { key, value in
                    HStack(alignment: .top, spacing: 6) {
                        Text(key)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        Text(value)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                    }
                }
            }

            // 端口（非空时展示）
            if !usedPorts.isEmpty {
                HStack(spacing: 6) {
                    Text(L10n.tr("端口", "Ports"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(usedPorts.sorted().joined(separator: ", "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.04)))
    }
}
