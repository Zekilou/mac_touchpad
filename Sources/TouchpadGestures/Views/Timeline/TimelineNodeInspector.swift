import SwiftUI
import GestureEngine

// MARK: - NodeType 视觉映射（icon + 颜色）

/// 节点大类（右键菜单二级分栏/工具箱分组用）
enum NodeCategory: String, CaseIterable {
    case source, variable, finger, math, compare, quantize, branch, feedback, flow, other

    var displayName: String {
        switch self {
        case .source:   return L10n.tr("数据源", "Data Source")
        case .variable: return L10n.tr("变量", "Variable")
        case .finger:   return L10n.tr("手指", "Finger")
        case .math:     return L10n.tr("数学", "Math")
        case .compare:  return L10n.tr("比较/时间", "Compare / Time")
        case .quantize: return L10n.tr("量化/门控", "Quantize / Gate")
        case .branch:   return L10n.tr("分支", "Branch")
        case .feedback: return L10n.tr("反馈", "Feedback")
        case .flow:     return L10n.tr("流控制", "Flow")
        case .other:    return L10n.tr("其他", "Other")
        }
    }
}

extension NodeType {
    /// 大类归属（废弃/连接器/引用等归 .other；工具箱隐藏的类目本身不显示）
    var category: NodeCategory {
        switch self {
        case .touchData, .value, .boundaryState:    return .source
        case .varRef, .state:                   return .variable
        case .finger:                           return .finger
        case .transform, .scale, .clamp, .abs, .sign: return .math
        case .compare, .arith, .not, .now, .elapsed, .accumulate: return .compare
        case .quantize, .gate, .debounce:       return .quantize
        case .branch, .`switch`:                return .branch
        case .consume, .haptic, .hud, .notify:  return .feedback
        case .split, .merge, .baseline:         return .flow
        default:                                return .other
        }
    }

    /// SF Symbol 图标（按功能大类分组）
    var symbolName: String {
        switch self {
        case .pipeOut:    return "arrow.forward.circle"
        case .group:      return "square.dashed"
        case .touchData:  return "waveform.path.ecg"
        case .value:      return "number"
        case .boundaryState: return "rectangle.portrait.on.rectangle.portrait.angled"
        case .recognizer: return "hand.tap"
        case .varRef:     return "internaldrive"
        case .finger:     return "hand.point.up"
        case .region:     return "rectangle.dashed"
        case .event:      return "bolt.badge.a"
        case .transform:  return "arrow.triangle.2.circlepath"
        case .scale:      return "arrow.up.left.and.arrow.down.right"
        case .clamp:      return "rectangle.compress.vertical"
        case .abs:        return "abs"
        case .sign:       return "plus.forwardslash.minus"
        case .compare:    return "greaterthan"
        case .arith:      return "plusminus"
        case .not:        return "arrow.uturn.backward"
        case .now:        return "clock"
        case .elapsed:    return "timer"
        case .accumulate: return "sum"
        case .quantize:   return "slider.horizontal.3"
        case .gate:       return "arrow.turn.down.right"
        case .debounce:   return "timer"
        case .branch:     return "point.topleft.down.to.point.bottomright.curvepath"
        case .`switch`:   return "arrow.triangle.branch"
        case .set:        return "pencil.and.outline"
        case .toggle:     return "switch.2"
        case .module:     return "square.stack.3d.up"
        case .moduleInput:  return "arrow.down.to.line"
        case .moduleOutput: return "arrow.up.from.line"
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
        case .pipeOut:                              return .yellow
        case .group:                                return .gray
        case .touchData, .value, .boundaryState, .recognizer, .region, .event: return .blue
        case .varRef:                               return .indigo
        case .finger:                               return .cyan
        case .transform, .scale, .clamp, .abs, .sign: return .purple
        case .compare, .arith, .not, .now, .elapsed, .accumulate: return .pink
        case .quantize, .gate, .debounce:           return .orange
        case .branch, .`switch`:                    return .red
        case .set, .toggle:                         return .indigo
        case .module:                               return .brown
        case .moduleInput, .moduleOutput:           return .gray
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

    /// 类型化的非 nil 参数行（key + 原始类型值）——卡片内编辑器据此生成真实可编辑控件
    var typedRows: [(String, Any)] {
        Mirror(reflecting: self).children.compactMap { label, value in
            guard let label else { return nil }
            let mirror = Mirror(reflecting: value)
            // Optional：解包出真实值；nil 跳过
            if mirror.displayStyle == .optional {
                guard let child = mirror.children.first else { return nil }
                return (label, child.value)
            }
            return (label, value)
        }
    }
}
