import SwiftUI
import GestureEngine

/// 触觉波形对照表
struct HapticWaveformReference: View {
    let gesture: GestureConfig

    private let waveforms: [(Int32, String, String)] = [
        (1,  "弱 click",              "Weak click"),
        (2,  "强 click (Force Touch)", "Strong click (Force Touch)"),
        (3,  "buzz 震颤",              "Buzz"),
        (4,  "轻 tap",                "Light tap"),
        (5,  "中 tap",                "Medium tap"),
        (6,  "强 tap",                "Strong tap"),
        (15, "软重击",                 "Soft hit"),
        (16, "强重击",                 "Strong hit"),
    ]

    private func usageLabel(id: Int32) -> String {
        var usages: [String] = []
        if gesture.hapticEnter == id    { usages.append(L10n.tr("进入反馈", "Enter")) }
        if gesture.hapticTick == id     { usages.append(L10n.tr("滑动刻度", "Tick")) }
        if gesture.hapticBoundary == id { usages.append(L10n.tr("边界震动", "Boundary")) }
        return usages.isEmpty ? "—" : usages.joined(separator: " / ")
    }

    var body: some View {
        HStack {
            Text(L10n.tr("ID", "ID")).frame(width: 40, alignment: .leading)
            Text(L10n.tr("触感", "Sensation")).frame(width: 150, alignment: .leading)
            Text(L10n.tr("本项目用途", "Used For")).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

        ForEach(waveforms, id: \.0) { item in
            HStack {
                Text("\(item.0)").monospacedDigit().frame(width: 40, alignment: .leading)
                Text(L10n.tr(item.1, item.2)).frame(width: 150, alignment: .leading)
                Text(usageLabel(id: item.0))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
