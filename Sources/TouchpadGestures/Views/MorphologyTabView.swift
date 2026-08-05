import SwiftUI
import GestureEngine

/// 形态识别 tab（v10.21 新增一级菜单）：集中手指/手掌/触摸阶段识别设置。
/// - 手指识别：接触面积有效范围（touchSizeMin/Max）——过滤过轻误触与重压/手掌
/// - 手掌识别：palmFilter 开关——关闭后重压/手掌也进入识别（可能误触发）
/// - 触摸阶段参考：MTTouch state 字段说明（只读）
struct MorphologyTabView: View {
    @Binding var config: AppConfig

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                fingerCard
                palmCard
                stateRefCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - 手指识别

    private var fingerCard: some View {
        Card(title: L10n.tr("手指识别", "Finger Recognition")) {
            HStack {
                Text(L10n.tr("接触面积下限", "Touch Size Min")).frame(width: 150, alignment: .leading)
                Slider(value: $config.global.touchSizeMin, in: 0...0.5)
                Text(String(format: "%.2f", config.global.touchSizeMin))
                    .monospacedDigit().frame(width: 50, alignment: .trailing)
            }
            HStack {
                Text(L10n.tr("接触面积上限", "Touch Size Max")).frame(width: 150, alignment: .leading)
                Slider(value: $config.global.touchSizeMax, in: 0.5...2.0)
                Text(String(format: "%.2f", config.global.touchSizeMax))
                    .monospacedDigit().frame(width: 50, alignment: .trailing)
            }
            Text(L10n.tr("接触面积（size）~0.3 轻触 → ~1.35 重按。下限过滤过轻的悬停/误触，上限过滤手掌（手掌通常 >1.0）。",
                         "size ≈ 0.3 light touch → ~1.35 firm press. Min filters hover/light touches, Max filters palm (>1.0)."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - 手掌识别

    private var palmCard: some View {
        Card(title: L10n.tr("手掌识别", "Palm Recognition")) {
            HStack {
                Text(L10n.tr("手掌过滤", "Palm Filter")).frame(width: 150, alignment: .leading)
                Toggle("", isOn: $config.global.palmFilter)
                    .labelsHidden()
                    .toggleStyle(.switch)
                Text(config.global.palmFilter
                     ? L10n.tr("已启用（接触面积超过上限即视为手掌，不参与手指识别）", "On (size over Max is treated as palm, excluded from finger recognition)")
                     : L10n.tr("已关闭（重压/手掌也会进入识别，可能误触发）", "Off (firm press & palm also enter recognition, may misfire)"))
                    .font(.caption)
                    .foregroundStyle(config.global.palmFilter ? Color.secondary : Color.red)
                Spacer()
            }
        }
    }

    // MARK: - 触摸阶段参考（MTTouch.state）

    private var stateRefCard: some View {
        Card(title: L10n.tr("触摸阶段识别", "Touch State Reference")) {
            ForEach([
                (0, "none", L10n.tr("无接触", "No touch")),
                (1, "start", L10n.tr("首次接触", "First contact")),
                (2, "hover", L10n.tr("悬停（未接触）", "Hover (not touching)")),
                (3, "make", L10n.tr("接触瞬间", "Contact moment")),
                (4, "touch", L10n.tr("持续接触", "Sustained touch")),
                (5, "press", L10n.tr("Force Touch 阈值越过", "Force Touch threshold crossed")),
                (6, "tap", L10n.tr("短暂点击", "Brief tap")),
                (7, "lift", L10n.tr("手指离开", "Finger lifted")),
            ], id: \.0) { id, name, desc in
                HStack(spacing: 8) {
                    Text("\(id)").monospacedDigit().frame(width: 24, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Text(name).monospaced().frame(width: 60, alignment: .leading)
                    Text(desc).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            Text(L10n.tr("识别状态：手指离开触控板（state 0/7）才判定抬起；区域内 + 尺寸有效（手指识别范围）才判定按下。",
                         "Lift is determined by 'no finger on trackpad' (state 0/7); press by 'in region + size valid'."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 形态识别（无二级 tab，同 SettingsDetail 模式）
struct MorphologyDetail: View {
    @EnvironmentObject var appDelegate: AppDelegate

    var body: some View {
        MorphologyTabView(config: $appDelegate.config)
    }
}
