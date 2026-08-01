import SwiftUI
import GestureEngine

// MARK: - NodeType 视觉映射（icon + 颜色）

extension NodeType {
    /// SF Symbol 图标（按功能大类分组）
    var symbolName: String {
        switch self {
        case .pipeOut:    return "arrow.forward.circle"
        case .group:      return "square.dashed"
        case .touchData:  return "waveform.path.ecg"
        case .value:      return "number"
        case .recognizer: return "hand.tap"
        case .region:     return "rectangle.dashed"
        case .event:      return "bolt.badge.a"
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
        case .pipeOut:                              return .yellow
        case .group:                                return .gray
        case .touchData, .value, .recognizer, .region, .event: return .blue
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
