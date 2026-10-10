import SwiftUI
import GestureEngine

// MARK: - 波形缩略预览（列表 / 选择器旁的小图）

/// 波形缩略图：以极简折线呈现波形轮廓。
///
/// 用途：所有需要"选择波形"的地方（预设 Stepper / 自定义波形 Picker /
/// 波形库列表 / 节点参数行）都在控件旁挂一张，让用户不必靠 ID 猜测手感。
///
/// - 采样点数固定 48（够平滑且开销极低，可在列表中大量渲染）
/// - 只画合成曲线：包络 × 音调，最接近实际触感
struct WaveformSparkline: View {
    let spec: WaveformSpec
    /// 按压力度档位（0=Light / 1=Medium / 2=Firm）
    var intensity: Int = 1
    var lineWidth: CGFloat = 1.2
    var showsBaseline: Bool = true

    private var samples: [Float] {
        WaveformPreview.data(for: spec, samples: 48, intensity: intensity).combined
    }

    var body: some View {
        GeometryReader { geo in
            let pts = samples
            ZStack {
                if showsBaseline {
                    // 零轴：让"纯正/纯负"的波形也有参照
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                        p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                    }
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                }
                if pts.count > 1 {
                    // 包络填充（上半部分的柔和区域，表达"力度"）
                    envelopeFill(pts: pts, size: geo.size)
                        .fill(Color.accentColor.opacity(0.16))
                    // 合成曲线主体
                    curvePath(pts: pts, size: geo.size)
                        .stroke(Color.accentColor,
                                style: StrokeStyle(lineWidth: lineWidth,
                                                   lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    /// 曲线路径：x 按采样序号均分，y 为振幅（中心为零轴）
    private func curvePath(pts: [Float], size: CGSize) -> Path {
        Path { p in
            let mid = size.height / 2
            let amp = size.height / 2 * 0.92
            for (i, v) in pts.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(pts.count - 1)
                let y = mid - CGFloat(v) * amp
                if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                else { p.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }

    /// 包络填充：从零轴到包络值的闭合区域
    private func envelopeFill(pts: [Float], size: CGSize) -> Path {
        Path { p in
            let mid = size.height / 2
            let amp = size.height / 2 * 0.92
            p.move(to: CGPoint(x: 0, y: mid))
            for (i, v) in pts.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(pts.count - 1)
                let y = mid - CGFloat(abs(v)) * amp
                p.addLine(to: CGPoint(x: x, y: y))
            }
            p.addLine(to: CGPoint(x: size.width, y: mid))
            p.closeSubpath()
        }
    }
}

// MARK: - 预设波形缩略图（带 ID 与名称）

/// 预设波形（1~16）的行内预览：左侧小图 + 右侧 ID。
struct WaveformPresetThumbnail: View {
    let presetID: Int32
    var width: CGFloat = 46
    var height: CGFloat = 20
    var showsID: Bool = true

    private var spec: WaveformSpec { WaveformPresetCatalog.spec(for: presetID) }

    var body: some View {
        HStack(spacing: 5) {
            WaveformSparkline(spec: spec, lineWidth: 1.1)
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
            if showsID {
                Text("\(presetID)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 自定义波形缩略图

/// 自定义波形行内预览：小图 + 名称（名称可截断）。
struct WaveformThumbnail: View {
    let name: String
    let spec: WaveformSpec
    var width: CGFloat = 46
    var height: CGFloat = 20
    var showsName: Bool = true

    var body: some View {
        HStack(spacing: 5) {
            WaveformSparkline(spec: spec, lineWidth: 1.1)
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
            if showsName {
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - 波形选择器（预设 / 自定义二选一）

/// 统一的波形选择控件：分段开关（预设 / 自定义）+ 对应选择器 + 缩略预览。
///
/// 被「基础设置」触觉卡片与画布节点参数面板共用，
/// 保证两处行为一致、且都带预览图。
struct WaveformPickerRow: View {
    /// 预设波形 ID
    @Binding var presetID: Int32
    /// 自定义波形引用（nil = 使用预设）
    @Binding var customWaveformID: UUID?
    /// 可选的自定义波形库
    let customWaveforms: [CustomWaveform]
    var labelWidth: CGFloat? = nil
    /// 紧凑模式（画布窄卡片用）
    var compact: Bool = false

    private var usesCustom: Binding<Bool> {
        Binding(
            get: { customWaveformID != nil },
            set: { isCustom in
                if isCustom {
                    // 打开自定义：默认选第一条（无库时保持 nil，UI 会提示去创建）
                    customWaveformID = customWaveforms.first?.id
                } else {
                    customWaveformID = nil
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Picker("", selection: usesCustom) {
                    Text(L10n.tr("预设", "Preset")).tag(false)
                    Text(L10n.tr("自定义", "Custom")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: compact ? 130 : 160)
                Spacer()
            }

            if customWaveformID != nil {
                if customWaveforms.isEmpty {
                    Text(L10n.tr("还没有自定义波形，请到「波形」页新建。",
                                 "No custom waveforms yet — create one in the Waveforms tab."))
                        .font(.caption2).foregroundStyle(.orange)
                        .lineLimit(2)
                } else {
                    HStack(spacing: 6) {
                        Picker("", selection: Binding(
                            get: { customWaveformID ?? customWaveforms.first!.id },
                            set: { customWaveformID = $0 }
                        )) {
                            ForEach(customWaveforms) { w in
                                Text(w.name).tag(w.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.mini)
                        Spacer()
                    }
                    // 选中自定义波形的缩略预览
                    if let selected = customWaveforms.first(where: { $0.id == customWaveformID }) {
                        WaveformThumbnail(name: selected.name, spec: selected.spec,
                                          width: compact ? 54 : 64)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Stepper(value: $presetID, in: 1...16) {
                        Text("\(presetID)").font(.caption.monospacedDigit())
                            .frame(width: 22, alignment: .trailing)
                    }
                    .fixedSize()
                    Text(WaveformPresetCatalog.displayName(presetID))
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                // 预设波形的缩略预览
                WaveformPresetThumbnail(presetID: presetID, width: compact ? 54 : 64,
                                        showsID: false)
            }
        }
    }
}
